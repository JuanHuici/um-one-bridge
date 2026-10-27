import os
import ServiceManagement
import UMOneCore

/// "Iniciar al abrir sesión" through SMAppService. Works best when the app lives in /Applications.
enum LoginItem {
    private static let log = Logger(subsystem: Log.subsystem, category: "app")

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
