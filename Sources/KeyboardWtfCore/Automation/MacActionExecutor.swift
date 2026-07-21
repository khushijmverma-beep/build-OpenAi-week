import AppKit
import Foundation

public final class MacActionExecutor: ActionExecutor {
    private let apps: AppResolver
    private let delivery: TextDeliveryService
    private let selectedText: SelectedTextProvider
    private let clipboard: ClipboardService
    private let system: SystemActionService
    private let files: FileSearchService
    private let windows: WindowController
    private let screen: ScreenCaptureService
    private let spotify: SpotifyPlaybackController
    private let memory: MemoryStore
    private let workflows: WorkflowStore
    private let decoder = JSONDecoder()
    public init(apps: AppResolver, delivery: TextDeliveryService, selectedText: SelectedTextProvider, clipboard: ClipboardService, system: SystemActionService, files: FileSearchService, windows: WindowController, screen: ScreenCaptureService, memory: MemoryStore, workflows: WorkflowStore, spotify: SpotifyPlaybackController = MacSpotifyPlaybackController()) { self.apps = apps; self.delivery = delivery; self.selectedText = selectedText; self.clipboard = clipboard; self.system = system; self.files = files; self.windows = windows; self.screen = screen; self.memory = memory; self.workflows = workflows; self.spotify = spotify }

    public func execute(_ call: ToolCall, confirmed: Bool) async -> ActionReceipt {
        switch call.name {
        case .openApp:
            guard let args = decode(NameArguments.self, call) else { return invalid(call) }
            switch await apps.resolve(args.name) {
            case let .resolved(candidate): return await apps.open(candidate)
            case let .ambiguous(candidates): return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "I found multiple matches: \(candidates.map(\.name).joined(separator: ", ")).", failureCategory: .ambiguous)
            case .notFound: return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "I could not find \(args.name).", failureCategory: .notFound)
            }
        case .focusApp:
            guard let args = decode(NameArguments.self, call) else { return invalid(call) }
            switch await apps.resolve(args.name) {
            case let .resolved(candidate): return await apps.focus(candidate)
            case let .ambiguous(candidates): return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "I found multiple matches: \(candidates.map(\.name).joined(separator: ", ")).", failureCategory: .ambiguous)
            case .notFound: return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "I could not find \(args.name).", failureCategory: .notFound)
            }
        case .closeApp:
            guard let args = decode(NameArguments.self, call) else { return invalid(call) }
            switch await apps.resolve(args.name) {
            case let .resolved(candidate): return await apps.quit(candidate)
            case let .ambiguous(candidates): return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "I found multiple matches: \(candidates.map(\.name).joined(separator: ", ")).", failureCategory: .ambiguous)
            case .notFound: return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "I could not find \(args.name).", failureCategory: .notFound)
            }
        case .openURL, .webSearch:
            guard let args = decode(URLArguments.self, call) else { return invalid(call) }
            let raw = call.name == .webSearch ? "https://www.google.com/search?q=\(args.url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" : args.url
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return ActionReceipt(toolName: call.name, requestedTarget: args.url, success: false, verified: false, summary: "Only secure web URLs can be opened.", failureCategory: .validation) }
            let success = NSWorkspace.shared.open(url)
            return ActionReceipt(toolName: call.name, requestedTarget: args.url, resolvedTarget: url.absoluteString, success: success, verified: success, summary: success ? "Opened \(call.name == .webSearch ? "search" : "URL")." : "Could not open that URL.", failureCategory: success ? .none : .unknown)
        case .typeText:
            guard let args = decode(TextArguments.self, call) else { return invalid(call) }
            let receipt = await delivery.deliver(args.text, mode: .typeIntoFocusedApp)
            return ActionReceipt(toolName: .typeText, requestedTarget: "focused app", success: receipt.success, verified: receipt.verified, summary: receipt.summary, failureCategory: receipt.failureCategory, permissionBlocked: receipt.permissionBlocked)
        case .copyText:
            guard let args = decode(TextArguments.self, call) else { return invalid(call) }
            clipboard.writeString(args.text); return ActionReceipt(toolName: .copyText, requestedTarget: "clipboard", success: true, verified: true, summary: "Copied text to the clipboard.")
        case .playSpotifyPlaylist:
            guard let args = decode(PlaylistArguments.self, call) else { return invalid(call) }
            return await spotify.playPlaylist(reference: args.reference)
        case .getSelectedText:
            let context = await selectedText.capture(); return ActionReceipt(toolName: .getSelectedText, requestedTarget: "selected text", success: !context.text.isEmpty, verified: context.method == .accessibility, summary: context.text.isEmpty ? "No selected text is available." : "Captured selected text.", failureCategory: context.text.isEmpty ? .notFound : .none)
        case .listRunningApps:
            let names = NSWorkspace.shared.runningApplications.compactMap(\.localizedName).sorted()
            return ActionReceipt(toolName: call.name, requestedTarget: "running apps", success: true, verified: true, summary: names.prefix(20).joined(separator: ", "))
        case .listWindows:
            let result = await windows.listWindows()
            return ActionReceipt(toolName: call.name, requestedTarget: "windows", success: true, verified: true, summary: result.prefix(8).joined(separator: " • "))
        case .focusWindow:
            guard let args = decode(TitleArguments.self, call) else { return invalid(call) }
            return await windows.focusWindow(matching: args.title)
        case .minimiseWindow:
            guard let args = decode(TitleArguments.self, call) else { return invalid(call) }
            return await windows.minimiseWindow(matching: args.title)
        case .takeScreenshot:
            do {
                let url = try await screen.screenshot()
                return ActionReceipt(toolName: call.name, requestedTarget: "screen", resolvedTarget: url.path, success: true, verified: FileManager.default.fileExists(atPath: url.path), summary: "Saved a screenshot to \(url.lastPathComponent).")
            } catch AppError.permission {
                return ActionReceipt(toolName: call.name, requestedTarget: "screen", success: false, verified: false, summary: "Screen Recording permission is required before taking a screenshot.", failureCategory: .permission, permissionBlocked: true)
            } catch {
                return ActionReceipt(toolName: call.name, requestedTarget: "screen", success: false, verified: false, summary: "Could not capture the screen.", failureCategory: .unknown)
            }
        case .searchFiles:
            guard let args = decode(SearchArguments.self, call) else { return invalid(call) }
            do {
                let result = try await files.search(query: args.query, roots: defaultSearchRoots())
                return ActionReceipt(toolName: call.name, requestedTarget: args.query, success: !result.isEmpty, verified: true, summary: result.prefix(5).map(\.path).joined(separator: " • "), failureCategory: result.isEmpty ? .notFound : .none)
            } catch { return ActionReceipt(toolName: call.name, requestedTarget: args.query, success: false, verified: false, summary: "File search could not finish.", failureCategory: .unknown) }
        case .openFile, .openFolder:
            guard let args = decode(PathArguments.self, call), args.path.hasPrefix("/") else { return invalid(call) }
            let url = URL(fileURLWithPath: args.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return ActionReceipt(toolName: call.name, requestedTarget: args.path, success: false, verified: false, summary: "That path no longer exists.", failureCategory: .notFound) }
            guard isApprovedPath(url) else { return ActionReceipt(toolName: call.name, requestedTarget: args.path, success: false, verified: false, summary: "That path is outside approved user folders.", failureCategory: .denied) }
            guard (call.name == .openFolder) == isDirectory.boolValue else { return ActionReceipt(toolName: call.name, requestedTarget: args.path, success: false, verified: false, summary: "That path is not the requested type.", failureCategory: .validation) }
            guard isDirectory.boolValue || !blockedFile(url) else { return ActionReceipt(toolName: call.name, requestedTarget: args.path, success: false, verified: false, summary: "Opening executable or installer files is blocked.", failureCategory: .denied) }
            let success = NSWorkspace.shared.open(url)
            return ActionReceipt(toolName: call.name, requestedTarget: args.path, resolvedTarget: url.path, success: success, verified: success, summary: success ? "Opened \(url.lastPathComponent)." : "Could not open that path.", failureCategory: success ? .none : .unknown)
        case .remember:
            guard let args = decode(MemoryArguments.self, call) else { return invalid(call) }
            do { try await memory.remember(key: args.key, value: args.value, sensitivity: .ordinary); return ActionReceipt(toolName: call.name, requestedTarget: args.key, success: true, verified: true, summary: "Remembered \(args.key).") } catch { return ActionReceipt(toolName: call.name, requestedTarget: args.key, success: false, verified: false, summary: error.localizedDescription, failureCategory: .validation) }
        case .searchMemory:
            guard let args = decode(SearchArguments.self, call) else { return invalid(call) }
            do { let results = try await memory.search(args.query); return ActionReceipt(toolName: call.name, requestedTarget: args.query, success: !results.isEmpty, verified: true, summary: results.map { "\($0.key): \($0.value)" }.joined(separator: " • "), failureCategory: results.isEmpty ? .notFound : .none) } catch { return ActionReceipt(toolName: call.name, requestedTarget: args.query, success: false, verified: false, summary: "Memory search failed.", failureCategory: .unknown) }
        case .createWorkflow:
            guard let args = decode(WorkflowArguments.self, call), let steps = try? JSONDecoder().decode([WorkflowStep].self, from: Data(args.steps.utf8)) else { return invalid(call) }
            do { let workflow = Workflow(name: args.name, triggers: args.triggers.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }, steps: steps); try await workflows.save(workflow); return ActionReceipt(toolName: call.name, requestedTarget: workflow.name, success: true, verified: true, summary: "Saved workflow \(workflow.name).") } catch { return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "Could not save workflow.", failureCategory: .validation) }
        case .listWorkflows:
            do { let items = try await workflows.all(); return ActionReceipt(toolName: call.name, requestedTarget: "workflows", success: true, verified: true, summary: items.map(\.name).joined(separator: ", ")) } catch { return ActionReceipt(toolName: call.name, requestedTarget: "workflows", success: false, verified: false, summary: "Could not load workflows.", failureCategory: .unknown) }
        case .runWorkflow:
            guard let args = decode(NameArguments.self, call) else { return invalid(call) }
            do {
                let items = try await workflows.all()
                guard let workflow = items.first(where: { $0.name.caseInsensitiveCompare(args.name) == .orderedSame }) else { return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "No workflow named \(args.name).", failureCategory: .notFound) }
                for step in workflow.steps {
                    let receipt = await execute(ToolCall(id: UUID().uuidString, name: step.tool, argumentsJSON: step.argumentsJSON), confirmed: false)
                    if !receipt.success { return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "Workflow stopped: \(receipt.summary)", failureCategory: receipt.failureCategory) }
                }
                return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: true, verified: true, summary: "Ran workflow \(workflow.name).")
            } catch { return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "Workflow could not run.", failureCategory: .unknown) }
        case .restartMac: return await system.perform(.restart, confirmed: confirmed)
        case .shutDownMac: return await system.perform(.shutDown, confirmed: confirmed)
        default: return ActionReceipt(toolName: call.name, requestedTarget: "", success: false, verified: false, summary: "\(call.name.rawValue) is not implemented in this build.", failureCategory: .unsupported)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ call: ToolCall) -> T? { try? decoder.decode(type, from: Data(call.argumentsJSON.utf8)) }
    private func invalid(_ call: ToolCall) -> ActionReceipt { ActionReceipt(toolName: call.name, requestedTarget: "", success: false, verified: false, summary: "The requested action had invalid arguments.", failureCategory: .validation) }
    private func defaultSearchRoots() -> [URL] { let manager = FileManager.default; return [.desktopDirectory, .documentDirectory, .downloadsDirectory, .picturesDirectory, .moviesDirectory, .musicDirectory].compactMap { manager.urls(for: $0, in: .userDomainMask).first } }
    private func isApprovedPath(_ url: URL) -> Bool { defaultSearchRoots().contains { url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") || url.standardizedFileURL == $0.standardizedFileURL } }
    private func blockedFile(_ url: URL) -> Bool { ["app", "command", "sh", "bash", "zsh", "pkg", "dmg", "iso", "exe", "msi", "scpt"].contains(url.pathExtension.lowercased()) }
}

private struct NameArguments: Decodable { let name: String }
private struct URLArguments: Decodable { let url: String }
private struct TextArguments: Decodable { let text: String }
private struct SearchArguments: Decodable { let query: String }
private struct PathArguments: Decodable { let path: String }
private struct TitleArguments: Decodable { let title: String }
private struct MemoryArguments: Decodable { let key: String; let value: String }
private struct WorkflowArguments: Decodable { let name: String; let triggers: String; let steps: String }
private struct PlaylistArguments: Decodable { let reference: String }
