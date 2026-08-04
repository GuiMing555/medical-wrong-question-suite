import CSQLite
import Foundation

enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var int: Int? {
        switch self {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }
}

typealias SQLiteRow = [String: SQLiteValue]

final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw QuestionBankError.database(message)
        }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        try configureWALMode()
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error(sql) }
    }

    func rows(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var output: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return output }
            guard result == SQLITE_ROW else { throw error(sql) }
            var row: SQLiteRow = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                default:
                    row[name] = .null
                }
            }
            output.append(row)
        }
    }

    func scalarInt(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        try rows(sql, bindings).first?.values.first?.int ?? 0
    }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try operation()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ bindings: [SQLiteValue]) throws -> OpaquePointer {
        guard let handle else { throw QuestionBankError.database("SQLite database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error(sql)
        }
        do {
            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .null:
                    result = sqlite3_bind_null(statement, index)
                case .integer(let value):
                    result = sqlite3_bind_int64(statement, index, value)
                case .real(let value):
                    result = sqlite3_bind_double(statement, index, value)
                case .text(let value):
                    result = sqlite3_bind_text(statement, index, value, -1, transient)
                }
                guard result == SQLITE_OK else { throw error(sql) }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func error(_ sql: String) -> QuestionBankError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
        return .database("\(message) [\(sql.prefix(100))]")
    }

    private func configureWALMode() throws {
        // Changing journal mode is one of the few PRAGMAs that can return BUSY
        // immediately even with busy_timeout. Both desktop apps may open a new
        // database at login, so retry this small, bounded initialization race.
        var lastError: Error?
        for attempt in 0..<25 {
            do {
                _ = try rows("PRAGMA journal_mode = WAL")
                return
            } catch {
                lastError = error
                guard attempt < 24 else { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        throw lastError ?? QuestionBankError.database("Unable to enable WAL mode")
    }
}

extension Array where Element == String {
    func encodedJSONString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let value = String(data: data, encoding: .utf8) else {
            throw QuestionBankError.database("Unable to encode JSON")
        }
        return value
    }
}

func decodeStringArray(_ value: String?) throws -> [String] {
    guard let value, let data = value.data(using: .utf8) else { return [] }
    return try JSONDecoder().decode([String].self, from: data)
}
