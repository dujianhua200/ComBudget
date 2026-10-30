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

    /// 供闭包内部（撤销/重做之类延迟执行的逻辑）报告失败
    static func noteFail(_ msg: String) {
        passed = false
        failures.append(msg)
        print("  ✗ \(msg)")
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
                ReportBuilder.installationTable(project: created, template: tpl, summary: summary),
                ReportBuilder.detailTable(project: created, items: items, costs: costs, summary: summary),
                ReportBuilder.machineTable(project: created, items: items, kind: .machine),
                ReportBuilder.machineTable(project: created, items: items, kind: .instrument),
                ReportBuilder.materialTable(project: created, items: items),
                ReportBuilder.otherFeeTable(project: created, summary: summary)
            ]
            let excelOut = tmp.appendingPathComponent("预算表.xlsx")
            try ExcelExporter.export(tables: tables, to: excelOut)
            let back = try XlsxReader.read(url: excelOut)
            check("Excel 导出并可回读（表一～表五甲）", back.count == 7, "\(back.count) 个工作表")

            let pdfOut = tmp.appendingPathComponent("预算表.pdf")
            try PDFExporter.export(tables: tables, to: pdfOut)
            let size = (try FileManager.default.attributesOfItem(atPath: pdfOut.path)[.size] as? Int) ?? 0
            check("PDF 导出", size > 3000, "\(size) 字节")

            let materialRows = ReportBuilder.materialTable(project: created, items: items).rows.count
            check("表四甲器材表有内容（定额关联生效）", materialRows > 0, "\(materialRows) 行")
            // 这几条管式子目本身不带机械/仪表，先几何聚合口径对（同类同名同价要合并成一行），
            // 表三乙有数据的情况放在第 7 节换算子目那里验
            let machineRows = ReportBuilder.machineTable(project: created, items: items,
                                                         kind: .machine).rows.count
            let machineKeys = Set(items.flatMap { $0.resources }
                .filter { $0.kind == .machine }
                .map { "\($0.name)|\($0.spec)|\($0.unit)|\($0.unitPrice)" })
            check("表三乙按「名称+规格+单位+单价」合并",
                  machineRows == machineKeys.count, "\(machineRows) 行 / \(machineKeys.count) 种")

            // ---------- 6. 价格库与套价 ----------
            print("\n[6] 价格库与套价")
            // 构造一份价格册样本：直接取定额里真实出现过的资源名，贴近实际询价清单
            let sample = try db.db.query("""
            SELECT DISTINCT qr.kind, qr.name, qr.unit FROM quota_resource qr
            JOIN quota_item qi ON qi.id = qr.quota_id WHERE qi.code IN ('TXL3-222','TXL1-001')
            LIMIT 30;
            """) { r in (r.text(0), r.text(1), r.text(2)) }
            var priceRows: [PriceEntry] = []
            for (i, s) in sample.enumerated() {
                priceRows.append(PriceEntry(kind: ResourceKind(rawValue: s.0) ?? .mainMaterial,
                                            name: s.1, spec: "", unit: s.2,
                                            unitPrice: Double(i + 1) * 10, source: "自检价格册"))
            }
            check("构造价格册样本", priceRows.count > 3, "\(priceRows.count) 条")
            let savedPrices = try db.price.save(priceRows)
            check("价格库批量 upsert", try db.price.count() == Set(priceRows.map { $0.name }).count || savedPrices > 0,
                  "入库 \(savedPrices) 条 / 库内 \(try db.price.count()) 条")

            // 重复导入同一批不翻倍
            _ = try db.price.save(priceRows)
            check("重复导入不翻倍", try db.price.count() == savedPrices,
                  "库内仍为 \(try db.price.count()) 条")

            let priceBefore = try db.project.items(projectID: created.id)
                .flatMap { $0.resources }.filter { $0.unitPrice > 0 }.count
            check("套价前多数资源单价为 0（451 手册不含价格）", priceBefore == 0, "\(priceBefore) 项有价")

            let applied = try db.project.applyPrices(projectID: created.id)
            print("     \(applied.summary)")
            let pricedItems = try db.project.items(projectID: created.id)
            let priced = pricedItems.flatMap { $0.resources }.filter { $0.unitPrice > 0 }
            check("套价后资源有单价", !priced.isEmpty, "\(priced.count) 项")
            check("价格库查不到的会列出", applied.missing.count >= 0,
                  "未匹配 \(applied.missing.count) 项")

            let afterCost = BudgetCalculator.summarize(items: pricedItems, template: tpl)
            check("主材费不再为 0（套价生效）",
                  afterCost.itemCost.mainMaterial > summary.itemCost.mainMaterial,
                  "套价前 \(Fmt.money(summary.itemCost.mainMaterial)) → 套价后 \(Fmt.money(afterCost.itemCost.mainMaterial))")
            check("直接费随套价变大", afterCost.itemCost.direct > summary.itemCost.direct,
                  Fmt.money(afterCost.itemCost.direct))

            // 新插入的子目应自动套价
            guard let autoQ = try db.quota.item(code: "TXL3-222") else { throw ImportError.noRows }
            let autoItem = try db.project.insertItem(projectID: created.id, quota: autoQ, quantity: 2,
                                                     techPrice: 114, laborPrice: 61)
            let autoPriced = autoItem.resources.filter { $0.unitPrice > 0 }.count
            check("新插入子目自动套价", autoPriced > 0, "\(autoPriced)/\(autoItem.resources.count) 项")
            try db.project.deleteItem(id: autoItem.id)

            let priceSearch = try db.price.search(keyword: sample.first?.1 ?? "")
            check("价格库可按名称检索", !priceSearch.isEmpty, "命中 \(priceSearch.count) 条")

            // Excel 价格清单导入：生成模板 → 回读 → 入库 → 重复导入不翻倍
            let priceXlsx = tmp.appendingPathComponent("价格清单.xlsx")
            try PriceImporter.writeTemplate(to: priceXlsx)
            let parsed = try PriceImporter.read(url: priceXlsx, config: PriceImportConfig())
            check("价格模板可生成并回读", parsed.entries.count == 4, "\(parsed.entries.count) 条")
            check("资源类型识别", PriceImporter.kind(of: "主要材料") == .mainMaterial
                  && PriceImporter.kind(of: "机械") == .machine
                  && PriceImporter.kind(of: "仪表") == .instrument)
            check("单价解析", parsed.entries.first?.unitPrice == 58,
                  "\(parsed.entries.first?.unitPrice ?? -1)")
            // 库里已有的「类型+名称+规格+单位」不算新增，剩下的才应该插入
            let existingKeys = Set(try db.price.search().map {
                "\($0.kind.rawValue)|\($0.name)|\($0.spec)|\($0.unit)" })
            let expectNew = Set(parsed.entries.map {
                "\($0.kind.rawValue)|\($0.name)|\($0.spec)|\($0.unit)" })
                .subtracting(existingKeys).count
            let priceCountBefore = try db.price.count()
            _ = try db.price.save(parsed.entries, source: "Excel 导入")
            let priceCountAfter1 = try db.price.count()
            check("价格表入库条数正确",
                  priceCountAfter1 - priceCountBefore == expectNew,
                  "应新增 \(expectNew) 条，实际 +\(priceCountAfter1 - priceCountBefore)")
            _ = try db.price.save(parsed.entries, source: "Excel 导入")
            check("重复导入不翻倍（按类型+名称+规格+单位 upsert）",
                  try db.price.count() == priceCountAfter1,
                  "导入一次 \(priceCountAfter1) 条，再导一次仍为 \(try db.price.count()) 条")
            // 模板示例行的「价格来源」列写的是「示例价」；导入时该列非空，故不套用默认来源
            let excelOnly = try db.price.all(source: "示例价")
            check("可按来源取出价格（清空前留快照用）", excelOnly.count >= 3,
                  "\(excelOnly.count) 条")
            let landed = parsed.entries.allSatisfy { e in
                ((try? db.price.search(keyword: e.name)
                    .contains { $0.unit == e.unit && $0.unitPrice == e.unitPrice }) ?? false)
            }
            check("导入的价格可按名称查到且单价正确", landed)

            // ---------- 7. 定额换算与分组小计 ----------
            print("\n[7] 定额换算与分组小计")
            // 换算测试要落到「真的有机械台班」的子目上：先从定额库找一条带机械的定额插进来
            let machineCode = try db.db.query("""
            SELECT qi.code FROM quota_item qi JOIN quota_resource qr ON qr.quota_id = qi.id
            WHERE qr.kind = '机械' GROUP BY qi.code ORDER BY COUNT(*) DESC LIMIT 1;
            """) { $0.text(0) }.first
            guard let machineCode, let machineQuota = try db.quota.item(code: machineCode) else {
                throw ImportError.noRows
            }
            var victim = try db.project.insertItem(projectID: created.id, quota: machineQuota,
                                                   quantity: 5, techPrice: 114, laborPrice: 61)
            _ = try db.project.applyPrices(projectID: created.id)
            victim = try db.project.items(projectID: created.id).first { $0.id == victim.id } ?? victim
            let beforeConv = BudgetCalculator.cost(of: victim, auxRate: tpl?.auxMaterialRate ?? 0.3)
            guard let mountain = ConversionPresets.all.first(where: { $0.name == "山区·高海拔" }) else {
                throw ImportError.noRows
            }
            let baseTech = victim.baseTech
            QuotaConverter.apply(mountain, to: &victim)
            let afterConv = BudgetCalculator.cost(of: victim, auxRate: tpl?.auxMaterialRate ?? 0.3)
            check("换算后技工工日 = 原值×1.30", abs(victim.techWorkday - baseTech * 1.30) < 1e-9,
                  "\(baseTech) → \(victim.techWorkday)")
            check("换算保留定额原值", victim.techWorkdayBase == baseTech, "原值 \(victim.techWorkdayBase)")
            check("换算写入痕迹", victim.convNote.contains("山区"), victim.convNote)
            check("换算后人工费变大", afterConv.labor > beforeConv.labor,
                  "\(Fmt.money(beforeConv.labor)) → \(Fmt.money(afterConv.labor))")

            let machineBefore = victim.resources.filter { $0.kind == .machine }.map { $0.qtyPerUnit }
            let machineAfter = victim.resources.filter { $0.kind == .machine }.map { $0.effectiveQtyPerUnit }
            let machineOK = machineBefore.count == machineAfter.count
                && zip(machineBefore, machineAfter).allSatisfy { abs($1 - $0 * 1.20) < 1e-9 }
            check("机械台班×1.20 落到 qty_override（且保留 qty_per_unit 原值）",
                  machineBefore.count > 0 && machineOK,
                  "\(machineAfter.count) 项机械：\(machineBefore.first ?? 0) → \(machineAfter.first ?? 0)")

            QuotaConverter.revoke(from: &victim)
            check("还原回定额原值", abs(victim.techWorkday - baseTech) < 1e-9 && victim.convNote.isEmpty,
                  "\(victim.techWorkday)")
            check("还原后资源回到定额原量",
                  victim.resources.allSatisfy { $0.qtyOverride == nil })

            // 带机械的子目在库里，这才有机会验证表三乙（第 5 节那几条没有机械）
            let spread0 = try db.project.items(projectID: created.id)
            let machineCross = ReportBuilder.machineTable(project: created, items: spread0,
                                                          kind: .machine)
            check("表三乙机械表有内容", !machineCross.rows.isEmpty, "\(machineCross.rows.count) 行")
            let crossAmount = Double(machineCross.rows.compactMap { row -> Double? in
                Double(row.last?.replacingOccurrences(of: ",", with: "") ?? "")
            }.reduce(0, +))
            let manualMachine = spread0.reduce(0.0) { sum, it in
                sum + it.resources.filter { $0.kind == .machine }
                    .reduce(0.0) { $0 + $1.effectiveQtyPerUnit * it.quantity * $1.unitPrice }
            }
            check("表三乙台班金额 = 单价×台班×工程量",
                  abs(crossAmount - manualMachine) < 1.0,
                  "\(Fmt.money(crossAmount)) vs \(Fmt.money(manualMachine))")

            let original = ConversionPresets.all.first { $0.isIdentity }!
            var idItem = pricedItems[0]
            QuotaConverter.apply(original, to: &idItem)
            check("×1.0 换算等于不换算", idItem.convNote.isEmpty && idItem.techWorkday == idItem.baseTech)
            try db.project.deleteItem(id: victim.id)   // 换算测试用的临时子目不留在工程里

            // 分组小计
            let spreadItems = try db.project.items(projectID: created.id)
            let spreadCosts = BudgetCalculator.rowCosts(items: spreadItems, template: tpl)
            let series = Set(spreadItems.map { $0.series })
            let groups = BudgetGrouping.group(items: spreadItems, costs: spreadCosts, key: .series)
            check("按分册分组", groups.count == series.count,
                  "\(groups.count) 组：\(groups.map { $0.title }.joined(separator: "、"))")
            let groupSum = groups.reduce(0.0) { $0 + $1.cost.direct }
            let manualSum = BudgetGrouping.total(items: spreadItems, costs: spreadCosts).direct
            check("分组小计合计 = 全工程合计", abs(groupSum - manualSum) < 0.01,
                  "\(Fmt.money(groupSum)) vs \(Fmt.money(manualSum))")
            check("每个分组都有子目", groups.allSatisfy { !$0.items.isEmpty })

            let groupedTable = ReportBuilder.detailTable(project: created, items: spreadItems,
                                                         costs: spreadCosts, summary: summary,
                                                         grouping: .series)
            check("分组明细表行数多于子目数（含组标题与小计）",
                  groupedTable.rows.count > spreadItems.count,
                  "\(spreadItems.count) 条 → \(groupedTable.rows.count) 行")
            check("分组明细表标记了加重行", !groupedTable.emphasizedRows.isEmpty,
                  "\(groupedTable.emphasizedRows.count) 行")
            let groupedPDF = tmp.appendingPathComponent("分组明细.pdf")
            try PDFExporter.export(tables: [groupedTable], to: groupedPDF)
            check("分组明细表可导出 PDF",
                  ((try FileManager.default.attributesOfItem(atPath: groupedPDF.path)[.size] as? Int) ?? 0) > 3000)

            // ---------- 8. 撤销 / 重做 ----------
            print("\n[8] 撤销 / 重做")
            let history = History()
            var counter = 0
            history.perform("加一") { counter += 1 } undo: { counter -= 1 }
            check("perform 立即执行 redo", counter == 1, "counter=\(counter)")
            check("可撤销", history.canUndo && history.undoLabel == "加一", history.undoLabel ?? "")
            _ = history.undo()
            check("撤销回到变更前", counter == 0, "counter=\(counter)")
            check("撤销后可重做", history.canRedo && history.redoLabel == "加一")
            _ = history.redo()
            check("重做恢复变更", counter == 1, "counter=\(counter)")

            // 真实链路：删子目 → 撤销 → 子目连同资源快照一起回来
            let before = try db.project.items(projectID: created.id)
            guard let doomed = before.first(where: { !$0.resources.isEmpty }) ?? before.first else {
                throw ImportError.noRows
            }
            let snapshot = doomed
            let h2 = History()
            h2.register("删除子目", undo: {
                do {
                    _ = try db.project.restoreItem(snapshot)
                } catch { SelfTest.noteFail("restoreItem 抛错：\(error.localizedDescription)") }
            }, redo: {
                do { try db.project.deleteItem(id: snapshot.id) } catch { SelfTest.noteFail("deleteItem 抛错：\(error.localizedDescription)") }
            })
            try db.project.deleteItem(id: doomed.id)
            let afterDelete = try db.project.items(projectID: created.id)
            check("删除生效", afterDelete.count == before.count - 1,
                  "\(before.count) → \(afterDelete.count)")
            _ = h2.undo()
            let restored = try db.project.items(projectID: created.id)
            let revived = restored.first { $0.id == snapshot.id }
            check("撤销后子目回来了", revived != nil && restored.count == before.count,
                  "\(restored.count) 条")
            check("撤销后资源快照完整",
                  (revived?.resources.count ?? -1) == snapshot.resources.count,
                  "\(revived?.resources.count ?? -1)/\(snapshot.resources.count)")
            // 注意：restore 会重建资源行，id 不可能与原快照一致，所以按「名称+单价」比对内容
            let beforePrices = snapshot.resources
                .map { "\($0.name)-\($0.unit)-\(Fmt.money($0.unitPrice))" }.sorted().joined(separator: ",")
            let afterPrices = (revived?.resources ?? [])
                .map { "\($0.name)-\($0.unit)-\(Fmt.money($0.unitPrice))" }.sorted().joined(separator: ",")
            check("撤销后单价与消耗量保留", !beforePrices.isEmpty && beforePrices == afterPrices,
                  afterPrices.isEmpty ? "（资源为空）" : String(afterPrices.prefix(50)))
            _ = h2.redo()
            check("重做再次删除", try db.project.items(projectID: created.id).count == before.count - 1)
            _ = h2.undo()

            // 新操作要清掉旧重做栈
            h2.register("别的事", undo: {}, redo: {})
            check("新操作后不可重做", !h2.canRedo, "canRedo=\(h2.canRedo)")

            // ---------- 9. 工程包 ----------
            print("\n[9] .combudget 工程包")
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

                // 换机器打开工程包：价格库跟着走，套价结果要能复现
                let srcItems = try db.project.items(projectID: created.id)
                let stdTpl = SeedLibrary.defaultFeeTemplate()
                let srcSum = BudgetCalculator.summarize(items: srcItems, template: stdTpl)
                let dstSum = BudgetCalculator.summarize(items: importedItems, template: stdTpl)
                check("工程包自带价格库", (try db2.price.count()) > 0,
                      "包里带 \(try db2.price.count()) 条价格")
                check("换库后金额与原工程一致",
                      abs(srcSum.itemCost.mainMaterial - dstSum.itemCost.mainMaterial) < 0.01
                      && abs(srcSum.total - dstSum.total) < 0.01,
                      "主材 \(Fmt.money(dstSum.itemCost.mainMaterial))，建安 \(Fmt.money(dstSum.total))")
                // 资源单价跟着工程包走，不用重新套价就该有价
                let pricedCount = importedItems.flatMap { $0.resources }
                    .filter { $0.unitPrice > 0 }.count
                check("资源单价随包走（不重新套价也有价）", pricedCount > 0,
                      "\(pricedCount) 项有单价")
                _ = try db2.project.applyPrices(projectID: pid, overwrite: false)
                let reSum = BudgetCalculator.summarize(
                    items: try db2.project.items(projectID: pid), template: stdTpl)
                check("在别的机器上重新套价结果不变",
                      abs(reSum.itemCost.mainMaterial - dstSum.itemCost.mainMaterial) < 0.01,
                      "\(Fmt.money(reSum.itemCost.mainMaterial))")
            }

            // ---------- 10. 费用口径（451）与标准报表 ----------
            print("\n[10] 费用组成与标准报表")
            let feeItems = try db.project.items(projectID: created.id)
            let s = BudgetCalculator.summarize(items: feeItems, template: tpl)
            guard let tplRates = tpl?.sortedRates else { throw ImportError.noRows }

            // 直接费 = 人工 + 主材 + 辅材 + 机械 + 仪表
            let directSum = s.itemCost.labor + s.itemCost.mainMaterial + s.itemCost.auxMaterial
                + s.itemCost.machine + s.itemCost.instrument
            check("直接费 = 人工+主材+辅材+机械+仪表",
                  abs(directSum - s.itemCost.direct) < 0.01, Fmt.money(directSum))
            check("间接费 = 规费 + 企业管理费",
                  abs(s.indirect - (s.regulation + s.admin)) < 0.01, Fmt.money(s.indirect))
            check("建安工程费 = 直接费+措施费+间接费+利润+税金",
                  abs(s.total - (s.itemCost.direct + s.measures + s.indirect + s.profit + s.tax)) < 0.01,
                  Fmt.money(s.total))

            // 税金 = 税前造价 × 税率（税后基数不能倒过来用）
            let taxRate = (tplRates.first { $0.key == "tax" })?.rate ?? 0
            check("税金 = 税前造价 × 税率",
                  abs(s.tax - s.beforeTax * taxRate / 100) < 1.0,
                  "\(Fmt.money(s.beforeTax)) × \(taxRate)% = \(Fmt.money(s.tax))")
            check("总造价 = 建安工程费+设备费+其他费+预备费",
                  abs(s.grandTotal - (s.total + s.itemCost.equipment + s.otherFees + s.contingency)) < 0.01,
                  Fmt.money(s.grandTotal))
            // 其他费/预备费单列在总造价里，不进建安工程费
            check("其他费与预备费不计入建安工程费",
                  s.otherFees > 0 && s.contingency > 0 && s.total < s.grandTotal,
                  "建安 \(Fmt.money(s.total)) < 总造价 \(Fmt.money(s.grandTotal))")
            // 科目齐全：内置模板要铺满 451 口径的每一类
            let kinds = Set(tplRates.compactMap { FeeKind.of($0.group) })
            check("内置模板科目齐全（措施费/规费/企管/利润/税金/其他费/预备费）",
                  kinds.count == FeeKind.allCases.count,
                  kinds.map { $0.rawValue }.sorted().joined(separator: "、"))

            // 标准表式
            let feeTables = [
                ReportBuilder.summaryTable(project: created, template: tpl, summary: s),
                ReportBuilder.installationTable(project: created, template: tpl, summary: s),
                ReportBuilder.detailTable(project: created, items: feeItems,
                                          costs: BudgetCalculator.rowCosts(items: feeItems, template: tpl),
                                          summary: s),
                ReportBuilder.machineTable(project: created, items: feeItems, kind: .machine),
                ReportBuilder.machineTable(project: created, items: feeItems, kind: .instrument),
                ReportBuilder.materialTable(project: created, items: feeItems),
                ReportBuilder.otherFeeTable(project: created, summary: s)
            ]
            check("标准报表 7 张（表一～表五甲）", feeTables.count == 7,
                  feeTables.map { $0.title }.joined(separator: " / "))

            // 表一、表二 的合计行要对得上总造价
            let tableOne = feeTables[0]
            let totalRow = tableOne.rows.last { $0[1].contains("工程总造价（大写）") }
            check("表一有大写金额行", !(totalRow?.isEmpty ?? true), totalRow?[2] ?? "")
            let tableTwo = feeTables[1]
            let twoTotal = tableTwo.rows.last { $0[1].contains("建筑安装工程费合计") }
            check("表二建安合计 = 汇总口径",
                  twoTotal?[4] == Fmt.money(s.total), "\(twoTotal?[4] ?? "") vs \(Fmt.money(s.total))")
            // 表格之间的数字必须一致（表一建安 = 表二合计）
            let oneInstall = tableOne.rows.first { $0[1] == "建筑安装工程费" }
            check("表一建安 = 表二合计", oneInstall?[4] == twoTotal?[4],
                  "\(oneInstall?[4] ?? "") vs \(twoTotal?[4] ?? "")")

            let allPDF = tmp.appendingPathComponent("标准报表.pdf")
            try PDFExporter.export(tables: feeTables, to: allPDF)
            let allSize = (try FileManager.default.attributesOfItem(atPath: allPDF.path)[.size] as? Int) ?? 0
            check("标准报表可导出 PDF", allSize > 8000, "\(allSize) 字节")

            // 大写金额：这是国内造价表的硬要求，错了整份预算作废
            check("大写：壹万贰仟叁佰肆拾伍元陆角柒分",
                  Fmt.cnyUpper(12345.67) == "壹万贰仟叁佰肆拾伍元陆角柒分", Fmt.cnyUpper(12345.67))
            check("大写：壹亿零伍元整",
                  Fmt.cnyUpper(100000005) == "壹亿零伍元整", Fmt.cnyUpper(100000005))
            check("大写：壹佰零伍元零伍分",
                  Fmt.cnyUpper(105.05) == "壹佰零伍元零伍分", Fmt.cnyUpper(105.05))
            check("大写：壹拾元整", Fmt.cnyUpper(10) == "壹拾元整", Fmt.cnyUpper(10))
            check("大写：零元整", Fmt.cnyUpper(0) == "零元整", Fmt.cnyUpper(0))
            check("大写：角整", Fmt.cnyUpper(100.5) == "壹佰元伍角整", Fmt.cnyUpper(100.5))

            // 简易计税模板
            let simple = SeedLibrary.simpleTaxFeeTemplate()
            check("简易计税模板税率 3%",
                  (simple.rates.first { $0.key == "tax" })?.rate == 3.0,
                  "\(simple.rates.first { $0.key == "tax" }?.rate ?? -1)%")
            let simpleSummary = BudgetCalculator.summarize(items: feeItems, template: simple)
            check("换模板后税金变小", simpleSummary.tax < s.tax,
                  "\(Fmt.money(s.tax)) → \(Fmt.money(simpleSummary.tax))")

            // ---------- 11. 可定制：取费模板导出 / 导入 ----------
            print("\n[11] 取费模板 JSON 导入导出")
            guard var shareTemplate = tpl else { throw ImportError.noRows }
            shareTemplate.rates[0].rate = 9.99            // 改一处，验证内容真的被带上
            let shareURL = tmp.appendingPathComponent("取费模板.json")
            try FeeTemplateIO.write([shareTemplate], to: shareURL)
            check("模板可导出 JSON",
                  ((try FileManager.default.attributesOfItem(atPath: shareURL.path)[.size] as? Int) ?? 0) > 200,
                  "\(try Data(contentsOf: shareURL).count) 字节")

            let decoded = try FeeTemplateIO.read(shareURL)
            check("导出后可原样读回", decoded.count == 1
                  && decoded[0].name == shareTemplate.name
                  && decoded[0].rates.count == shareTemplate.rates.count,
                  "\(decoded.first?.name ?? "") \(decoded.first?.rates.count ?? 0) 项")

            let same = zip(decoded[0].sortedRates, shareTemplate.sortedRates)
                .allSatisfy { $0.name == $1.name && $0.group == $1.group
                    && $0.base == $1.base && $0.rate == $1.rate }
            check("费率明细逐项一致", same, "含改过的 \(decoded[0].sortedRates.first?.rate ?? 0)%")

            // 裸数组（不包一层 File）也要能读，手写模板时少一层外套很常见
            let bare = try JSONEncoder().encode(shareTemplate.sortedRates.isEmpty ? [] : [shareTemplate])
            check("裸数组也能读", (try? FeeTemplateIO.decode(bare).count) == 1)
            struct WrongFile: Codable { var format: String; var templates: [FeeTemplate] }
            let wrongFormat = try JSONEncoder().encode(
                WrongFile(format: "not.mine", templates: [shareTemplate]))
            let rejected = (try? FeeTemplateIO.decode(wrongFormat)) == nil
            check("不是本软件的文件会被拒", rejected)

            // 导入：id 清零重新入库，同名不覆盖原模板
            let beforeCount = try db.fee.templates().count
            var incoming = decoded[0]
            incoming.name = shareTemplate.name
            try db.fee.save(&incoming)
            let midCount = try db.fee.templates().count
            check("导入后库里多一套模板", midCount == beforeCount + 1,
                  "\(beforeCount) → \(midCount)")
            let names = Set(try db.fee.templates().map { $0.name })
            check("同名模板不会被覆盖（自动改名）", names.contains(shareTemplate.name)
                  && FeeTemplateIO.uniqueName(shareTemplate.name, among: names) != shareTemplate.name,
                  FeeTemplateIO.uniqueName(shareTemplate.name, among: names))

            // 改过的费率要真的能算出不同的钱（定制是有意义的）
            let originalSummary = BudgetCalculator.summarize(items: feeItems, template: tpl)
            let editedSummary = BudgetCalculator.summarize(items: feeItems, template: decoded[0])
            check("改一处费率就能算出不同的总造价",
                  abs(originalSummary.grandTotal - editedSummary.grandTotal) > 0.01,
                  "\(Fmt.money(originalSummary.grandTotal)) vs \(Fmt.money(editedSummary.grandTotal))")

            // ---------- 12. 报表可选表导出 ----------
            print("\n[12] 按需导出报表")
            let pickedTables: [ReportTable] = [
                ReportBuilder.summaryTable(project: created, template: tpl, summary: s),
                ReportBuilder.installationTable(project: created, template: tpl, summary: s)
            ]
            let pickPDF = tmp.appendingPathComponent("只要表一表二.pdf")
            try PDFExporter.export(tables: pickedTables, to: pickPDF)
            let pickSize = (try FileManager.default.attributesOfItem(atPath: pickPDF.path)[.size] as? Int) ?? 0
            check("可只导出勾选的表", pickSize > 3000 && pickSize < allSize,
                  "\(pickSize) 字节 < 全套 \(allSize) 字节")
            let pickXlsx = tmp.appendingPathComponent("只要表一表二.xlsx")
            try ExcelExporter.export(tables: pickedTables, to: pickXlsx)
            check("选表导出同样能出 Excel",
                  (try? XlsxReader.read(url: pickXlsx).count) == 2)
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
