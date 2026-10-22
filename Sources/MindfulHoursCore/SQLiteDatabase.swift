import Foundation
import SQLite3

public enum SQLValue: Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null

    public static func optionalText(_ value: String?) -> SQLValue {
        value.map(SQLValue.text) ?? .null
    }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            throw SQLiteError(description: "Cannot open database at \(path)")
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close(handle)
    }

    var userVersion: Int {
        (try? query("PRAGMA user_version") { Int($0.int(0)) }.first) ?? 0
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw lastError() }
    }

    func query<T>(_ sql: String, _ values: [SQLValue] = [], map: (Row) -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw lastError() }
            rows.append(map(Row(statement: statement)))
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let string): sqlite3_bind_text(statement, index, string, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func lastError() -> SQLiteError {
        SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
    }

    struct Row {
        let statement: OpaquePointer?

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: double(column)) }

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
    }
}
