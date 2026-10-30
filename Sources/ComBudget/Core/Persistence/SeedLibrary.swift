import Foundation

// =============================================================================
// 内置 451 定额库导入 + 默认取费模板
//
// 内置库是 `quota451.sqlite`（由 tools/parse_451.py 从官方电子手册抽取，
// 3091 条子目 + 主材/机械/仪表消耗量）。首次启动时整库导入主库（ATTACH + INSERT SELECT，
// 万级数据毫秒级完成）。
// =============================================================================

enum SeedLibrary {
    static let fileName = "quota451.sqlite"

    /// 依次尝试：环境变量 → .app/Contents/Resources → 可执行文件同级 → 源码树 data/
    static func locate() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["COMBUDGET_SEED"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent(fileName))
        }
        let bundleURL = Bundle.main.bundleURL
        candidates.append(bundleURL.appendingPathComponent("Contents/Resources/\(fileName)"))
        candidates.append(bundleURL.appendingPathComponent(fileName))

        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent()
        candidates.append(exe.appendingPathComponent(fileName))
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("Resources/\(fileName)"))
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent("Resources/\(fileName)"))

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("data/\(fileName)"))
        candidates.append(cwd.appendingPathComponent(fileName))

        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 从内置库导入定额（幂等：已存在同编号会覆盖）
    @discardableResult
    static func importQuota(from url: URL, into db: SQLiteDB) throws -> (items: Int, resources: Int) {
        let escaped = url.path.replacingOccurrences(of: "'", with: "''")
        try db.exec("ATTACH DATABASE '\(escaped)' AS seed;")
        defer { try? db.exec("DETACH DATABASE seed;") }

        return try db.transaction {
            try db.run("""
            INSERT OR REPLACE INTO quota_item
                (code, name, unit, chapter, section, series, book, work,
                 tech_workday, labor_workday, is_builtin, sort_index, created_at)
            SELECT code, name, unit, chapter, section, series, book, work,
                   tech_workday, labor_workday, 1, sort_index, 0
            FROM seed.quota_item;
            """)
            try db.run("""
            DELETE FROM quota_resource
            WHERE quota_id IN (SELECT id FROM quota_item WHERE is_builtin = 1);
            """)
            try db.run("""
            INSERT INTO quota_resource(quota_id, kind, name, spec, unit, qty_per_unit, unit_price)
            SELECT qi.id, sr.kind, sr.name, '', sr.unit, sr.qty_per_unit, 0
            FROM seed.quota_resource sr
            JOIN quota_item qi ON qi.code = sr.quota_code;
            """)
            let items = try db.query("SELECT COUNT(*) FROM quota_item;") { Int($0.int(0)) }.first ?? 0
            let resources = try db.query("SELECT COUNT(*) FROM quota_resource;") { Int($0.int(0)) }.first ?? 0
            return (items, resources)
        }
    }

    /// 内置取费模板
    ///
    /// 科目按 451 号文口径铺满：措施费 → 间接费（规费 + 企业管理费）→ 利润 → 税金，
    /// 再加 工程建设其他费（表五）与 预备费。
    /// **费率全部是示例值**：规费/社保类按各地文件，税种与税率随政策变（一般计税 9%、
    /// 简易计税 3%），开工前必须按招标文件、工程所在地造价管理部门文件逐项核对，
    /// 界面里可以直接改、也可以另存成自己的模板。
    static func defaultFeeTemplate() -> FeeTemplate {
        var tpl = FeeTemplate(name: "451 默认取费模板（示例费率·需核定）", isBuiltin: true,
                              auxMaterialRate: 0.3,
                              note: "示例费率：请按 451 号文 / 工程所在地文件 / 招标文件核定后使用")
        tpl.rates = [
            // —— 措施费（以人工费为基数）——
            FeeRate(key: "cs_safe",   name: "安全文明施工费",   group: FeeKind.measures.rawValue,
                    base: .labor, rate: 2.5, sortIndex: 10, note: "示例值"),
            FeeRate(key: "cs_temp",   name: "临时设施费",       group: FeeKind.measures.rawValue,
                    base: .labor, rate: 1.5, sortIndex: 11, note: "示例值"),
            FeeRate(key: "cs_winter", name: "冬雨季施工增加费", group: FeeKind.measures.rawValue,
                    base: .labor, rate: 1.0, sortIndex: 12, note: "示例值"),

            // —— 间接费：规费（人工费为基数）——
            FeeRate(key: "gf_social", name: "社会保障费",       group: FeeKind.regulation.rawValue,
                    base: .labor, rate: 16.0, sortIndex: 20, note: "示例值，按当地社保文件"),
            FeeRate(key: "gf_fund",   name: "住房公积金",       group: FeeKind.regulation.rawValue,
                    base: .labor, rate: 8.0, sortIndex: 21, note: "示例值，按当地缴存比例"),
            FeeRate(key: "gf_injury", name: "工伤保险费",       group: FeeKind.regulation.rawValue,
                    base: .labor, rate: 1.0, sortIndex: 22, note: "示例值"),

            // —— 间接费：企业管理费 ——
            FeeRate(key: "qy_manage",  name: "企业管理费",      group: FeeKind.admin.rawValue,
                    base: .labor, rate: 18.0, sortIndex: 30, note: "示例值"),
            FeeRate(key: "qy_finance", name: "财务费用",        group: FeeKind.admin.rawValue,
                    base: .labor, rate: 1.0, sortIndex: 31, note: "示例值"),

            // —— 利润 ——
            FeeRate(key: "lr", name: "利润", group: FeeKind.profit.rawValue,
                    base: .labor, rate: 7.0, sortIndex: 40, note: "示例值，按招标文件"),

            // —— 税金（以税前造价为基数；简易计税把税率改成 3%）——
            FeeRate(key: "tax", name: "税金（增值税）", group: FeeKind.tax.rawValue,
                    base: .beforeTax, rate: 9.0, sortIndex: 50, note: "一般计税 9%；简易计税改 3%"),

            // —— 工程建设其他费（表五，不计入建安工程费）——
            FeeRate(key: "qt_manage", name: "建设单位管理费", group: FeeKind.other.rawValue,
                    base: .installation, rate: 1.5, sortIndex: 60, note: "示例值，按财政部/主管部门文件分档"),
            FeeRate(key: "qt_design", name: "勘察设计费",     group: FeeKind.other.rawValue,
                    base: .installation, rate: 3.0, sortIndex: 61, note: "示例值，按收费标准分档"),
            FeeRate(key: "qt_superv", name: "工程监理费",     group: FeeKind.other.rawValue,
                    base: .installation, rate: 2.0, sortIndex: 62, note: "示例值，按发改价格文件分档"),

            // —— 预备费 ——
            FeeRate(key: "by_basic", name: "基本预备费", group: FeeKind.contingency.rawValue,
                    base: .projectTotal, rate: 3.0, sortIndex: 70, note: "示例值")
        ]
        return tpl
    }

    /// 简易计税模板（小规模 / 清包工等场景，税率 3%）
    static func simpleTaxFeeTemplate() -> FeeTemplate {
        var tpl = defaultFeeTemplate()
        tpl.name = "简易计税模板（税率 3%·示例费率）"
        tpl.isBuiltin = true
        tpl.note = "简易计税：税金按 3%，规费/企管费率同样需按当地文件核定"
        for i in tpl.rates.indices where tpl.rates[i].key == "tax" {
            tpl.rates[i].rate = 3.0
            tpl.rates[i].note = "简易计税 3%"
        }
        return tpl
    }
}
