import Foundation

// =============================================================================
// 取费模板仓储
// =============================================================================

final class FeeStore {
    private let db: SQLiteDB

    init(db: SQLiteDB) { self.db = db }

    func templates() throws -> [FeeTemplate] {
        let tpls = try db.query("SELECT id, name, is_builtin, aux_rate, note FROM fee_template ORDER BY id;") { r in
            FeeTemplate(id: r.int(0), name: r.text(1), isBuiltin: r.bool(2),
                        auxMaterialRate: r.double(3), note: r.text(4))
        }
        return try tpls.map { t in
            var copy = t
            copy.rates = try rates(templateID: t.id)
            return copy
        }
    }

    func template(id: Int64) throws -> FeeTemplate? {
        try templates().first { $0.id == id }
    }

    func rates(templateID: Int64) throws -> [FeeRate] {
        try db.query("""
        SELECT id, template_id, key, name, grp, base, rate, sort_index, is_enabled, note
        FROM fee_rate WHERE template_id=? ORDER BY sort_index, id;
        """, [templateID]) { r in
            FeeRate(id: r.int(0), templateID: r.int(1), key: r.text(2), name: r.text(3),
                    group: r.text(4), base: FeeBase(rawValue: r.text(5)) ?? .labor,
                    rate: r.double(6), sortIndex: Int(r.int(7)),
                    isEnabled: r.bool(8), note: r.text(9))
        }
    }

    /// 保存（id=0 新增，否则整模板覆盖费率明细）
    @discardableResult
    func save(_ tpl: inout FeeTemplate) throws -> Int64 {
        try db.transaction {
            if tpl.id == 0 {
                try db.run("INSERT INTO fee_template(name, is_builtin, aux_rate, note) VALUES(?,?,?,?);",
                           [tpl.name, tpl.isBuiltin, tpl.auxMaterialRate, tpl.note])
                tpl.id = db.lastInsertRowID
            } else {
                try db.run("UPDATE fee_template SET name=?, aux_rate=?, note=? WHERE id=?;",
                           [tpl.name, tpl.auxMaterialRate, tpl.note, tpl.id])
                try db.run("DELETE FROM fee_rate WHERE template_id=?;", [tpl.id])
            }
            for (idx, var rate) in tpl.sortedRates.enumerated() {
                rate.templateID = tpl.id
                rate.sortIndex = idx
                try db.run("""
                INSERT INTO fee_rate(template_id, key, name, grp, base, rate, sort_index, is_enabled, note)
                VALUES(?,?,?,?,?,?,?,?,?);
                """, [rate.templateID, rate.key, rate.name, rate.group, rate.base.rawValue,
                      rate.rate, rate.sortIndex, rate.isEnabled, rate.note])
            }
            return tpl.id
        }
    }

    func delete(id: Int64) throws {
        try db.run("DELETE FROM fee_template WHERE id=? AND is_builtin=0;", [id])
    }
}
