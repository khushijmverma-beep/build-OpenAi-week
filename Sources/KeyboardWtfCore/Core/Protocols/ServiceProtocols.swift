import Foundation

public protocol AssistantCoordinatorProtocol: AnyObject {
    func start(mode: AssistantMode) async
    func cancel() async
    func confirmPendingAction() async
}

@MainActor public protocol AssistantStateStore: AnyObject {
    var snapshot: AssistantSnapshot { get }
    func transition(to snapshot: AssistantSnapshot)
}

public protocol AudioCaptureService: AnyObject {
    var onAudioChunk: ((Data, Float) -> Void)? { get set }
    func start() throws
    func stop()
}

public protocol AudioPlaybackService: AnyObject {
    func enqueuePCM16(_ data: Data)
    func stop()
}

@MainActor public protocol LocalSpeechRecognizer: AnyObject {
    var partialTranscript: AsyncStream<String> { get }
    func prepare() async throws
    func startStreaming() async throws
    func append(audio: Data) async
    func finish() async throws -> String
    func cancel() async
}

public protocol OpenAIRealtimeClient: AnyObject {
    var events: AsyncStream<RealtimeEvent> { get }
    func connect(configuration: RealtimeConfiguration) async throws
    func appendAudio(_ data: Data) async throws
    func sendText(_ text: String) async throws
    func sendToolOutput(callID: String, output: String) async throws
    /// Starts a new response only after all function-call outputs for the
    /// preceding response have been written to the conversation.
    func requestResponse() async throws
    func interrupt() async
    func disconnect() async
}

public protocol OpenAIResponsesClient: AnyObject {
    func create(_ request: ResponsesRequest) async throws -> ResponsesResult
}

public protocol CredentialProvider: AnyObject {
    func apiKey() throws -> String?
    func save(apiKey: String) throws
    func delete() throws
}

public protocol EphemeralCredentialProvider: AnyObject {
    func realtimeCredential() async throws -> String
}

public protocol SelectedTextProvider: AnyObject {
    func capture() async -> SelectedTextContext
    func replaceSelection(with text: String) async -> ActionReceipt
}

public protocol ClipboardService: AnyObject {
    func readString() -> String?
    func writeString(_ value: String)
    func withPreservedClipboard<T>(_ action: () async throws -> T) async rethrows -> T
}

public protocol AppResolver: AnyObject {
    func resolve(_ query: String) async -> AppResolution
    func open(_ candidate: AppCandidate) async -> ActionReceipt
}

public protocol FileSearchService: AnyObject {
    func search(query: String, roots: [URL]) async throws -> [URL]
}

public protocol WindowController: AnyObject {
    func listWindows() async -> [String]
    func focusWindow(matching title: String) async -> ActionReceipt
    func minimiseWindow(matching title: String) async -> ActionReceipt
}
public protocol SpaceController: AnyObject { func switchSpace(direction: Int) async -> ActionReceipt }
public protocol ScreenCaptureService: AnyObject { func screenshot() async throws -> URL }
public protocol CameraCaptureService: AnyObject { func capturePhoto() async throws -> URL }
public protocol RecordingService: AnyObject { func stopRecording() async -> ActionReceipt }
public protocol SystemActionService: AnyObject { func perform(_ operation: SystemOperation, confirmed: Bool) async -> ActionReceipt }
public protocol ToolRegistry: AnyObject { func schemas() -> [ToolDefinition] }
public protocol ActionExecutor: AnyObject { func execute(_ call: ToolCall, confirmed: Bool) async -> ActionReceipt }
public protocol PermissionPolicy: AnyObject { func requiresConfirmation(for tool: ToolName) -> Bool }
public protocol ActionReceiptStore: AnyObject { func append(_ receipt: ActionReceipt) async; func recent(limit: Int) async -> [ActionReceipt] }
public protocol MemoryStore: AnyObject { func remember(key: String, value: String, sensitivity: MemorySensitivity) async throws; func search(_ query: String) async throws -> [MemoryItem] }
public protocol WorkflowStore: AnyObject { func save(_ workflow: Workflow) async throws; func all() async throws -> [Workflow] }
public protocol WorkflowExecutor: AnyObject { func run(_ workflow: Workflow) async -> [ActionReceipt] }
public protocol BrowserAutomationEngine: AnyObject { func checkAvailability() async -> Bool; func cancel() async }
public protocol Clock { func now() -> Date }
public protocol Logger { func info(_ event: String, metadata: [String: String]); func error(_ event: String, metadata: [String: String]) }

public struct ToolDefinition: Codable, Equatable, Sendable {
    public let name: ToolName
    public let description: String
    public let parameters: [ToolParameter]
    public init(name: ToolName, description: String, parameters: [ToolParameter]) { self.name = name; self.description = description; self.parameters = parameters }
}

public enum ToolParameterType: String, Codable, Sendable { case string, integer, number, boolean }

public struct ToolParameter: Codable, Equatable, Sendable {
    public let name: String
    public let type: ToolParameterType
    public let description: String
    public let required: Bool
    public init(name: String, type: ToolParameterType, description: String, required: Bool = true) { self.name = name; self.type = type; self.description = description; self.required = required }
}

public struct ToolCall: Codable, Equatable, Sendable {
    public let id: String
    public let name: ToolName
    public let argumentsJSON: String
    public init(id: String, name: ToolName, argumentsJSON: String) { self.id = id; self.name = name; self.argumentsJSON = argumentsJSON }
}

public enum MemorySensitivity: String, Codable, Sendable { case ordinary, sensitive }

public struct MemoryItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID; public let key: String; public let value: String; public let sensitivity: MemorySensitivity; public let updatedAt: Date
    public init(id: UUID = UUID(), key: String, value: String, sensitivity: MemorySensitivity = .ordinary, updatedAt: Date = Date()) { self.id = id; self.key = key; self.value = value; self.sensitivity = sensitivity; self.updatedAt = updatedAt }
}

public struct Workflow: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID; public let name: String; public let triggers: [String]; public let steps: [WorkflowStep]; public let createdAt: Date
    public init(id: UUID = UUID(), name: String, triggers: [String], steps: [WorkflowStep], createdAt: Date = Date()) { self.id = id; self.name = name; self.triggers = triggers; self.steps = steps; self.createdAt = createdAt }
}

public struct WorkflowStep: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID; public let tool: ToolName; public let argumentsJSON: String; public let requiresConfirmation: Bool
    public init(id: UUID = UUID(), tool: ToolName, argumentsJSON: String, requiresConfirmation: Bool = false) { self.id = id; self.tool = tool; self.argumentsJSON = argumentsJSON; self.requiresConfirmation = requiresConfirmation }
}
