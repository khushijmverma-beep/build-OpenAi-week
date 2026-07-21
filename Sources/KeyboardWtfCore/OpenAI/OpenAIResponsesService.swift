import Foundation

public final class OpenAIResponsesService: OpenAIResponsesClient {
    private let credentials: CredentialProvider
    private let session: URLSession
    private let logger: Logger
    public init(credentials: CredentialProvider, session: URLSession? = nil, logger: Logger = RedactingLogger()) {
        self.credentials = credentials
        self.session = session ?? OpenAIURLSession.default
        self.logger = logger
    }

    public func create(_ request: ResponsesRequest) async throws -> ResponsesResult {
        guard let key = try credentials.apiKey(), !key.isEmpty else { throw AppError.authentication }
        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": request.model,
            "instructions": request.instructions,
            "input": [["role": "user", "content": [["type": "input_text", "text": request.input]]]]
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let started = Date()
        let (data, response) = try await responseData(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AppError.realtimeTransport("No HTTP response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw AppError.authentication }
        if http.statusCode == 429 { throw AppError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw AppError.malformedResponse(String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)") }
        let result = try Self.parse(data)
        logger.info("responses.complete", metadata: ["model": request.model, "latency_ms": String(Int(Date().timeIntervalSince(started) * 1000))])
        return result
    }

    private func responseData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await self.session.data(for: request) }
            group.addTask {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                throw AppError.realtimeTransport("OpenAI request timed out after 20 seconds.")
            }
            guard let result = try await group.next() else { throw AppError.realtimeTransport("OpenAI request did not start.") }
            group.cancelAll()
            return result
        }
    }

    static func parse(_ data: Data) throws -> ResponsesResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = object["id"] as? String, let model = object["model"] as? String else { throw AppError.malformedResponse("Missing response fields") }
        let output = object["output"] as? [[String: Any]] ?? []
        let text = output.compactMap { item -> String? in
            guard let content = item["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { $0["text"] as? String }.joined()
        }.joined()
        guard !text.isEmpty else { throw AppError.malformedResponse("No output text") }
        let usage = object["usage"] as? [String: Any]
        return ResponsesResult(id: id, outputText: text, model: model, inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int)
    }
}

/// Sends an explicitly requested local screenshot to the Responses API and
/// returns only the assistant's analysis. The caller owns and deletes the
/// temporary capture after this method completes.
public final class OpenAIScreenAnalyzer: ScreenAnalyzer {
    private let credentials: CredentialProvider
    private let session: URLSession

    public init(credentials: CredentialProvider, session: URLSession? = nil) {
        self.credentials = credentials
        self.session = session ?? OpenAIURLSession.default
    }

    public func analyze(imageAt url: URL, question: String) async throws -> String {
        guard let key = try credentials.apiKey(), !key.isEmpty else { throw AppError.authentication }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= 18 * 1_024 * 1_024 else { throw AppError.unsupported("The screen capture is too large to analyze safely.") }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let imageURL = "data:image/png;base64,\(data.base64EncodedString())"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": ModelCatalog.default.responses,
            "instructions": "Analyze only the explicitly supplied screenshot. Be concise, factual, and actionable. Do not claim controls or text that are not visible. If asked what to click next, give guidance rather than taking action.",
            "input": [["role": "user", "content": [
                ["type": "input_text", "text": question],
                ["type": "input_image", "image_url": imageURL]
            ]]]
        ])
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.realtimeTransport("No HTTP response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw AppError.authentication }
        if http.statusCode == 429 { throw AppError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw AppError.malformedResponse(String(data: responseData, encoding: .utf8) ?? "HTTP \(http.statusCode)") }
        return try OpenAIResponsesService.parse(responseData).outputText
    }
}

/// Resolves a user-requested visible control to normalized screenshot
/// coordinates. The click itself remains local and is performed only after
/// Accessibility permission is checked by MacScreenClickService.
public final class OpenAIScreenClickResolver: ScreenClickTargetResolver {
    private let credentials: CredentialProvider
    private let session: URLSession
    private let model: String

    public init(credentials: CredentialProvider, session: URLSession? = nil, model: String = ModelCatalog.default.responses) {
        self.credentials = credentials
        self.session = session ?? OpenAIURLSession.default
        self.model = model
    }

    public func resolve(imageAt url: URL, target: String) async throws -> ScreenClickTarget {
        guard let key = try credentials.apiKey(), !key.isEmpty else { throw AppError.authentication }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= 18 * 1_024 * 1_024 else { throw AppError.unsupported("The screen capture is too large to analyze safely.") }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let imageURL = "data:image/png;base64,\(data.base64EncodedString())"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": "You locate one visible UI control for a requested click. Return only one JSON object with found (boolean), x and y (numbers from 0.0 to 1.0 measured from the screenshot's top-left corner), label (string), and confidence (number from 0.0 to 1.0). Choose the center of the requested control. If it is not visible, return found false with null coordinates. Do not click anything. Never invent a target.",
            "input": [["role": "user", "content": [
                ["type": "input_text", "text": "Requested control: \(target)"],
                ["type": "input_image", "image_url": imageURL]
            ]]]
        ])
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.realtimeTransport("No HTTP response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw AppError.authentication }
        if http.statusCode == 429 { throw AppError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw AppError.malformedResponse(String(data: responseData, encoding: .utf8) ?? "HTTP \(http.statusCode)") }
        return try Self.parse(OpenAIResponsesService.parse(responseData).outputText)
    }

    static func parse(_ text: String) throws -> ScreenClickTarget {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}") {
            candidate = String(candidate[start...end])
        }
        guard let data = candidate.data(using: .utf8) else { throw AppError.malformedResponse("Screen click response was not valid JSON.") }
        let result = try JSONDecoder().decode(ScreenClickTarget.self, from: data)
        guard result.found else { return result }
        guard let x = result.x, let y = result.y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw AppError.malformedResponse("Screen click response contained invalid coordinates.")
        }
        return result
    }
}

private enum OpenAIURLSession {
    static let `default`: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
}
