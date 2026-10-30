import Foundation

// =============================================================================
// 价格库仓储
//
// 451 定额手册只给「消耗量」（主材多少、机械几个台班），不给单价 ——
// 单价来自另一本价格册或市场询价，所以单独一张 resource_price 表存。
//
// 匹配策略（从严格到宽松，依次尝试，命中即止）：
//   1. 类型 + 全名 + 规格 + 单位 完全一致        → 精确
//   2. 类型 + 全名 + 单位一致（忽略规格）        → 同单位
//   3. 类型 + 裸名（去掉括号后的型号）+ 单位一致  → 同单位（名称模糊）
//   4. 类型 + 裸名（忽略单位）                   → 弱匹配（仅当查不到上面三种）
// 前三种都要求「单位一致」，避免把「每米」的价格套到「每吨」上。
// 第 4 种是兜底（询价清单常常不写单位），套价结果里会单独计数提示。
// =============================================================================

final class PriceStore {
    private let db: SQLiteDB

    init(db: SQLiteDB) { self.db = db }

    private static let columns = "id, kind, name, spec, unit, unit_price, source, updated_at"

    private static func map(_ r: Row) -> PriceEntry {
        PriceEntry(id: r.int(0),
                   kind: ResourceKind(rawValue: r.text(1)) ?? .mainMaterial,
                   name: r.text(2), spec: r.text(3), unit: r.text(4),
                   unitPrice: r.double(5), source: r.text(6),
                   updatedAt: r.date(7))
    }

    // MARK: - 查询

    func count() throws -> Int {
        try db.query("SELECT COUNT(*) FROM resource_price;") { Int($0.int(0)) }.first ?? 0
    }

    /// 检索（编号式模糊匹配名称/规格/来源）
    func search(keyword: String = "", kind: ResourceKind? = nil, limit: Int = 500) throws -> [PriceEntry] {
        var sql = "SELECT \(Self.columns) FROM resource_price WHERE 1=1"
        var params: [Any?] = []

        let kw = keyword.trimmingCharacters(in: .whitespaces)
        if !kw.isEmpty {
            sql += " AND (name LIKE ? OR spec LIKE ? OR source LIKE ?)"
            let like = "%\(kw)%"
            params += [like, like, like]
        }
        if let k = kind {
            sql += " AND kind = ?"
            params.append(k.rawValue)
        }
        sql += " ORDER BY kind, name LIMIT ?;"
        params.append(limit)
        return try db.query(sql, params) { Self.map($0) }
    }

    func entry(id: Int64) throws -> PriceEntry? {
        try db.query("SELECT \(Self.columns) FROM resource_price WHERE id=?;", [id]) { Self.map($0) }.first
    }

    /// 全量读取（不限条数，清空前留快照用；可按来源过滤）
    func all(source: String? = nil) throws -> [PriceEntry] {
        if let s = source {
            return try db.query("SELECT \(Self.columns) FROM resource_price WHERE source=? ORDER BY id;",
                                [s]) { Self.map($0) }
        }
        return try db.query("SELECT \(Self.columns) FROM resource_price ORDER BY id;") { Self.map($0) }
    }

    // MARK: - 写入

    /// 新增或更新（按 类型+名称+规格+单位 唯一键 upsert，重复导入不会翻倍）
    @discardableResult
    func upsert(_ entry: PriceEntry) throws -> Int64 {
        var e = entry
        e.updatedAt = Date()
        if let exists = try db.query(
            "SELECT id FROM resource_price WHERE kind=? AND name=? AND spec=? AND unit=?;",
            [e.kind.rawValue, e.name, e.spec, e.unit], { $0.int(0) }).first {
            e.id = exists
            try db.run("""
            UPDATE resource_price SET unit_price=?, source=?, updated_at=? WHERE id=?;
            """, [e.unitPrice, e.source, e.updatedAt, e.id])
            return e.id
        }
        try db.run("""
        INSERT INTO resource_price(kind, name, spec, unit, unit_price, source, updated_at)
        VALUES(?,?,?,?,?,?,?);
        """, [e.kind.rawValue, e.name, e.spec, e.unit, e.unitPrice, e.source, e.updatedAt])
        e.id = db.lastInsertRowID
        return e.id
    }

    /// 批量导入（单事务；上百上千行也是毫秒级）
    @discardableResult
    func save(_ entries: [PriceEntry], source: String = "") throws -> Int {
        guard !entries.isEmpty else { return 0 }
        return try db.transaction {
            var n = 0
            for e in entries {
                var x = e
                if x.source.isEmpty { x.source = source }
                try upsert(x)
                n += 1
            }
            return n
        }
    }

    func delete(id: Int64) throws {
        try db.run("DELETE FROM resource_price WHERE id=?;", [id])
    }

    /// 清空（可按来源清，比如只删某次导入的那一批）
    func clear(source: String? = nil) throws {
        if let s = source {
            try db.run("DELETE FROM resource_price WHERE source=?;", [s])
        } else {
            try db.run("DELETE FROM resource_price;")
        }
    }

    // MARK: - 匹配

    /// 预建内存索引，套价时用它做纯内存匹配，避免 N 次查库
    func buildIndex() throws -> PriceIndex {
        let rows = try db.query("SELECT kind, name, spec, unit, unit_price FROM resource_price;") {
            (kind: ResourceKind(rawValue: $0.text(0)) ?? .mainMaterial,
             name: $0.text(1), spec: $0.text(2), unit: $0.text(3), price: $0.double(4))
        }
        var index = PriceIndex()
        for row in rows {
            index.add(kind: row.kind, name: row.name, spec: row.spec,
                      unit: row.unit, price: row.price)
        }
        return index
    }
}

// MARK: - 价格索引

/// 一次建好、反复使用的匹配索引
struct PriceIndex {
    /// 候选规格：同一「类型+名字」下可能有多条（不同规格/单位）
    private struct Candidate {
        var spec: String
        var unit: String
        var price: Double
    }

    private var exact: [String: [Candidate]] = [:]   // key = 类型|全名
    private var bare: [String: [Candidate]] = [:]    // key = 类型|裸名（去掉括号里的型号）

    var isEmpty: Bool { exact.isEmpty && bare.isEmpty }

    mutating func add(kind: ResourceKind, name: String, spec: String, unit: String, price: Double) {
        let c = Candidate(spec: spec, unit: unit, price: price)
        let cleanName = PriceMatch.norm(name)
        exact["\(kind.rawValue)|\(cleanName)", default: []].append(c)
        let bareName = PriceMatch.bareName(name)
        if bareName != cleanName {
            bare["\(kind.rawValue)|\(bareName)", default: []].append(c)
        } else {
            bare["\(kind.rawValue)|\(cleanName)", default: []].append(c)
        }
    }

    /// 匹配优先级：0 精确（同规格同单位）／1 同单位不同规格／2 忽略规格型号（名称模糊）／3 忽略单位（弱）
    enum Level: Int {
        case exact = 0, sameUnit = 1, fuzzyName = 2, ignoreUnit = 3

        var label: String {
            switch self {
            case .exact:      return "精确"
            case .sameUnit:   return "同单位"
            case .fuzzyName:  return "名称匹配"
            case .ignoreUnit: return "忽略单位"
            }
        }
    }

    func lookup(kind: ResourceKind, name: String, spec: String, unit: String) -> (price: Double, level: Level)? {
        let cleanName = PriceMatch.norm(name)
        let cleanSpec = PriceMatch.norm(spec)
        let cleanUnit = PriceMatch.norm(unit)

        // 先按全名找（含规格，最准）
        if let hit = pick(candidates: exact["\(kind.rawValue)|\(cleanName)"], spec: cleanSpec, unit: cleanUnit) {
            return hit
        }
        // 再按裸名找：价格册写「螺栓」、定额写「螺栓（M12×100 以内）」时命中
        if let hit = pick(candidates: bare["\(kind.rawValue)|\(PriceMatch.bareName(name))"],
                          spec: cleanSpec, unit: cleanUnit) {
            return (hit.0, .fuzzyName)
        }
        return nil
    }

    private func pick(candidates: [Candidate]?, spec: String, unit: String) -> (Double, Level)? {
        guard let list = candidates, !list.isEmpty else { return nil }

        // 1) 规格 + 单位都一致
        if !spec.isEmpty, let hit = list.first(where: {
            PriceMatch.norm($0.spec) == spec && PriceMatch.sameUnit($0.unit, unit) }) {
            return (hit.price, .exact)
        }
        // 2) 单位一致（忽略规格）
        if let hit = list.first(where: { PriceMatch.sameUnit($0.unit, unit) }) {
            return (hit.price, .sameUnit)
        }
        // 3) 忽略单位（兜底）：只有当查询方或价格方单位为空，或候选只有一条时才敢用
        if unit.isEmpty || list.count == 1, let hit = list.first {
            return (hit.price, .ignoreUnit)
        }
        return nil
    }
}

// MARK: - 名称归一化

enum PriceMatch {
    /// 去掉空白
    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 裸名：去掉括号里的型号说明。「螺栓（M12×100 以内）」→「螺栓」
    static func bareName(_ s: String) -> String {
        var out = norm(s)
        for (open, close) in [("（", "）"), ("(", ")")] {
            if let range = out.range(of: open) {
                out = String(out[..<range.lowerBound])
            }
            _ = close
        }
        return out.isEmpty ? norm(s) : out
    }

    /// 单位一致判定：任一方为空视为通配（询价单常漏单位）
    static func sameUnit(_ a: String, _ b: String) -> Bool {
        let x = norm(a), y = norm(b)
        if x.isEmpty || y.isEmpty { return true }
        return x == y
    }
}
