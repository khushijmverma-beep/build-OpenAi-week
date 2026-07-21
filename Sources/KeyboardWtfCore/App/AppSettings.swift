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
        cancelShortcut: String = "⌃⌥X", settingsShortcut: String = "⌃⌥J",
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
        settingsShortcut = try values.decodeIfPresent(String.self, forKey: .settingsShortcut) ?? "⌃⌥J"
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
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        var loaded = stored ?? AppSettings()
        // Repair values written by older builds or by text-field edits. A single
        // malformed shortcut otherwise prevents Carbon from registering every
        // global shortcut at launch.
        let defaults = AppSettings()
        if loaded.settingsShortcut == "⌃⌥," { loaded.settingsShortcut = "⌃⌥J" }
        let candidates = [
            GlobalHotkeyService.canonicalShortcut(loaded.dictationShortcut),
            GlobalHotkeyService.canonicalShortcut(loaded.smartWritingShortcut),
            GlobalHotkeyService.canonicalShortcut(loaded.jarvisShortcut),
            GlobalHotkeyService.canonicalShortcut(loaded.cancelShortcut),
            GlobalHotkeyService.canonicalShortcut(loaded.settingsShortcut)
        ]
        let fallback = [defaults.dictationShortcut, defaults.smartWritingShortcut, defaults.jarvisShortcut, defaults.cancelShortcut, defaults.settingsShortcut]
        // Keep Settings at Control-Option-J when possible, then fill the other
        // actions without duplicates. This repairs files written by an older UI
        // that stored only the final key character (or control characters).
        var repaired = Array(repeating: "", count: candidates.count)
        var used = Set<String>()
        let settingsIndex = candidates.count - 1
        repaired[settingsIndex] = candidates[settingsIndex] ?? fallback[settingsIndex]
        used.insert(repaired[settingsIndex])
        for index in 0..<settingsIndex {
            let preferred = candidates[index]
            let replacement = (preferred.flatMap { used.contains($0) ? nil : $0 })
                ?? (fallback[index].isEmpty || used.contains(fallback[index]) ? nil : fallback[index])
                ?? ("⌃⌥" + String("ABCDEFGHIJKLMNOPQRSTUVWXYZ".first { !used.contains("⌃⌥\($0)") } ?? "A"))
            repaired[index] = replacement
            used.insert(replacement)
        }
        loaded.dictationShortcut = repaired[0]
        loaded.smartWritingShortcut = repaired[1]
        loaded.jarvisShortcut = repaired[2]
        loaded.cancelShortcut = repaired[3]
        loaded.settingsShortcut = repaired[4]
        settings = loaded
        if loaded != (stored ?? AppSettings()) { persist() }
    }
    private func persist() { if let data = try? JSONEncoder().encode(settings) { try? data.write(to: url, options: .atomic) } }
}
