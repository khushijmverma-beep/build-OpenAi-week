import AppKit
import ApplicationServices
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public final class MacAppResolver: AppResolver {
    private let workspace: NSWorkspace
    private var candidates = [AppCandidate]()
    private var lastRefresh = Date.distantPast
    public init(workspace: NSWorkspace = .shared) { self.workspace = workspace }

    public func resolve(_ query: String) async -> AppResolution {
        refreshIfNeeded()
        let normalized = FuzzyScore.normalize(query)
        let matches = candidates.map { candidate in (candidate, FuzzyScore.score(query, candidate.name)) }
            .filter { $0.1 >= 0.50 || FuzzyScore.normalize($0.0.bundleIdentifier ?? "") == normalized }
            .sorted { $0.1 > $1.1 }
            .map { AppCandidate(id: $0.0.id, name: $0.0.name, bundleIdentifier: $0.0.bundleIdentifier, url: $0.0.url, score: $0.1, source: $0.0.source) }
        guard let first = matches.first else { return .notFound(query) }
        if matches.count > 1, first.score - matches[1].score < 0.12 { return .ambiguous(Array(matches.prefix(4))) }
        return .resolved(first)
    }

    public func open(_ candidate: AppCandidate) async -> ActionReceipt {
        let started = Date()
        guard isTrustedApplication(candidate.url) else { return ActionReceipt(toolName: .openApp, requestedTarget: candidate.name, success: false, verified: false, summary: "That app bundle is not in an approved Applications location.", startedAt: started, endedAt: Date(), failureCategory: .denied) }
        let success = workspace.open(candidate.url)
        return ActionReceipt(toolName: .openApp, requestedTarget: candidate.name, resolvedTarget: candidate.url.path, success: success, verified: success, summary: success ? "Opened \(candidate.name)." : "Could not open \(candidate.name).", startedAt: started, endedAt: Date(), failureCategory: success ? .none : .unknown)
    }

    public func focus(_ candidate: AppCandidate) async -> ActionReceipt {
        let started = Date()
        guard let application = runningApplication(for: candidate) else {
            return ActionReceipt(toolName: .focusApp, requestedTarget: candidate.name, success: false, verified: false, summary: "\(candidate.name) is not running.", startedAt: started, endedAt: Date(), failureCategory: .notFound)
        }
        let success = application.activate(options: [])
        try? await Task.sleep(nanoseconds: 120_000_000)
        let verified = workspace.frontmostApplication?.processIdentifier == application.processIdentifier
        return ActionReceipt(toolName: .focusApp, requestedTarget: candidate.name, resolvedTarget: candidate.url.path, success: success, verified: verified, summary: success ? "Focused \(candidate.name)." : "Could not focus \(candidate.name).", startedAt: started, endedAt: Date(), failureCategory: success ? .none : .permission, permissionBlocked: !success)
    }

    public func quit(_ candidate: AppCandidate) async -> ActionReceipt {
        let started = Date()
        guard let application = runningApplication(for: candidate) else {
            return ActionReceipt(toolName: .closeApp, requestedTarget: candidate.name, success: false, verified: false, summary: "\(candidate.name) is not running.", startedAt: started, endedAt: Date(), failureCategory: .notFound)
        }
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return ActionReceipt(toolName: .closeApp, requestedTarget: candidate.name, success: false, verified: false, summary: "Jarvis will not quit itself while a request is active.", startedAt: started, endedAt: Date(), failureCategory: .denied)
        }
        let requested = application.terminate()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let verified = application.isTerminated
        let summary: String
        if verified { summary = "Closed \(candidate.name)." }
        else if requested { summary = "Asked \(candidate.name) to close. macOS may be waiting for unsaved-work confirmation." }
        else { summary = "\(candidate.name) did not accept a normal quit request." }
        return ActionReceipt(toolName: .closeApp, requestedTarget: candidate.name, resolvedTarget: candidate.url.path, success: requested, verified: verified, summary: summary, startedAt: started, endedAt: Date(), failureCategory: requested ? .none : .permission, permissionBlocked: !requested)
    }

    private func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastRefresh) > 60 || candidates.isEmpty else { return }
        var values = [AppCandidate]()
        for app in workspace.runningApplications where app.activationPolicy != .prohibited {
            if let url = app.bundleURL, let name = app.localizedName { values.append(AppCandidate(id: app.bundleIdentifier ?? url.path, name: name, bundleIdentifier: app.bundleIdentifier, url: url, score: 1, source: "running")) }
        }
        let fileManager = FileManager.default
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for url in entries where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                let bundle = Bundle(url: url)
                values.append(AppCandidate(id: bundle?.bundleIdentifier ?? url.path, name: name, bundleIdentifier: bundle?.bundleIdentifier, url: url, score: 0, source: "applications"))
            }
        }
        candidates = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { old, _ in old }).values.sorted { $0.name < $1.name }
        lastRefresh = Date()
    }

    private func isTrustedApplication(_ url: URL) -> Bool { ["/Applications/", "/System/Applications/", NSHomeDirectory() + "/Applications/"].contains { url.path.hasPrefix($0) } }

    private func runningApplication(for candidate: AppCandidate) -> NSRunningApplication? {
        workspace.runningApplications.first {
            if let identifier = candidate.bundleIdentifier, $0.bundleIdentifier == identifier { return true }
            return $0.bundleURL?.standardizedFileURL == candidate.url.standardizedFileURL
        }
    }
}

/// Spotify exposes a compact Apple Events interface for playback. The user
/// approves this once in macOS's Automation prompt; this never uses a browser
/// session, password, or Spotify API token.
public final class MacSpotifyPlaybackController: SpotifyPlaybackController {
    private let workspace: NSWorkspace
    public init(workspace: NSWorkspace = .shared) { self.workspace = workspace }

    public func playPlaylist(reference: String) async -> ActionReceipt {
        let started = Date()
        guard let playlistURI = Self.playlistURI(from: reference) else {
            return ActionReceipt(toolName: .playSpotifyPlaylist, requestedTarget: reference, success: false, verified: false, summary: "For exact playback, share the Spotify playlist link or URI with Jarvis.", startedAt: started, endedAt: Date(), failureCategory: .validation)
        }
        guard workspace.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil else {
            return ActionReceipt(toolName: .playSpotifyPlaylist, requestedTarget: reference, success: false, verified: false, summary: "Spotify is not installed on this Mac.", startedAt: started, endedAt: Date(), failureCategory: .notFound)
        }
        let source = """
        tell application id "com.spotify.client"
            activate
            play track "\(playlistURI)"
        end tell
        """
        var error: NSDictionary?
        guard NSAppleScript(source: source)?.executeAndReturnError(&error) != nil else {
            let message = error?[NSAppleScript.errorMessage] as? String ?? "macOS did not allow Spotify control."
            return ActionReceipt(toolName: .playSpotifyPlaylist, requestedTarget: reference, resolvedTarget: playlistURI, success: false, verified: false, summary: message, startedAt: started, endedAt: Date(), failureCategory: .permission, permissionBlocked: true)
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
        let running = workspace.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
        return ActionReceipt(toolName: .playSpotifyPlaylist, requestedTarget: reference, resolvedTarget: playlistURI, success: true, verified: running, summary: "Asked Spotify to play the playlist.", startedAt: started, endedAt: Date())
    }

    static func playlistURI(from reference: String) -> String? {
        let clean = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("spotify:playlist:"), clean.range(of: "^spotify:playlist:[A-Za-z0-9]+$", options: .regularExpression) != nil {
            return clean
        }
        guard let url = URL(string: clean), url.host?.lowercased() == "open.spotify.com" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2, components[0].lowercased() == "playlist", components[1].range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else { return nil }
        return "spotify:playlist:\(components[1])"
    }
}

/// Sends the standard macOS media Play/Pause key to the current media player.
/// It does not inspect or capture the screen and only runs after Jarvis receives
/// an explicit play/pause request.
public final class MacMediaPlaybackController: MediaPlaybackController {
    public init() {}

    public func play() async -> ActionReceipt {
        let started = Date()
        guard AXIsProcessTrusted() else {
            return ActionReceipt(toolName: .playMedia, requestedTarget: "active media player", success: false, verified: false, summary: "Accessibility permission is required to press the system Play/Pause key.", startedAt: started, endedAt: Date(), failureCategory: .permission, permissionBlocked: true)
        }
        let keyCode: Int32 = 16 // NX_KEYTYPE_PLAY
        let data1 = Int((keyCode << 16) | (0xA << 8))
        var posted = true
        for keyDown in [true, false] {
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00), timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1 | (keyDown ? 0 : 1), data2: -1), let cgEvent = event.cgEvent else {
                posted = false
                continue
            }
            cgEvent.post(tap: .cghidEventTap)
        }
        return ActionReceipt(toolName: .playMedia, requestedTarget: "active media player", success: posted, verified: posted, summary: posted ? "Pressed Play/Pause for the active media player." : "macOS did not accept the Play/Pause key.", startedAt: started, endedAt: Date(), failureCategory: posted ? .none : .permission, permissionBlocked: !posted)
    }
}

public final class BoundedFileSearchService: FileSearchService {
    public init() {}
    public func search(query: String, roots: [URL]) async throws -> [URL] {
        let normalized = FuzzyScore.normalize(query)
        var found = [(URL, Double)](); let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        for root in roots.prefix(12) {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var visited = 0
            while let url = enumerator.nextObject() as? URL, visited < 3_000 {
                visited += 1
                let nameScore = FuzzyScore.score(query, url.deletingPathExtension().lastPathComponent)
                if nameScore >= 0.58 || FuzzyScore.normalize(url.lastPathComponent).contains(normalized) { found.append((url, nameScore)) }
            }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(30).map(\.0)
    }
}

public final class MacScreenCaptureService: ScreenCaptureService {
    public init() {}

    public func screenshot() async throws -> URL {
        guard CGPreflightScreenCaptureAccess() else { throw AppError.permission(.screenRecording) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AppError.unsupported("macOS could not find a display to capture.") }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
        let directory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("keyboard.wtf", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("Screenshot-\(stamp).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AppError.unsupported("macOS could not write the screenshot.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppError.unsupported("macOS could not finalise the screenshot.") }
        return url
    }
}

public final class MacWindowController: WindowController {
    public init() {}
    public func listWindows() async -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let name = app.localizedName else { return nil }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var rawWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &rawWindows) == .success, let windows = rawWindows as? [AXUIElement] else { return nil }
            let titles = windows.compactMap { window -> String? in var rawTitle: CFTypeRef?; guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle) == .success else { return nil }; return rawTitle as? String }.filter { !$0.isEmpty }
            return titles.isEmpty ? nil : "\(name): \(titles.joined(separator: ", "))"
        }
    }

    public func focusWindow(matching title: String) async -> ActionReceipt { await updateWindow(matching: title, tool: .focusWindow, action: kAXRaiseAction as String) }
    public func minimiseWindow(matching title: String) async -> ActionReceipt { await updateWindow(matching: title, tool: .minimiseWindow, action: nil) }
    public func maximiseWindow(matching title: String) async -> ActionReceipt { await updateWindow(matching: title, tool: .maximiseWindow, action: "AXZoomAction") }
    public func closeWindow(matching title: String) async -> ActionReceipt { await updateWindow(matching: title, tool: .closeWindow, action: "AXCloseAction") }

    private func updateWindow(matching title: String, tool: ToolName, action: String?) async -> ActionReceipt {
        let started = Date()
        for app in NSWorkspace.shared.runningApplications {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            var rawWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success, let windows = rawWindows as? [AXUIElement] else { continue }
            for window in windows {
                var rawTitle: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle) == .success, let windowTitle = rawTitle as? String, FuzzyScore.score(title, windowTitle) >= 0.56 else { continue }
                let status: AXError
                if let action { status = AXUIElementPerformAction(window, action as CFString) }
                else { status = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
                let success = status == .success
                let verb = tool == .focusWindow ? "Focused" : (tool == .minimiseWindow ? "Minimised" : (tool == .maximiseWindow ? "Maximised" : "Closed"))
                return ActionReceipt(toolName: tool, requestedTarget: title, resolvedTarget: windowTitle, success: success, verified: success, summary: success ? "\(verb) \(windowTitle)." : "macOS did not allow that window action.", startedAt: started, endedAt: Date(), failureCategory: success ? .none : .permission, permissionBlocked: !success)
            }
        }
        return ActionReceipt(toolName: tool, requestedTarget: title, success: false, verified: false, summary: "No accessible window matched \(title).", startedAt: started, endedAt: Date(), failureCategory: .notFound)
    }
}

public final class DefaultPermissionPolicy: PermissionPolicy {
    public init() {}
    public func requiresConfirmation(for tool: ToolName) -> Bool { tool == .restartMac || tool == .shutDownMac }
}

public final class MacSystemActionService: SystemActionService {
    public init() {}
    public func perform(_ operation: SystemOperation, confirmed: Bool) async -> ActionReceipt {
        let start = Date()
        if operation.requiresConfirmation && !confirmed { return ActionReceipt(toolName: operation == .restart ? .restartMac : .shutDownMac, requestedTarget: operation.rawValue, success: false, verified: false, summary: "Confirmation is required before \(operation.rawValue).", startedAt: start, endedAt: Date(), failureCategory: .denied) }
        return ActionReceipt(toolName: operation == .lock ? .lockMac : (operation == .sleep ? .sleepMac : (operation == .restart ? .restartMac : .shutDownMac)), requestedTarget: operation.rawValue, success: false, verified: false, summary: "macOS system power controls are intentionally unavailable until their permission path is verified on this Mac.", startedAt: start, endedAt: Date(), failureCategory: .unsupported, confirmationUsed: confirmed)
    }
}

public final class DefaultToolRegistry: ToolRegistry {
    public init() {}
    public func schemas() -> [ToolDefinition] {
        [
            ToolDefinition(name: .openApp, description: "Open an installed macOS application by name.", parameters: [ToolParameter(name: "name", type: .string, description: "Application name")]),
            ToolDefinition(name: .openApps, description: "Open multiple installed macOS applications. Pass names as a comma-separated string.", parameters: [ToolParameter(name: "names", type: .string, description: "Comma-separated application names")]),
            ToolDefinition(name: .focusApp, description: "Bring a running macOS application to the front.", parameters: [ToolParameter(name: "name", type: .string, description: "Application name")]),
            ToolDefinition(name: .closeApp, description: "Ask a running macOS application to quit normally. Never force-quit; macOS can request confirmation for unsaved work.", parameters: [ToolParameter(name: "name", type: .string, description: "Application name")]),
            ToolDefinition(name: .openURL, description: "Open a verified http or https URL.", parameters: [ToolParameter(name: "url", type: .string, description: "URL")]),
            ToolDefinition(name: .webSearch, description: "Search the web in the default browser.", parameters: [ToolParameter(name: "query", type: .string, description: "Search query")]),
            ToolDefinition(name: .playMedia, description: "Press the standard macOS Play/Pause key for the active media player after the user explicitly asks to play or pause media.", parameters: []),
            ToolDefinition(name: .playSpotifyPlaylist, description: "Play an exact Spotify playlist using a spotify:playlist URI or an open.spotify.com/playlist link. If the user only gives a playlist name, ask them for its Spotify share link rather than guessing.", parameters: [ToolParameter(name: "reference", type: .string, description: "Spotify playlist URI or share URL")]),
            ToolDefinition(name: .typeText, description: "Insert text into the focused application without submitting it.", parameters: [ToolParameter(name: "text", type: .string, description: "Text to insert")]),
            ToolDefinition(name: .copyText, description: "Copy text to the clipboard.", parameters: [ToolParameter(name: "text", type: .string, description: "Text to copy")]),
            ToolDefinition(name: .getSelectedText, description: "Read currently selected text when macOS permits it.", parameters: []),
            ToolDefinition(name: .listRunningApps, description: "List running applications.", parameters: []),
            ToolDefinition(name: .listWindows, description: "List accessible windows.", parameters: []),
            ToolDefinition(name: .focusWindow, description: "Focus an accessible window by title.", parameters: [ToolParameter(name: "title", type: .string, description: "Window title")]),
            ToolDefinition(name: .minimiseWindow, description: "Minimise an accessible window by title.", parameters: [ToolParameter(name: "title", type: .string, description: "Window title")]),
            ToolDefinition(name: .maximiseWindow, description: "Maximise or zoom an accessible window by title where macOS supports it.", parameters: [ToolParameter(name: "title", type: .string, description: "Window title")]),
            ToolDefinition(name: .closeWindow, description: "Close one accessible window by title using its normal close action.", parameters: [ToolParameter(name: "title", type: .string, description: "Window title")]),
            ToolDefinition(name: .takeScreenshot, description: "Take an explicit screenshot and save it locally. Requires Screen Recording permission.", parameters: []),
            ToolDefinition(name: .takeWebcamPhoto, description: "Take one photo with the Mac camera only after the user explicitly asks.", parameters: []),
            ToolDefinition(name: .inspectScreen, description: "Capture and analyze the visible screen only when the user explicitly asks to analyze, explain, or navigate their screen.", parameters: [ToolParameter(name: "question", type: .string, description: "The user's explicit screen-analysis question")]),
            ToolDefinition(name: .searchFiles, description: "Search user-approved folders for a filename.", parameters: [ToolParameter(name: "query", type: .string, description: "Filename or phrase")]),
            ToolDefinition(name: .openFile, description: "Open an approved, non-executable local file.", parameters: [ToolParameter(name: "path", type: .string, description: "Absolute file path")]),
            ToolDefinition(name: .openFolder, description: "Open an approved local folder.", parameters: [ToolParameter(name: "path", type: .string, description: "Absolute folder path")]),
            ToolDefinition(name: .remember, description: "Store an explicit non-sensitive preference locally.", parameters: [ToolParameter(name: "key", type: .string, description: "Memory label"), ToolParameter(name: "value", type: .string, description: "Preference")]),
            ToolDefinition(name: .forget, description: "Delete one saved local memory by its label.", parameters: [ToolParameter(name: "name", type: .string, description: "Memory label")]),
            ToolDefinition(name: .clearMemory, description: "Delete all saved local memories only when the user explicitly asks to clear memory.", parameters: []),
            ToolDefinition(name: .searchMemory, description: "Search explicit local memories.", parameters: [ToolParameter(name: "query", type: .string, description: "Memory query")]),
            ToolDefinition(name: .createWorkflow, description: "Create a user-approved workflow of typed tools.", parameters: [ToolParameter(name: "name", type: .string, description: "Workflow name"), ToolParameter(name: "triggers", type: .string, description: "Comma-separated triggers"), ToolParameter(name: "steps", type: .string, description: "JSON workflow steps")]),
            ToolDefinition(name: .runWorkflow, description: "Run an explicit saved workflow.", parameters: [ToolParameter(name: "name", type: .string, description: "Workflow name")]),
            ToolDefinition(name: .listWorkflows, description: "List saved workflows.", parameters: []),
            ToolDefinition(name: .deleteWorkflow, description: "Delete one saved workflow by name.", parameters: [ToolParameter(name: "name", type: .string, description: "Workflow name")]),
            ToolDefinition(name: .restartMac, description: "Request a macOS restart. This always needs fresh confirmation.", parameters: []),
            ToolDefinition(name: .shutDownMac, description: "Request a macOS shutdown. This always needs fresh confirmation.", parameters: [])
        ]
    }
}

private enum FuzzyScore {
    static func normalize(_ value: String) -> String { value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined() }
    static func score(_ query: String, _ candidate: String) -> Double {
        let a = normalize(query), b = normalize(candidate); guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }; if b.contains(a) { return 0.88 }; if a.contains(b) { return 0.78 }
        let distance = levenshtein(a, b); return max(0, 1 - Double(distance) / Double(max(a.count, b.count)))
    }
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let left = Array(a), right = Array(b); var row = Array(0...right.count)
        for (i, char) in left.enumerated() { var next = [i + 1]; for (j, other) in right.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (char == other ? 0 : 1))) }; row = next }
        return row[right.count]
    }
}
