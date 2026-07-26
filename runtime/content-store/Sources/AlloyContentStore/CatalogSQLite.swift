// Author: Timur Isaev

import Foundation
import SQLite3

final class CatalogSQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL, createIfMissing: Bool) throws {
        var opened: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if createIfMissing {
            flags |= SQLITE_OPEN_CREATE
        }
        let result = sqlite3_open_v2(url.path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 returned no database handle"
            if let opened {
                sqlite3_close(opened)
            }
            throw CatalogError.sqlite(code: result, message: message)
        }
        handle = opened
        sqlite3_extended_result_codes(opened, 1)
        sqlite3_busy_timeout(opened, 5_000)
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = DELETE")
            try execute("PRAGMA synchronous = FULL")
        } catch {
            handle = nil
            sqlite3_close(opened)
            throw error
        }
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func execute(_ sql: String) throws {
        guard let handle else {
            throw CatalogError.sqlite(
                code: SQLITE_MISUSE,
                message: "database handle is closed"
            )
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw CatalogError.sqlite(code: result, message: message)
        }
    }

    func prepare(_ sql: String) throws -> CatalogSQLiteStatement {
        guard let handle else {
            throw CatalogError.sqlite(
                code: SQLITE_MISUSE,
                message: "database handle is closed"
            )
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw CatalogError.sqlite(
                code: result,
                message: String(cString: sqlite3_errmsg(handle))
            )
        }
        return CatalogSQLiteStatement(database: handle, statement: statement)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

final class CatalogSQLiteStatement {
    private let database: OpaquePointer
    private var statement: OpaquePointer?

    init(database: OpaquePointer, statement: OpaquePointer) {
        self.database = database
        self.statement = statement
    }

    deinit {
        if let statement {
            sqlite3_finalize(statement)
        }
    }

    func bind(_ value: String, at index: Int32) throws {
        guard let statement else {
            throw misuseError()
        }
        let result = sqlite3_bind_text(
            statement,
            index,
            value,
            -1,
            sqliteTransientDestructor()
        )
        try requireSuccess(result)
    }

    func bind(_ value: Int64, at index: Int32) throws {
        guard let statement else {
            throw misuseError()
        }
        try requireSuccess(sqlite3_bind_int64(statement, index, value))
    }

    func execute() throws {
        guard let statement else {
            throw misuseError()
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw databaseError(result)
        }
    }

    func rows(_ body: (CatalogSQLiteRow) throws -> Void) throws {
        guard let statement else {
            throw misuseError()
        }
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                try body(CatalogSQLiteRow(statement: statement))
            case SQLITE_DONE:
                return
            default:
                throw databaseError(result)
            }
        }
    }

    private func requireSuccess(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw databaseError(result)
        }
    }

    private func databaseError(_ result: Int32) -> CatalogError {
        CatalogError.sqlite(
            code: result,
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    private func misuseError() -> CatalogError {
        CatalogError.sqlite(
            code: SQLITE_MISUSE,
            message: "prepared statement is closed"
        )
    }
}

struct CatalogSQLiteRow {
    let statement: OpaquePointer

    func string(at index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, index) else {
            throw CatalogError.invalidCatalogValue("column \(index) is not text")
        }
        return String(cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self))
    }

    func integer(at index: Int32) throws -> Int64 {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw CatalogError.invalidCatalogValue("column \(index) is not an integer")
        }
        return sqlite3_column_int64(statement, index)
    }
}

private func sqliteTransientDestructor() -> sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
