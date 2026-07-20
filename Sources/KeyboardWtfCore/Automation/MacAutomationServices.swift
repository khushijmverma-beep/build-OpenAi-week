import AppKit
import ApplicationServices
import Foundation
import ImageIO
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
        guard let image = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, .bestResolution) else {
            throw AppError.unsupported("macOS could not capture the screen.")
        }
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
                return ActionReceipt(toolName: tool, requestedTarget: title, resolvedTarget: windowTitle, success: success, verified: success, summary: success ? "\(tool == .focusWindow ? "Focused" : "Minimised") \(windowTitle)." : "macOS did not allow that window action.", startedAt: started, endedAt: Date(), failureCategory: success ? .none : .permission, permissionBlocked: !success)
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
            ToolDefinition(name: .openURL, description: "Open a verified http or https URL.", parameters: [ToolParameter(name: "url", type: .string, description: "URL")]),
            ToolDefinition(name: .webSearch, description: "Search the web in the default browser.", parameters: [ToolParameter(name: "query", type: .string, description: "Search query")]),
            ToolDefinition(name: .typeText, description: "Insert text into the focused application without submitting it.", parameters: [ToolParameter(name: "text", type: .string, description: "Text to insert")]),
            ToolDefinition(name: .copyText, description: "Copy text to the clipboard.", parameters: [ToolParameter(name: "text", type: .string, description: "Text to copy")]),
            ToolDefinition(name: .getSelectedText, description: "Read currently selected text when macOS permits it.", parameters: []),
            ToolDefinition(name: .listRunningApps, description: "List running applications.", parameters: []),
            ToolDefinition(name: .listWindows, description: "List accessible windows.", parameters: []),
            ToolDefinition(name: .focusWindow, description: "Focus an accessible window by title.", parameters: [ToolParameter(name: "title", type: .string, description: "Window title")]),
            ToolDefinition(name: .minimiseWindow, description: "Minimise an accessible window by title.", parameters: [ToolParameter(name: "title", type: .string, description: "Window title")]),
            ToolDefinition(name: .takeScreenshot, description: "Take an explicit screenshot and save it locally. Requires Screen Recording permission.", parameters: []),
            ToolDefinition(name: .searchFiles, description: "Search user-approved folders for a filename.", parameters: [ToolParameter(name: "query", type: .string, description: "Filename or phrase")]),
            ToolDefinition(name: .openFile, description: "Open an approved, non-executable local file.", parameters: [ToolParameter(name: "path", type: .string, description: "Absolute file path")]),
            ToolDefinition(name: .openFolder, description: "Open an approved local folder.", parameters: [ToolParameter(name: "path", type: .string, description: "Absolute folder path")]),
            ToolDefinition(name: .remember, description: "Store an explicit non-sensitive preference locally.", parameters: [ToolParameter(name: "key", type: .string, description: "Memory label"), ToolParameter(name: "value", type: .string, description: "Preference")]),
            ToolDefinition(name: .searchMemory, description: "Search explicit local memories.", parameters: [ToolParameter(name: "query", type: .string, description: "Memory query")]),
            ToolDefinition(name: .createWorkflow, description: "Create a user-approved workflow of typed tools.", parameters: [ToolParameter(name: "name", type: .string, description: "Workflow name"), ToolParameter(name: "triggers", type: .string, description: "Comma-separated triggers"), ToolParameter(name: "steps", type: .string, description: "JSON workflow steps")]),
            ToolDefinition(name: .runWorkflow, description: "Run an explicit saved workflow.", parameters: [ToolParameter(name: "name", type: .string, description: "Workflow name")]),
            ToolDefinition(name: .listWorkflows, description: "List saved workflows.", parameters: []),
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
