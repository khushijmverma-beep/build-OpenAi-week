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
    private let initialSettingsShownKey = "keyboard.wtf.initial-settings-shown"
    private(set) var environment: AppEnvironment?
    private var overlay: OverlayPanelController?
    private var menuBar: MenuBarController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // This is a menu-bar agent with intentionally transient overlay panels,
        // so it normally has no document window. Keep the process alive for
        // global hotkeys and active Jarvis sessions when Spaces/displays change.
        ProcessInfo.processInfo.disableAutomaticTermination("keyboard.wtf menu bar assistant")
        do {
            let environment = try AppEnvironment(); self.environment = environment
            environment.presentSettings = { [weak self] in self?.showSettings() }
            overlay = OverlayPanelController(store: environment.state, coordinator: environment.coordinator)
            menuBar = MenuBarController(coordinator: environment.coordinator, openSettings: { [weak self] in self?.showSettings() })
            do { try environment.hotkeys.register(environment.settings.settings) }
            catch { environment.state.transition(to: AssistantSnapshot(phase: .error, title: "Hotkeys unavailable", detail: error.localizedDescription)) }
            showInitialSettingsIfNeeded()
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

    private func showInitialSettingsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: initialSettingsShownKey) else { return }
        UserDefaults.standard.set(true, forKey: initialSettingsShownKey)
        showSettings()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
