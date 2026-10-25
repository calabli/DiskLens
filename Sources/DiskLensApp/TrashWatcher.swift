import AppKit
import DiskLensCore
import Observation
import SwiftUI
import UserNotifications
import os

/// Notices apps dragged into the Trash and offers to clean up the data they
/// leave behind, the way dedicated uninstallers do.
@MainActor @Observable
final class TrashWatcher {
    /// Leftovers of an app just moved to the Trash, waiting for the user.
    var pending: AppFootprint?
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var known = Set<String>()
    private let trash = NSHomeDirectory() + "/.Trash"

    /// Leftovers smaller than this are not worth interrupting for.
    nonisolated private static let minimumLeftovers: Int64 = 1_000_000

    func start() {
        guard source == nil else { return }
        let fd = open(trash, O_EVTONLY)
        guard fd >= 0 else {
            // Needs Full Disk Access; started again once it is granted.
            Logger(subsystem: "app.disklens.DiskLens", category: "trash")
                .notice("cannot watch the Trash: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        Logger(subsystem: "app.disklens.DiskLens", category: "trash").notice("watching the Trash")
        known = Set(contents())
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.trashChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func contents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? []
    }

    private func trashChanged() {
        let now = Set(contents())
        let added = now.subtracting(known).filter { $0.hasSuffix(".app") }
        known = now
        for name in added {
            let path = trash + "/" + name
            Task { await inspect(path) }
        }
    }

    private func inspect(_ path: String) async {
        let footprint = await Task.detached(priority: .utility) { () -> AppFootprint? in
            guard let app = InstalledApp(path: path) else { return nil }
            let installed = AppCatalog.installedApps()
            // Still installed elsewhere (a duplicate copy was trashed): nothing is left over.
            if installed.contains(where: { $0.bundleID == app.bundleID }) { return nil }
            var finder = AppFootprintFinder(installed: installed + [app])
            finder.includeInstallerReceipts = false
            let footprint = finder.footprint(of: app)
            let leftovers = AppFootprint(app: app, files: footprint.files.filter { $0.kind != .app })
            return leftovers.dataSize >= TrashWatcher.minimumLeftovers ? leftovers : nil
        }.value
        guard let footprint else { return }
        pending = footprint
        if !NSApp.isActive { notify(footprint) }
    }

    private func notify(_ footprint: AppFootprint) {
        let content = UNMutableNotificationContent()
        content.title = "\(footprint.app.name) 还留下了 \(ByteFormat.string(footprint.dataSize)) 数据"
        content.body = "应用已移到废纸篓，但它的缓存、设置和数据还在。打开 DiskLens 一起清理。"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// The offer shown after an app went to the Trash.
struct LeftoversSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let footprint: AppFootprint
    @State private var choices: [String: Bool] = [:]

    private func isChosen(_ file: AppFile) -> Bool {
        !file.requiresAdmin && (choices[file.path] ?? (file.confidence == .certain))
    }

    var body: some View {
        let chosen = footprint.files.filter(isChosen)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: footprint.app.path))
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(footprint.app.name) 已移到废纸篓")
                        .font(.title3.weight(.semibold))
                    Text("它还在资源库里留下了 \(ByteFormat.string(footprint.dataSize)) 的数据和设置。")
                        .foregroundStyle(.secondary)
                }
            }
            List(footprint.files.filter { !$0.requiresAdmin }) { file in
                HStack {
                    Toggle("", isOn: Binding(get: { isChosen(file) }, set: { choices[file.path] = $0 }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text((file.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text("\(file.kind.title) · \(file.reason)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ByteFormat.string(file.size)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(height: min(CGFloat(footprint.files.count) * 46 + 20, 300))
            HStack {
                Button("保留") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("加入收集筐（\(ByteFormat.string(chosen.reduce(0) { $0 + $1.size }))）") {
                    chosen.forEach { model.addToBasket(path: $0.path, size: $0.size) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

/// Identifiable wrapper so the leftovers can drive `.sheet(item:)`.
struct PendingLeftovers: Identifiable {
    let footprint: AppFootprint
    var id: String { footprint.app.path }
}
