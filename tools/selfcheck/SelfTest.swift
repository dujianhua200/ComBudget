import Foundation

// =============================================================================
// 核心链路自检（不弹窗）：建库 → 导入内置 451 → 建工程 → 生成 Excel →
// 校验导入（三类错误）→ 事务入库 → 计算 → 导出 Excel/PDF → .combudget 往返
// =============================================================================

enum SelfTest {
    private(set) static var passed = true
    private static var checks = 0
    private static var failures: [String] = []

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks += 1
        if ok {
            print("  ✓ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        } else {
            passed = false
            failures.append(name)
            print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    static func run() {
        print("ComBudget 自检开始\n")
        let keep = CommandLine.arguments.contains("--keep")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComBudgetSelfTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        if keep { print("产物目录：\(tmp.path)\n") }
        defer { if !keep { try? FileManager.default.removeItem(at: tmp) } }

        do {
            // ---------- 1. 内置 451 定额库 ----------
            print("[1] 内置 451 定额库")
            let db = try AppDatabase(path: tmp.appendingPathComponent("test.db").path)
            let quotaCount = try db.quota.count()
            let resCount = try db.quota.resourceCount()
            check("定额导入（应为全册 3091 条）", quotaCount == 3091, "\(quotaCount) 条")
            check("主材/机械/仪表关联", resCount > 9000, "\(resCount) 条资源")
            print("     \(db.seedStatus)")

            let books = try db.quota.seriesList()
            check("分册结构可用", books.count >= 20, "\(books.count) 个分册")

            if let q = try db.quota.item(code: "TXL1-001") {
                check("抽查 TXL1-001 名称", q.name.contains("施工测量") && q.name.contains("直埋"), q.name)
                check("抽查 TXL1-001 单位", q.unit == "百米", q.unit)
                check("抽查 TXL1-001 技工工日 0.56", abs(q.techWorkday - 0.56) < 1e-9, "\(q.techWorkday)")
                check("抽查 TXL1-001 普工工日 0.14", abs(q.laborWorkday - 0.14) < 1e-9, "\(q.laborWorkday)")
                check("抽查 TXL1-001 仪表 2 项",
                      q.resources.filter { $0.kind == .instrument }.count == 2,
                      "\(q.resources.count) 项资源")
            } else {
                check("抽查 TXL1-001", false, "未找到")
            }

            let hits = try db.quota.search(keyword: "光缆")
            check("模糊检索", hits.count > 50, "命中 \(hits.count) 条")
            let byPhoto = try db.quota.search(series: "TXL3")
            check("按册筛选", byPhoto.count > 100, "TXL3 \(byPhoto.count) 条")

            let tpls = try db.fee.templates()
            check("默认取费模板", tpls.count >= 1, tpls.first?.name ?? "")

            // ---------- 2. 工程与子目 ----------
            print("\n[2] 工程与子目")
            var project = Project.newDraft()
            project.name = "自检工程-架空光缆"
            project.code = "ZT-2026-001"
            project.owner = "某运营商"
            project.contractor = "某工程公司"
            project.compiler = "自检"
            project.feeTemplateID = tpls.first?.id ?? 0
            let created = try db.project.create(project)
            check("工程创建", created.id > 0, "id=\(created.id)")

            guard let quota1 = try db.quota.item(code: "TXL1-001") else { throw ImportError.noRows }
            _ = try db.project.insertItem(projectID: created.id, quota: quota1, quantity: 100,
                                          techPrice: 114, laborPrice: 61)
            let seededItems = try db.project.items(projectID: created.id)
            let first = seededItems[0]
            check("插入即带资源快照", first.resources.count == quota1.resources.count,
                  "\(first.resources.count) 项")
            check("技工工日 = 0.56×100", abs(first.effectiveTechWorkday - 56) < 1e-9,
                  "\(first.effectiveTechWorkday)")
            check("普工工日 = 0.14×100", abs(first.effectiveLaborWorkday - 14) < 1e-9,
                  "\(first.effectiveLaborWorkday)")

            let single = BudgetCalculator.cost(of: first, auxRate: 0.3)
            // 56×114 + 14×61 = 6384 + 854 = 7238
            check("人工费 = 技工×114 + 普工×61", abs(single.labor - 7238) < 0.01, Fmt.money(single.labor))
            try db.project.deleteItem(id: first.id)

            // ---------- 3. Excel 批量导入 ----------
            print("\n[3] Excel 模板批量导入")
            let xlsx = tmp.appendingPathComponent("导入样本.xlsx")
            let rows: [[XlsxCell]] = [
                [.text("定额编号"), .text("工程量"), .text("备注")],
                [.text("TXL1-001"), .number(12), .text("施工测量 12 百米")],
                [.text("TXL2-001"), .number(8.5), .text("挖填缆沟")],
                [.text("TXL1-003"), .number(6), .text("施工测量（管道）")],
                [.text("XXX-999"), .number(3), .text("编号不存在")],
                [.text("TXL1-004"), .number(0), .text("工程量为 0")],
                [.text("TXL1-001"), .number(5), .text("重复行")],
                [.blank, .blank, .blank]
            ]
            try XlsxWriter.write(sheets: [XlsxSheetData(name: "定额清单", rows: rows)], to: xlsx)

            let report = try ExcelImporter.analyze(url: xlsx, config: ImportConfig(), quota: db.quota)
            print("     \(report.summaryText)")
            check("正常行", report.okCount == 3, "\(report.okCount)")
            check("编号不存在拦截", report.unknownCount == 1, "\(report.unknownCount)")
            check("工程量异常拦截", report.badQtyCount == 1, "\(report.badQtyCount)")
            check("重复行标记", report.duplicateCount == 1, "\(report.duplicateCount)")

            let inserted = try ExcelImporter.commit(report: report, projectID: created.id,
                                                    techPrice: 114, laborPrice: 61,
                                                    store: db.project)
            check("可导入行入库", inserted == 4, "\(inserted) 条")

            // 再插一条「主材型」子目（取主材项最多的一条），验证定额→主材关联能进报表
            let matCode = try db.db.query("""
            SELECT qi.code FROM quota_item qi JOIN quota_resource qr ON qr.quota_id = qi.id
            WHERE qr.kind = '主材' GROUP BY qi.code ORDER BY COUNT(*) DESC LIMIT 1;
            """) { $0.text(0) }.first
            if let matCode, let matQuota = try db.quota.item(code: matCode) {
                _ = try db.project.insertItem(projectID: created.id, quota: matQuota, quantity: 10,
                                              techPrice: 114, laborPrice: 61)
                check("主材型子目可插入", !matQuota.resources.isEmpty,
                      "\(matCode) 主材 \(matQuota.resources.filter { $0.kind == .mainMaterial }.count) 项")
            }

            // ---------- 4. 计算 ----------
            print("\n[4] 自动计算与取费")
            let items = try db.project.items(projectID: created.id)
            let tpl = tpls.first
            let summary = BudgetCalculator.summarize(items: items, template: tpl)
            // TXL1-001×12: 技 6.72/普 1.68；TXL2-001×8.5: 普 39.38×8.5=334.73；
            // TXL1-003×6；TXL1-001×5
            check("工日合计 > 0", summary.itemCost.workdays > 0,
                  String(format: "技工 %.2f + 普工 %.2f", summary.itemCost.techWorkdays, summary.itemCost.laborWorkdays))
            check("人工费 > 0", summary.itemCost.labor > 0, Fmt.money(summary.itemCost.labor))
            check("辅助材料费按 0.3% 计提",
                  abs(summary.itemCost.auxMaterial - summary.itemCost.labor * 0.003) < 0.01,
                  Fmt.money(summary.itemCost.auxMaterial))
            check("措施费/间接费/利润/税金均已计算",
                  summary.measures > 0 && summary.indirect > 0 && summary.profit > 0 && summary.tax > 0,
                  "措施 \(Fmt.money(summary.measures)) 间接 \(Fmt.money(summary.indirect)) 利润 \(Fmt.money(summary.profit)) 税金 \(Fmt.money(summary.tax))")
            check("建安费 = 直接费+取费", abs(summary.total - (summary.itemCost.direct + summary.measures + summary.indirect + summary.profit + summary.tax)) < 0.01,
                  Fmt.money(summary.total))

            // 改工程量即时重算
            var changed = items[0]
            changed.quantity = 200
            let reCost = BudgetCalculator.cost(of: changed, auxRate: 0.3)
            check("改工程量即刻重算", abs(reCost.techWorkdays - changed.techWorkday * 200) < 1e-9,
                  "\(reCost.techWorkdays) 工日")

            // ---------- 5. 导出 ----------
            print("\n[5] 报表导出")
            let costs = BudgetCalculator.rowCosts(items: items, template: tpl)
            let tables = [
                ReportBuilder.summaryTable(project: created, template: tpl, summary: summary),
                ReportBuilder.detailTable(project: created, items: items, costs: costs, summary: summary),
                ReportBuilder.materialTable(project: created, items: items),
                ReportBuilder.machineTable(project: created, items: items)
            ]
            let excelOut = tmp.appendingPathComponent("预算表.xlsx")
            try ExcelExporter.export(tables: tables, to: excelOut)
            let back = try XlsxReader.read(url: excelOut)
            check("Excel 导出并可回读", back.count == 4, "\(back.count) 个工作表")

            let pdfOut = tmp.appendingPathComponent("预算表.pdf")
            try PDFExporter.export(tables: tables, to: pdfOut)
            let size = (try FileManager.default.attributesOfItem(atPath: pdfOut.path)[.size] as? Int) ?? 0
            check("PDF 导出", size > 3000, "\(size) 字节")

            let materialRows = ReportBuilder.materialTable(project: created, items: items).rows.count
            check("主材表有内容（定额关联生效）", materialRows > 0, "\(materialRows) 行")

            // ---------- 6. 工程包 ----------
            print("\n[6] .combudget 工程包")
            let bundleURL = tmp.appendingPathComponent("工程包.\(ProjectBundle.fileExtension)")
            try ProjectBundle.export(db: db.db, projectID: created.id, to: bundleURL)
            check("工程包导出", FileManager.default.fileExists(atPath: bundleURL.path))

            let db2 = try AppDatabase(path: tmp.appendingPathComponent("other.db").path, importSeed: false)
            let ids = try ProjectBundle.importBundle(db: db2.db, from: bundleURL)
            check("工程包导入", ids.count == 1, "\(ids.count) 个工程")
            if let pid = ids.first {
                let importedItems = try db2.project.items(projectID: pid)
                check("导入后子目完整", importedItems.count == items.count,
                      "\(importedItems.count)/\(items.count)")
                check("工程包自带定额库", try db2.quota.count() == quotaCount,
                      "\(try db2.quota.count()) 条")
            }
        } catch {
            passed = false
            failures.append("异常：\(error.localizedDescription)")
            print("  ✗ 异常：\(error.localizedDescription)")
        }

        print("\n自检结束：\(checks - failures.count)/\(checks) 项通过")
        if !failures.isEmpty {
            print("失败项：\(failures.joined(separator: "、"))")
        } else {
            print("全部通过 ✅")
        }
    }
}
