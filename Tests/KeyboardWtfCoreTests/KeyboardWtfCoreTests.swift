import XCTest
@testable import KeyboardWtfCore

final class KeyboardWtfCoreTests: XCTestCase {
    func testPhaseMapsToSemanticTone() {
        XCTAssertEqual(AssistantSnapshot(phase: .listening).tone, .red)
        XCTAssertEqual(AssistantSnapshot(phase: .thinking).tone, .purple)
        XCTAssertEqual(AssistantSnapshot(phase: .speaking).tone, .teal)
        XCTAssertTrue(AssistantPhase.done.isTerminal)
    }

    func testConfirmationExpires() {
        let start = Date(timeIntervalSince1970: 1_000)
        let confirmation = PendingConfirmation(operation: .restart, now: start, ttl: 5)
        XCTAssertTrue(confirmation.isValid(at: start.addingTimeInterval(5)))
        XCTAssertFalse(confirmation.isValid(at: start.addingTimeInterval(5.01)))
    }

    func testRedactionRemovesAPIKeys() {
        let logger = RedactingLogger()
        XCTAssertFalse(logger.redact("Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz").contains("abcdefghijklmnopqrstuvwxyz"))
    }

    func testResponsesParserReadsOutputTextAndUsage() throws {
        let data = Data("{\"id\":\"resp_1\",\"model\":\"gpt-5.4-mini\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Ready.\"}]}],\"usage\":{\"input_tokens\":12,\"output_tokens\":3}}".utf8)
        let result = try OpenAIResponsesService.parse(data)
        XCTAssertEqual(result.outputText, "Ready.")
        XCTAssertEqual(result.inputTokens, 12)
    }

    func testSQLitePersistsMemoryAndWorkflow() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStore(url: url)
        try await store.remember(key: "browser", value: "Safari", sensitivity: .ordinary)
        let memories = try await store.search("browser")
        XCTAssertEqual(memories.first?.value, "Safari")
        let workflow = Workflow(name: "work setup", triggers: ["start work"], steps: [WorkflowStep(tool: .openApp, argumentsJSON: "{\"name\":\"Safari\"}")])
        try await store.save(workflow)
        let workflows = try await store.all()
        XCTAssertEqual(workflows.first?.name, "work setup")
    }

    func testLiveResponsesSmokeWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_OPENAI_TESTS"] == "1" else {
            throw XCTSkip("Live API checks are opt-in.")
        }
        let client = OpenAIResponsesService(credentials: KeychainCredentialProvider())
        let result = try await client.create(ResponsesRequest(
            instructions: "Reply with exactly: ok",
            input: "Connection test"
        ))
        XCTAssertEqual(result.outputText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "ok")
    }
}
