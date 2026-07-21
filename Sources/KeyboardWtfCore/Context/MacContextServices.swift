import AppKit
import ApplicationServices
import Foundation

public final class MacClipboardService: ClipboardService {
    private let pasteboard: NSPasteboard
    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    public func readString() -> String? { pasteboard.string(forType: .string) }
    public func writeString(_ value: String) { pasteboard.clearContents(); pasteboard.setString(value, forType: .string) }

    public func withPreservedClipboard<T>(_ action: () async throws -> T) async rethrows -> T {
        let snapshot = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            item.types.forEach { type in if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); if let snapshot { pasteboard.writeObjects(snapshot) } }
        return try await action()
    }
}

public final class MacSelectedTextProvider: SelectedTextProvider {
    private let clipboard: ClipboardService
    public init(clipboard: ClipboardService) { self.clipboard = clipboard }

    public func capture() async -> SelectedTextContext {
        let app = NSWorkspace.shared.frontmostApplication
        let base = contextBase(for: app)
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = focused {
            let focusedElement = element as! AXUIElement
            var selected: CFTypeRef?
            if AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selected) == .success, let text = selected as? String, !text.isEmpty {
                return SelectedTextContext(text: text, applicationName: base.name, bundleIdentifier: base.bundleID, windowTitle: focusedWindowTitle(app), contentType: nil, method: .accessibility, capturedAt: Date())
            }
        }
        let fallback: String? = await (try? clipboard.withPreservedClipboard {
            postCommandKey("c")
            try await Task.sleep(nanoseconds: 160_000_000)
            return clipboard.readString()
        })
        return SelectedTextContext(text: fallback ?? "", applicationName: base.name, bundleIdentifier: base.bundleID, windowTitle: focusedWindowTitle(app), contentType: nil, method: fallback?.isEmpty == false ? .clipboardFallback : .unavailable, capturedAt: Date())
    }

    public func replaceSelection(with text: String) async -> ActionReceipt {
        let started = Date()
        guard AXIsProcessTrusted() else {
            return ActionReceipt(toolName: .typeText, requestedTarget: "focused app", success: false, verified: false, summary: "Accessibility permission is required to type into another app.", startedAt: started, endedAt: Date(), failureCategory: .permission, permissionBlocked: true)
        }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = focused {
            let focusedElement = element as! AXUIElement
            if AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
                return ActionReceipt(toolName: .replaceSelectedText, requestedTarget: "selected text", success: true, verified: true, summary: "Replaced the selected text.", startedAt: started, endedAt: Date())
            }
        }
        do {
            let result: ActionReceipt = try await clipboard.withPreservedClipboard {
                clipboard.writeString(text)
                postCommandKey("v")
                try await Task.sleep(nanoseconds: 180_000_000)
                return ActionReceipt(toolName: .replaceSelectedText, requestedTarget: "selected text", success: true, verified: false, summary: "Pasted text into the focused app.", startedAt: started, endedAt: Date())
            }
            return result
        } catch {
            return ActionReceipt(toolName: .replaceSelectedText, requestedTarget: "selected text", success: false, verified: false, summary: "Copied text to the clipboard; insertion could not be completed.", startedAt: started, endedAt: Date(), failureCategory: .permission, permissionBlocked: true)
        }
    }

    private func contextBase(for app: NSRunningApplication?) -> (name: String?, bundleID: String?) { (app?.localizedName, app?.bundleIdentifier) }
    private func focusedWindowTitle(_ app: NSRunningApplication?) -> String? {
        guard let pid = app?.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(pid); var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &title) == .success, let window = title else { return nil }
        var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

public final class TextDeliveryService {
    private let selectedText: SelectedTextProvider
    private let clipboard: ClipboardService
    public init(selectedText: SelectedTextProvider, clipboard: ClipboardService) { self.selectedText = selectedText; self.clipboard = clipboard }

    public func deliver(_ text: String, mode: DeliveryMode) async -> ActionReceipt {
        if mode == .copyToClipboard { clipboard.writeString(text); return ActionReceipt(toolName: .copyText, requestedTarget: "clipboard", success: true, verified: true, summary: "Copied to clipboard.") }
        if mode == .askEachTime { clipboard.writeString(text); return ActionReceipt(toolName: .copyText, requestedTarget: "clipboard", success: true, verified: true, summary: "Ready to paste from the clipboard.") }
        if mode == .typeIntoFocusedApp { return await typeIntoFocusedApp(text) }
        return await selectedText.replaceSelection(with: text)
    }

    public func press(_ key: TextNavigationKey) async -> ActionReceipt {
        let started = Date()
        guard AXIsProcessTrusted() else {
            return ActionReceipt(toolName: .typeText, requestedTarget: key.description, success: false, verified: false, summary: "Accessibility permission is required to move through the focused app.", startedAt: started, endedAt: Date(), failureCategory: .permission, permissionBlocked: true)
        }
        let keyCode: CGKeyCode = key == .tab ? 48 : 36
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return ActionReceipt(toolName: .typeText, requestedTarget: key.description, success: false, verified: false, summary: "macOS could not create the keyboard event.", startedAt: started, endedAt: Date(), failureCategory: .permission, permissionBlocked: true)
        }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return ActionReceipt(toolName: .typeText, requestedTarget: key.description, success: true, verified: true, summary: "Pressed \(key.description).", startedAt: started, endedAt: Date())
    }

    private func typeIntoFocusedApp(_ text: String) async -> ActionReceipt {
        let started = Date()
        guard AXIsProcessTrusted() else {
            return ActionReceipt(toolName: .typeText, requestedTarget: "focused app", success: false, verified: false, summary: "Accessibility permission is required to type into another app.", startedAt: started, endedAt: Date(), failureCategory: .permission, permissionBlocked: true)
        }
        do {
            return try await clipboard.withPreservedClipboard {
                clipboard.writeString(text)
                postCommandKey("v")
                try await Task.sleep(nanoseconds: 180_000_000)
                return ActionReceipt(toolName: .typeText, requestedTarget: "focused app", success: true, verified: false, summary: "Typed text into the focused app.", startedAt: started, endedAt: Date())
            }
        } catch {
            return ActionReceipt(toolName: .typeText, requestedTarget: "focused app", success: false, verified: false, summary: "Copied text to the clipboard; typing could not be completed.", startedAt: started, endedAt: Date(), failureCategory: .permission, permissionBlocked: true)
        }
    }
}

public enum TextNavigationKey: Sendable, Equatable, CustomStringConvertible {
    case tab
    case returnKey

    public var description: String {
        switch self {
        case .tab: return "Tab"
        case .returnKey: return "Return"
        }
    }
}

private func postCommandKey(_ character: Character) {
    let source = CGEventSource(stateID: .combinedSessionState)
    let keyCode: CGKeyCode = character.lowercased() == "c" ? 8 : 9
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true); down?.flags = .maskCommand; down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false); up?.flags = .maskCommand; up?.post(tap: .cghidEventTap)
}
