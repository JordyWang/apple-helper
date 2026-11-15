import Foundation
import SQLite3
import CryptoKit

func jsonData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
}
func fingerprint(_ value: Any) throws -> String {
    SHA256.hash(data: try jsonData(value)).map { String(format: "%02x", $0) }.joined()
}

/// Local durable state. SQLite serializes writers across independently launched MCP clients.
final class StateStore {
    private var db: OpaquePointer?
    let directory: URL
    init() throws {
        umask(0o077)
        directory = ProcessInfo.processInfo.environment["APPLE_HELPER_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Apple Helper MCP")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(directory.appendingPathComponent("state.sqlite3").path, &db) == SQLITE_OK else {
            throw BridgeError("STATE_ERROR", "Cannot open local state database.")
        }
        sqlite3_busy_timeout(db, 35000)
        try sql("PRAGMA journal_mode=WAL")
        try sql("PRAGMA synchronous=FULL")
        try sql("CREATE TABLE IF NOT EXISTS records (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try sql("CREATE INDEX IF NOT EXISTS records_created ON records(json_extract(value,'$.created_at') DESC)")
    }
    deinit { sqlite3_close(db) }
    @discardableResult func sql(_ sql: String, _ values: [String] = []) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { throw failure() }
        }
        var rows: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            if let text = sqlite3_column_text(statement, 0) { rows.append(String(cString: text)) }
        }
    }
    private func failure() -> BridgeError {
        BridgeError("STATE_ERROR", String(cString: sqlite3_errmsg(db)))
    }
    func get(_ key: String) throws -> [String: Any]? {
        guard let string = try sql("SELECT value FROM records WHERE key = ?", [key]).first else { return nil }
        return try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
    }
    func set(_ key: String, _ value: [String: Any]) throws {
        try sql("INSERT INTO records(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, String(decoding: try jsonData(value), as: UTF8.self)])
    }
    func begin() throws { try sql("BEGIN IMMEDIATE") }
    func commit() throws { try sql("COMMIT") }
    func rollback() { _ = try? sql("ROLLBACK") }
    func recent(_ limit: Int) throws -> [[String: Any]] {
        try sql("SELECT value FROM records WHERE key LIKE 'operation:%' ORDER BY json_extract(value,'$.created_at') DESC, key DESC LIMIT ?", [String(limit)])
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
}
