import Foundation
import ServiceManagement

@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    @Published public private(set) var detail = "Checking login-item status…"

    public init() { refresh() }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            return nil
        } catch {
            refresh()
            return enabled
                ? "macOS could not register keyboard.wtf as a login item."
                : "macOS could not remove keyboard.wtf from Login Items."
        }
    }

    public func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            detail = "Enabled — keyboard.wtf will start when you sign in."
        case .requiresApproval:
            detail = "macOS needs approval in System Settings → General → Login Items."
        case .notRegistered:
            detail = "Not enabled at login."
        case .notFound:
            detail = "Install the app in Applications, then enable Launch at Login."
        @unknown default:
            detail = "Login-item status is unavailable."
        }
    }
}
