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
    public var launchAtLogin: Bool

    public init(
        assistantName: String = "Jarvis", deliveryMode: DeliveryMode = .typeIntoFocusedApp,
        dictationShortcut: String = "⌃⌥D", smartWritingShortcut: String = "⌃⌥K", jarvisShortcut: String = "⌃⌥Q",
        cancelShortcut: String = "⌃⌥X", settingsShortcut: String = "⌃⌥,",
        realtimeModel: String = ModelCatalog.default.realtime,
        responsesModel: String = ModelCatalog.default.responses,
        reasoningModel: String = ModelCatalog.default.reasoning,
        autoExecuteRoutineActions: Bool = true, wakePhraseEnabled: Bool = false,
        launchAtLogin: Bool = true
    ) {
        self.assistantName = assistantName; self.deliveryMode = deliveryMode
        self.dictationShortcut = dictationShortcut; self.smartWritingShortcut = smartWritingShortcut; self.jarvisShortcut = jarvisShortcut
        self.cancelShortcut = cancelShortcut; self.settingsShortcut = settingsShortcut
        self.realtimeModel = realtimeModel; self.responsesModel = responsesModel; self.reasoningModel = reasoningModel
        self.autoExecuteRoutineActions = autoExecuteRoutineActions; self.wakePhraseEnabled = wakePhraseEnabled; self.launchAtLogin = launchAtLogin
    }

    private enum CodingKeys: String, CodingKey {
        case assistantName, deliveryMode, dictationShortcut, smartWritingShortcut, jarvisShortcut, cancelShortcut, settingsShortcut
        case realtimeModel, responsesModel, reasoningModel, autoExecuteRoutineActions, wakePhraseEnabled, launchAtLogin
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        assistantName = try values.decodeIfPresent(String.self, forKey: .assistantName) ?? "Jarvis"
        deliveryMode = try values.decodeIfPresent(DeliveryMode.self, forKey: .deliveryMode) ?? .typeIntoFocusedApp
        dictationShortcut = try values.decodeIfPresent(String.self, forKey: .dictationShortcut) ?? "⌃⌥D"
        smartWritingShortcut = try values.decodeIfPresent(String.self, forKey: .smartWritingShortcut) ?? "⌃⌥K"
        jarvisShortcut = try values.decodeIfPresent(String.self, forKey: .jarvisShortcut) ?? "⌃⌥Q"
        cancelShortcut = try values.decodeIfPresent(String.self, forKey: .cancelShortcut) ?? "⌃⌥X"
        settingsShortcut = try values.decodeIfPresent(String.self, forKey: .settingsShortcut) ?? "⌃⌥,"
        realtimeModel = try values.decodeIfPresent(String.self, forKey: .realtimeModel) ?? ModelCatalog.default.realtime
        responsesModel = try values.decodeIfPresent(String.self, forKey: .responsesModel) ?? ModelCatalog.default.responses
        reasoningModel = try values.decodeIfPresent(String.self, forKey: .reasoningModel) ?? ModelCatalog.default.reasoning
        autoExecuteRoutineActions = try values.decodeIfPresent(Bool.self, forKey: .autoExecuteRoutineActions) ?? true
        wakePhraseEnabled = try values.decodeIfPresent(Bool.self, forKey: .wakePhraseEnabled) ?? false
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
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
