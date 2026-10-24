import Foundation
import SQLite3

// =============================================================================
// SQLite 极薄封装：只用系统自带的 libsqlite3（零第三方依赖）
// 提供 exec / query / run / 事务 / 最后插入 rowid
// =============================================================================

/// SQLITE_TRANSIENT 在 Swift 中需要手工桥接，否则 SQLite 只记住字符串指针不复制内容
let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

enum DBError: LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    var errorDescription: String? {
        switch self {
        case .open(let m):            return "数据库打开失败：\(m)"
        case .prepare(let m, let sql): return "SQL 预处理失败：\(m)\n\(sql)"
        case .step(let m, let sql):    return "SQL 执行失败：\(m)\n\(sql)"
        }
    }
}

/// 单行结果读取器
struct Row {
    let stmt: OpaquePointer

    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }
    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: sqlite3_column_double(stmt, i)) }
}

final class SQLiteDB {
    private(set) var handle: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(db)
            throw DBError.open(msg)
        }
        handle = opened
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec("PRAGMA synchronous=NORMAL;")
    }

    deinit {
        if let h = handle { sqlite3_close(h) }
    }

    // MARK: - 基础执行

    func exec(_ sql: String) throws {
        guard let h = handle else { throw DBError.open("no handle") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.step(msg, sql: sql)
        }
    }

    /// 写操作（INSERT/UPDATE/DELETE）
    func run(_ sql: String, _ params: [Any?] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
    }

    /// 查询
    func query<T>(_ sql: String, _ params: [Any?] = [], _ map: (Row) -> T) throws -> [T] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(map(Row(stmt: stmt)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DBError.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
            }
        }
        return out
    }

    var lastInsertRowID: Int64 {
        guard let h = handle else { return 0 }
        return sqlite3_last_insert_rowid(h)
    }

    // MARK: - 事务

    /// 在事务中执行；抛错自动回滚。
    /// 批量导入上百条子目必须走事务，否则每条一次 fsync，会明显卡顿。
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let r = try body()
            try exec("COMMIT;")
            return r
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - 私有

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer {
        guard let h = handle else { throw DBError.open("no handle") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(h)), sql: sql)
        }
        for (idx, value) in params.enumerated() {
            let i = Int32(idx + 1)
            switch value {
            case nil, is NSNull:
                sqlite3_bind_null(s, i)
            case let v as Int:
                sqlite3_bind_int64(s, i, Int64(v))
            case let v as Int64:
                sqlite3_bind_int64(s, i, v)
            case let v as Bool:
                sqlite3_bind_int64(s, i, v ? 1 : 0)
            case let v as Double:
                sqlite3_bind_double(s, i, v)
            case let v as String:
                sqlite3_bind_text(s, i, v, -1, SQLITE_TRANSIENT)
            case let v as Date:
                sqlite3_bind_double(s, i, v.timeIntervalSince1970)
            default:
                sqlite3_bind_text(s, i, String(describing: value!), -1, SQLITE_TRANSIENT)
            }
        }
        return s
    }
}
