import Observation
import ServiceManagement

/// Turns the background agent (a login item) on and off.
@MainActor @Observable
final class BackgroundRecording {
    private let service = SMAppService.agent(plistName: "app.disklens.DiskLens.agent.plist")
    private(set) var status: SMAppService.Status = .notRegistered
    var errorMessage: String?

    init() {
        refresh()
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = service.status
    }

    func setOn(_ on: Bool) {
        errorMessage = nil
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = on
                ? "没能开启后台记录：\(error.localizedDescription)"
                : "没能关闭后台记录：\(error.localizedDescription)"
        }
        refresh()
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
