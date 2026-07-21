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
    private let screenClick: ScreenClickService
    private let camera: CameraCaptureService
    private let media: MediaPlaybackController
    private let screenAnalyzer: ScreenAnalyzer
    private let spotify: SpotifyPlaybackController
    private let memory: MemoryStore
    private let workflows: WorkflowStore
    private let decoder = JSONDecoder()
    public init(apps: AppResolver, delivery: TextDeliveryService, selectedText: SelectedTextProvider, clipboard: ClipboardService, system: SystemActionService, files: FileSearchService, windows: WindowController, screen: ScreenCaptureService, memory: MemoryStore, workflows: WorkflowStore, spotify: SpotifyPlaybackController = MacSpotifyPlaybackController(), media: MediaPlaybackController = MacMediaPlaybackController(), screenAnalyzer: ScreenAnalyzer = UnavailableScreenAnalyzer(), screenClick: ScreenClickService = UnavailableScreenClickService(), camera: CameraCaptureService = MacCameraCaptureService()) { self.apps = apps; self.delivery = delivery; self.selectedText = selectedText; self.clipboard = clipboard; self.system = system; self.files = files; self.windows = windows; self.screen = screen; self.screenClick = screenClick; self.camera = camera; self.memory = memory; self.workflows = workflows; self.spotify = spotify; self.media = media; self.screenAnalyzer = screenAnalyzer }

    public func execute(_ call: ToolCall, confirmed: Bool) async -> ActionReceipt {
        switch call.name {
        case .openApp:
            guard let args = decode(NameArguments.self, call) else { return invalid(call) }
            return await openApplication(named: args.name)
        case .openApps:
            guard let args = decode(NamesArguments.self, call) else { return invalid(call) }
            let names = args.names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !names.isEmpty else { return invalid(call) }
            var summaries = [String](); var allSucceeded = true
            for name in names {
                let receipt = await openApplication(named: name)
                allSucceeded = allSucceeded && receipt.success
                summaries.append(receipt.summary)
            }
            return ActionReceipt(toolName: call.name, requestedTarget: args.names, success: allSucceeded, verified: allSucceeded, summary: summaries.joined(separator: " "), failureCategory: allSucceeded ? .none : .unknown)
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
        case .openURL:
            guard let args = decode(URLArguments.self, call) else { return invalid(call) }
            guard let url = URL(string: args.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return ActionReceipt(toolName: call.name, requestedTarget: args.url, success: false, verified: false, summary: "Only secure web URLs can be opened.", failureCategory: .validation) }
            let success = NSWorkspace.shared.open(url)
            return ActionReceipt(toolName: call.name, requestedTarget: args.url, resolvedTarget: url.absoluteString, success: success, verified: success, summary: success ? "Opened URL." : "Could not open that URL.", failureCategory: success ? .none : .unknown)
        case .webSearch:
            guard let args = decode(SearchArguments.self, call), !args.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return invalid(call) }
            let encoded = args.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            guard let url = URL(string: "https://www.google.com/search?q=\(encoded)") else { return invalid(call) }
            let success = NSWorkspace.shared.open(url)
            return ActionReceipt(toolName: call.name, requestedTarget: args.query, resolvedTarget: url.absoluteString, success: success, verified: success, summary: success ? "Opened web search for \(args.query)." : "Could not open that search.", failureCategory: success ? .none : .unknown)
        case .playMedia:
            return await media.play()
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
            let context = await selectedText.capture(); return ActionReceipt(toolName: .getSelectedText, requestedTarget: "selected text", success: !context.text.isEmpty, verified: context.method == .accessibility, summary: context.text.isEmpty ? "No selected text is available." : "Selected text: \(context.text)", failureCategory: context.text.isEmpty ? .notFound : .none)
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
        case .maximiseWindow:
            guard let args = decode(TitleArguments.self, call) else { return invalid(call) }
            return await windows.maximiseWindow(matching: args.title)
        case .closeWindow:
            guard let args = decode(TitleArguments.self, call) else { return invalid(call) }
            return await windows.closeWindow(matching: args.title)
        case .takeScreenshot:
            do {
                let url = try await screen.screenshot()
                return ActionReceipt(toolName: call.name, requestedTarget: "screen", resolvedTarget: url.path, success: true, verified: FileManager.default.fileExists(atPath: url.path), summary: "Saved a screenshot to \(url.lastPathComponent).")
            } catch AppError.permission {
                return ActionReceipt(toolName: call.name, requestedTarget: "screen", success: false, verified: false, summary: "Screen Recording permission is required before taking a screenshot.", failureCategory: .permission, permissionBlocked: true)
            } catch {
                return ActionReceipt(toolName: call.name, requestedTarget: "screen", success: false, verified: false, summary: "Could not capture the screen.", failureCategory: .unknown)
            }
        case .inspectScreen:
            guard let args = decode(ScreenQuestionArguments.self, call) else { return invalid(call) }
            do {
                let url = try await screen.screenshot()
                defer { try? FileManager.default.removeItem(at: url) }
                let analysis = try await screenAnalyzer.analyze(imageAt: url, question: args.question)
                return ActionReceipt(toolName: call.name, requestedTarget: "screen", success: true, verified: true, summary: analysis)
            } catch AppError.permission {
                return ActionReceipt(toolName: call.name, requestedTarget: "screen", success: false, verified: false, summary: "Screen Recording permission is required before analyzing the screen.", failureCategory: .permission, permissionBlocked: true)
            } catch {
                return ActionReceipt(toolName: call.name, requestedTarget: "screen", success: false, verified: false, summary: error.localizedDescription, failureCategory: .unknown)
            }
        case .clickScreen:
            guard let args = decode(ScreenClickArguments.self, call), !args.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return invalid(call) }
            return await screenClick.click(target: args.target)
        case .composeEmail:
            guard let args = decode(ComposeEmailArguments.self, call), !args.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !args.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return invalid(call) }
            return await composeEmail(args)
        case .takeWebcamPhoto:
            do {
                let url = try await camera.capturePhoto()
                return ActionReceipt(toolName: call.name, requestedTarget: "camera", resolvedTarget: url.path, success: true, verified: FileManager.default.fileExists(atPath: url.path), summary: "Saved a camera photo to \(url.lastPathComponent).")
            } catch AppError.permission {
                return ActionReceipt(toolName: call.name, requestedTarget: "camera", success: false, verified: false, summary: "Camera permission is required before taking a photo.", failureCategory: .permission, permissionBlocked: true)
            } catch {
                return ActionReceipt(toolName: call.name, requestedTarget: "camera", success: false, verified: false, summary: error.localizedDescription, failureCategory: .unknown)
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
        case .forget:
            guard let args = decode(NameArguments.self, call) else { return invalid(call) }
            do {
                let removed = try await memory.forget(key: args.name)
                return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: removed, verified: removed, summary: removed ? "Forgot \(args.name)." : "No memory named \(args.name) was found.", failureCategory: removed ? .none : .notFound)
            } catch { return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "Could not remove that memory.", failureCategory: .unknown) }
        case .clearMemory:
            do { try await memory.clear(); return ActionReceipt(toolName: call.name, requestedTarget: "all memories", success: true, verified: true, summary: "Cleared all saved memories.") }
            catch { return ActionReceipt(toolName: call.name, requestedTarget: "all memories", success: false, verified: false, summary: "Could not clear saved memories.", failureCategory: .unknown) }
        case .searchMemory:
            guard let args = decode(SearchArguments.self, call) else { return invalid(call) }
            do { let results = try await memory.search(args.query); return ActionReceipt(toolName: call.name, requestedTarget: args.query, success: !results.isEmpty, verified: true, summary: results.map { "\($0.key): \($0.value)" }.joined(separator: " • "), failureCategory: results.isEmpty ? .notFound : .none) } catch { return ActionReceipt(toolName: call.name, requestedTarget: args.query, success: false, verified: false, summary: "Memory search failed.", failureCategory: .unknown) }
        case .createWorkflow:
            guard let args = decode(WorkflowArguments.self, call), let steps = try? JSONDecoder().decode([WorkflowStep].self, from: Data(args.steps.utf8)) else { return invalid(call) }
            do { let workflow = Workflow(name: args.name, triggers: args.triggers.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }, steps: steps); try await workflows.save(workflow); return ActionReceipt(toolName: call.name, requestedTarget: workflow.name, success: true, verified: true, summary: "Saved workflow \(workflow.name).") } catch { return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "Could not save workflow.", failureCategory: .validation) }
        case .listWorkflows:
            do { let items = try await workflows.all(); return ActionReceipt(toolName: call.name, requestedTarget: "workflows", success: true, verified: true, summary: items.map(\.name).joined(separator: ", ")) } catch { return ActionReceipt(toolName: call.name, requestedTarget: "workflows", success: false, verified: false, summary: "Could not load workflows.", failureCategory: .unknown) }
        case .deleteWorkflow:
            guard let args = decode(NameArguments.self, call) else { return invalid(call) }
            do {
                let removed = try await workflows.delete(name: args.name)
                return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: removed, verified: removed, summary: removed ? "Deleted workflow \(args.name)." : "No workflow named \(args.name) was found.", failureCategory: removed ? .none : .notFound)
            } catch { return ActionReceipt(toolName: call.name, requestedTarget: args.name, success: false, verified: false, summary: "Could not delete workflow.", failureCategory: .unknown) }
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

    private func openApplication(named name: String) async -> ActionReceipt {
        switch await apps.resolve(name) {
        case let .resolved(candidate): return await apps.open(candidate)
        case let .ambiguous(candidates): return ActionReceipt(toolName: .openApp, requestedTarget: name, success: false, verified: false, summary: "I found multiple matches: \(candidates.map(\.name).joined(separator: ", ")).", failureCategory: .ambiguous)
        case .notFound: return ActionReceipt(toolName: .openApp, requestedTarget: name, success: false, verified: false, summary: "I could not find \(name).", failureCategory: .notFound)
        }
    }

    private func composeEmail(_ args: ComposeEmailArguments) async -> ActionReceipt {
        let started = Date()
        let requestedApp = args.app?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let useGmail = requestedApp.isEmpty || requestedApp.localizedCaseInsensitiveContains("gmail") || requestedApp.localizedCaseInsensitiveContains("gmail.com")
        let appName = useGmail ? "Gmail" : requestedApp
        var opened = false
        if useGmail {
            // Gmail is the default for “create an email” so the task starts in
            // the browser rather than waiting for Mail or another app to open.
            opened = NSWorkspace.shared.open(URL(string: "https://mail.google.com")!)
        } else {
            switch await apps.resolve(appName) {
            case let .resolved(candidate):
                let openReceipt = await apps.open(candidate)
                opened = openReceipt.success
                if !opened { opened = (await apps.focus(candidate)).success }
            case .notFound where appName.localizedCaseInsensitiveContains("outlook"):
                opened = NSWorkspace.shared.open(URL(string: "https://outlook.live.com/mail")!)
            case let .ambiguous(candidates):
                return composeFailure(args.to, "I found multiple email apps: \(candidates.map { $0.name }.joined(separator: ", ")).", started: started, category: .ambiguous)
            case .notFound:
                return composeFailure(args.to, "I could not find the email app \(appName).", started: started, category: .notFound)
            }
        }
        guard opened else { return composeFailure(args.to, "I could not open \(appName).", started: started, category: .unknown) }
        try? await Task.sleep(nanoseconds: 300_000_000)

        let compose = await clickScreenWithRetry(target: "Compose button or New Message button")
        guard compose.success else { return composeFailure(args.to, "Could not open a compose window: \(compose.summary)", started: started, category: compose.failureCategory, permissionBlocked: compose.permissionBlocked) }
        try? await Task.sleep(nanoseconds: 120_000_000)

        let recipientField = await clickScreenWithRetry(target: "To recipient field in the compose window")
        guard recipientField.success else { return composeFailure(args.to, "Could not find the recipient field: \(recipientField.summary)", started: started, category: recipientField.failureCategory, permissionBlocked: recipientField.permissionBlocked) }
        let recipient = await delivery.deliver(args.to, mode: .typeIntoFocusedApp)
        guard recipient.success else { return composeFailure(args.to, recipient.summary, started: started, category: recipient.failureCategory, permissionBlocked: recipient.permissionBlocked) }

        if !args.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let subjectField = await clickScreenWithRetry(target: "Subject field in the compose window")
            guard subjectField.success else { return composeFailure(args.to, "Could not find the subject field: \(subjectField.summary)", started: started, category: subjectField.failureCategory, permissionBlocked: subjectField.permissionBlocked) }
            let subject = await delivery.deliver(args.subject, mode: .typeIntoFocusedApp)
            guard subject.success else { return composeFailure(args.to, subject.summary, started: started, category: subject.failureCategory, permissionBlocked: subject.permissionBlocked) }
        }

        let messageField = await clickScreenWithRetry(target: "message body field in the compose window")
        guard messageField.success else { return composeFailure(args.to, "Could not find the message field: \(messageField.summary)", started: started, category: messageField.failureCategory, permissionBlocked: messageField.permissionBlocked) }
        let body = await delivery.deliver(args.body, mode: .typeIntoFocusedApp)
        guard body.success else { return composeFailure(args.to, body.summary, started: started, category: body.failureCategory, permissionBlocked: body.permissionBlocked) }
        return ActionReceipt(toolName: .composeEmail, requestedTarget: args.to, resolvedTarget: appName, success: true, verified: true, summary: "Drafted an email in \(appName) to \(args.to). It was not sent.", startedAt: started, endedAt: Date())
    }

    private func clickScreenWithRetry(target: String, attempts: Int = 5) async -> ActionReceipt {
        var last = ActionReceipt(toolName: .clickScreen, requestedTarget: target, success: false, verified: false, summary: "The screen is still loading.", failureCategory: .notFound)
        for attempt in 0..<attempts {
            let receipt = await screenClick.click(target: target)
            if receipt.success || receipt.permissionBlocked || receipt.failureCategory == .denied || receipt.failureCategory == .validation { return receipt }
            last = receipt
            if attempt + 1 < attempts { try? await Task.sleep(nanoseconds: 350_000_000) }
        }
        return last
    }

    private func composeFailure(_ target: String, _ summary: String, started: Date, category: FailureCategory, permissionBlocked: Bool = false) -> ActionReceipt {
        ActionReceipt(toolName: .composeEmail, requestedTarget: target, success: false, verified: false, summary: summary, startedAt: started, endedAt: Date(), failureCategory: category, permissionBlocked: permissionBlocked)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ call: ToolCall) -> T? { try? decoder.decode(type, from: Data(call.argumentsJSON.utf8)) }
    private func invalid(_ call: ToolCall) -> ActionReceipt { ActionReceipt(toolName: call.name, requestedTarget: "", success: false, verified: false, summary: "The requested action had invalid arguments.", failureCategory: .validation) }
    private func defaultSearchRoots() -> [URL] { let manager = FileManager.default; return [.desktopDirectory, .documentDirectory, .downloadsDirectory, .picturesDirectory, .moviesDirectory, .musicDirectory].compactMap { manager.urls(for: $0, in: .userDomainMask).first } }
    private func isApprovedPath(_ url: URL) -> Bool { defaultSearchRoots().contains { url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") || url.standardizedFileURL == $0.standardizedFileURL } }
    private func blockedFile(_ url: URL) -> Bool { ["app", "command", "sh", "bash", "zsh", "pkg", "dmg", "iso", "exe", "msi", "scpt"].contains(url.pathExtension.lowercased()) }
}

private struct NameArguments: Decodable { let name: String }
private struct NamesArguments: Decodable { let names: String }
private struct URLArguments: Decodable { let url: String }
private struct TextArguments: Decodable { let text: String }
private struct SearchArguments: Decodable { let query: String }
private struct PathArguments: Decodable { let path: String }
private struct TitleArguments: Decodable { let title: String }
private struct MemoryArguments: Decodable { let key: String; let value: String }
private struct WorkflowArguments: Decodable { let name: String; let triggers: String; let steps: String }
private struct PlaylistArguments: Decodable { let reference: String }
private struct ScreenQuestionArguments: Decodable { let question: String }
private struct ScreenClickArguments: Decodable { let target: String }
private struct ComposeEmailArguments: Decodable { let app: String?; let to: String; let subject: String; let body: String }

public final class UnavailableScreenAnalyzer: ScreenAnalyzer {
    public init() {}
    public func analyze(imageAt url: URL, question: String) async throws -> String { throw AppError.unsupported("Screen analysis is unavailable in this configuration.") }
}

public final class UnavailableScreenClickService: ScreenClickService {
    public init() {}
    public func click(target: String) async -> ActionReceipt {
        ActionReceipt(toolName: .clickScreen, requestedTarget: target, success: false, verified: false, summary: "Screen clicking is unavailable in this configuration.", failureCategory: .unsupported)
    }
}
