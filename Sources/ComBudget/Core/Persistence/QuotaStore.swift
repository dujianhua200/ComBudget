import Foundation

// =============================================================================
// 定额库仓储：检索 / 插入 / 补充定额 / 整库导入
// 内置 451 全册 3091 条；检索走 LIKE，上限 400 条，够用且不卡。
// =============================================================================

final class QuotaStore {
    private let db: SQLiteDB

    init(db: SQLiteDB) { self.db = db }

    private static let columns = """
    id, code, name, unit, chapter, section, series, book, work,
    tech_workday, labor_workday, is_builtin
    """

    private static func map(_ r: Row) -> QuotaItem {
        QuotaItem(id: r.int(0), code: r.text(1), name: r.text(2), unit: r.text(3),
                  chapter: r.text(4), section: r.text(5), series: r.text(6),
                  book: r.text(7), work: r.text(8),
                  techWorkday: r.double(9), laborWorkday: r.double(10),
                  isBuiltin: r.bool(11))
    }

    // MARK: - 查询

    func count() throws -> Int {
        try db.query("SELECT COUNT(*) FROM quota_item;") { Int($0.int(0)) }.first ?? 0
    }

    func resourceCount() throws -> Int {
        try db.query("SELECT COUNT(*) FROM quota_resource;") { Int($0.int(0)) }.first ?? 0
    }

    /// 册列表（左侧筛选）：(series, book, 条数)
    func seriesList() throws -> [(series: String, book: String, count: Int)] {
        try db.query("""
        SELECT series, book, COUNT(*) FROM quota_item
        GROUP BY series ORDER BY MIN(sort_index);
        """) { r in
            (r.text(0), r.text(1), Int(r.int(2)))
        }
    }

    func chapters() throws -> [String] {
        try db.query("""
        SELECT DISTINCT chapter FROM quota_item WHERE chapter <> '' ORDER BY chapter;
        """) { $0.text(0) }
    }

    /// 模糊检索：编号 / 名称 / 工作内容，可按册与章过滤
    func search(keyword: String = "", series: String? = nil, chapter: String? = nil,
                limit: Int = 400) throws -> [QuotaItem] {
        var sql = "SELECT \(Self.columns) FROM quota_item WHERE 1=1"
        var params: [Any?] = []

        let kw = keyword.trimmingCharacters(in: .whitespaces)
        if !kw.isEmpty {
            sql += " AND (code LIKE ? OR name LIKE ? OR work LIKE ?)"
            let like = "%\(kw)%"
            params += [like, like, like]
        }
        if let s = series, !s.isEmpty {
            sql += " AND series = ?"
            params.append(s)
        }
        if let c = chapter, !c.isEmpty {
            sql += " AND chapter = ?"
            params.append(c)
        }
        sql += " ORDER BY sort_index, code LIMIT ?;"
        params.append(limit)

        let items = try db.query(sql, params) { Self.map($0) }
        return try attachResources(items)
    }

    func item(code: String) throws -> QuotaItem? {
        let items = try db.query("SELECT \(Self.columns) FROM quota_item WHERE code = ?;", [code]) {
            Self.map($0)
        }
        return try attachResources(items).first
    }

    /// 批量按编号取（一次 SQL，避免 N+1）
    func items(codes: [String]) throws -> [String: QuotaItem] {
        let unique = Array(Set(codes.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [:] }
        let holders = Array(repeating: "?", count: unique.count).joined(separator: ",")
        let items = try db.query(
            "SELECT \(Self.columns) FROM quota_item WHERE code IN (\(holders));",
            unique.map { $0 as Any? }) { Self.map($0) }
        var map: [String: QuotaItem] = [:]
        for it in try attachResources(items) { map[it.code] = it }
        return map
    }

    private func attachResources(_ items: [QuotaItem]) throws -> [QuotaItem] {
        guard !items.isEmpty else { return [] }
        let ids = items.map { $0.id }
        let holders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try db.query("""
        SELECT id, quota_id, kind, name, spec, unit, qty_per_unit, unit_price
        FROM quota_resource WHERE quota_id IN (\(holders)) ORDER BY id;
        """, ids.map { $0 as Any? }) { r in
            QuotaResource(id: r.int(0), quotaID: r.int(1),
                          kind: ResourceKind(rawValue: r.text(2)) ?? .mainMaterial,
                          name: r.text(3), spec: r.text(4), unit: r.text(5),
                          qtyPerUnit: r.double(6), unitPrice: r.double(7))
        }
        var grouped: [Int64: [QuotaResource]] = [:]
        for r in rows { grouped[r.quotaID, default: []].append(r) }
        return items.map { it in
            var copy = it
            copy.resources = grouped[it.id] ?? []
            return copy
        }
    }

    // MARK: - 写入

    /// 新增 / 更新一条定额（补充定额、Excel 导入都用）
    @discardableResult
    func save(_ item: inout QuotaItem) throws -> Int64 {
        try db.transaction {
            if item.id == 0 {
                try db.run("""
                INSERT INTO quota_item(code, name, unit, chapter, section, series, book, work,
                                       tech_workday, labor_workday, is_builtin, sort_index, created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [item.code, item.name, item.unit, item.chapter, item.section, item.series,
                      item.book, item.work, item.techWorkday, item.laborWorkday,
                      item.isBuiltin, 999999, Date()])
                item.id = db.lastInsertRowID
            } else {
                try db.run("""
                UPDATE quota_item SET code=?, name=?, unit=?, chapter=?, section=?, series=?,
                                      book=?, work=?, tech_workday=?, labor_workday=?
                WHERE id=?;
                """, [item.code, item.name, item.unit, item.chapter, item.section, item.series,
                      item.book, item.work, item.techWorkday, item.laborWorkday, item.id])
                try db.run("DELETE FROM quota_resource WHERE quota_id=?;", [item.id])
            }
            for res in item.resources {
                try db.run("""
                INSERT INTO quota_resource(quota_id, kind, name, spec, unit, qty_per_unit, unit_price)
                VALUES(?,?,?,?,?,?,?);
                """, [item.id, res.kind.rawValue, res.name, res.spec, res.unit,
                      res.qtyPerUnit, res.unitPrice])
            }
            return item.id
        }
    }

    /// 批量导入（Excel 定额库导入）
    func importBatch(_ items: [QuotaItem]) throws -> Int {
        guard !items.isEmpty else { return 0 }
        return try db.transaction {
            var n = 0
            for var it in items {
                try db.run("""
                INSERT OR REPLACE INTO quota_item(code, name, unit, chapter, section, series, book,
                                                 work, tech_workday, labor_workday, is_builtin,
                                                 sort_index, created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [it.code, it.name, it.unit, it.chapter, it.section, it.series, it.book, it.work,
                      it.techWorkday, it.laborWorkday, 0, 999999, Date()])
                it.id = db.lastInsertRowID
                try db.run("DELETE FROM quota_resource WHERE quota_id=?;", [it.id])
                for res in it.resources {
                    try db.run("""
                    INSERT INTO quota_resource(quota_id, kind, name, spec, unit, qty_per_unit, unit_price)
                    VALUES(?,?,?,?,?,?,?);
                    """, [it.id, res.kind.rawValue, res.name, res.spec, res.unit,
                          res.qtyPerUnit, res.unitPrice])
                }
                n += 1
            }
            return n
        }
    }

    /// 删除（内置定额不允许删）
    func delete(id: Int64) throws {
        try db.run("DELETE FROM quota_item WHERE id=? AND is_builtin=0;", [id])
    }

    /// 清空内置库（用户换用别家定额库时）
    func clearBuiltin() throws {
        try db.transaction {
            try db.run("DELETE FROM quota_resource WHERE quota_id IN (SELECT id FROM quota_item WHERE is_builtin=1);")
            try db.run("DELETE FROM quota_item WHERE is_builtin=1;")
        }
    }
}
