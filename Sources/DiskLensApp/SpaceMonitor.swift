import DiskLensCore
import Foundation
import Observation
import UserNotifications

/// Keeps an eye on the startup disk for the menu bar: free space every minute,
/// today's change from the background agent's records, and notifications when
/// space runs low or grows unusually fast.
@MainActor @Observable
final class SpaceMonitor {
    enum Keys {
        static let menuBar = "menubar.enabled"
        static let lowSpaceAlerts = "alerts.lowSpace"
        static let lowSpaceThreshold = "alerts.lowSpaceThresholdGB"
        static let growthAlerts = "alerts.fastGrowth"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.menuBar: true,
            Keys.lowSpaceAlerts: true,
            Keys.lowSpaceThreshold: 20,
            Keys.growthAlerts: true,
        ])
    }

    private(set) var volume: VolumeInfo?
    /// Change in used space since local midnight, when the agent has records for today.
    private(set) var todayChange: Int64?
    private(set) var todaySources: [ActivityStore.WriteTotal] = []

    /// Growth of this size within `growthWindow` counts as unusual.
    static let growthLimit: Int64 = 5_000_000_000
    static let growthWindow: TimeInterval = 3_600

    @ObservationIgnored private var samples: [(date: Date, used: Int64)] = []
    @ObservationIgnored private var lastLowSpaceAlert = Date.distantPast
    @ObservationIgnored private var lastGrowthAlert = Date.distantPast
    @ObservationIgnored private var started = false

    /// Free space for the menu bar, e.g. "211 GB".
    var menuBarTitle: String {
        volume.map { ByteFormat.string($0.availableForImportantUsage) } ?? "DiskLens"
    }

    /// Free space is under the warning threshold.
    var isLow: Bool {
        guard let volume else { return false }
        let threshold = Int64(UserDefaults.standard.integer(forKey: Keys.lowSpaceThreshold)) * 1_000_000_000
        return volume.availableForImportantUsage < threshold
    }

    func start() {
        guard !started else { return }
        started = true
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Keys.lowSpaceAlerts) || defaults.bool(forKey: Keys.growthAlerts) {
            Self.requestNotificationPermission()
        }
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh() async {
        volume = VolumeInfo(path: "/")
        let midnight = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let now = Int64(Date().timeIntervalSince1970)
        let (change, sources) = await Task.detached(priority: .utility) { () -> (Int64?, [ActivityStore.WriteTotal]) in
            guard let store = try? ActivityStore() else { return (nil, []) }
            let points = store.volumeSeries(from: midnight, to: now + 60, bucket: 86_400 * 2)
            let change = points.isEmpty ? nil : points.reduce(Int64(0)) { $0 + $1.change }
            return (change, store.growthByOwner(from: midnight, to: now + 60, limit: 3).filter { $0.bytes > 0 })
        }.value
        todayChange = change
        todaySources = sources
        if let volume { checkAlerts(volume) }
    }

    // MARK: Notifications

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkAlerts(_ volume: VolumeInfo) {
        let defaults = UserDefaults.standard
        let now = Date()

        let threshold = Int64(defaults.integer(forKey: Keys.lowSpaceThreshold)) * 1_000_000_000
        // Purgeable space is free in practice: macOS releases it on demand.
        let free = volume.availableForImportantUsage
        if defaults.bool(forKey: Keys.lowSpaceAlerts), free < threshold,
           now.timeIntervalSince(lastLowSpaceAlert) > 6 * 3_600 {
            lastLowSpaceAlert = now
            post(title: "磁盘空间不足",
                 body: "“\(volume.name)”只剩 \(ByteFormat.string(free))。打开 DiskLens 看看哪些可以清理。")
        }

        samples.append((now, volume.used))
        samples.removeAll { now.timeIntervalSince($0.date) > Self.growthWindow }
        if defaults.bool(forKey: Keys.growthAlerts), let oldest = samples.first,
           volume.used - oldest.used >= Self.growthLimit, now.timeIntervalSince(lastGrowthAlert) > 3 * 3_600 {
            lastGrowthAlert = now
            let grown = volume.used - oldest.used
            let start = Int64(oldest.date.timeIntervalSince1970)
            Task {
                let top = await Task.detached { (try? ActivityStore())?.growthByOwner(from: start, to: Int64(now.timeIntervalSince1970) + 60, limit: 1).first }.value
                let source = top.map { "，主要来自“\($0.app)”（\($0.bytes.signedBytes)）" } ?? ""
                post(title: "磁盘占用增长很快",
                     body: "过去一小时内多用了 \(ByteFormat.string(grown))\(source)。")
            }
        }
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
