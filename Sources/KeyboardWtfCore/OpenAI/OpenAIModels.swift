import Foundation

public struct ModelCatalog: Codable, Equatable, Sendable {
    public let realtime: String
    public let responses: String
    public let reasoning: String
    public static let `default` = ModelCatalog(realtime: "gpt-realtime-2.1", responses: "gpt-5.4-mini", reasoning: "gpt-5.6-terra")
}

public struct ResponsesRequest: Sendable {
    public let model: String
    public let instructions: String
    public let input: String
    public let useReasoningModel: Bool
    public init(model: String = ModelCatalog.default.responses, instructions: String, input: String, useReasoningModel: Bool = false) {
        self.model = model; self.instructions = instructions; self.input = input; self.useReasoningModel = useReasoningModel
    }
}

public struct ResponsesResult: Equatable, Sendable {
    public let id: String
    public let outputText: String
    public let model: String
    public let inputTokens: Int?
    public let outputTokens: Int?
}

public struct RealtimeConfiguration: Sendable {
    public let model: String
    public let assistantName: String
    public let instructions: String
    public let voice: String
    public let tools: [ToolDefinition]
    public init(model: String = ModelCatalog.default.realtime, assistantName: String, instructions: String, voice: String = "marin", tools: [ToolDefinition]) {
        self.model = model; self.assistantName = assistantName; self.instructions = instructions; self.voice = voice; self.tools = tools
    }
}

public enum RealtimeEvent: Equatable, Sendable {
    case connected
    case sessionUpdated
    case inputTranscriptDelta(String)
    case inputTranscriptCompleted(String)
    case outputAudio(Data)
    case outputTranscriptDelta(String)
    case toolCall(ToolCall)
    case responseDone
    case inputSpeechStarted
    case inputSpeechStopped
    case error(AppError)
}
