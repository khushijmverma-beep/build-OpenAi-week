import AppKit
import Foundation

@MainActor
public final class AppEnvironment {
    public let state: ObservableAssistantStateStore
    public let settings: SettingsStore
    public let coordinator: AssistantCoordinator
    public let credentials: CredentialProvider
    public let permissionCenter: PermissionCenter
    public let launchAtLogin: LaunchAtLoginManager
    public let receiptStore: ActionReceiptStore
    public let memoryStore: MemoryStore
    public let workflowStore: WorkflowStore
    public var presentSettings: (() -> Void)?
    public lazy var hotkeys: GlobalHotkeyService = GlobalHotkeyService { [weak self] action in
        Task { @MainActor in
            guard let self else { return }
            switch action {
            case .dictation: await self.coordinator.start(mode: .dictation)
            case .smartWriting: await self.coordinator.start(mode: .smartWriting)
            case .jarvis: await self.coordinator.start(mode: .jarvis)
            case .cancel: await self.coordinator.cancel()
            case .settings: self.presentSettings?()
            }
        }
    }

    public init() throws {
        state = ObservableAssistantStateStore()
        settings = SettingsStore()
        let credentials = KeychainCredentialProvider()
        self.credentials = credentials
        let clipboard = MacClipboardService()
        let selectedText = MacSelectedTextProvider(clipboard: clipboard)
        let delivery = TextDeliveryService(selectedText: selectedText, clipboard: clipboard)
        let database = try SQLiteStore()
        receiptStore = database
        memoryStore = database
        workflowStore = database
        let appResolver = MacAppResolver()
        let screenCapture = MacScreenCaptureService()
        let executor = MacActionExecutor(apps: appResolver, delivery: delivery, selectedText: selectedText, clipboard: clipboard, system: MacSystemActionService(), files: BoundedFileSearchService(), windows: MacWindowController(), screen: screenCapture, memory: database, workflows: database, media: MacMediaPlaybackController(), screenAnalyzer: OpenAIScreenAnalyzer(credentials: credentials), screenClick: MacScreenClickService(screen: screenCapture, resolver: OpenAIScreenClickResolver(credentials: credentials, model: settings.settings.responsesModel)))
        permissionCenter = PermissionCenter()
        launchAtLogin = LaunchAtLoginManager()
        coordinator = AssistantCoordinator(
            state: state,
            audioCapture: AVAudioCapture(),
            audioPlayback: AVAudioPlayback(),
            recognizer: OnDeviceSpeechRecognizer(),
            responses: OpenAIResponsesService(credentials: credentials),
            realtime: OpenAIRealtimeWebSocketClient(credentials: credentials),
            delivery: delivery,
            selectedText: selectedText,
            tools: DefaultToolRegistry(),
            executor: executor,
            policy: DefaultPermissionPolicy(),
            receiptStore: database,
            settings: settings
        )
        if settings.settings.launchAtLogin { _ = launchAtLogin.setEnabled(true) }
    }

    public func testOpenAIConnection() async throws {
        let client = OpenAIResponsesService(credentials: credentials)
        _ = try await client.create(ResponsesRequest(model: settings.settings.responsesModel, instructions: "Reply with exactly: ok", input: "Connection test"))
    }

    /// Exercises the real Realtime transport and verifies that the service returns audio.
    /// This avoids confusing a successful Responses request with a working Jarvis voice session.
    public func testJarvisVoiceConnection() async throws -> Int {
        let client = OpenAIRealtimeWebSocketClient(credentials: credentials)
        let configuration = RealtimeConfiguration(
            model: settings.settings.realtimeModel,
            assistantName: settings.settings.assistantName,
            instructions: "Reply naturally and very briefly."
        , tools: [])
        try await client.connect(configuration: configuration)
        do {
            try await client.sendText("Say exactly: Jarvis voice is ready.")
            let audioBytes = try await Self.awaitVoiceProbe(from: client.events)
            await client.disconnect()
            guard audioBytes > 0 else { throw AppError.realtimeTransport("Realtime completed without returning audio.") }
            return audioBytes
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private static func awaitVoiceProbe(from events: AsyncStream<RealtimeEvent>) async throws -> Int {
        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                var audioBytes = 0
                for await event in events {
                    switch event {
                    case let .outputAudio(data): audioBytes += data.count
                    case .responseDone: return audioBytes
                    case let .error(error): throw error
                    default: continue
                    }
                }
                throw AppError.realtimeTransport("Realtime closed before finishing the voice test.")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw AppError.realtimeTransport("Realtime voice test timed out after 15 seconds.")
            }
            guard let result = try await group.next() else { throw AppError.realtimeTransport("Realtime voice test did not start.") }
            group.cancelAll()
            return result
        }
    }
}
