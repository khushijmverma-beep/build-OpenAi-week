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
        unregister()
        let bindings: [(Action, String)] = [(.dictation, settings.dictationShortcut), (.smartWriting, settings.smartWritingShortcut), (.jarvis, settings.jarvisShortcut), (.cancel, settings.cancelShortcut), (.settings, settings.settingsShortcut)]
        let normalized = bindings.map { $0.1.uppercased().compactWhitespace }
        guard Set(normalized).count == normalized.count else { throw AppError.unsupported("Two shortcuts are the same. Each action needs a unique shortcut.") }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var identifier = EventHotKeyID(); guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr, let action = Action(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue().callback(action)
            return noErr
        }, 1, &eventType, pointer, &handler) == noErr else { throw AppError.unsupported("macOS could not install the global hotkey listener.") }
        for (action, shortcut) in bindings { try register(action, keyCode: try keyCode(for: shortcut)) }
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
    private func keyCode(for shortcut: String) throws -> UInt32 {
        switch shortcut.uppercased().last {
        case "D": return UInt32(kVK_ANSI_D)
        case "K": return UInt32(kVK_ANSI_K)
        case "Q": return UInt32(kVK_ANSI_Q)
        case "X": return UInt32(kVK_ANSI_X)
        case ",": return UInt32(kVK_ANSI_Comma)
        default: throw AppError.unsupported("\(shortcut) is not a supported shortcut yet. Use Control + Option with D, K, Q, X, or comma.")
        }
    }
}
