import Combine
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var assistantName: String
    public var deliveryMode: DeliveryMode
    public var dictationShortcut: String
    public var smartWritingShortcut: String
    public var jarvisShortcut: String
    public var cancelShortcut: String
    public var settingsShortcut: String
    public var realtimeModel: String
    public var responsesModel: String
    public var reasoningModel: String
    public var autoExecuteRoutineActions: Bool
    public var wakePhraseEnabled: Bool

    public init(
        assistantName: String = "Jarvis", deliveryMode: DeliveryMode = .typeIntoFocusedApp,
        dictationShortcut: String = "⌃⌥D", smartWritingShortcut: String = "⌃⌥K", jarvisShortcut: String = "⌃⌥Q",
        cancelShortcut: String = "⌃⌥X", settingsShortcut: String = "⌃⌥,",
        realtimeModel: String = ModelCatalog.default.realtime,
        responsesModel: String = ModelCatalog.default.responses,
        reasoningModel: String = ModelCatalog.default.reasoning,
        autoExecuteRoutineActions: Bool = true, wakePhraseEnabled: Bool = false
    ) {
        self.assistantName = assistantName; self.deliveryMode = deliveryMode
        self.dictationShortcut = dictationShortcut; self.smartWritingShortcut = smartWritingShortcut; self.jarvisShortcut = jarvisShortcut
        self.cancelShortcut = cancelShortcut; self.settingsShortcut = settingsShortcut
        self.realtimeModel = realtimeModel; self.responsesModel = responsesModel; self.reasoningModel = reasoningModel
        self.autoExecuteRoutineActions = autoExecuteRoutineActions; self.wakePhraseEnabled = wakePhraseEnabled
    }
}

public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings { didSet { persist() } }
    private let url: URL
    public init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("keyboard.wtf", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("settings.json")
        settings = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }
    private func persist() { if let data = try? JSONEncoder().encode(settings) { try? data.write(to: url, options: .atomic) } }
}
