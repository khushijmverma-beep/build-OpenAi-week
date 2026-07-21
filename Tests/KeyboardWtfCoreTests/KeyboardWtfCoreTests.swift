import XCTest
@testable import KeyboardWtfCore

final class KeyboardWtfCoreTests: XCTestCase {
    func testPhaseMapsToSemanticTone() {
        XCTAssertEqual(AssistantSnapshot(phase: .listening).tone, .red)
        XCTAssertEqual(AssistantSnapshot(phase: .thinking).tone, .purple)
        XCTAssertEqual(AssistantSnapshot(phase: .speaking).tone, .teal)
        XCTAssertTrue(AssistantPhase.done.isTerminal)
    }

    func testConfirmationExpires() {
        let start = Date(timeIntervalSince1970: 1_000)
        let confirmation = PendingConfirmation(operation: .restart, now: start, ttl: 5)
        XCTAssertTrue(confirmation.isValid(at: start.addingTimeInterval(5)))
        XCTAssertFalse(confirmation.isValid(at: start.addingTimeInterval(5.01)))
    }

    func testRedactionRemovesAPIKeys() {
        let logger = RedactingLogger()
        XCTAssertFalse(logger.redact("Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz").contains("abcdefghijklmnopqrstuvwxyz"))
    }

    func testResponsesParserReadsOutputTextAndUsage() throws {
        let data = Data("{\"id\":\"resp_1\",\"model\":\"gpt-5.4-mini\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Ready.\"}]}],\"usage\":{\"input_tokens\":12,\"output_tokens\":3}}".utf8)
        let result = try OpenAIResponsesService.parse(data)
        XCTAssertEqual(result.outputText, "Ready.")
        XCTAssertEqual(result.inputTokens, 12)
    }

    func testSpotifyPlaylistLinkNormalizesToSafeURI() {
        XCTAssertEqual(
            MacSpotifyPlaybackController.playlistURI(from: "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=test"),
            "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"
        )
        XCTAssertEqual(
            MacSpotifyPlaybackController.playlistURI(from: "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"),
            "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"
        )
        XCTAssertNil(MacSpotifyPlaybackController.playlistURI(from: "spotify:playlist:unsafe\" script"))
    }

    func testToolRegistryIncludesRequestedMacControls() {
        let names = Set(DefaultToolRegistry().schemas().map(\.name))
        XCTAssertTrue(names.contains(.closeApp))
        XCTAssertTrue(names.contains(.typeText))
        XCTAssertTrue(names.contains(.playSpotifyPlaylist))
    }

    func testSQLitePersistsMemoryAndWorkflow() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStore(url: url)
        try await store.remember(key: "browser", value: "Safari", sensitivity: .ordinary)
        let memories = try await store.search("browser")
        XCTAssertEqual(memories.first?.value, "Safari")
        let forgotBrowser = try await store.forget(key: "browser")
        XCTAssertTrue(forgotBrowser)
        let afterForget = try await store.search("browser")
        XCTAssertTrue(afterForget.isEmpty)
        try await store.remember(key: "name", value: "Alex", sensitivity: .ordinary)
        try await store.clear()
        let afterClear = try await store.search("name")
        XCTAssertTrue(afterClear.isEmpty)
        let workflow = Workflow(name: "work setup", triggers: ["start work"], steps: [WorkflowStep(tool: .openApp, argumentsJSON: "{\"name\":\"Safari\"}")])
        try await store.save(workflow)
        let workflows = try await store.all()
        XCTAssertEqual(workflows.first?.name, "work setup")
        let deletedWorkflow = try await store.delete(name: "work setup")
        XCTAssertTrue(deletedWorkflow)
        let afterWorkflowDelete = try await store.all()
        XCTAssertTrue(afterWorkflowDelete.isEmpty)
    }

    func testLiveResponsesSmokeWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_OPENAI_TESTS"] == "1" else {
            throw XCTSkip("Live API checks are opt-in.")
        }
        let client = OpenAIResponsesService(credentials: KeychainCredentialProvider())
        let result = try await client.create(ResponsesRequest(
            instructions: "Reply with exactly: ok",
            input: "Connection test"
        ))
        XCTAssertEqual(result.outputText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "ok")
    }

    func testLiveRealtimeToolRoundTripWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_OPENAI_TESTS"] == "1" else {
            throw XCTSkip("Live API checks are opt-in.")
        }

        let client = OpenAIRealtimeWebSocketClient(credentials: KeychainCredentialProvider())
        try await client.connect(configuration: RealtimeConfiguration(
            assistantName: "Jarvis test",
            instructions: "For every user message, call list_running_apps before replying. Do not describe the action yourself.",
            tools: DefaultToolRegistry().schemas()
        ))
        defer { Task { await client.disconnect() } }

        try await client.sendText("Run the list_running_apps function now.")
        var pendingCall: ToolCall?
        var toolOutputWasSent = false
        var completed = false
        let deadline = Date().addingTimeInterval(30)

        for await event in client.events {
            if Date() > deadline {
                throw AppError.realtimeTransport("Realtime tool-round-trip test timed out.")
            }
            switch event {
            case let .toolCall(call) where call.name == .listRunningApps:
                // The server may provide the same function call through two
                // event variants; only one output belongs in the conversation.
                if pendingCall == nil { pendingCall = call }
            case .responseDone where !toolOutputWasSent:
                guard let pendingCall else { continue }
                // This ordering is the regression being tested: wait for the
                // current response to finish, then write its output, then ask
                // Realtime for the assistant's follow-up response.
                try await client.sendToolOutput(callID: pendingCall.id, output: #"{"applications":["TestApp"]}"#)
                try await client.requestResponse()
                toolOutputWasSent = true
            case .responseDone where toolOutputWasSent:
                completed = true
            case let .error(error):
                throw error
            default:
                break
            }
            if completed { break }
        }

        XCTAssertNotNil(pendingCall)
        XCTAssertTrue(toolOutputWasSent)
        XCTAssertTrue(completed)
    }

    @MainActor
    func testJarvisDefersToolOutputUntilResponseDone() async throws {
        let realtime = TestRealtimeClient()
        let executor = TestActionExecutor()
        let selectedText = TestSelectedTextProvider()
        let coordinator = AssistantCoordinator(
            state: ObservableAssistantStateStore(),
            audioCapture: TestAudioCapture(),
            audioPlayback: TestAudioPlayback(),
            recognizer: TestSpeechRecognizer(),
            responses: TestResponsesClient(),
            realtime: realtime,
            delivery: TextDeliveryService(selectedText: selectedText, clipboard: TestClipboard()),
            selectedText: selectedText,
            tools: DefaultToolRegistry(),
            executor: executor,
            policy: DefaultPermissionPolicy(),
            receiptStore: TestReceiptStore(),
            settings: SettingsStore()
        )

        await coordinator.start(mode: .jarvis)
        let toolCall = ToolCall(id: "call_1", name: .openApp, argumentsJSON: #"{"name":"TextEdit"}"#)
        realtime.emit(.toolCall(toolCall))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(executor.executedCalls.isEmpty)
        XCTAssertTrue(realtime.eventsSent.isEmpty)

        realtime.emit(.responseDone)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(executor.executedCalls, [toolCall])
        XCTAssertEqual(realtime.eventsSent, ["tool_output:call_1", "response.create"])
        await coordinator.cancel()
    }
}

private final class TestAudioCapture: AudioCaptureService {
    var onAudioChunk: ((Data, Float) -> Void)?
    func start() throws {}
    func stop() {}
}

private final class TestAudioPlayback: AudioPlaybackService {
    func enqueuePCM16(_ data: Data) {}
    func stop() {}
}

@MainActor
private final class TestSpeechRecognizer: LocalSpeechRecognizer {
    private let stream = AsyncStream<String> { $0.finish() }
    var partialTranscript: AsyncStream<String> { stream }
    func prepare() async throws {}
    func startStreaming() async throws {}
    func append(audio: Data) async {}
    func finish() async throws -> String { "" }
    func cancel() async {}
}

private final class TestResponsesClient: OpenAIResponsesClient {
    func create(_ request: ResponsesRequest) async throws -> ResponsesResult {
        ResponsesResult(id: "test", outputText: "", model: request.model, inputTokens: nil, outputTokens: nil)
    }
}

private final class TestRealtimeClient: OpenAIRealtimeClient {
    let events: AsyncStream<RealtimeEvent>
    private let continuation: AsyncStream<RealtimeEvent>.Continuation
    private(set) var eventsSent: [String] = []

    init() {
        var continuation: AsyncStream<RealtimeEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect(configuration: RealtimeConfiguration) async throws {}
    func appendAudio(_ data: Data) async throws {}
    func sendText(_ text: String) async throws {}
    func sendToolOutput(callID: String, output: String) async throws { eventsSent.append("tool_output:\(callID)") }
    func requestResponse() async throws { eventsSent.append("response.create") }
    func interrupt() async {}
    func disconnect() async {}
    func emit(_ event: RealtimeEvent) { continuation.yield(event) }
}

private final class TestSelectedTextProvider: SelectedTextProvider {
    func capture() async -> SelectedTextContext {
        SelectedTextContext(text: "", applicationName: nil, bundleIdentifier: nil, windowTitle: nil, contentType: nil, method: .unavailable, capturedAt: Date())
    }

    func replaceSelection(with text: String) async -> ActionReceipt {
        ActionReceipt(toolName: .replaceSelectedText, requestedTarget: "", success: true, verified: true, summary: "")
    }
}

private final class TestClipboard: ClipboardService {
    private var value: String?
    func readString() -> String? { value }
    func writeString(_ value: String) { self.value = value }
    func withPreservedClipboard<T>(_ action: () async throws -> T) async rethrows -> T { try await action() }
}

private final class TestActionExecutor: ActionExecutor {
    private(set) var executedCalls: [ToolCall] = []
    func execute(_ call: ToolCall, confirmed: Bool) async -> ActionReceipt {
        executedCalls.append(call)
        return ActionReceipt(toolName: call.name, requestedTarget: "TextEdit", success: true, verified: true, summary: "Opened TextEdit.")
    }
}

private final class TestReceiptStore: ActionReceiptStore {
    func append(_ receipt: ActionReceipt) async {}
    func recent(limit: Int) async -> [ActionReceipt] { [] }
}
