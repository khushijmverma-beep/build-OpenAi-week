import AppKit
import KeyboardWtfCore
import SwiftUI

@main
struct KeyboardWtfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene { Settings { SettingsView(environment: appDelegate.environment) } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var environment: AppEnvironment?
    private var overlay: OverlayPanelController?
    private var menuBar: MenuBarController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let environment = try AppEnvironment(); self.environment = environment
            environment.presentSettings = { [weak self] in self?.showSettings() }
            overlay = OverlayPanelController(store: environment.state, coordinator: environment.coordinator)
            menuBar = MenuBarController(coordinator: environment.coordinator, openSettings: { [weak self] in self?.showSettings() })
            do { try environment.hotkeys.registerDefaults() }
            catch { environment.state.transition(to: AssistantSnapshot(phase: .error, title: "Hotkeys unavailable", detail: error.localizedDescription)) }
        } catch {
            environment = nil
        }
    }

    private func showSettings() {
        guard let environment else { return }
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 470),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "keyboard.wtf Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(environment: environment))
        window.center()
        window.setFrameAutosaveName("keyboard.wtf.settings")
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
