import Darwin
import DiskLensCore
import Foundation
import os

/// DiskLens's background agent, started by launchd as a login item. Every 10 s
/// it samples how much each app wrote; every minute it stores those totals,
/// the growth of folders that changed, and the volume's used space.
final class Agent: @unchecked Sendable {
    private let log = Logger(subsystem: "app.disklens.DiskLens", category: "agent")
    private let queue = DispatchQueue(label: "app.disklens.DiskLens.agent")
    private let store: ActivityStore
    private let sampler = WriteSampler()
    private let tracker: FolderGrowthTracker
    private let home = NSHomeDirectory()
    private var timers: [DispatchSourceTimer] = []
    private var termination: DispatchSourceSignal?
    // Touched only on `queue`.
    private var writes: [String: Int64] = [:]
    private var lastPrune = Date.distantPast

    /// Records are kept this long.
    private static let retention: TimeInterval = 90 * 86_400

    init() throws {
        store = try ActivityStore()
        // Our own database and caches would otherwise show up as growth every minute.
        tracker = FolderGrowthTracker(
            root: home,
            excluding: [ActivityStore.defaultURL.deletingLastPathComponent().path, ScanCache.standard.directory.path],
            queue: queue)
    }

    func start() {
        queue.async { [self] in
            _ = sampler.sample()  // baseline
            tracker.start()
            recordVolume(minute: FolderGrowthTracker.minute())
            reportAccess()
        }
        timers.append(repeating(every: 10) { [self] in
            for (app, bytes) in sampler.sample() { writes[app, default: 0] += bytes }
        })
        timers.append(repeating(every: 60) { [self] in flush() })
        log.info("agent started for \(self.home, privacy: .public)")
    }

    /// Stores the last minute's totals. Runs on `queue`.
    func flush() {
        let minute = FolderGrowthTracker.minute() - 60
        do {
            try store.addWrites(writes, minute: minute)
            writes = [:]
            try store.addGrowth(tracker.takeChanges(), minute: minute)
            recordVolume(minute: minute)
            if minute % 600 == 0 { reportAccess() }
            if Date().timeIntervalSince(lastPrune) > 86_400 {
                try store.prune(before: Int64(Date().timeIntervalSince1970 - Self.retention))
                lastPrune = Date()
            }
        } catch {
            log.error("could not store activity: \(String(describing: error), privacy: .public)")
        }
    }

    /// Keeps the last partial minute when launchd stops us (logout, or recording turned off).
    func flushAndExitOnTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler { [self] in
            tracker.stop()
            flush()
            exit(0)
        }
        source.resume()
        termination = source
    }

    /// Tells the app whether the agent itself can read protected folders; macOS
    /// may grant Full Disk Access to it separately from the app.
    private func reportAccess() {
        try? store.setMeta(Agent.accessKey, FullDiskAccess.status(home: home).rawValue)
    }

    static let accessKey = "agent.fullDiskAccess"

    private func recordVolume(minute: Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: home).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return }
        try? store.recordVolume(used: Int64(total) - available, available: available, minute: minute)
    }

    private func repeating(every seconds: Int, _ work: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway lets the system batch our wakeups with others.
        timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds), leeway: .seconds(2))
        timer.setEventHandler(handler: work)
        timer.resume()
        return timer
    }
}

// Background priority: throttled CPU and disk I/O, so recording never gets in the way.
setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)

let agent: Agent
do {
    agent = try Agent()
} catch {
    Logger(subsystem: "app.disklens.DiskLens", category: "agent")
        .fault("cannot open the activity database: \(String(describing: error), privacy: .public)")
    exit(1)
}
agent.start()
agent.flushAndExitOnTermination()

dispatchMain()
