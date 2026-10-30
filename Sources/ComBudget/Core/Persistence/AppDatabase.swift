import Foundation

// =============================================================================
// 应用数据库入口
//   主库：~/Library/Application Support/ComBudget/combudget.db
//   首次启动：建表 → 从内置 quota451.sqlite 导入 3091 条定额 → 写默认取费模板
// =============================================================================

final class AppDatabase {
    let db: SQLiteDB
    let quota: QuotaStore
    let project: ProjectStore
    let fee: FeeStore
    /// 价格库（451 手册只有消耗量，单价存在这里）
    let price: PriceStore
    /// 内置定额是否成功导入（界面上提示用）
    private(set) var seedStatus: String = ""

    init(path: String, importSeed: Bool = true) throws {
        db = try SQLiteDB(path: path)
        try Schema.migrate(db)
        quota = QuotaStore(db: db)
        project = ProjectStore(db: db)
        fee = FeeStore(db: db)
        price = PriceStore(db: db)
        // 装配后，插入子目会自动套价（价格库为空时不改变原有行为）
        project.price = price

        if importSeed {
            let count = try quota.count()
            if count == 0 {
                if let seedURL = SeedLibrary.locate() {
                    let result = try SeedLibrary.importQuota(from: seedURL, into: db)
                    seedStatus = "已导入内置 451 定额 \(result.items) 条、主材/机械/仪表 \(result.resources) 条"
                } else {
                    seedStatus = "未找到内置定额库 \(SeedLibrary.fileName)，可在「定额库 → 导入定额」自行导入"
                }
            }
        }

        if try fee.templates().isEmpty {
            var tpl = SeedLibrary.defaultFeeTemplate()
            try fee.save(&tpl)
        }
    }

    /// 强制重建内置定额库（定额库页面「重新导入内置库」用）
    @discardableResult
    func reimportSeed() throws -> String {
        guard let seedURL = SeedLibrary.locate() else {
            return "未找到内置定额库 \(SeedLibrary.fileName)"
        }
        try quota.clearBuiltin()
        let result = try SeedLibrary.importQuota(from: seedURL, into: db)
        seedStatus = "已重新导入 \(result.items) 条定额"
        return seedStatus
    }

    static func defaultPath() throws -> String {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("ComBudget", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("combudget.db").path
    }
}

// =============================================================================
// 工程文件包（.combudget）
// VACUUM INTO 生成主库快照 → 只保留目标工程 → 单文件自包含（含定额库与取费模板）
// =============================================================================

enum ProjectBundle {
    static let fileExtension = "combudget"

    static func export(db: SQLiteDB, projectID: Int64, to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try db.run("VACUUM INTO ?;", [url.path])

        let pkg = try SQLiteDB(path: url.path)
        try pkg.run("DELETE FROM project WHERE id <> ?;", [projectID])
        try pkg.run("DELETE FROM project_item WHERE project_id NOT IN (SELECT id FROM project);")
        try pkg.run("DELETE FROM project_item_resource WHERE item_id NOT IN (SELECT id FROM project_item);")
        try pkg.exec("VACUUM;")
    }

    @discardableResult
    static func importBundle(db: SQLiteDB, from url: URL) throws -> [Int64] {
        let pkg = try SQLiteDB(path: url.path)
        let projects = try pkg.query("""
        SELECT id, code, name, category, specialty, scale, owner, contractor, compiler, reviewer,
               fee_template_id, created_at, updated_at FROM project;
        """) { r in
            Project(id: r.int(0), code: r.text(1), name: r.text(2), category: r.text(3),
                    specialty: r.text(4), scale: r.text(5), owner: r.text(6),
                    contractor: r.text(7), compiler: r.text(8), reviewer: r.text(9),
                    feeTemplateID: r.int(10), createdAt: r.date(11), updatedAt: r.date(12))
        }
        guard !projects.isEmpty else { return [] }

        var newIDs: [Int64] = []
        try db.transaction {
            // 包里带的价格库一并收下（换机器后仍能重新套价）
            let priceRows = try pkg.query("""
            SELECT kind, name, spec, unit, unit_price, source FROM resource_price;
            """, []) { r in
                (r.text(0), r.text(1), r.text(2), r.text(3), r.double(4), r.text(5))
            }
            for pr in priceRows {
                let exists = try db.query(
                    "SELECT 1 FROM resource_price WHERE kind=? AND name=? AND spec=? AND unit=?;",
                    [pr.0, pr.1, pr.2, pr.3]) { _ in true }
                guard exists.isEmpty else { continue }
                try db.run("""
                INSERT INTO resource_price(kind, name, spec, unit, unit_price, source, updated_at)
                VALUES(?,?,?,?,?,?,?);
                """, [pr.0, pr.1, pr.2, pr.3, pr.4, pr.5, Date()])
            }

            // 包里带的定额（换机器时补齐）
        let pkgQuotas = try pkg.query("""
        SELECT id, code, name, unit, chapter, section, series, book, work,
               tech_workday, labor_workday, is_builtin FROM quota_item;
        """) { r in
            QuotaItem(id: r.int(0), code: r.text(1), name: r.text(2), unit: r.text(3),
                      chapter: r.text(4), section: r.text(5), series: r.text(6),
                      book: r.text(7), work: r.text(8),
                      techWorkday: r.double(9), laborWorkday: r.double(10),
                      isBuiltin: r.bool(11))
        }
            for q in pkgQuotas {
                let exists = try db.query("SELECT 1 FROM quota_item WHERE code=?;", [q.code]) { _ in true }
                guard exists.isEmpty else { continue }
                try db.run("""
                INSERT INTO quota_item(code, name, unit, chapter, section, series, book, work,
                                       tech_workday, labor_workday, is_builtin, sort_index, created_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [q.code, q.name, q.unit, q.chapter, q.section, q.series, q.book, q.work,
                      q.techWorkday, q.laborWorkday, q.isBuiltin, 999999, Date()])
                let newQID = db.lastInsertRowID
                let res = try pkg.query("""
                SELECT kind, name, spec, unit, qty_per_unit, unit_price FROM quota_resource WHERE quota_id=?;
                """, [q.id]) { r in (r.text(0), r.text(1), r.text(2), r.text(3), r.double(4), r.double(5)) }
                for r in res {
                    try db.run("""
                    INSERT INTO quota_resource(quota_id, kind, name, spec, unit, qty_per_unit, unit_price)
                    VALUES(?,?,?,?,?,?,?);
                    """, [newQID, r.0, r.1, r.2, r.3, r.4, r.5])
                }
            }

            for p in projects {
                var feeTemplateID: Int64 = 0
                if let row = try pkg.query(
                    "SELECT id, name, aux_rate, note FROM fee_template WHERE id=?;",
                    [p.feeTemplateID], { r in (r.int(0), r.text(1), r.double(2), r.text(3)) }).first {
                    let same = try db.query("SELECT id FROM fee_template WHERE name=?;", [row.1]) {
                        $0.int(0)
                    }.first
                    if let same {
                        feeTemplateID = same
                    } else {
                        try db.run("INSERT INTO fee_template(name, is_builtin, aux_rate, note) VALUES(?,?,?,?);",
                                   [row.1 + "（导入）", false, row.2, row.3])
                        feeTemplateID = db.lastInsertRowID
                        let rates = try pkg.query("""
                        SELECT key, name, grp, base, rate, sort_index, is_enabled, note
                        FROM fee_rate WHERE template_id=?;
                        """, [row.0]) { r in
                            (r.text(0), r.text(1), r.text(2), r.text(3), r.double(4),
                             Int(r.int(5)), r.bool(6), r.text(7))
                        }
                        for r in rates {
                            try db.run("""
                            INSERT INTO fee_rate(template_id, key, name, grp, base, rate, sort_index,
                                                 is_enabled, note)
                            VALUES(?,?,?,?,?,?,?,?,?);
                            """, [feeTemplateID, r.0, r.1, r.2, r.3, r.4, r.5, r.6, r.7])
                        }
                    }
                }

                var np = p
                np.id = 0
                np.feeTemplateID = feeTemplateID
                try db.run("""
                INSERT INTO project(code, name, category, specialty, scale, owner, contractor,
                                    compiler, reviewer, fee_template_id, created_at, updated_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?);
                """, [np.code, np.name, np.category, np.specialty, np.scale, np.owner,
                      np.contractor, np.compiler, np.reviewer, np.feeTemplateID, Date(), Date()])
                let newPID = db.lastInsertRowID
                newIDs.append(newPID)

                let items = try pkg.query("""
                SELECT id, sort_index, quota_code, quota_name, unit, quantity, workday_coeff,
                       tech_workday, labor_workday, tech_price, labor_price, note, is_supplement,
                       COALESCE(chapter,''), COALESCE(series,''),
                       COALESCE(tech_workday_base, tech_workday),
                       COALESCE(labor_workday_base, labor_workday), COALESCE(conv_note,'')
                FROM project_item WHERE project_id=? ORDER BY sort_index;
                """, [p.id]) { r in
                    (r.int(0), r.int(1), r.text(2), r.text(3), r.text(4), r.double(5),
                     r.double(6), r.double(7), r.double(8), r.double(9), r.double(10),
                     r.text(11), r.bool(12), r.text(13), r.text(14), r.double(15),
                     r.double(16), r.text(17))
                }
                for it in items {
                    try db.run("""
                    INSERT INTO project_item(project_id, sort_index, quota_code, quota_name, unit,
                                             quantity, workday_coeff, tech_workday, labor_workday,
                                             tech_price, labor_price, note, is_supplement,
                                             chapter, series, tech_workday_base, labor_workday_base,
                                             conv_note)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                    """, [newPID, it.1, it.2, it.3, it.4, it.5, it.6, it.7, it.8, it.9, it.10,
                          it.11, it.12, it.13, it.14, it.15, it.16, it.17])
                    let newItemID = db.lastInsertRowID
                    let res = try pkg.query("""
                    SELECT kind, name, spec, unit, qty_per_unit, qty_override, unit_price, is_extra
                    FROM project_item_resource WHERE item_id=?;
                    """, [it.0]) { r in
                        (r.text(0), r.text(1), r.text(2), r.text(3), r.double(4),
                         r.isNull(5) ? nil : r.double(5), r.double(6), r.bool(7))
                    }
                    for r in res {
                        try db.run("""
                        INSERT INTO project_item_resource(item_id, kind, name, spec, unit, qty_per_unit,
                                                         qty_override, unit_price, is_extra)
                        VALUES(?,?,?,?,?,?,?,?,?);
                        """, [newItemID, r.0, r.1, r.2, r.3, r.4, r.5, r.6, r.7])
                    }
                }
            }
        }
        return newIDs
    }
}
