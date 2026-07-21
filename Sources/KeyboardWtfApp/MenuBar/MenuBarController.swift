import AppKit
import KeyboardWtfCore

@MainActor
final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let coordinator: AssistantCoordinator
    private let openSettings: () -> Void

    init(coordinator: AssistantCoordinator, openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
        self.coordinator = coordinator; super.init()
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "keyboard.wtf")
        let menu = NSMenu()
        // These actions are registered as global Carbon hotkeys. Giving the
        // menu items normal key equivalents made macOS display misleading ⌘
        // shortcuts (for example ⌘Q), which is the system Quit command.
        menu.addItem(item("Dictation   ⌃⌥D") { Task { await coordinator.start(mode: .dictation) } })
        menu.addItem(item("Smart Writing   ⌃⌥K") { Task { await coordinator.start(mode: .smartWriting) } })
        menu.addItem(item("Orisis   ⌃⌥Q") { Task { await coordinator.start(mode: .jarvis) } })
        menu.addItem(.separator())
        menu.addItem(item("Cancel   ⌃⌥X") { Task { await coordinator.cancel() } })
        menu.addItem(item("Settings…   ⌃⌥J", action: openSettings))
        menu.addItem(.separator())
        menu.addItem(item("Quit keyboard.wtf") { NSApp.terminate(nil) })
        item.menu = menu
    }
    private func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem { let menuItem = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: ""); menuItem.target = self; menuItem.representedObject = action; return menuItem }
    @objc private func runAction(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }
}
