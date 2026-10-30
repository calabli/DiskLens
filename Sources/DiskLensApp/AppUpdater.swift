import AppKit
import DiskLensCore
import Foundation
import Observation

/// Checks GitHub for a newer DiskLens, then downloads, verifies and installs it in
/// place of the running copy and opens the new one.
@MainActor @Observable
final class AppUpdater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case downloading(AvailableUpdate, Double)
        case installing(AvailableUpdate)
        case failed(String)
    }

    enum Keys {
        static let autoCheck = "updates.autoCheck"
        static let includePrereleases = "updates.includePrereleases"
        static let lastCheck = "updates.lastCheck"
        static let skippedVersion = "updates.skippedVersion"
    }

    private(set) var state: State = .idle
    var showWindow = false

    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    static let commit = Bundle.main.infoDictionary?["DiskLensCommit"] as? String
    /// When this copy was built, stamped by build-app.sh; nil for `swift run`.
    static let buildDate = (Bundle.main.infoDictionary?["DiskLensBuildDate"] as? String)
        .flatMap { ISO8601DateFormatter().date(from: $0) }

    private static let checkInterval: TimeInterval = 24 * 60 * 60

    var lastCheck: Date? { UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date }

    /// Once a day at most, when automatic checks are on (the default). Shows the window only
    /// when there is a version the user has not chosen to skip.
    func checkIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Keys.autoCheck) as? Bool ?? true,
              Date().timeIntervalSince(lastCheck ?? .distantPast) >= Self.checkInterval else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        if case .checking = state { return }
        if case .downloading = state { return }
        state = .checking
        if userInitiated { showWindow = true }
        let includePrereleases = UserDefaults.standard.object(forKey: Keys.includePrereleases) as? Bool ?? true
        Task {
            do {
                let update = try await SoftwareUpdate.check(current: Self.version, includePrereleases: includePrereleases)
                UserDefaults.standard.set(Date(), forKey: Keys.lastCheck)
                if let update {
                    state = .available(update)
                    let skipped = UserDefaults.standard.string(forKey: Keys.skippedVersion)
                    if userInitiated || skipped != update.version { showWindow = true }
                } else {
                    state = .upToDate
                }
            } catch {
                state = userInitiated ? .failed("没能连上 GitHub 检查更新，请稍后再试。") : .idle
            }
        }
    }

    func skip(_ update: AvailableUpdate) {
        UserDefaults.standard.set(update.version, forKey: Keys.skippedVersion)
        close()
    }

    func close() {
        showWindow = false
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .idle
    }

    /// Downloads and checks the update, puts it where this copy is, moves this copy to the
    /// Trash (so it can be put back), then quits and opens the new one.
    func install(_ update: AvailableUpdate) {
        state = .downloading(update, 0)
        Task {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLensUpdate-\(UUID().uuidString)")
                let newApp = try await SoftwareUpdate.download(update, into: folder) { fraction in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.state { self?.state = .downloading(update, fraction) }
                    }
                }
                state = .installing(update)
                let installed = try Self.replaceRunningApp(with: newApp)
                // macOS will not quit while a window has a sheet open, so close it first.
                showWindow = false
                try? await Task.sleep(for: .milliseconds(400))
                Self.relaunch(installed)
            } catch {
                state = .failed(Self.describe(error))
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? SoftwareUpdate.Failure { return failure.description }
        if error is URLError { return "下载没能完成，请检查网络后再试。" }
        return (error as NSError).localizedDescription
    }

    /// Swaps the bundle on disk. A running app's files stay open after it is moved,
    /// so this copy keeps working until it quits.
    private static func replaceRunningApp(with newApp: URL) throws -> URL {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        var trashed: NSURL?
        do {
            try fm.trashItem(at: current, resultingItemURL: &trashed)
        } catch {
            throw NSError(domain: "DiskLens", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "没能替换 \(current.deletingLastPathComponent().path) 里的 DiskLens（\(error.localizedDescription)）。可以从 GitHub 下载后手动替换。"])
        }
        do {
            try fm.moveItem(at: newApp, to: current)
        } catch {
            // Put the old copy back so DiskLens is never left missing.
            if let trashed = trashed as URL? { try? fm.moveItem(at: trashed, to: current) }
            throw error
        }
        return current
    }

    /// Opens `app` once this process has exited, and restarts the background agent from it.
    private static func relaunch(_ app: URL) {
        let script = """
            while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
            /usr/bin/open "$2"
            /bin/launchctl kickstart -k "gui/$3/app.disklens.DiskLens.agent" >/dev/null 2>&1
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Values go in as positional parameters, never into the script text.
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), app.path, String(getuid())]
        try? process.run()
        NSApp.terminate(nil)
        // If something still holds the app open, the new copy is already in place: leave anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }

    /// For the About panel and Settings: "0.2.0（构建 63）".
    static var versionLabel: String { build.isEmpty ? version : "\(version)（构建 \(build)）" }
}
