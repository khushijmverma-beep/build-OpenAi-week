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
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let environment = try AppEnvironment(); self.environment = environment
            overlay = OverlayPanelController(store: environment.state, coordinator: environment.coordinator)
            menuBar = MenuBarController(coordinator: environment.coordinator)
            do { try environment.hotkeys.registerDefaults() }
            catch { environment.state.transition(to: AssistantSnapshot(phase: .error, title: "Hotkeys unavailable", detail: error.localizedDescription)) }
        } catch {
            environment = nil
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
