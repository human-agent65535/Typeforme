import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    var displayText: String {
        switch self {
        case .disabled: return "Off"
        case .enabled: return "On"
        case .requiresApproval: return "Needs approval"
        case .unavailable: return "Unavailable"
        }
    }

    var logValue: String {
        switch self {
        case .disabled: return "disabled"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .unavailable: return "unavailable"
        }
    }
}

enum LaunchAtLoginController {
    static var status: LaunchAtLoginStatus {
        map(SMAppService.mainApp.status)
    }

    @discardableResult
    static func syncDesiredState() throws -> LaunchAtLoginStatus {
        try setEnabled(AppSettings.launchAtLogin)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus {
        let service = SMAppService.mainApp
        let current = map(service.status)

        if enabled {
            switch current {
            case .enabled, .requiresApproval:
                return current
            case .disabled, .unavailable:
                try service.register()
                return status
            }
        } else {
            switch current {
            case .disabled, .unavailable:
                return current
            case .enabled, .requiresApproval:
                try service.unregister()
                return status
            }
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func map(_ status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }
}
