import Carbon
import Foundation

public final class GlobalHotkeyService {
    public enum Action: UInt32, CaseIterable { case dictation = 1, smartWriting, jarvis, cancel, settings }
    private var references = [EventHotKeyRef?]()
    private var handler: EventHandlerRef?
    private let callback: (Action) -> Void
    private let logger: Logger

    public init(logger: Logger = RedactingLogger(), callback: @escaping (Action) -> Void) { self.logger = logger; self.callback = callback }
    deinit { unregister() }

    public func registerDefaults() throws { try register(AppSettings()) }

    public func register(_ settings: AppSettings) throws {
        let bindings: [(Action, String)] = [(.dictation, settings.dictationShortcut), (.smartWriting, settings.smartWritingShortcut), (.jarvis, settings.jarvisShortcut), (.cancel, settings.cancelShortcut), (.settings, settings.settingsShortcut)]
        // Validate every shortcut before removing the currently working set.
        // A malformed saved field must not silently disable all global keys.
        let planned = try bindings.map { (action: $0.0, keyCode: try Self.keyCode(for: $0.1)) }
        guard Set(planned.map(\.keyCode)).count == planned.count else { throw AppError.unsupported("Two shortcuts are the same. Each action needs a unique shortcut.") }

        unregister()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var identifier = EventHotKeyID(); guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr, let action = Action(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
            service.logger.info("hotkey.pressed", metadata: ["action": "\(action)"])
            service.callback(action)
            return noErr
        }, 1, &eventType, pointer, &handler) == noErr else { throw AppError.unsupported("macOS could not install the global hotkey listener.") }
        for binding in planned { try register(binding.action, keyCode: binding.keyCode) }
    }

    public func unregister() {
        references.forEach { if let reference = $0 { UnregisterEventHotKey(reference) } }; references.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }

    private func register(_ action: Action, keyCode: UInt32) throws {
        var reference: EventHotKeyRef?
        let modifiers = UInt32(controlKey | optionKey)
        let identifier = EventHotKeyID(signature: fourCharCode("kwtf"), id: action.rawValue)
        guard RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference) == noErr else { throw AppError.unsupported("The \(action) shortcut is unavailable. Choose another shortcut in Settings.") }
        references.append(reference)
        logger.info("hotkey.registered", metadata: ["action": "\(action)"])
    }

    private func fourCharCode(_ string: String) -> OSType { string.utf8.reduce(0) { ($0 << 8) + OSType($1) } }
    public static func canonicalShortcut(_ shortcut: String) -> String? {
        let trimmed = shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("⌃"), trimmed.contains("⌥"), let key = trimmed.uppercased().last, keyCodes[key] != nil else { return nil }
        return "⌃⌥\(key)"
    }

    private static func keyCode(for shortcut: String) throws -> UInt32 {
        guard let key = shortcut.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().last, let code = keyCodes[key] else {
            throw AppError.unsupported("\(shortcut) is not a supported shortcut. Use Control + Option with a letter key.")
        }
        return code
    }

    private static let keyCodes: [Character: UInt32] = [
        "A": UInt32(kVK_ANSI_A), "B": UInt32(kVK_ANSI_B), "C": UInt32(kVK_ANSI_C), "D": UInt32(kVK_ANSI_D),
        "E": UInt32(kVK_ANSI_E), "F": UInt32(kVK_ANSI_F), "G": UInt32(kVK_ANSI_G), "H": UInt32(kVK_ANSI_H),
        "I": UInt32(kVK_ANSI_I), "J": UInt32(kVK_ANSI_J), "K": UInt32(kVK_ANSI_K), "L": UInt32(kVK_ANSI_L),
        "M": UInt32(kVK_ANSI_M), "N": UInt32(kVK_ANSI_N), "O": UInt32(kVK_ANSI_O), "P": UInt32(kVK_ANSI_P),
        "Q": UInt32(kVK_ANSI_Q), "R": UInt32(kVK_ANSI_R), "S": UInt32(kVK_ANSI_S), "T": UInt32(kVK_ANSI_T),
        "U": UInt32(kVK_ANSI_U), "V": UInt32(kVK_ANSI_V), "W": UInt32(kVK_ANSI_W), "X": UInt32(kVK_ANSI_X),
        "Y": UInt32(kVK_ANSI_Y), "Z": UInt32(kVK_ANSI_Z)
    ]
}
