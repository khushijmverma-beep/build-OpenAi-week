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
        menu.addItem(item("Dictation", key: "d") { Task { await coordinator.start(mode: .dictation) } })
        menu.addItem(item("Smart Writing", key: "k") { Task { await coordinator.start(mode: .smartWriting) } })
        menu.addItem(item("Jarvis", key: "q") { Task { await coordinator.start(mode: .jarvis) } })
        menu.addItem(.separator())
        menu.addItem(item("Cancel", key: "x") { Task { await coordinator.cancel() } })
        menu.addItem(item("Settings…", key: ",", action: openSettings))
        menu.addItem(.separator())
        menu.addItem(item("Quit keyboard.wtf", key: "q") { NSApp.terminate(nil) })
        item.menu = menu
    }
    private func item(_ title: String, key: String, action: @escaping () -> Void) -> NSMenuItem { let menuItem = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: key); menuItem.target = self; menuItem.representedObject = action; return menuItem }
    @objc private func runAction(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }
}
