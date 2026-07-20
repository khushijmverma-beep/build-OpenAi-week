import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor SQLiteStore: ActionReceiptStore, MemoryStore, WorkflowStore {
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL? = nil) throws {
        let path: URL
        if let url { path = url } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("keyboard.wtf", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("keyboard.wtf.sqlite")
        }
        guard sqlite3_open_v2(path.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw AppError.malformedResponse("Could not open local database") }
        try Self.migrate(database)
    }

    deinit { if let database { sqlite3_close(database) } }

    public func append(_ receipt: ActionReceipt) async { try? execute("INSERT OR REPLACE INTO action_receipts(id, created_at, receipt_json) VALUES(?, ?, ?)", [receipt.id.uuidString, String(receipt.endedAt.timeIntervalSince1970), encode(receipt)]) }
    public func recent(limit: Int) async -> [ActionReceipt] {
        (try? query("SELECT receipt_json FROM action_receipts ORDER BY created_at DESC LIMIT \(max(1, min(limit, 100)))").compactMap { decode(ActionReceipt.self, $0[0]) }) ?? []
    }

    public func remember(key: String, value: String, sensitivity: MemorySensitivity) async throws {
        guard sensitivity == .ordinary else { throw AppError.unsupported("Sensitive values are not stored automatically.") }
        let item = MemoryItem(key: key.compactWhitespace, value: value.compactWhitespace, sensitivity: sensitivity)
        try execute("INSERT OR REPLACE INTO personal_memories(id, memory_key, memory_value, sensitivity, updated_at) VALUES(?, ?, ?, ?, ?)", [item.id.uuidString, item.key, item.value, item.sensitivity.rawValue, String(item.updatedAt.timeIntervalSince1970)])
        try execute("INSERT OR REPLACE INTO memory_fts(id, memory_key, memory_value) VALUES(?, ?, ?)", [item.id.uuidString, item.key, item.value])
    }

    public func search(_ query: String) async throws -> [MemoryItem] {
        let clean = query.compactWhitespace
        let rows = try queryRows("SELECT id, memory_key, memory_value, sensitivity, updated_at FROM personal_memories WHERE memory_key LIKE ? OR memory_value LIKE ? ORDER BY updated_at DESC LIMIT 20", ["%\(clean)%", "%\(clean)%"])
        return rows.compactMap { row in
            guard row.count == 5, let id = UUID(uuidString: row[0]), let sensitivity = MemorySensitivity(rawValue: row[3]), let timestamp = TimeInterval(row[4]) else { return nil }
            return MemoryItem(id: id, key: row[1], value: row[2], sensitivity: sensitivity, updatedAt: Date(timeIntervalSince1970: timestamp))
        }
    }

    public func save(_ workflow: Workflow) async throws { try execute("INSERT OR REPLACE INTO workflows(id, name, workflow_json, updated_at) VALUES(?, ?, ?, ?)", [workflow.id.uuidString, workflow.name, encode(workflow), String(Date().timeIntervalSince1970)]) }
    public func all() async throws -> [Workflow] { try query("SELECT workflow_json FROM workflows ORDER BY updated_at DESC").compactMap { decode(Workflow.self, $0[0]) } }

    private static func migrate(_ database: OpaquePointer?) throws {
        try executeRaw(database, "CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY)")
        try executeRaw(database, "CREATE TABLE IF NOT EXISTS personal_memories(id TEXT PRIMARY KEY, memory_key TEXT NOT NULL, memory_value TEXT NOT NULL, sensitivity TEXT NOT NULL, updated_at REAL NOT NULL)")
        try executeRaw(database, "CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(id UNINDEXED, memory_key, memory_value)")
        try executeRaw(database, "CREATE TABLE IF NOT EXISTS workflows(id TEXT PRIMARY KEY, name TEXT NOT NULL, workflow_json TEXT NOT NULL, updated_at REAL NOT NULL)")
        try executeRaw(database, "CREATE TABLE IF NOT EXISTS action_receipts(id TEXT PRIMARY KEY, created_at REAL NOT NULL, receipt_json TEXT NOT NULL)")
        try executeRaw(database, "CREATE TABLE IF NOT EXISTS action_history(id TEXT PRIMARY KEY, tool_name TEXT, created_at REAL)")
        try executeRaw(database, "CREATE TABLE IF NOT EXISTS failure_history(id TEXT PRIMARY KEY, category TEXT, created_at REAL)")
        try executeRaw(database, "CREATE TABLE IF NOT EXISTS memory_aliases(id TEXT PRIMARY KEY, alias TEXT, target TEXT)")
        try executeRaw(database, "CREATE TABLE IF NOT EXISTS workflow_runs(id TEXT PRIMARY KEY, workflow_id TEXT, created_at REAL, result TEXT)")
        try executeRaw(database, "CREATE TABLE IF NOT EXISTS conversation_summaries(id TEXT PRIMARY KEY, summary TEXT, created_at REAL)")
        try executeRaw(database, "CREATE TABLE IF NOT EXISTS app_aliases(id TEXT PRIMARY KEY, alias TEXT, bundle_id TEXT)")
        try executeRaw(database, "CREATE TABLE IF NOT EXISTS file_aliases(id TEXT PRIMARY KEY, alias TEXT, bookmark BLOB)")
        try executeRaw(database, "CREATE TABLE IF NOT EXISTS permission_events(id TEXT PRIMARY KEY, kind TEXT, status TEXT, created_at REAL)")
        try executeRaw(database, "INSERT OR IGNORE INTO schema_migrations(version) VALUES(1)")
    }

    private static func executeRaw(_ database: OpaquePointer?, _ statement: String) throws { guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw AppError.malformedResponse(database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error") } }
    private func execute(_ sql: String, _ values: [String]) throws {
        guard let database else { throw AppError.malformedResponse("Database closed") }
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw AppError.malformedResponse(errorMessage()) }; defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError.malformedResponse(errorMessage()) }
    }
    private func query(_ sql: String) throws -> [[String]] { try queryRows(sql, []) }
    private func queryRows(_ sql: String, _ values: [String]) throws -> [[String]] {
        guard let database else { throw AppError.malformedResponse("Database closed") }
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw AppError.malformedResponse(errorMessage()) }; defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT) }
        var result = [[String]](); while sqlite3_step(statement) == SQLITE_ROW { result.append((0..<Int(sqlite3_column_count(statement))).map { sqlite3_column_text(statement, Int32($0)).map { String(cString: $0) } ?? "" }) }; return result
    }
    private func encode<T: Encodable>(_ value: T) -> String { String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? "{}" }
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? { try? decoder.decode(T.self, from: Data(json.utf8)) }
    private func errorMessage() -> String { database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error" }
}
