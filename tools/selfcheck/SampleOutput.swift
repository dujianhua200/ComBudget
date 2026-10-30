import Foundation

// =============================================================================
// 生成文档用的示例输出（docs/示例输出-预算表.xlsx / .pdf）
//
//   combudget-cli --make-samples <输出目录>
//
// 为什么要有这条命令：内置 451 手册不含单价，为了让示例报表不「全 0」，
// 这里按资源种类给一组**明确的假设单价**（见 assumedPrice），收甲方料的时候
// 照着自己当地的价格册套一次就行。
// =============================================================================

enum SampleOutput {

    /// 假设单价（示例输出专用）：主材按关键字估个数，机械/仪表按台班估个数
    private static let mainPrices: [(String, Double)] = [
        ("光缆", 3200), ("接头盒", 180), ("电杆", 460), ("钢绞线", 12.5),
        ("铁件", 35), ("螺栓", 2.5), ("PVC管", 9.8), ("塑料管", 9.8),
        ("防腐", 26), ("标石", 42), ("水泥", 0.62), ("砂", 130), ("碎石", 120)
    ]

    private static func assumedPrice(kind: ResourceKind, name: String) -> Double {
        switch kind {
        case .mainMaterial:
            for (key, price) in mainPrices where name.contains(key) { return price }
            return 28
        case .machine:      return 860
        case .instrument:   return 240
        case .equipment:    return 0
        }
    }

    static func run(outdir: String) throws {
        let fm = FileManager.default
        let tmpDB = NSTemporaryDirectory() + "cb-samples-\(UUID().uuidString).db"
        defer { try? fm.removeItem(atPath: tmpDB) }
        let adb = try AppDatabase(path: tmpDB)
        print(adb.seedStatus)

        var p = Project.newDraft()
        p.name = "示例工程 · 架空光缆线路"
        p.code = "DEMO-2026-001"
        p.category = ProjectCategory.line.rawValue
        p.specialty = Specialty.wired.rawValue
        p.scale = "架空光缆 12km"
        p.owner = "示例建设单位"
        p.contractor = "示例施工单位"
        p.compiler = "示例"
        p.reviewer = "—"
        p.feeTemplateID = try adb.fee.templates().first?.id ?? 0
        let project = try adb.project.create(p)

        // 固定几条常见线路子目，再动态补一条「机械最多」一条「仪表最多」，
        // 这样表三乙 / 表三丙不会是空表
        var codes: [(String, Double)] = [("TXL1-001", 120), ("TXL3-101", 60), ("TXL1-003", 12),
                                         ("TXL2-001", 45), ("TXL1-005", 8), ("TXL3-102", 30)]
        for kind in ["机械", "仪表"] {
            let found = try adb.db.query("""
            SELECT qi.code FROM quota_item qi JOIN quota_resource qr ON qr.quota_id = qi.id
            WHERE qr.kind = ? GROUP BY qi.code ORDER BY COUNT(*) DESC LIMIT 1;
            """, [kind]) { $0.text(0) }.first
            if let c = found, !codes.contains(where: { $0.0 == c }) { codes.append((c, 20)) }
        }
        for (code, qty) in codes {
            guard let q = try adb.quota.item(code: code) else { continue }
            let item = try adb.project.insertItem(projectID: project.id, quota: q, quantity: qty,
                                                  techPrice: 114, laborPrice: 61)
            var res = try adb.project.resources(itemID: item.id)
            for i in res.indices where res[i].unitPrice == 0 {
                res[i].unitPrice = assumedPrice(kind: res[i].kind, name: res[i].name)
            }
            try adb.project.replaceResources(itemID: item.id, resources: res)
        }

        let items = try adb.project.items(projectID: project.id)
        let tpl = try adb.fee.templates().first
        let summary = BudgetCalculator.summarize(items: items, template: tpl)
        let costs = BudgetCalculator.rowCosts(items: items, template: tpl)
        let tables = [
            ReportBuilder.summaryTable(project: project, template: tpl, summary: summary),
            ReportBuilder.installationTable(project: project, template: tpl, summary: summary),
            ReportBuilder.detailTable(project: project, items: items, costs: costs, summary: summary),
            ReportBuilder.machineTable(project: project, items: items, kind: .machine),
            ReportBuilder.machineTable(project: project, items: items, kind: .instrument),
            ReportBuilder.materialTable(project: project, items: items),
            ReportBuilder.otherFeeTable(project: project, summary: summary)
        ]

        try fm.createDirectory(atPath: outdir, withIntermediateDirectories: true)
        let dir = URL(fileURLWithPath: outdir, isDirectory: true)
        let xlsx = dir.appendingPathComponent("示例输出-预算表.xlsx")
        let pdf = dir.appendingPathComponent("示例输出-预算表.pdf")
        try ExcelExporter.export(tables: tables, to: xlsx)
        try PDFExporter.export(tables: tables, to: pdf)

        print("示例工程：\(codes.count) 条子目，建安 \(Fmt.money(summary.total))，"
              + "总造价 \(Fmt.money(summary.grandTotal))")
        print("已写出 \(xlsx.path)")
        print("已写出 \(pdf.path)")
        print("（主材/机械/仪表单价为假设值，仅用于演示表格样式）")
    }
}
