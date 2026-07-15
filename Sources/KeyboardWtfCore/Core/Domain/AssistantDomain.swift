import Foundation

public enum AssistantMode: String, Codable, CaseIterable, Sendable {
    case dictation
    case smartWriting
    case jarvis

    public var displayName: String {
        switch self {
        case .dictation: return "Dictation"
        case .smartWriting: return "Smart Writing"
        case .jarvis: return "Jarvis"
        }
    }
}

public enum AssistantPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case connecting
    case listening
    case transcribing
    case thinking
    case executing
    case speaking
    case done
    case cancelled
    case error
    case permissionRequired
    case confirmationRequired

    public var isTerminal: Bool {
        self == .done || self == .cancelled || self == .error
    }
}

public enum OverlayTone: String, Codable, Sendable {
    case purple, red, blue, amber, teal, green
}

public struct AssistantSnapshot: Equatable, Sendable {
    public let phase: AssistantPhase
    public let mode: AssistantMode?
    public let title: String
    public let detail: String
    public let partialTranscript: String
    public let microphoneLevel: Float
    public let startedAt: Date
    public let cancelHint: String?

    public init(
        phase: AssistantPhase = .idle,
        mode: AssistantMode? = nil,
        title: String = "keyboard.wtf",
        detail: String = "Ready",
        partialTranscript: String = "",
        microphoneLevel: Float = 0,
        startedAt: Date = Date(),
        cancelHint: String? = nil
    ) {
        self.phase = phase
        self.mode = mode
        self.title = title
        self.detail = detail
        self.partialTranscript = partialTranscript
        self.microphoneLevel = microphoneLevel
        self.startedAt = startedAt
        self.cancelHint = cancelHint
    }

    public var tone: OverlayTone {
        switch phase {
        case .connecting, .thinking, .confirmationRequired: return .purple
        case .listening, .error, .permissionRequired: return .red
        case .transcribing: return .blue
        case .executing, .cancelled: return .amber
        case .speaking: return .teal
        case .done, .idle: return .green
        }
    }
}

public enum DeliveryMode: String, Codable, CaseIterable, Sendable {
    case typeIntoFocusedApp
    case copyToClipboard
    case askEachTime
}

public enum PermissionKind: String, Codable, CaseIterable, Sendable {
    case microphone
    case accessibility
    case screenRecording
    case camera
    case automation
    case filesAndFolders
    case notifications
}

public enum PermissionStatus: String, Codable, Sendable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

public enum AppError: LocalizedError, Equatable, Sendable {
    case audio(String)
    case transcription(String)
    case authentication
    case modelUnavailable(String)
    case rateLimited
    case realtimeTransport(String)
    case permission(PermissionKind)
    case accessibility(String)
    case appResolution(String)
    case fileResolution(String)
    case cancellation
    case unsupported(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .audio: return "Audio could not be started."
        case .transcription: return "Speech could not be transcribed."
        case .authentication: return "Add a valid OpenAI API key in Settings."
        case let .modelUnavailable(name): return "The model \(name) is unavailable."
        case .rateLimited: return "OpenAI is rate limiting this request. Try again shortly."
        case .realtimeTransport: return "The live conversation connection was interrupted."
        case .permission: return "A macOS permission is needed for that action."
        case .accessibility: return "Accessibility could not complete that action."
        case .appResolution: return "That application could not be identified safely."
        case .fileResolution: return "That file could not be identified safely."
        case .cancellation: return "Cancelled."
        case .unsupported: return "That capability is not available yet."
        case .malformedResponse: return "The service returned an unexpected response."
        }
    }
}
