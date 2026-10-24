import Foundation

// =============================================================================
// 工程 / 子目仓储
// =============================================================================

final class ProjectStore {
    private let db: SQLiteDB

    init(db: SQLiteDB) { self.db = db }

    // MARK: - 工程

    func list() throws -> [Project] {
        try db.query("""
        SELECT id, code, name, category, specialty, scale, owner, contractor, compiler, reviewer,
               fee_template_id, created_at, updated_at
        FROM project ORDER BY updated_at DESC;
        """) { r in
            Project(id: r.int(0), code: r.text(1), name: r.text(2), category: r.text(3),
                    specialty: r.text(4), scale: r.text(5), owner: r.text(6),
                    contractor: r.text(7), compiler: r.text(8), reviewer: r.text(9),
                    feeTemplateID: r.int(10), createdAt: r.date(11), updatedAt: r.date(12))
        }
    }

    @discardableResult
    func create(_ p: Project) throws -> Project {
        var p = p
        let now = Date()
        p.createdAt = now
        p.updatedAt = now
        try db.run("""
        INSERT INTO project(code, name, category, specialty, scale, owner, contractor, compiler,
                            reviewer, fee_template_id, created_at, updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?);
        """, [p.code, p.name, p.category, p.specialty, p.scale, p.owner, p.contractor,
              p.compiler, p.reviewer, p.feeTemplateID, now, now])
        p.id = db.lastInsertRowID
        return p
    }

    func update(_ p: Project) throws {
        try db.run("""
        UPDATE project SET code=?, name=?, category=?, specialty=?, scale=?, owner=?, contractor=?,
                          compiler=?, reviewer=?, fee_template_id=?, updated_at=?
        WHERE id=?;
        """, [p.code, p.name, p.category, p.specialty, p.scale, p.owner, p.contractor,
              p.compiler, p.reviewer, p.feeTemplateID, Date(), p.id])
    }

    func touch(id: Int64) throws {
        try db.run("UPDATE project SET updated_at=? WHERE id=?;", [Date(), id])
    }

    func delete(id: Int64) throws {
        try db.run("DELETE FROM project WHERE id=?;", [id])
    }

    func project(id: Int64) throws -> Project? {
        try db.query("""
        SELECT id, code, name, category, specialty, scale, owner, contractor, compiler, reviewer,
               fee_template_id, created_at, updated_at
        FROM project WHERE id=?;
        """, [id]) { r in
            Project(id: r.int(0), code: r.text(1), name: r.text(2), category: r.text(3),
                    specialty: r.text(4), scale: r.text(5), owner: r.text(6),
                    contractor: r.text(7), compiler: r.text(8), reviewer: r.text(9),
                    feeTemplateID: r.int(10), createdAt: r.date(11), updatedAt: r.date(12))
        }.first
    }

    // MARK: - 子目

    func items(projectID: Int64) throws -> [ProjectItem] {
        let items = try db.query("""
        SELECT id, project_id, sort_index, quota_code, quota_name, unit, quantity, workday_coeff,
               tech_workday, labor_workday, tech_price, labor_price, note, is_supplement
        FROM project_item WHERE project_id=? ORDER BY sort_index, id;
        """, [projectID]) { r in
            ProjectItem(id: r.int(0), projectID: r.int(1), sortIndex: Int(r.int(2)),
                        quotaCode: r.text(3), quotaName: r.text(4), unit: r.text(5),
                        quantity: r.double(6), workdayCoeff: r.double(7),
                        techWorkday: r.double(8), laborWorkday: r.double(9),
                        techPrice: r.double(10), laborPrice: r.double(11),
                        note: r.text(12), isSupplement: r.bool(13))
        }
        guard !items.isEmpty else { return [] }
        let ids = items.map { $0.id }
        let holders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let resRows = try db.query("""
        SELECT id, item_id, kind, name, spec, unit, qty_per_unit, qty_override, unit_price, is_extra
        FROM project_item_resource WHERE item_id IN (\(holders)) ORDER BY id;
        """, ids.map { $0 as Any? }) { r in
            ItemResource(id: r.int(0), itemID: r.int(1),
                         kind: ResourceKind(rawValue: r.text(2)) ?? .mainMaterial,
                         name: r.text(3), spec: r.text(4), unit: r.text(5),
                         qtyPerUnit: r.double(6),
                         qtyOverride: r.isNull(7) ? nil : r.double(7),
                         unitPrice: r.double(8), isExtra: r.bool(9))
        }
        var grouped: [Int64: [ItemResource]] = [:]
        for r in resRows { grouped[r.itemID, default: []].append(r) }
        return items.map { it in
            var copy = it
            copy.resources = grouped[it.id] ?? []
            return copy
        }
    }

    /// 由定额插入子目（复制资源快照）
    @discardableResult
    func insertItem(projectID: Int64, quota: QuotaItem, quantity: Double,
                    techPrice: Double, laborPrice: Double, note: String = "") throws -> ProjectItem {
        let nextSort = try db.query(
            "SELECT COALESCE(MAX(sort_index),0)+1 FROM project_item WHERE project_id=?;",
            [projectID]) { Int($0.int(0)) }.first ?? 1

        var item = ProjectItem(projectID: projectID, sortIndex: nextSort,
                               quotaCode: quota.code, quotaName: quota.name, unit: quota.unit,
                               quantity: quantity, workdayCoeff: 1,
                               techWorkday: quota.techWorkday, laborWorkday: quota.laborWorkday,
                               techPrice: techPrice, laborPrice: laborPrice,
                               note: note, isSupplement: false)
        try db.run("""
        INSERT INTO project_item(project_id, sort_index, quota_code, quota_name, unit, quantity,
                                 workday_coeff, tech_workday, labor_workday, tech_price, labor_price,
                                 note, is_supplement)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [item.projectID, item.sortIndex, item.quotaCode, item.quotaName, item.unit,
              item.quantity, item.workdayCoeff, item.techWorkday, item.laborWorkday,
              item.techPrice, item.laborPrice, item.note, item.isSupplement])
        item.id = db.lastInsertRowID

        for res in quota.resources {
            try db.run("""
            INSERT INTO project_item_resource(item_id, kind, name, spec, unit, qty_per_unit,
                                             qty_override, unit_price, is_extra)
            VALUES(?,?,?,?,?,?,?,?,0);
            """, [item.id, res.kind.rawValue, res.name, res.spec, res.unit,
                  res.qtyPerUnit, nil, res.unitPrice])
        }
        item.resources = try resources(itemID: item.id)
        return item
    }

    /// 插入空子目（补充定额 / 手填）
    @discardableResult
    func insertBlankItem(projectID: Int64, techPrice: Double, laborPrice: Double) throws -> ProjectItem {
        let nextSort = try db.query(
            "SELECT COALESCE(MAX(sort_index),0)+1 FROM project_item WHERE project_id=?;",
            [projectID]) { Int($0.int(0)) }.first ?? 1
        try db.run("""
        INSERT INTO project_item(project_id, sort_index, quota_code, quota_name, unit, quantity,
                                 workday_coeff, tech_workday, labor_workday, tech_price, labor_price,
                                 note, is_supplement)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,1);
        """, [projectID, nextSort, "补-\(nextSort)", "补充定额", "项", 1, 1, 0, 0,
              techPrice, laborPrice, ""])
        return ProjectItem(id: db.lastInsertRowID, projectID: projectID, sortIndex: nextSort,
                           quotaCode: "补-\(nextSort)", quotaName: "补充定额", unit: "项",
                           quantity: 1, workdayCoeff: 1, techWorkday: 0, laborWorkday: 0,
                           techPrice: techPrice, laborPrice: laborPrice,
                           note: "", isSupplement: true)
    }

    func updateItem(_ item: ProjectItem) throws {
        try db.run("""
        UPDATE project_item SET quota_name=?, unit=?, quantity=?, workday_coeff=?,
                               tech_workday=?, labor_workday=?, tech_price=?, labor_price=?, note=?
        WHERE id=?;
        """, [item.quotaName, item.unit, item.quantity, item.workdayCoeff,
              item.techWorkday, item.laborWorkday, item.techPrice, item.laborPrice,
              item.note, item.id])
    }

    func replaceResources(itemID: Int64, resources: [ItemResource]) throws {
        try db.transaction {
            try db.run("DELETE FROM project_item_resource WHERE item_id=?;", [itemID])
            for res in resources {
                try db.run("""
                INSERT INTO project_item_resource(item_id, kind, name, spec, unit, qty_per_unit,
                                                  qty_override, unit_price, is_extra)
                VALUES(?,?,?,?,?,?,?,?,?);
                """, [itemID, res.kind.rawValue, res.name, res.spec, res.unit,
                      res.qtyPerUnit, res.qtyOverride, res.unitPrice, res.isExtra])
            }
        }
    }

    func resources(itemID: Int64) throws -> [ItemResource] {
        try db.query("""
        SELECT id, item_id, kind, name, spec, unit, qty_per_unit, qty_override, unit_price, is_extra
        FROM project_item_resource WHERE item_id=? ORDER BY id;
        """, [itemID]) { r in
            ItemResource(id: r.int(0), itemID: r.int(1),
                         kind: ResourceKind(rawValue: r.text(2)) ?? .mainMaterial,
                         name: r.text(3), spec: r.text(4), unit: r.text(5),
                         qtyPerUnit: r.double(6),
                         qtyOverride: r.isNull(7) ? nil : r.double(7),
                         unitPrice: r.double(8), isExtra: r.bool(9))
        }
    }

    func deleteItem(id: Int64) throws {
        try db.run("DELETE FROM project_item WHERE id=?;", [id])
    }

    /// 拖拽排序
    func reorder(projectID: Int64, orderedIDs: [Int64]) throws {
        try db.transaction {
            for (idx, id) in orderedIDs.enumerated() {
                try db.run("UPDATE project_item SET sort_index=? WHERE id=?;", [idx + 1, id])
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try db.transaction(body)
    }

    /// 复制工程（含全部子目与资源快照）
    @discardableResult
    func duplicate(projectID: Int64, newName: String) throws -> Int64 {
        guard let src = try project(id: projectID) else { return 0 }
        var copy = src
        copy.id = 0
        copy.name = newName
        copy.code = src.code.isEmpty ? "" : src.code + "-copy"
        let created = try create(copy)
        for item in try items(projectID: projectID) {
            var it = item
            it.id = 0
            it.projectID = created.id
            try db.run("""
            INSERT INTO project_item(project_id, sort_index, quota_code, quota_name, unit, quantity,
                                     workday_coeff, tech_workday, labor_workday, tech_price,
                                     labor_price, note, is_supplement)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [it.projectID, it.sortIndex, it.quotaCode, it.quotaName, it.unit, it.quantity,
                  it.workdayCoeff, it.techWorkday, it.laborWorkday, it.techPrice, it.laborPrice,
                  it.note, it.isSupplement])
            try replaceResources(itemID: db.lastInsertRowID, resources: it.resources)
        }
        return created.id
    }
}
