import Foundation

public enum ToolName: String, Codable, CaseIterable, Sendable {
    case openApps = "open_apps"
    case openApp = "open_app"
    case focusApp = "focus_app"
    case closeApp = "close_app"
    case listRunningApps = "list_running_apps"
    case listWindows = "list_windows"
    case focusWindow = "focus_window"
    case minimiseWindow = "minimise_window"
    case maximiseWindow = "maximise_window"
    case closeWindow = "close_window"
    case openFile = "open_file"
    case openFolder = "open_folder"
    case searchFiles = "search_files"
    case openURL = "open_url"
    case webSearch = "web_search"
    case playSpotifyPlaylist = "play_spotify_playlist"
    case getSelectedText = "get_selected_text"
    case replaceSelectedText = "replace_selected_text"
    case typeText = "type_text"
    case copyText = "copy_text"
    case takeScreenshot = "take_screenshot"
    case inspectScreen = "inspect_screen"
    case takeWebcamPhoto = "take_webcam_photo"
    case setVolume = "set_volume"
    case mute
    case unmute
    case getSystemStatus = "get_system_status"
    case remember
    case forget
    case searchMemory = "search_memory"
    case createWorkflow = "create_workflow"
    case runWorkflow = "run_workflow"
    case listWorkflows = "list_workflows"
    case lockMac = "lock_mac"
    case sleepMac = "sleep_mac"
    case restartMac = "restart_mac"
    case shutDownMac = "shut_down_mac"
}

public enum FailureCategory: String, Codable, Sendable {
    case none, permission, notFound, ambiguous, unsupported, denied, cancelled, transport, validation, unknown
}

public struct ActionReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let toolName: ToolName
    public let requestedTarget: String
    public let resolvedTarget: String?
    public let startedAt: Date
    public let endedAt: Date
    public let success: Bool
    public let verified: Bool
    public let summary: String
    public let failureCategory: FailureCategory
    public let confirmationUsed: Bool
    public let permissionBlocked: Bool
    public let rollbackSummary: String?

    public init(
        id: UUID = UUID(), toolName: ToolName, requestedTarget: String, resolvedTarget: String? = nil,
        success: Bool, verified: Bool, summary: String, startedAt: Date = Date(), endedAt: Date = Date(),
        failureCategory: FailureCategory = .none, confirmationUsed: Bool = false,
        permissionBlocked: Bool = false, rollbackSummary: String? = nil
    ) {
        self.id = id; self.toolName = toolName; self.requestedTarget = requestedTarget; self.resolvedTarget = resolvedTarget
        self.startedAt = startedAt; self.endedAt = endedAt; self.success = success; self.verified = verified
        self.summary = summary; self.failureCategory = failureCategory; self.confirmationUsed = confirmationUsed
        self.permissionBlocked = permissionBlocked; self.rollbackSummary = rollbackSummary
    }
}

public enum SystemOperation: String, Codable, CaseIterable, Sendable {
    case lock, sleep, restart, shutDown

    public var requiresConfirmation: Bool { self == .restart || self == .shutDown }
}

public struct PendingConfirmation: Equatable, Sendable {
    public let id: UUID
    public let operation: SystemOperation
    public let requestedAt: Date
    public let expiresAt: Date

    public init(operation: SystemOperation, now: Date = Date(), ttl: TimeInterval = 20) {
        id = UUID(); self.operation = operation; requestedAt = now; expiresAt = now.addingTimeInterval(ttl)
    }

    public func isValid(at date: Date = Date()) -> Bool { date <= expiresAt }
}

public struct SelectedTextContext: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable { case accessibility, clipboardFallback, unavailable }
    public let text: String
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let windowTitle: String?
    public let contentType: String?
    public let method: Method
    public let capturedAt: Date
}

public struct AppCandidate: Equatable, Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let url: URL
    public let score: Double
    public let source: String
}

public enum AppResolution: Equatable, Sendable {
    case resolved(AppCandidate)
    case ambiguous([AppCandidate])
    case notFound(String)
}
