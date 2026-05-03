import ServiceManagement

@MainActor
final class LoginItemService {
    func isEnabled() -> Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }

        return SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw LoginItemError.unsupportedOS
        }

        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else if service.status == .enabled {
            try service.unregister()
        }
    }
}

enum LoginItemError: LocalizedError {
    case unsupportedOS

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Start at login requires macOS 13 or later."
        }
    }
}
