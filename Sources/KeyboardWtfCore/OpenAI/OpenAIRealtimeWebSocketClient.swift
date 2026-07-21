import CryptoKit
import Foundation

public final class OpenAIRealtimeWebSocketClient: OpenAIRealtimeClient {
    public var events: AsyncStream<RealtimeEvent> { eventStream }
    private var eventStream: AsyncStream<RealtimeEvent>
    private var continuation: AsyncStream<RealtimeEvent>.Continuation
    private let credentials: CredentialProvider
    private let session: URLSession
    private let logger: Logger
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var lastOutputItemID: String?
    private var installationHash: String
    private var currentResponseAudioBytes = 0
    private var sessionConfigured = false
    private var connectionError: AppError?
    private var connectionID = UUID()

    public init(credentials: CredentialProvider, session: URLSession = .shared, logger: Logger = RedactingLogger()) {
        var continuation: AsyncStream<RealtimeEvent>.Continuation!
        eventStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.credentials = credentials; self.session = session; self.logger = logger
        installationHash = InstallationIdentifier.hash(credentials: credentials)
    }

    deinit { receiver?.cancel(); socket?.cancel(with: .goingAway, reason: nil); continuation.finish() }

    public func connect(configuration: RealtimeConfiguration) async throws {
        await disconnect()
        var continuation: AsyncStream<RealtimeEvent>.Continuation!
        eventStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
        let id = UUID()
        connectionID = id
        guard let key = try credentials.apiKey(), !key.isEmpty else { throw AppError.authentication }
        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else { throw AppError.realtimeTransport("Invalid Realtime URL") }
        components.queryItems = [URLQueryItem(name: "model", value: configuration.model)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(installationHash, forHTTPHeaderField: "OpenAI-Safety-Identifier")
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        sessionConfigured = false
        connectionError = nil
        // Start receiving before configuration is sent so that a quick server-side
        // rejection is observed instead of leaving the overlay in a listening state.
        receiver = Task { [weak self] in await self?.receiveLoop(socket: task, connectionID: id, continuation: continuation) }
        do {
            try await send(sessionUpdate(configuration))
            try await waitForSessionConfiguration(connectionID: id)
            logger.info("realtime.connected", metadata: ["model": configuration.model])
            continuation.yield(.connected)
        } catch {
            await disconnect(connectionID: id)
            throw error
        }
    }

    public func appendAudio(_ data: Data) async throws {
        guard data.count <= 15 * 1_024 * 1_024 else { throw AppError.audio("Audio chunk exceeds Realtime limit.") }
        try await send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
    }

    public func sendText(_ text: String) async throws {
        try await send(["type": "conversation.item.create", "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]])
        try await requestResponse()
    }

    public func sendToolOutput(callID: String, output: String) async throws {
        try await send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID, "output": output]])
    }

    public func requestResponse() async throws {
        try await send(["type": "response.create"])
    }

    public func interrupt() async {
        guard socket != nil else { return }
        try? await send(["type": "response.cancel"])
        if let itemID = lastOutputItemID {
            try? await send(["type": "conversation.item.truncate", "item_id": itemID, "content_index": 0, "audio_end_ms": 0])
        }
    }

    public func disconnect() async {
        let oldContinuation = continuation
        connectionID = UUID()
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil; lastOutputItemID = nil; currentResponseAudioBytes = 0; sessionConfigured = false; connectionError = nil
        oldContinuation.finish()
        logger.info("realtime.disconnected", metadata: [:])
    }

    private func disconnect(connectionID id: UUID) async {
        guard connectionID == id else { return }
        await disconnect()
    }

    private func receiveLoop(socket: URLSessionWebSocketTask, connectionID id: UUID, continuation: AsyncStream<RealtimeEvent>.Continuation) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                switch message {
                case let .string(text): handle(text, connectionID: id, continuation: continuation)
                case let .data(data): handle(String(data: data, encoding: .utf8) ?? "", connectionID: id, continuation: continuation)
                @unknown default: continuation.yield(.error(.malformedResponse("Unknown WebSocket message")))
                }
            }
        } catch {
            if !Task.isCancelled, connectionID == id {
                logger.error("realtime.receive_failed", metadata: ["error": error.localizedDescription])
                let classified = classify(error)
                connectionError = classified
                continuation.yield(.error(classified))
            }
        }
    }

    private func handle(_ text: String, connectionID id: UUID, continuation: AsyncStream<RealtimeEvent>.Continuation) {
        guard connectionID == id else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let type = object["type"] as? String else { continuation.yield(.error(.malformedResponse("Missing Realtime event type"))); return }
        switch type {
        case "session.created", "session.updated":
            logger.info("realtime.session_event", metadata: ["type": type])
            if type == "session.updated" { sessionConfigured = true }
            continuation.yield(.sessionUpdated)
        case "input_audio_buffer.speech_started":
            logger.info("realtime.speech_started", metadata: [:])
            continuation.yield(.inputSpeechStarted)
        case "input_audio_buffer.speech_stopped":
            logger.info("realtime.speech_stopped", metadata: [:])
            continuation.yield(.inputSpeechStopped)
        case "conversation.item.created":
            if let item = object["item"] as? [String: Any], item["role"] as? String == "assistant" { lastOutputItemID = item["id"] as? String }
        case "response.output_audio.delta":
            if let delta = object["delta"] as? String, let audio = Data(base64Encoded: delta) {
                currentResponseAudioBytes += audio.count
                continuation.yield(.outputAudio(audio))
            }
        case "response.output_audio_transcript.delta", "response.output_text.delta":
            if let delta = object["delta"] as? String { continuation.yield(.outputTranscriptDelta(delta)) }
        case "conversation.item.input_audio_transcription.delta":
            if let delta = object["delta"] as? String { continuation.yield(.inputTranscriptDelta(delta)) }
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = object["transcript"] as? String { continuation.yield(.inputTranscriptCompleted(transcript)) }
        case "response.output_item.done":
            if let item = object["item"] as? [String: Any], item["type"] as? String == "function_call", let id = item["call_id"] as? String, let name = item["name"] as? String, let tool = ToolName(rawValue: name), let arguments = item["arguments"] as? String { continuation.yield(.toolCall(ToolCall(id: id, name: tool, argumentsJSON: arguments))) }
        case "response.function_call_arguments.done":
            if let id = object["call_id"] as? String, let name = object["name"] as? String, let tool = ToolName(rawValue: name), let arguments = object["arguments"] as? String { continuation.yield(.toolCall(ToolCall(id: id, name: tool, argumentsJSON: arguments))) }
        case "response.done":
            logger.info("realtime.response_done", metadata: ["audio_bytes": "\(currentResponseAudioBytes)"])
            currentResponseAudioBytes = 0
            continuation.yield(.responseDone)
        case "error":
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Realtime request failed"
            let code = error?["code"] as? String ?? "unknown"
            logger.error("realtime.server_error", metadata: ["code": code, "message": message])
            let appError = AppError.realtimeTransport(message)
            connectionError = appError
            continuation.yield(.error(appError))
        default: break
        }
    }

    private func send(_ object: [String: Any]) async throws {
        guard let socket else { throw AppError.realtimeTransport("Not connected") }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw AppError.malformedResponse("Could not encode event") }
        try await socket.send(.string(text))
    }

    private func waitForSessionConfiguration(connectionID id: UUID) async throws {
        // Do not let the overlay claim it is listening until the server has
        // accepted the session configuration. A WebSocket can otherwise stay
        // open indefinitely after a bad model, key, or network transition.
        for _ in 0..<100 {
            guard connectionID == id else { throw AppError.cancellation }
            if sessionConfigured { return }
            if let connectionError { throw connectionError }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AppError.realtimeTransport("Realtime session setup timed out after 10 seconds.")
    }

    private func sessionUpdate(_ configuration: RealtimeConfiguration) -> [String: Any] {
        let tools = configuration.tools.map { definition in
            let properties = Dictionary(uniqueKeysWithValues: definition.parameters.map { parameter in
                (parameter.name, ["type": parameter.type.rawValue, "description": parameter.description])
            })
            return ["type": "function", "name": definition.name.rawValue, "description": definition.description, "parameters": ["type": "object", "properties": properties, "required": definition.parameters.filter(\.required).map(\.name), "additionalProperties": false]] as [String: Any]
        }
        return [
            "type": "session.update",
            "session": [
                "type": "realtime", "model": configuration.model, "output_modalities": ["audio"],
                "instructions": configuration.instructions + "\nSafety identifier: \(installationHash).",
                "audio": [
                    // Server VAD gives a deliberate turn end after a short silence.
                    // It is more reliable for a hands-free desktop assistant than
                    // semantic VAD, which can wait too long after brief requests.
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "turn_detection": [
                            "type": "server_vad",
                            // Use an exactly representable value. JSONSerialization can
                            // expand values such as 0.45 to 17 decimal places, which the Realtime API
                            // rejects during session.update.
                            "threshold": 0.75,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 900,
                            // The coordinator waits for an actual input
                            // transcription before creating or interrupting a
                            // response. Raw VAD starts can be noise or echo.
                            "create_response": false,
                            "interrupt_response": false
                        ],
                        // A MacBook microphone is normally several inches from the
                        // speaker, so favour far-field filtering over reacting to room noise.
                        "noise_reduction": ["type": "far_field"],
                        // Input transcription is a separate ASR signal used only
                        // as a word gate for interruption and turn creation.
                        "transcription": ["model": "gpt-4o-mini-transcribe", "language": "en"]
                    ],
                    "output": ["format": ["type": "audio/pcm", "rate": 24_000], "voice": configuration.voice]
                ],
                "tools": tools, "tool_choice": "auto"
            ]
        ]
    }

    private func classify(_ error: Error) -> AppError {
        let description = error.localizedDescription.lowercased()
        if description.contains("401") || description.contains("403") { return .authentication }
        if description.contains("429") { return .rateLimited }
        return .realtimeTransport(error.localizedDescription)
    }
}

private enum InstallationIdentifier {
    static func hash(credentials: CredentialProvider) -> String {
        let key = "installation-id"
        let defaults = UserDefaults.standard
        let identifier = defaults.string(forKey: key) ?? UUID().uuidString
        if defaults.string(forKey: key) == nil { defaults.set(identifier, forKey: key) }
        return SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
