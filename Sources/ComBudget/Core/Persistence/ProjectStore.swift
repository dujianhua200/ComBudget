import Foundation

// =============================================================================
// 工程 / 子目仓储
// =============================================================================

final class ProjectStore {
    private let db: SQLiteDB

    /// 价格库（可选）：设置后，插入子目会自动给主材/机械/仪表套价。
    /// 由 AppDatabase 在建完三个 store 后装配，避免构造顺序依赖。
    var price: PriceStore?

    /// 套价索引缓存：价格库条数变化时才重建（COUNT 一次就能判断是否失效）
    private var priceIndexCache: PriceIndex?
    private var priceCacheCount = -1

    /// 取一份可用的价格索引；没装配价格库时返回空索引（资源保持原价）
    func priceIndex() throws -> PriceIndex {
        guard let price else { return PriceIndex() }
        let n = try price.count()
        if n != priceCacheCount || priceIndexCache == nil {
            priceIndexCache = try price.buildIndex()
            priceCacheCount = n
        }
        return priceIndexCache ?? PriceIndex()
    }

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
               tech_workday, labor_workday, tech_price, labor_price, note, is_supplement,
               chapter, series, tech_workday_base, labor_workday_base, conv_note
        FROM project_item WHERE project_id=? ORDER BY sort_index, id;
        """, [projectID]) { r in
            var it = ProjectItem(id: r.int(0), projectID: r.int(1), sortIndex: Int(r.int(2)),
                        quotaCode: r.text(3), quotaName: r.text(4), unit: r.text(5),
                        quantity: r.double(6), workdayCoeff: r.double(7),
                        techWorkday: r.double(8), laborWorkday: r.double(9),
                        techPrice: r.double(10), laborPrice: r.double(11),
                        note: r.text(12), isSupplement: r.bool(13))
            it.chapter = r.text(14)
            it.series = r.text(15)
            it.techWorkdayBase = r.double(16)
            it.laborWorkdayBase = r.double(17)
            it.convNote = r.text(18)
            return it
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

    /// 定额子目表字段顺序（多处 INSERT 复用，集中定义避免错位）
    private static let itemColumns = """
    project_id, sort_index, quota_code, quota_name, unit, quantity, workday_coeff,
    tech_workday, labor_workday, tech_price, labor_price, note, is_supplement,
    chapter, series, tech_workday_base, labor_workday_base, conv_note
    """

    /// 由定额插入子目（复制资源快照 + 自动套价 + 记录章节/系列用于分组小计）
    @discardableResult
    func insertItem(projectID: Int64, quota: QuotaItem, quantity: Double,
                    techPrice: Double, laborPrice: Double, note: String = "",
                    autoPrice: Bool = true) throws -> ProjectItem {
        let nextSort = try db.query(
            "SELECT COALESCE(MAX(sort_index),0)+1 FROM project_item WHERE project_id=?;",
            [projectID]) { Int($0.int(0)) }.first ?? 1

        var item = ProjectItem(projectID: projectID, sortIndex: nextSort,
                               quotaCode: quota.code, quotaName: quota.name, unit: quota.unit,
                               quantity: quantity, workdayCoeff: 1,
                               techWorkday: quota.techWorkday, laborWorkday: quota.laborWorkday,
                               techPrice: techPrice, laborPrice: laborPrice,
                               note: note, isSupplement: false)
        item.chapter = quota.chapter
        item.series = quota.series
        item.techWorkdayBase = quota.techWorkday
        item.laborWorkdayBase = quota.laborWorkday

        try db.run("""
        INSERT INTO project_item(\(Self.itemColumns))
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [item.projectID, item.sortIndex, item.quotaCode, item.quotaName, item.unit,
              item.quantity, item.workdayCoeff, item.techWorkday, item.laborWorkday,
              item.techPrice, item.laborPrice, item.note, item.isSupplement,
              item.chapter, item.series, item.techWorkdayBase, item.laborWorkdayBase, item.convNote])
        item.id = db.lastInsertRowID

        // 插入同时按价格库套价（价格库为空时保持 0，不影响既有行为）
        let index = autoPrice ? (try? priceIndex()) ?? PriceIndex() : PriceIndex()
        for res in quota.resources {
            let matched: Double? = index.isEmpty
                ? nil
                : index.lookup(kind: res.kind, name: res.name, spec: res.spec, unit: res.unit)?.price
            let unitPrice = res.unitPrice > 0 ? res.unitPrice : (matched ?? 0)
            try db.run("""
            INSERT INTO project_item_resource(item_id, kind, name, spec, unit, qty_per_unit,
                                             qty_override, unit_price, is_extra)
            VALUES(?,?,?,?,?,?,?,?,0);
            """, [item.id, res.kind.rawValue, res.name, res.spec, res.unit,
                  res.qtyPerUnit, nil, unitPrice])
        }
        item.resources = try resources(itemID: item.id)
        return item
    }

    /// 撤销「删除子目」用：把整条子目（含资源快照）按原样还原
    @discardableResult
    func restoreItem(_ item: ProjectItem) throws -> Int64 {
        guard item.id > 0 else { return 0 }
        let exists = try db.query("SELECT 1 FROM project_item WHERE id=?;", [item.id]) { _ in true }
        if !exists.isEmpty {
            try updateItem(item)
            try replaceResources(itemID: item.id, resources: item.resources)
            return item.id
        }
        try db.run("""
        INSERT INTO project_item(id, \(Self.itemColumns))
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [item.id, item.projectID, item.sortIndex, item.quotaCode, item.quotaName, item.unit,
              item.quantity, item.workdayCoeff, item.techWorkday, item.laborWorkday,
              item.techPrice, item.laborPrice, item.note, item.isSupplement,
              item.chapter, item.series, item.techWorkdayBase, item.laborWorkdayBase, item.convNote])
        try replaceResources(itemID: item.id, resources: item.resources)
        return item.id
    }

    /// 插入空子目（补充定额 / 手填）
    @discardableResult
    func insertBlankItem(projectID: Int64, techPrice: Double, laborPrice: Double) throws -> ProjectItem {
        let nextSort = try db.query(
            "SELECT COALESCE(MAX(sort_index),0)+1 FROM project_item WHERE project_id=?;",
            [projectID]) { Int($0.int(0)) }.first ?? 1
        try db.run("""
        INSERT INTO project_item(\(Self.itemColumns))
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,1,?,?,?,?,?);
        """, [projectID, nextSort, "补-\(nextSort)", "补充定额", "项", 1, 1, 0, 0,
              techPrice, laborPrice, "", "", "补充子目", 0, 0, ""])
        return ProjectItem(id: db.lastInsertRowID, projectID: projectID, sortIndex: nextSort,
                           quotaCode: "补-\(nextSort)", quotaName: "补充定额", unit: "项",
                           quantity: 1, workdayCoeff: 1, techWorkday: 0, laborWorkday: 0,
                           techPrice: techPrice, laborPrice: laborPrice,
                           note: "", isSupplement: true, series: "补充子目")
    }

    func updateItem(_ item: ProjectItem) throws {
        try db.run("""
        UPDATE project_item SET quota_name=?, unit=?, quantity=?, workday_coeff=?,
                               tech_workday=?, labor_workday=?, tech_price=?, labor_price=?, note=?,
                               chapter=?, series=?, tech_workday_base=?, labor_workday_base=?,
                               conv_note=?
        WHERE id=?;
        """, [item.quotaName, item.unit, item.quantity, item.workdayCoeff,
              item.techWorkday, item.laborWorkday, item.techPrice, item.laborPrice,
              item.note, item.chapter, item.series, item.techWorkdayBase,
              item.laborWorkdayBase, item.convNote, item.id])
    }

    // MARK: - 套价

    /// 按价格库给整个工程的资源重新填单价。
    /// overwrite=false 时保留已手填的单价（手填优先于价格库），只补没填价的。
    func applyPrices(projectID: Int64, overwrite: Bool = true) throws -> PriceApplyResult {
        let index = try priceIndex()
        var result = PriceApplyResult()
        guard !index.isEmpty else { return result }

        let items = try items(projectID: projectID)
        guard !items.isEmpty else { return result }

        try db.transaction {
            for item in items {
                var changed = false
                for res in item.resources {
                    guard res.unitPrice == 0 || overwrite else {
                        result.unchanged += 1
                        continue
                    }
                    guard let hit = index.lookup(kind: res.kind, name: res.name,
                                                 spec: res.spec, unit: res.unit) else {
                        let label = "\(res.name)（\(res.unit.isEmpty ? "无单位" : res.unit)）"
                        if !result.missing.contains(label) { result.missing.append(label) }
                        continue
                    }
                    if res.unitPrice != hit.price {
                        try db.run("UPDATE project_item_resource SET unit_price=? WHERE id=?;",
                                   [hit.price, res.id])
                        changed = true
                    }
                    result.matched += 1
                    if hit.level == .ignoreUnit || hit.level == .fuzzyName {
                        result.fuzzy += 1
                    }
                }
                if changed { try touch(id: projectID) }
            }
        }
        return result
    }

    /// 批量给资源某一行写单价（界面里逐行改价落地用）
    func setResourcePrice(resourceID: Int64, price: Double) throws {
        try db.run("UPDATE project_item_resource SET unit_price=? WHERE id=?;", [price, resourceID])
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

    /// 撤销「删除工程」用：连 id 一起还原（auto_increment 会重新分配 id，这里显式写回）
    @discardableResult
    func restoreProject(_ p: Project) throws -> Int64 {
        guard p.id > 0 else { return 0 }
        let exists = try db.query("SELECT 1 FROM project WHERE id=?;", [p.id]) { _ in true }
        if exists.isEmpty {
            try db.run("""
            INSERT INTO project(id, code, name, category, specialty, scale, owner, contractor,
                                compiler, reviewer, fee_template_id, created_at, updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [p.id, p.code, p.name, p.category, p.specialty, p.scale, p.owner, p.contractor,
                  p.compiler, p.reviewer, p.feeTemplateID, p.createdAt, p.updatedAt])
        }
        return p.id
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
            INSERT INTO project_item(\(Self.itemColumns))
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [it.projectID, it.sortIndex, it.quotaCode, it.quotaName, it.unit, it.quantity,
                  it.workdayCoeff, it.techWorkday, it.laborWorkday, it.techPrice, it.laborPrice,
                  it.note, it.isSupplement, it.chapter, it.series,
                  it.techWorkdayBase, it.laborWorkdayBase, it.convNote])
            try replaceResources(itemID: db.lastInsertRowID, resources: it.resources)
        }
        return created.id
    }
}
