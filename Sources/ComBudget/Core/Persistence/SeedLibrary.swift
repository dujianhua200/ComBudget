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

    /// 内置取费模板（费率示例值，需按 451 号文/招标文件核定）
    static func defaultFeeTemplate() -> FeeTemplate {
        var tpl = FeeTemplate(name: "451 默认取费模板（示例费率）", isBuiltin: true,
                              auxMaterialRate: 0.3,
                              note: "示例费率：请按 451 号文/招标文件核定后使用")
        tpl.rates = [
            FeeRate(key: "cs_safety", name: "安全文明施工费", group: "措施费", base: .labor, rate: 3.0, sortIndex: 0, note: "示例值"),
            FeeRate(key: "cs_temp",   name: "临时设施费",     group: "措施费", base: .labor, rate: 1.5, sortIndex: 1, note: "示例值"),
            FeeRate(key: "ij_manage", name: "企业管理费",     group: "间接费", base: .labor, rate: 25.0, sortIndex: 2, note: "示例值"),
            FeeRate(key: "ij_guifei", name: "规费",           group: "间接费", base: .labor, rate: 12.0, sortIndex: 3, note: "示例值"),
            FeeRate(key: "lr",        name: "利润",           group: "利润",   base: .labor, rate: 8.0, sortIndex: 4, note: "示例值"),
            FeeRate(key: "tax",       name: "税金（增值税）", group: "税金",   base: .directPlus, rate: 9.0, sortIndex: 5, note: "一般计税法示例值")
        ]
        return tpl
    }
}
