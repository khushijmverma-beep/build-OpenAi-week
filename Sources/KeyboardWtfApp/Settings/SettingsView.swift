import KeyboardWtfCore
import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment?
    @State private var apiKey = ""
    @State private var keyStatus = "Not configured"
    @State private var jarvisStatus = "Not tested"
    var body: some View {
        if let environment {
            TabView {
                Form {
                    TextField("Assistant name", text: Binding(get: { environment.settings.settings.assistantName }, set: { environment.settings.settings.assistantName = $0 }))
                    Picker("Default delivery", selection: Binding(get: { environment.settings.settings.deliveryMode }, set: { environment.settings.settings.deliveryMode = $0 })) { Text("Type into focused app").tag(DeliveryMode.typeIntoFocusedApp); Text("Copy to clipboard").tag(DeliveryMode.copyToClipboard); Text("Ask each time").tag(DeliveryMode.askEachTime) }
                    Toggle("Auto-execute routine actions", isOn: Binding(get: { environment.settings.settings.autoExecuteRoutineActions }, set: { environment.settings.settings.autoExecuteRoutineActions = $0 }))
                    Toggle("Enable local wake phrase", isOn: Binding(get: { environment.settings.settings.wakePhraseEnabled }, set: { environment.settings.settings.wakePhraseEnabled = $0 })).disabled(true)
                    HStack {
                        Button("Start Jarvis") { Task { await environment.coordinator.start(mode: .jarvis) } }
                        Button("Cancel Jarvis") { Task { await environment.coordinator.cancel() } }
                        Spacer()
                        Text("Use these to test without a hotkey.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    LaunchAtLoginControl(settings: environment.settings, manager: environment.launchAtLogin)
                }.padding().tabItem { Label("General", systemImage: "gear") }
                Form {
                    SecureField("OpenAI API key", text: $apiKey)
                    HStack { Text(keyStatus).foregroundStyle(.secondary); Spacer(); Button("Save") { saveKey(environment) }; Button("Test Connection") { keyStatus = "Testing…"; Task { do { try await environment.testOpenAIConnection(); keyStatus = "Connection succeeded" } catch { keyStatus = error.localizedDescription } } }; Button("Delete", role: .destructive) { try? environment.credentials.delete(); apiKey = ""; keyStatus = "Not configured" } }
                    HStack { Text(jarvisStatus).foregroundStyle(.secondary); Spacer(); Button("Test Jarvis Voice") { jarvisStatus = "Testing Realtime voice…"; Task { do { let bytes = try await environment.testJarvisVoiceConnection(); jarvisStatus = "Realtime voice succeeded (\(bytes) audio bytes received)" } catch { jarvisStatus = error.localizedDescription } } } }
                    Divider(); TextField("Realtime model", text: Binding(get: { environment.settings.settings.realtimeModel }, set: { environment.settings.settings.realtimeModel = $0 })); TextField("Fast Responses model", text: Binding(get: { environment.settings.settings.responsesModel }, set: { environment.settings.settings.responsesModel = $0 })); TextField("Reasoning model", text: Binding(get: { environment.settings.settings.reasoningModel }, set: { environment.settings.settings.reasoningModel = $0 }))
                    Text("Local BYOK mode is for personal development. Your key is stored in Keychain and is never shown after saving.").font(.caption).foregroundStyle(.secondary)
                }.padding().tabItem { Label("OpenAI", systemImage: "key") }
                Form {
                    TextField("Dictation", text: Binding(get: { environment.settings.settings.dictationShortcut }, set: { environment.settings.settings.dictationShortcut = $0 }))
                    TextField("Smart Writing", text: Binding(get: { environment.settings.settings.smartWritingShortcut }, set: { environment.settings.settings.smartWritingShortcut = $0 }))
                    TextField("Jarvis", text: Binding(get: { environment.settings.settings.jarvisShortcut }, set: { environment.settings.settings.jarvisShortcut = $0 }))
                    TextField("Cancel", text: Binding(get: { environment.settings.settings.cancelShortcut }, set: { environment.settings.settings.cancelShortcut = $0 }))
                    TextField("Open Settings", text: Binding(get: { environment.settings.settings.settingsShortcut }, set: { environment.settings.settings.settingsShortcut = $0 }))
                    HStack { Text("Stop speaking"); Spacer(); Text("Control + Option + Command + X").foregroundStyle(.secondary) }
                    HStack { Button("Apply hotkeys") { do { try environment.hotkeys.register(environment.settings.settings) } catch { keyStatus = error.localizedDescription } }; Spacer(); Text("Use Control + Option combinations.").font(.caption).foregroundStyle(.secondary) }
                }.padding().tabItem { Label("Hotkeys", systemImage: "command") }
                DataSettingsView(environment: environment).tabItem { Label("Data", systemImage: "externaldrive") }
                PermissionSettingsView(center: environment.permissionCenter).tabItem { Label("Permissions", systemImage: "checkmark.shield") }
            }.frame(width: 700, height: 500).onAppear { keyStatus = isConfigured(environment) ? "Configured" : "Not configured" }
        } else { Text("keyboard.wtf could not start its local storage.").padding() }
    }
    @MainActor private func saveKey(_ environment: AppEnvironment) { do { try environment.credentials.save(apiKey: apiKey); apiKey = ""; keyStatus = "Configured" } catch { keyStatus = "Could not save key" } }
    @MainActor private func isConfigured(_ environment: AppEnvironment) -> Bool { do { return try environment.credentials.apiKey()?.isEmpty == false } catch { return false } }
}

private struct DataSettingsView: View {
    let environment: AppEnvironment
    @State private var receipts = [ActionReceipt]()
    @State private var memories = [MemoryItem]()
    @State private var workflows = [Workflow]()
    @State private var status = "Loading…"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local data").font(.headline)
                Spacer()
                Button("Refresh") { Task { await refresh() } }
                Button("Clear memories", role: .destructive) { Task { try? await environment.memoryStore.clear(); await refresh() } }
            }
            Text("History, memories, and workflows stay on this Mac. API keys remain in Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                Section("Memories") {
                    if memories.isEmpty { Text("No saved memories.").foregroundStyle(.secondary) }
                    ForEach(memories) { item in
                        HStack {
                            VStack(alignment: .leading) { Text(item.key); Text(item.value).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Forget", role: .destructive) { Task { _ = try? await environment.memoryStore.forget(key: item.key); await refresh() } }
                        }
                    }
                }
                Section("Workflows") {
                    if workflows.isEmpty { Text("No saved workflows.").foregroundStyle(.secondary) }
                    ForEach(workflows) { workflow in
                        HStack {
                            VStack(alignment: .leading) { Text(workflow.name); Text(workflow.triggers.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Delete", role: .destructive) { Task { _ = try? await environment.workflowStore.delete(name: workflow.name); await refresh() } }
                        }
                    }
                }
                Section("Recent actions") {
                    if receipts.isEmpty { Text("No action receipts yet.").foregroundStyle(.secondary) }
                    ForEach(receipts) { receipt in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(receipt.toolName.rawValue); Spacer(); Text(receipt.success ? "Succeeded" : "Failed").foregroundStyle(receipt.success ? .green : .red) }
                            Text(receipt.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .task { await refresh() }
    }

    @MainActor private func refresh() async {
        do {
            async let loadedReceipts = environment.receiptStore.recent(limit: 30)
            async let loadedMemories = environment.memoryStore.search("")
            async let loadedWorkflows = environment.workflowStore.all()
            receipts = await loadedReceipts
            memories = try await loadedMemories
            workflows = try await loadedWorkflows
            status = "Updated just now"
        } catch { status = "Could not load local data: \(error.localizedDescription)" }
    }
}

private struct LaunchAtLoginControl: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var manager: LaunchAtLoginManager
    @State private var error: String?

    var body: some View {
        Toggle("Launch keyboard.wtf at login", isOn: Binding(
            get: { settings.settings.launchAtLogin },
            set: { enabled in
                settings.settings.launchAtLogin = enabled
                error = manager.setEnabled(enabled)
            }
        ))
        HStack {
            Text(error ?? manager.detail).font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.red)
            Spacer()
            Button("Refresh") { manager.refresh() }
        }
    }
}

private struct PermissionSettingsView: View {
    @ObservedObject var center: PermissionCenter
    var body: some View { VStack(alignment: .leading) { List(center.records) { record in HStack { VStack(alignment: .leading) { Text(record.kind.rawValue).textCase(.uppercase); Text(record.detail).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(record.status.rawValue).foregroundStyle(record.status == .authorized ? .green : .secondary) } }; HStack { Button("Refresh") { center.refresh() }; Button("Accessibility") { center.openAccessibilitySettings() }; Button("Screen Recording") { center.openScreenRecordingSettings() }; Spacer() } }.padding() }
}
