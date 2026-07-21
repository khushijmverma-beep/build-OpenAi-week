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
        suppressJarvisInputUntil = nil
        estimatedJarvisPlaybackEnd = nil
        pendingWordInterruption = false
        inputTurnTranscript = ""
        inputSpeechStopped = false
        inputResponseRequested = false
        inputResponseTask?.cancel()
        inputResponseTask = nil
        lastOutputTranscript = ""
        state.transition(to: AssistantSnapshot(phase: .connecting, mode: .jarvis, title: settings.settings.assistantName, detail: "Starting live conversation…", cancelHint: "⌃⌥X cancels"))
        do {
            let selectionContext = invocationSelection?.text.isEmpty == false ? " The user explicitly selected this context before invoking you: \(invocationSelection!.text). Use it only when relevant to their request; do not retain it." : ""
            let instructions = "You are \(settings.settings.assistantName), a concise macOS assistant. Use typed tools only. Never claim an action succeeded without its returned receipt. When asked to type text, use type_text and do not submit the form. Close apps only with close_app; it performs a normal quit and never force-quits. If the user explicitly asks about the screen, use inspect_screen with their question; never capture a screen otherwise. If the user refers to text currently selected, call get_selected_text before answering so the current selection is read at that moment. When selected text is present and the user asks to translate, summarize, rewrite, or make it professional, produce the transformation and use copy_text so the result is on the clipboard; never replace their selection unless they explicitly ask. When the user explicitly asks to play or pause the active media, use play_media; for an exact Spotify playlist, use play_spotify_playlist only with a Spotify playlist URI or share URL. Ask for the share link if the playlist name is ambiguous. Ask when ambiguous. Require a fresh confirmation for restart, shutdown, purchases, deletion, submission, or other irreversible actions.\(selectionContext)"
            try await realtime.connect(configuration: RealtimeConfiguration(model: settings.settings.realtimeModel, assistantName: settings.settings.assistantName, instructions: instructions, tools: tools.schemas()))
            guard operationID == id, activeMode == .jarvis else { return }
            configureAudioCallback(for: .jarvis, operationID: id)
            try audioCapture.start()
            guard operationID == id, activeMode == .jarvis else { return }
            let events = realtime.events
            realtimeTask = Task { [weak self, id] in
                for await event in events { await self?.handle(event, operationID: id) }
            }
            state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Talk naturally.", cancelHint: "⌃⌥X cancels"))
        } catch {
            await failJarvis(error, operationID: id, title: "Could not connect")
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
                await failJarvis(error, operationID: operationID, title: "Microphone stream stopped")
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
            let receipt = await executor.execute(call, confirmed: false)
            await receiptStore.append(receipt)
            outputs.append((call.id, receiptJSON(receipt)))
        }
        guard !outputs.isEmpty else { return }
        await continueAfterToolOutputs(outputs, detail: "Action finished. Listening for your next request…")
    }

    private func continueAfterToolOutputs(_ outputs: [(String, String)], detail: String) async {
        do {
            // Write every function result before asking Realtime to continue.
            // Sending response.create between individual outputs causes the
            // API's “active response in progress” error and used to end Jarvis.
            for (callID, output) in outputs {
                try await realtime.sendToolOutput(callID: callID, output: output)
            }
            try await realtime.requestResponse()
            state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: detail, cancelHint: "⌃⌥X cancels"))
        } catch {
            // Keep the microphone and WebSocket alive.  A later Realtime
            // response-done event or the user's next turn can recover without
            // forcing them to reopen Jarvis.
            state.transition(to: AssistantSnapshot(phase: .listening, mode: .jarvis, title: settings.settings.assistantName, detail: "Action finished. Jarvis is still listening.", cancelHint: "⌃⌥X cancels"))
        }
    }

    private func cancel(silent: Bool) async {
        operationID = UUID(); suppressJarvisInputUntil = nil; estimatedJarvisPlaybackEnd = nil; pendingWordInterruption = false; inputTurnTranscript = ""; inputSpeechStopped = false; inputResponseRequested = false; inputResponseTask?.cancel(); inputResponseTask = nil; lastOutputTranscript = ""; audioCapture.onAudioChunk = nil; audioCapture.stop(); audioPlayback.stop(); partialTask?.cancel(); localCompletionTask?.cancel(); realtimeTask?.cancel(); partialTask = nil; localCompletionTask = nil; realtimeTask = nil; localSpeechDetected = false; await recognizer.cancel(); await realtime.disconnect(); activeMode = nil; pendingTool = nil; confirmation = nil; queuedToolCalls.removeAll()
        if !silent { state.transition(to: AssistantSnapshot(phase: .cancelled, title: "Cancelled", detail: "Nothing else will be typed, spoken, or executed.")) }
    }

    private func failJarvis(_ error: Error, operationID: UUID, title: String) async {
        guard self.operationID == operationID else { return }
        self.operationID = UUID()
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
        return message.localizedCaseInsensitiveContains("active response in progress")
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
