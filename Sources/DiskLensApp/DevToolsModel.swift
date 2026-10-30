import DiskLensCore
import Foundation
import Observation

/// The installed developer tools, found one ecosystem at a time, and running
/// a tool's own command to remove one of them.
@MainActor @Observable
final class DevToolsModel {
    private(set) var groups: [DevEcosystem: DevGroup] = [:]
    private(set) var loading: Set<DevEcosystem> = []
    /// The item whose command is running, and what it printed when done.
    private(set) var running: DevItem.ID?
    private(set) var lastRun: RunResult?
    /// The scan generation the groups were last found for.
    @ObservationIgnored private var loadedForTree: Int?

    struct RunResult: Identifiable {
        let id = UUID()
        let item: DevItem
        let command: ToolCommand
        let succeeded: Bool
        let output: String
    }

    var isLoading: Bool { !loading.isEmpty }

    /// Looks at every ecosystem, unless it already did so for this scan.
    func refreshIfNeeded(tree: FileTree?, generation: Int) {
        guard loadedForTree != generation || groups.isEmpty else { return }
        loadedForTree = generation
        refresh(tree: tree)
    }

    func refresh(tree: FileTree?, only ecosystems: [DevEcosystem] = DevEcosystem.allCases) {
        for ecosystem in ecosystems where !loading.contains(ecosystem) {
            loading.insert(ecosystem)
            Task {
                let context = DevContext(tree: tree)
                let group = await Task.detached(priority: .utility) {
                    DevEnvironmentScanner.discover(ecosystem, context: context)
                }.value
                groups[ecosystem] = group
                loading.remove(ecosystem)
            }
        }
    }

    /// Runs `command` for `item`, logs it as a cleanup and looks at its ecosystem again.
    func run(_ command: ToolCommand, for item: DevItem, tree: FileTree?, then done: @escaping @MainActor (Bool) -> Void) {
        guard running == nil else { return }
        running = item.id
        lastRun = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
                do {
                    let result = try command.run(timeout: 15 * 60)
                    let text = [result.output, result.errors].filter { !$0.isEmpty }.joined(separator: "\n")
                    return (result.succeeded, text.isEmpty ? (result.succeeded ? "完成。" : "命令失败，没有输出。") : text)
                } catch {
                    return (false, String(describing: error))
                }
            }.value
            if result.0 {
                let run = CleanupRecord.CommandRun(command: command.display, subject: "\(item.kind) \(item.title)",
                                                   size: item.size ?? 0)
                try? AppModel.cleanupLog.add(CleanupRecord(items: [], commands: [run]))
            }
            lastRun = RunResult(item: item, command: command, succeeded: result.0, output: result.1)
            running = nil
            refresh(tree: tree, only: [item.ecosystem])
            done(result.0)
        }
    }

    func dismissResult() {
        lastRun = nil
    }
}
