import DiskLensCore
import Foundation
import Observation

/// The cleanup rules in use, and keeping them current from the published library.
@MainActor @Observable
final class RuleLibrary {
    enum Status: Equatable {
        case idle
        case checking
        case updated(version: Int)
        case upToDate
        case failed(String)
    }

    enum Keys {
        static let autoUpdate = "rules.autoUpdate"
        static let lastCheck = "rules.lastCheck"
    }

    /// The rules suggestions are based on; nil only if even the built-in ones failed to load.
    private(set) var set: CleanupRuleSet?
    private(set) var loadError: String?
    private(set) var status: Status = .idle
    /// Called after newer rules are installed, so suggestions can be worked out again.
    @ObservationIgnored var onUpdate: (() -> Void)?

    nonisolated private static let store = RuleStore.standard
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    var lastCheck: Date? {
        UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date
    }

    init() {
        do {
            let bundled = try CleanupRuleSet.bundled()
            set = Self.store.current(bundled: bundled)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Checks once a day when automatic updates are on (the default).
    func checkIfDue() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: Keys.autoUpdate) as? Bool ?? true
        guard enabled, Date().timeIntervalSince(lastCheck ?? .distantPast) >= Self.checkInterval else { return }
        check()
    }

    func check() {
        guard status != .checking, let installed = set?.version else { return }
        status = .checking
        Task {
            do {
                let (outcome, newer) = try await Self.store.update(installed: installed)
                UserDefaults.standard.set(Date(), forKey: Keys.lastCheck)
                switch outcome {
                case let .updated(version):
                    set = newer
                    status = .updated(version: version)
                    onUpdate?()
                case .upToDate:
                    status = .upToDate
                }
            } catch let failure as SignedRules.Failure {
                status = .failed(failure.description)
            } catch {
                status = .failed("没能连上规则服务器")
            }
        }
    }
}
