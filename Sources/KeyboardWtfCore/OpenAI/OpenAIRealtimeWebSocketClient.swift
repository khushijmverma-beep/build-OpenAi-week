import CryptoKit
import Foundation

public final class OpenAIRealtimeWebSocketClient: OpenAIRealtimeClient {
    public let events: AsyncStream<RealtimeEvent>
    private let continuation: AsyncStream<RealtimeEvent>.Continuation
    private let credentials: CredentialProvider
    private let session: URLSession
    private let logger: Logger
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var lastOutputItemID: String?
    private var installationHash: String

    public init(credentials: CredentialProvider, session: URLSession = .shared, logger: Logger = RedactingLogger()) {
        var continuation: AsyncStream<RealtimeEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.credentials = credentials; self.session = session; self.logger = logger
        installationHash = InstallationIdentifier.hash(credentials: credentials)
    }

    deinit { receiver?.cancel(); socket?.cancel(with: .goingAway, reason: nil); continuation.finish() }

    public func connect(configuration: RealtimeConfiguration) async throws {
        await disconnect()
        guard let key = try credentials.apiKey(), !key.isEmpty else { throw AppError.authentication }
        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else { throw AppError.realtimeTransport("Invalid Realtime URL") }
        components.queryItems = [URLQueryItem(name: "model", value: configuration.model)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(installationHash, forHTTPHeaderField: "OpenAI-Safety-Identifier")
        let task = session.webSocketTask(with: request)
        socket = task; task.resume()
        try await send(sessionUpdate(configuration))
        continuation.yield(.connected)
        receiver = Task { [weak self] in await self?.receiveLoop() }
    }

    public func appendAudio(_ data: Data) async throws {
        guard data.count <= 15 * 1_024 * 1_024 else { throw AppError.audio("Audio chunk exceeds Realtime limit.") }
        try await send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
    }

    public func sendText(_ text: String) async throws {
        try await send(["type": "conversation.item.create", "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]])
        try await send(["type": "response.create"])
    }

    public func sendToolOutput(callID: String, output: String) async throws {
        try await send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID, "output": output]])
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
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil; lastOutputItemID = nil
    }

    private func receiveLoop() async {
        guard let socket else { return }
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                switch message {
                case let .string(text): handle(text)
                case let .data(data): handle(String(data: data, encoding: .utf8) ?? "")
                @unknown default: continuation.yield(.error(.malformedResponse("Unknown WebSocket message")))
                }
            }
        } catch {
            if !Task.isCancelled { continuation.yield(.error(classify(error))) }
        }
    }

    private func handle(_ text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let type = object["type"] as? String else { continuation.yield(.error(.malformedResponse("Missing Realtime event type"))); return }
        switch type {
        case "session.created", "session.updated": continuation.yield(.sessionUpdated)
        case "input_audio_buffer.speech_started": continuation.yield(.inputSpeechStarted)
        case "conversation.item.created":
            if let item = object["item"] as? [String: Any], item["role"] as? String == "assistant" { lastOutputItemID = item["id"] as? String }
        case "response.output_audio.delta":
            if let delta = object["delta"] as? String, let audio = Data(base64Encoded: delta) { continuation.yield(.outputAudio(audio)) }
        case "response.output_audio_transcript.delta", "response.output_text.delta":
            if let delta = object["delta"] as? String { continuation.yield(.outputTranscriptDelta(delta)) }
        case "conversation.item.input_audio_transcription.delta":
            if let delta = object["delta"] as? String { continuation.yield(.inputTranscriptDelta(delta)) }
        case "response.output_item.done":
            if let item = object["item"] as? [String: Any], item["type"] as? String == "function_call", let id = item["call_id"] as? String, let name = item["name"] as? String, let tool = ToolName(rawValue: name), let arguments = item["arguments"] as? String { continuation.yield(.toolCall(ToolCall(id: id, name: tool, argumentsJSON: arguments))) }
        case "response.function_call_arguments.done":
            if let id = object["call_id"] as? String, let name = object["name"] as? String, let tool = ToolName(rawValue: name), let arguments = object["arguments"] as? String { continuation.yield(.toolCall(ToolCall(id: id, name: tool, argumentsJSON: arguments))) }
        case "response.done": continuation.yield(.responseDone)
        case "error":
            let error = object["error"] as? [String: Any]
            continuation.yield(.error(.realtimeTransport(error?["message"] as? String ?? "Realtime request failed")))
        default: break
        }
    }

    private func send(_ object: [String: Any]) async throws {
        guard let socket else { throw AppError.realtimeTransport("Not connected") }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw AppError.malformedResponse("Could not encode event") }
        try await socket.send(.string(text))
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
                    "input": ["format": ["type": "audio/pcm", "rate": 24_000], "turn_detection": ["type": "semantic_vad"]],
                    "output": ["format": ["type": "audio/pcm"], "voice": configuration.voice]
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
