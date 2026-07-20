import AppKit
import Foundation

@MainActor
public final class AppEnvironment {
    public let state: ObservableAssistantStateStore
    public let settings: SettingsStore
    public let coordinator: AssistantCoordinator
    public let credentials: CredentialProvider
    public let permissionCenter: PermissionCenter
    public let receiptStore: ActionReceiptStore
    public lazy var hotkeys: GlobalHotkeyService = GlobalHotkeyService { [weak self] action in
        Task { @MainActor in
            guard let self else { return }
            switch action {
            case .dictation: await self.coordinator.start(mode: .dictation)
            case .smartWriting: await self.coordinator.start(mode: .smartWriting)
            case .jarvis: await self.coordinator.start(mode: .jarvis)
            case .cancel: await self.coordinator.cancel()
            case .settings: NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
        let appResolver = MacAppResolver()
        let executor = MacActionExecutor(apps: appResolver, delivery: delivery, selectedText: selectedText, clipboard: clipboard, system: MacSystemActionService(), files: BoundedFileSearchService(), windows: MacWindowController(), memory: database, workflows: database)
        permissionCenter = PermissionCenter()
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
    }

    public func testOpenAIConnection() async throws {
        let client = OpenAIResponsesService(credentials: credentials)
        _ = try await client.create(ResponsesRequest(model: settings.settings.responsesModel, instructions: "Reply with exactly: ok", input: "Connection test"))
    }
}
