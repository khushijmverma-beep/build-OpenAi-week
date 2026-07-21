import Foundation

@MainActor
public final class AssistantCoordinator: AssistantCoordinatorProtocol {
    private let state: ObservableAssistantStateStore
    private let audioCapture: AudioCaptureService
    private let audioPlayback: AudioPlaybackService
    private let recognizer: LocalSpeechRecognizer
    private let responses: OpenAIResponsesClient
    private let realtime: OpenAIRealtimeClient
    private let delivery: TextDeliveryService
    private let selectedText: SelectedTextProvider
    private let tools: ToolRegistry
    private let executor: ActionExecutor
    private let policy: PermissionPolicy
    private let receiptStore: ActionReceiptStore
    private let settings: SettingsStore
    private var activeMode: AssistantMode?
    private var operationID = UUID()
    private var partialTask: Task<Void, Never>?
    private var localCompletionTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?
    private var pendingTool: ToolCall?
    private var confirmation: PendingConfirmation?
    // Realtime emits a tool call before `response.done`.  The API will reject
    // a tool result sent before that response is complete, so retain calls
    // until the terminal event arrives.  The key also removes the duplicate
    // function-call events emitted by different Realtime event variants.
    private var queuedToolCalls: [String: ToolCall] = [:]
    private var invocationSelection: SelectedTextContext?
    private let pauseDetector = PauseDetector()
    private var localSpeechDetected = false
    // Prevent the Mac's speakers from being immediately fed back through its
    // microphone as a new user turn while Jarvis is talking.
    private var suppressJarvisInputUntil: Date?
    private var estimatedJarvisPlaybackEnd: Date?
    private var pendingWordInterruption = false
    private var inputTurnTranscript = ""
    private var inputSpeechStopped = false
    private var inputResponseRequested = false
    private var inputResponseTask: Task<Void, Never>?
    private var lastOutputTranscript = ""
    private var listeningPaused = false
    private var jarvisRecoveryTask: Task<Void, Never>?
    private var jarvisRecoveryAttempts = 0

    public init(state: ObservableAssistantStateStore, audioCapture: AudioCaptureService, audioPlayback: AudioPlaybackService, recognizer: LocalSpeechRecognizer, responses: OpenAIResponsesClient, realtime: OpenAIRealtimeClient, delivery: TextDeliveryService, selectedText: SelectedTextProvider, tools: ToolRegistry, executor: ActionExecutor, policy: PermissionPolicy, receiptStore: ActionReceiptStore, settings: SettingsStore) {
        self.state = state; self.audioCapture = audioCapture; self.audioPlayback = audioPlayback; self.recognizer = recognizer; self.responses = responses; self.realtime = realtime; self.delivery = delivery; self.selectedText = selectedText; self.tools = tools; self.executor = executor; self.policy = policy; self.receiptStore = receiptStore; self.settings = settings
    }

    public func start(mode: AssistantMode) async {
        if activeMode == mode { await finishActiveMode(); return }
        await cancel(silent: true)
        // Selection is deliberate Jarvis context. Smart Dictation always starts from speech alone.
        invocationSelection = mode == .jarvis ? await selectedText.capture() : nil
        activeMode = mode; operationID = UUID()
        switch mode {
        case .dictation, .smartWriting: await beginLocalCapture(mode)
        case .jarvis: await beginJarvis()
        }
    }

    public func cancel() async { await cancel(silent: false) }
    public func setListeningPaused(_ paused: Bool) async -> Bool {
        guard activeMode == .jarvis else { return false }
        guard paused != listeningPaused else { return true }

        if paused {
            audioCapture.stop()
            listeningPaused = true
            state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Listening paused. Press Resume to listen again.", cancelHint: "⌃⌥X cancels"))
            return true
        }

        do {
            try audioCapture.start()
            listeningPaused = false
            state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Listening again.", cancelHint: "⌃⌥X cancels"))
            return true
        } catch {
            state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Listening is paused. \(error.localizedDescription)", cancelHint: "⌃⌥X cancels"))
            return false
        }
    }
    public func stopSpeakingAndListen() async -> Bool {
        guard activeMode == .jarvis else { return false }
        audioPlayback.stop()
        estimatedJarvisPlaybackEnd = nil
        suppressJarvisInputUntil = nil
        pendingWordInterruption = false
        inputResponseTask?.cancel()
        inputResponseTask = nil
        inputResponseRequested = false
        await realtime.interrupt()
        guard !listeningPaused else {
            state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Listening paused. Press Resume to listen again.", cancelHint: "⌃⌥X cancels"))
            return true
        }
        state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Listening…", cancelHint: "⌃⌥X cancels"))
        return true
    }
    public func confirmPendingAction() async {
        guard let pendingTool, let confirmation, confirmation.isValid() else { state.transition(to: AssistantSnapshot(phase: .cancelled, title: "Confirmation expired", detail: "Nothing was executed.")); self.pendingTool = nil; self.confirmation = nil; return }
        self.pendingTool = nil; self.confirmation = nil
        let receipt = await executor.execute(pendingTool, confirmed: true)
        await receiptStore.append(receipt)
        await continueAfterToolOutputs([(pendingTool.id, receiptJSON(receipt))], detail: receipt.summary)
    }

    private func beginLocalCapture(_ mode: AssistantMode) async {
        let id = operationID
        configureAudioCallback(for: mode, operationID: id)
        state.transition(to: AssistantSnapshot(phase: .listening, mode: mode, title: mode.displayName, detail: "Speak naturally. Press the same shortcut to finish.", cancelHint: "⌃⌥X cancels"))
        do {
            try await recognizer.startStreaming()
            guard operationID == id, activeMode == mode else { return }
            try audioCapture.start()
            let stream = recognizer.partialTranscript
            localSpeechDetected = false
            partialTask = Task { [weak self] in
                for await partial in stream {
                    await MainActor.run { self?.state.updatePartialTranscript(partial) }
                }
            }
            localCompletionTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard let self, self.activeMode == mode, self.localSpeechDetected else { continue }
                    if await self.pauseDetector.detectedPause() {
                        await self.finishActiveMode()
                        return
                    }
                }
            }
        } catch {
            activeMode = nil; state.transition(to: AssistantSnapshot(phase: .permissionRequired, mode: mode, title: "Local speech model required", detail: error.localizedDescription))
        }
    }

    private func finishActiveMode() async {
        guard let mode = activeMode else { return }
        if mode == .jarvis { await cancel(); return }
        let id = operationID; localCompletionTask?.cancel(); localCompletionTask = nil; audioCapture.stop(); state.transition(to: AssistantSnapshot(phase: .transcribing, mode: mode, title: "Transcribing", detail: "Finishing locally…", partialTranscript: state.snapshot.partialTranscript, cancelHint: "⌃⌥X cancels"))
        do {
            let transcript = try await recognizer.finish(); guard id == operationID else { return }
            let text: String
            if mode == .smartWriting {
                state.transition(to: AssistantSnapshot(phase: .thinking, mode: mode, title: "Polishing", detail: "Preparing ready-to-send writing…", cancelHint: "⌃⌥X cancels"))
                text = try await smartWrite(transcript); guard id == operationID else { return }
            } else { text = transcript }
            state.transition(to: AssistantSnapshot(phase: .executing, mode: mode, title: "Inserting", detail: "Delivering text to the focused app…", cancelHint: "⌃⌥X cancels"))
            let receipt = await delivery.deliver(text, mode: settings.settings.deliveryMode); await receiptStore.append(receipt); guard id == operationID else { return }
            activeMode = nil; state.transition(to: AssistantSnapshot(phase: receipt.success ? .done : .error, mode: mode, title: receipt.success ? "Done" : "Could not insert", detail: receipt.summary))
        } catch is CancellationError { }
        catch { if id == operationID { activeMode = nil; state.transition(to: AssistantSnapshot(phase: .error, title: "Could not finish", detail: error.localizedDescription)) } }
    }

    private func smartWrite(_ transcript: String) async throws -> String {
        let instructions = "Return only the requested rewritten content. Preserve factual meaning, names, URLs, numbers, and code. Remove spoken fillers and false starts, honor self-corrections, fix punctuation, and never add commentary."
        let result = try await responses.create(ResponsesRequest(model: settings.settings.responsesModel, instructions: instructions, input: transcript))
        return result.outputText
    }

    private func beginJarvis() async {
        let id = operationID
        resetJarvisState()
        state.transition(to: AssistantSnapshot(phase: .connecting, mode: .jarvis, title: settings.settings.assistantName, detail: "Starting live conversation…", cancelHint: "⌃⌥X cancels"))
        do {
            guard try await connectJarvisTransport(operationID: id) else { return }
            state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Talk naturally.", cancelHint: "⌃⌥X cancels"))
        } catch {
            if isRecoverableJarvisTransportError(error) {
                scheduleJarvisRecovery(error, operationID: id)
            } else {
                await failJarvis(error, operationID: id, title: "Could not connect")
            }
        }
    }

    private func resetJarvisState() {
        listeningPaused = false
        suppressJarvisInputUntil = nil
        estimatedJarvisPlaybackEnd = nil
        pendingWordInterruption = false
        inputTurnTranscript = ""
        inputSpeechStopped = false
        inputResponseRequested = false
        inputResponseTask?.cancel()
        inputResponseTask = nil
        lastOutputTranscript = ""
        jarvisRecoveryTask?.cancel()
        jarvisRecoveryTask = nil
        jarvisRecoveryAttempts = 0
    }

    private func jarvisConfiguration() -> RealtimeConfiguration {
        let selectionContext = invocationSelection?.text.isEmpty == false ? " The user explicitly selected this context before invoking you: \(invocationSelection!.text). Use it only when relevant to their request; do not retain it." : ""
        let instructions = "You are \(settings.settings.assistantName), a concise macOS task assistant. Use typed tools and act before speaking. For a task request, do not narrate steps or give a long explanation; after a successful task say exactly, or nearly exactly, ‘Alright, done.’ For a failure, give one short actionable sentence. For a simple request to open or navigate to a website, call open_url exactly once, use https for a bare domain such as google.com, and do not inspect the screen or wait for page contents unless the user asks you to interact with that page. When the user explicitly asks to take a screenshot, call take_screenshot exactly once and report the saved file path briefly; do not analyze the screenshot unless asked. When the user asks to click any visible button or control, first call inspect_screen to understand the current screen, then call click_screen with the requested target; click_screen also captures a fresh screen immediately before clicking, and must never click blind. When the user asks to draft, create, or write a Gmail email, call compose_email exactly once with app=gmail and keep the arguments strictly separate: to contains only the recipient name/address, subject contains only the subject line, and body contains only the message. Do not put the subject or body into to, and do not call separate typing or clicking tools for this Gmail flow. compose_email opens Gmail, clicks Compose, commits To, moves to Subject, then moves to the message body, and leaves the draft open unsent. Never click Send unless the user explicitly asks to send and confirms. When asked to type text, use type_text and do not submit the form. Close apps only with close_app; it performs a normal quit and never force-quits. When the user explicitly says to close all browser tabs, use close_all_tabs; it only closes tabs in currently running Safari and Google Chrome windows and never sends or submits anything. For Spotify playback, use play_media for the currently selected Spotify playlist or track; for an exact playlist URI or share link, use play_spotify_playlist once and do not inspect the screen or wait for page contents afterward. For an explicit task that requires a visible UI, use inspect_screen or click_screen as needed after each screen transition; do not capture screens in the background or for unrelated conversation. Screen Recording and Accessibility are required for screen analysis/clicking. Never click delete, purchase, submit, send, publish, confirm, or another consequential control without first asking for a fresh confirmation. If the user refers to text currently selected, call get_selected_text before answering so the current selection is read at that moment. When selected text is present and the user asks to translate, summarize, rewrite, or make it professional, produce the transformation and use copy_text so the result is on the clipboard; never replace their selection unless explicitly asked. Ask when ambiguous. Require a fresh confirmation for restart, shutdown, purchases, deletion, submission, sending, or other irreversible actions.\(selectionContext)"
        return RealtimeConfiguration(model: settings.settings.realtimeModel, assistantName: settings.settings.assistantName, instructions: instructions, tools: tools.schemas())
    }

    private func connectJarvisTransport(operationID id: UUID) async throws -> Bool {
        try await realtime.connect(configuration: jarvisConfiguration())
        guard self.operationID == id, activeMode == .jarvis else { return false }
        configureAudioCallback(for: .jarvis, operationID: id)
        try audioCapture.start()
        guard self.operationID == id, activeMode == .jarvis else {
            audioCapture.stop()
            return false
        }
        let events = realtime.events
        realtimeTask = Task { [weak self, id] in
            for await event in events { await self?.handle(event, operationID: id) }
        }
        return true
    }

    private func scheduleJarvisRecovery(_ error: Error, operationID id: UUID) {
        guard self.operationID == id, activeMode == .jarvis, jarvisRecoveryTask == nil else { return }
        jarvisRecoveryAttempts += 1
        let attempt = jarvisRecoveryAttempts
        state.transition(to: AssistantSnapshot(phase: .connecting, mode: .jarvis, title: settings.settings.assistantName, detail: "Reconnecting…", cancelHint: "⌃⌥X cancels"))
        jarvisRecoveryTask = Task { [weak self] in
            let delay = UInt64(min(attempt, 4)) * 250_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.reconnectJarvis(operationID: id)
        }
    }

    private func reconnectJarvis(operationID id: UUID) async {
        guard self.operationID == id, activeMode == .jarvis else { jarvisRecoveryTask = nil; return }
        jarvisRecoveryTask = nil
        realtimeTask?.cancel()
        realtimeTask = nil
        audioCapture.onAudioChunk = nil
        audioCapture.stop()
        await realtime.disconnect()
        do {
            guard try await connectJarvisTransport(operationID: id) else { return }
            jarvisRecoveryAttempts = 0
            state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Listening again.", cancelHint: "⌃⌥X cancels"))
        } catch {
            if isRecoverableJarvisTransportError(error) {
                // Keep the Jarvis session alive through short network/display
                // transitions. It remains cancellable while the transport retries.
                scheduleJarvisRecovery(error, operationID: id)
            } else {
                await failJarvis(error, operationID: id, title: "Jarvis connection stopped")
            }
        }
    }

    private func configureAudioCallback(for mode: AssistantMode, operationID: UUID) {
        audioCapture.onAudioChunk = { [weak self] data, level in
            Task { @MainActor [weak self] in
                await self?.ingestAudio(data, level: level, mode: mode, operationID: operationID)
            }
        }
    }

    private func ingestAudio(_ data: Data, level: Float, mode: AssistantMode, operationID: UUID) async {
        guard self.operationID == operationID, activeMode == mode else { return }
        state.updateMicrophoneLevel(level)
        if mode == .jarvis {
            do {
                try await realtime.appendAudio(data)
            } catch {
                if isRecoverableJarvisTransportError(error) {
                    scheduleJarvisRecovery(error, operationID: operationID)
                } else {
                    await failJarvis(error, operationID: operationID, title: "Microphone stream stopped")
                }
            }
        } else {
            await recognizer.append(audio: data)
            await pauseDetector.ingest(level: level)
            if level >= 0.035 { localSpeechDetected = true }
        }
    }

    private func handle(_ event: RealtimeEvent, operationID: UUID) async {
        guard self.operationID == operationID, activeMode == .jarvis else { return }
        switch event {
        case let .outputAudio(data):
            suppressJarvisInput(for: data)
            audioPlayback.enqueuePCM16(data)
            state.transition(to: AssistantSnapshot(phase: .speaking, mode: .jarvis, title: settings.settings.assistantName, detail: "Speaking…", cancelHint: "⌃⌥X cancels"))
        case .inputSpeechStarted:
            inputTurnTranscript = ""
            inputSpeechStopped = false
            inputResponseRequested = false
            inputResponseTask?.cancel()
            inputResponseTask = nil
            pendingWordInterruption = state.snapshot.phase == .speaking || isSuppressingJarvisInput
            if !pendingWordInterruption {
                state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Listening…", cancelHint: "⌃⌥X cancels"))
            }
        case .inputSpeechStopped:
            inputSpeechStopped = true
            // Transcription is asynchronous and may arrive just after VAD
            // reports speech stopped. Give it a short grace period, then only
            // create a response if meaningful words were transcribed.
            inputResponseTask?.cancel()
            inputResponseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await self?.requestResponseForInputTurn()
            }
        case let .inputTranscriptDelta(text):
            inputTurnTranscript += text
            state.updatePartialTranscript(inputTurnTranscript)
            if pendingWordInterruption && hasMeaningfulWords(inputTurnTranscript) && !isLikelyOutputEcho(inputTurnTranscript) {
                pendingWordInterruption = false
                audioPlayback.stop()
                estimatedJarvisPlaybackEnd = nil
                suppressJarvisInputUntil = nil
                await realtime.interrupt()
                state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Listening…", cancelHint: "⌃⌥X cancels"))
            }
            if inputTurnTranscript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "confirm" { await confirmPendingAction() }
            if inputSpeechStopped { await requestResponseForInputTurn() }
        case let .inputTranscriptCompleted(text):
            // The final transcript can correct earlier deltas, so use it as
            // the authoritative turn text before deciding whether to speak.
            // Final events can arrive out of order across turns; deltas are
            // the interruption path, while a completion is only accepted
            // after this turn's VAD stop.
            guard inputSpeechStopped else { return }
            inputTurnTranscript = text
            state.updatePartialTranscript(text)
            if pendingWordInterruption && hasMeaningfulWords(inputTurnTranscript) && !isLikelyOutputEcho(inputTurnTranscript) {
                pendingWordInterruption = false
                audioPlayback.stop()
                estimatedJarvisPlaybackEnd = nil
                suppressJarvisInputUntil = nil
                await realtime.interrupt()
                state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Listening…", cancelHint: "⌃⌥X cancels"))
            }
            if inputTurnTranscript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "confirm" { await confirmPendingAction() }
            if inputSpeechStopped { await requestResponseForInputTurn() }
        case let .outputTranscriptDelta(text):
            lastOutputTranscript += text
            if lastOutputTranscript.count > 600 { lastOutputTranscript = String(lastOutputTranscript.suffix(600)) }
            state.updatePartialTranscript(text)
        case let .toolCall(call): queue(call)
        case .responseDone: await executeQueuedTools()
        case let .error(error):
            // A stale `response.create` must never tear down an otherwise
            // healthy voice session.  This is recoverable; the next turn can
            // continue normally, and the queued tool result is retried once
            // the current response reaches `response.done`.
            if isActiveResponseError(error) {
                state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Still listening…", cancelHint: "⌃⌥X cancels"))
            } else if isRecoverableJarvisTransportError(error) {
                scheduleJarvisRecovery(error, operationID: operationID)
            } else {
                await failJarvis(error, operationID: operationID, title: "Jarvis connection stopped")
            }
        default: break
        }
    }

    private func queue(_ call: ToolCall) {
        queuedToolCalls[call.id] = call
    }

    private func executeQueuedTools() async {
        guard !queuedToolCalls.isEmpty else { return }
        let calls = queuedToolCalls.values
        queuedToolCalls.removeAll()
        var outputs: [(String, String)] = []

        for call in calls {
            if policy.requiresConfirmation(for: call.name) {
                pendingTool = call
                confirmation = PendingConfirmation(operation: call.name == .restartMac ? .restart : .shutDown)
                state.transition(to: AssistantSnapshot(phase: .confirmationRequired, mode: .jarvis, title: "Confirm \(call.name == .restartMac ? "restart" : "shutdown")", detail: "Say “confirm” or click Confirm within 20 seconds.", cancelHint: "⌃⌥X cancels"))
                continue
            }
            state.transition(to: AssistantSnapshot(phase: .executing, mode: .jarvis, title: settings.settings.assistantName, detail: "Working…", cancelHint: "⌃⌥X cancels"))
            let receipt = await executeToolWithTimeout(call)
            await receiptStore.append(receipt)
            outputs.append((call.id, receiptJSON(receipt)))
        }
        guard !outputs.isEmpty else { return }
        await continueAfterToolOutputs(outputs, detail: "Action finished. Listening for your next request…")
    }

    private func continueAfterToolOutputs(_ outputs: [(String, String)], detail: String) async {
        let submitted = await submitToolOutputsWithTimeout(outputs)
        if submitted {
            state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: detail, cancelHint: "⌃⌥X cancels"))
        } else {
            // Keep the microphone and WebSocket alive.  A later Realtime
            // response-done event or the user's next turn can recover without
            // forcing them to reopen Jarvis.
            state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Action finished. Jarvis is still listening.", cancelHint: "⌃⌥X cancels"))
        }
    }

    private func executeToolWithTimeout(_ call: ToolCall) async -> ActionReceipt {
        let executor = self.executor
        return await withTaskGroup(of: ActionReceipt.self) { group in
            group.addTask { await executor.execute(call, confirmed: false) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return ActionReceipt(toolName: call.name, requestedTarget: "", success: false, verified: false, summary: "That action timed out, but Jarvis is still listening.", failureCategory: .transport)
            }
            let result = await group.next() ?? ActionReceipt(toolName: call.name, requestedTarget: "", success: false, verified: false, summary: "That action could not finish, but Jarvis is still listening.", failureCategory: .transport)
            group.cancelAll()
            return result
        }
    }

    private func submitToolOutputsWithTimeout(_ outputs: [(String, String)]) async -> Bool {
        let realtime = self.realtime
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    // Write every function result before asking Realtime to continue.
                    // Sending response.create between individual outputs causes the
                    // API's “active response in progress” error and used to end Jarvis.
                    for (callID, output) in outputs {
                        try await realtime.sendToolOutput(callID: callID, output: output)
                    }
                    try await realtime.requestResponse()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func cancel(silent: Bool) async {
        operationID = UUID(); jarvisRecoveryTask?.cancel(); jarvisRecoveryTask = nil; jarvisRecoveryAttempts = 0; listeningPaused = false; suppressJarvisInputUntil = nil; estimatedJarvisPlaybackEnd = nil; pendingWordInterruption = false; inputTurnTranscript = ""; inputSpeechStopped = false; inputResponseRequested = false; inputResponseTask?.cancel(); inputResponseTask = nil; lastOutputTranscript = ""; audioCapture.onAudioChunk = nil; audioCapture.stop(); audioPlayback.stop(); partialTask?.cancel(); localCompletionTask?.cancel(); realtimeTask?.cancel(); partialTask = nil; localCompletionTask = nil; realtimeTask = nil; localSpeechDetected = false; await recognizer.cancel(); await realtime.disconnect(); activeMode = nil; pendingTool = nil; confirmation = nil; queuedToolCalls.removeAll()
        if !silent { state.transition(to: AssistantSnapshot(phase: .cancelled, title: "Cancelled", detail: "Nothing else will be typed, spoken, or executed.")) }
    }

    private func failJarvis(_ error: Error, operationID: UUID, title: String) async {
        guard self.operationID == operationID else { return }
        self.operationID = UUID()
        jarvisRecoveryTask?.cancel()
        jarvisRecoveryTask = nil
        jarvisRecoveryAttempts = 0
        listeningPaused = false
        suppressJarvisInputUntil = nil
        estimatedJarvisPlaybackEnd = nil
        pendingWordInterruption = false
        inputTurnTranscript = ""
        inputSpeechStopped = false
        inputResponseRequested = false
        inputResponseTask?.cancel()
        inputResponseTask = nil
        lastOutputTranscript = ""
        audioCapture.onAudioChunk = nil
        audioCapture.stop()
        audioPlayback.stop()
        realtimeTask?.cancel()
        realtimeTask = nil
        await realtime.disconnect()
        activeMode = nil
        pendingTool = nil
        confirmation = nil
        queuedToolCalls.removeAll()
        state.transition(to: AssistantSnapshot(phase: .error, mode: .jarvis, title: title, detail: error.localizedDescription))
    }

    private func isActiveResponseError(_ error: Error) -> Bool {
        guard case let AppError.realtimeTransport(message) = error else { return false }
        return message.localizedCaseInsensitiveContains("active response in progress") || message.localizedCaseInsensitiveContains("no active response") || message.localizedCaseInsensitiveContains("cancellation failed")
    }

    private func isRecoverableJarvisTransportError(_ error: Error) -> Bool {
        guard case let AppError.realtimeTransport(message) = error else { return false }
        let text = message.lowercased()
        if text.contains("rate") || text.contains("authentication") || text.contains("unauthorized") || text.contains("forbidden") || text.contains("invalid") { return false }
        return text.contains("socket") || text.contains("not connected") || text.contains("connection") || text.contains("network") || text.contains("timed out") || text.contains("timeout") || text.contains("closed")
    }

    private var isSuppressingJarvisInput: Bool {
        guard let suppressJarvisInputUntil else { return false }
        return Date() < suppressJarvisInputUntil
    }

    private func requestResponseForInputTurn() async {
        guard inputSpeechStopped, !inputResponseRequested, hasMeaningfulWords(inputTurnTranscript), !isLikelyOutputEcho(inputTurnTranscript) else { return }
        inputResponseRequested = true
        do {
            try await realtime.requestResponse()
            state.transition(to: AssistantSnapshot(phase: .thinking, mode: .jarvis, title: settings.settings.assistantName, detail: "Thinking…", cancelHint: "⌃⌥X cancels"))
        } catch {
            inputResponseRequested = false
            state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Still listening…", cancelHint: "⌃⌥X cancels"))
        }
    }

    private func hasMeaningfulWords(_ text: String) -> Bool {
        let noiseTokens: Set<String> = ["uh", "um", "erm", "er", "hmm", "mm", "ah"]
        return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { word in
            let token = word.lowercased()
            return token.count >= 2 && !noiseTokens.contains(token)
        }
    }

    private func isLikelyOutputEcho(_ input: String) -> Bool {
        let normalize: (String) -> String = { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") }
        let candidate = normalize(input)
        let output = normalize(lastOutputTranscript)
        guard candidate.count >= 4, output.count >= 8 else { return false }
        return output.contains(candidate)
    }

    private func suppressJarvisInput(for audio: Data) {
        // PCM16 mono at 24 kHz: 48,000 bytes per second. Realtime can deliver
        // audio faster than it is played, so accumulate the queued duration
        // instead of looking only at the last delta.
        let audioSeconds = Double(audio.count) / 48_000
        let now = Date()
        let playbackStart = max(now, estimatedJarvisPlaybackEnd ?? now)
        let playbackEnd = playbackStart.addingTimeInterval(audioSeconds)
        estimatedJarvisPlaybackEnd = playbackEnd
        suppressJarvisInputUntil = max(now.addingTimeInterval(1), playbackEnd.addingTimeInterval(1))
    }

    private func receiptJSON(_ receipt: ActionReceipt) -> String { String(data: (try? JSONEncoder().encode(receipt)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}" }
}
