import Foundation
import CoreGraphics

// =============================================================================
// 报表模型：一套数据，界面预览 / Excel 导出 / PDF 打印共用
// =============================================================================

struct ReportTable: Identifiable {
    var id = UUID()
    var title: String
    var subtitle: String = ""
    var header: [String]
    var rows: [[String]]
    var footers: [[String]] = []
    var rightAligned: [Bool]
    var widths: [CGFloat]
    /// 需要加粗的行的下标（分组标题行、小计行），导出与预览共用同一套口径
    var emphasizedRows: Set<Int> = []
}

enum ReportBuilder {

    private static func head(_ p: Project) -> String {
        var parts: [String] = []
        if !p.code.isEmpty { parts.append("工程编号：\(p.code)") }
        if !p.name.isEmpty { parts.append("工程名称：\(p.name)") }
        parts.append("专业：\(p.specialty)")
        if !p.owner.isEmpty { parts.append("建设单位：\(p.owner)") }
        if !p.contractor.isEmpty { parts.append("施工单位：\(p.contractor)") }
        return parts.joined(separator: "　")
    }

    // MARK: - 表一 预算汇总表

    static func summaryTable(project: Project, template: FeeTemplate?, summary: BudgetSummary) -> ReportTable {
        var rows: [[String]] = []
        var idx = 1
        let c = summary.itemCost

        func line(_ name: String, _ base: String, _ rate: String, _ amount: Double) -> [String] {
            defer { idx += 1 }
            return ["\(idx)", name, base, rate, Fmt.money(amount)]
        }

        rows.append(line("人工费", "技工 \(Fmt.workday(c.techWorkdays)) 工日 + 普工 \(Fmt.workday(c.laborWorkdays)) 工日", "—", c.labor))
        rows.append(line("主要材料费", "—", "—", c.mainMaterial))
        rows.append(line("辅助材料费", "人工费 × \(Fmt.rate(template?.auxMaterialRate ?? 0))", "—", c.auxMaterial))
        rows.append(line("机械使用费", "—", "—", c.machine))
        rows.append(line("仪表使用费", "—", "—", c.instrument))
        rows.append(line("直接费小计", "（一）～（五）", "—", c.direct))

        for f in summary.feeLines {
            rows.append(line(f.name, "\(f.baseLabel) \(Fmt.money(f.baseValue))", Fmt.rate(f.rate), f.amount))
        }
        let measuresCount = summary.feeLines.filter { $0.group == "措施费" }.count
        let indirectCount = summary.feeLines.filter { $0.group == "间接费" }.count
        if measuresCount > 1 { rows.append(line("措施费小计", "—", "—", summary.measures)) }
        if indirectCount > 1 { rows.append(line("间接费小计", "—", "—", summary.indirect)) }
        rows.append(line("建安工程费合计", "直接费+措施费+间接费+利润+税金", "—", summary.total))
        if c.equipment > 0 {
            rows.append(line("设备费", "单列，不计取费", "—", c.equipment))
            rows.append(line("工程总造价", "建安工程费 + 设备费", "—", summary.grandTotal))
        }

        let dateText: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        return ReportTable(
            title: "预算汇总表",
            subtitle: head(project),
            header: ["序号", "费用名称", "计算基数", "费率", "金额（元）"],
            rows: rows,
            footers: [["", "编制人：" + project.compiler, "审核人：" + project.reviewer,
                       "", "日期：" + dateText]],
            rightAligned: [false, false, false, true, true],
            widths: [0.6, 2.0, 2.8, 0.9, 1.4]
        )
    }

    // MARK: - 表二 定额明细表

    static func detailTable(project: Project, items: [ProjectItem], costs: [Int64: ItemCost],
                            summary: BudgetSummary, grouping: GroupingKey = .none) -> ReportTable {
        var rows: [[String]] = []
        var emphasized: Set<Int> = []

        func bodyRow(_ seq: Int, _ item: ProjectItem) -> [String] {
            let c = costs[item.id] ?? ItemCost()
            return [
                "\(seq)", item.quotaCode, item.quotaName, item.unit,
                Fmt.quantity(item.quantity),
                String(format: "%.2f", item.workdayCoeff),
                Fmt.workday(c.techWorkdays), Fmt.workday(c.laborWorkdays),
                Fmt.money(c.labor), Fmt.money(c.mainMaterial),
                Fmt.money(c.machine), Fmt.money(c.instrument),
                Fmt.money(c.direct), item.note
            ]
        }

        func subtotalRow(_ label: String, _ g: GroupCost) -> [String] {
            ["", label, "", "", "", "",
             Fmt.workday(g.techWorkdays), Fmt.workday(g.laborWorkdays),
             Fmt.money(g.labor), Fmt.money(g.mainMaterial), Fmt.money(g.machine),
             Fmt.money(g.instrument), Fmt.money(g.direct), ""]
        }

        if grouping == .none {
            for (i, item) in items.enumerated() { rows.append(bodyRow(i + 1, item)) }
        } else {
            // 分组：每组先一行组标题，再逐条列子目，最后一行小计
            let groups = BudgetGrouping.group(items: items, costs: costs, key: grouping)
            var seq = 0
            for g in groups {
                emphasized.insert(rows.count)
                rows.append(["", "【\(g.title)】", "共 \(g.items.count) 条", "", "", "",
                             "", "", "", "", "", "", "", ""])
                for item in g.items {
                    seq += 1
                    rows.append(bodyRow(seq, item))
                }
                emphasized.insert(rows.count)
                rows.append(subtotalRow("\(g.title) 小计", g.cost))
            }
            // 分组模式下最后补一行总合计，方便和汇总表对账
            emphasized.insert(rows.count)
            rows.append(subtotalRow("总计", BudgetGrouping.total(items: items, costs: costs)))
        }

        let c = summary.itemCost
        return ReportTable(
            title: grouping == .none ? "定额明细表（表二）" : "定额明细表（表二 · \(grouping.rawValue)）",
            subtitle: head(project),
            header: ["序号", "定额编号", "定额名称", "单位", "工程量", "系数",
                     "技工工日", "普工工日", "人工费", "主材费", "机械费", "仪表费", "小计", "备注"],
            rows: rows,
            footers: grouping == .none ? [[
                "", "合计", "", "", "", "",
                Fmt.workday(c.techWorkdays), Fmt.workday(c.laborWorkdays),
                Fmt.money(c.labor), Fmt.money(c.mainMaterial), Fmt.money(c.machine),
                Fmt.money(c.instrument), Fmt.money(c.direct), ""
            ]] : [],
            rightAligned: [false, false, false, false, true, true, true, true, true, true, true, true, true, false],
            widths: [0.5, 1.0, 2.6, 0.7, 0.8, 0.7, 0.85, 0.85, 1.0, 1.0, 0.9, 0.9, 1.1, 1.2],
            emphasizedRows: emphasized
        )
    }

    // MARK: - 材料/设备、机械仪表

    struct ResourceLine {
        var kind: ResourceKind
        var name: String
        var spec: String
        var unit: String
        var qty: Double
        var price: Double
        var amount: Double { qty * price }
    }

    static func resourceLines(items: [ProjectItem], kinds: Set<ResourceKind>) -> [ResourceLine] {
        var map: [String: ResourceLine] = [:]
        for item in items {
            for res in item.resources where kinds.contains(res.kind) {
                let key = "\(res.kind.rawValue)|\(res.name)|\(res.spec)|\(res.unit)|\(res.unitPrice)"
                let qty = res.effectiveQtyPerUnit * item.quantity
                if var line = map[key] {
                    line.qty += qty
                    map[key] = line
                } else {
                    map[key] = ResourceLine(kind: res.kind, name: res.name, spec: res.spec,
                                            unit: res.unit, qty: qty, price: res.unitPrice)
                }
            }
        }
        return map.values.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.name < $1.name
        }
    }

    static func materialTable(project: Project, items: [ProjectItem]) -> ReportTable {
        let lines = resourceLines(items: items, kinds: [.mainMaterial, .equipment])
        var rows: [[String]] = []
        for (i, l) in lines.enumerated() {
            rows.append(["\(i + 1)", l.kind.rawValue, l.name, l.spec, l.unit,
                         Fmt.quantity(l.qty), Fmt.money(l.price), Fmt.money(l.amount)])
        }
        let total = lines.reduce(0) { $0 + $1.amount }
        return ReportTable(
            title: "主要材料（设备）表",
            subtitle: head(project),
            header: ["序号", "类型", "名称", "规格程式", "单位", "数量", "单价（元）", "金额（元）"],
            rows: rows,
            footers: [["", "合计", "", "", "", "", "", Fmt.money(total)]],
            rightAligned: [false, false, false, false, false, true, true, true],
            widths: [0.5, 0.8, 2.6, 2.2, 0.7, 1.0, 1.2, 1.4]
        )
    }

    static func machineTable(project: Project, items: [ProjectItem]) -> ReportTable {
        let lines = resourceLines(items: items, kinds: [.machine, .instrument])
        var rows: [[String]] = []
        for (i, l) in lines.enumerated() {
            rows.append(["\(i + 1)", l.kind.rawValue, l.name, l.spec, l.unit,
                         Fmt.quantity(l.qty), Fmt.money(l.price), Fmt.money(l.amount)])
        }
        let total = lines.reduce(0) { $0 + $1.amount }
        return ReportTable(
            title: "机械仪表台班表",
            subtitle: head(project),
            header: ["序号", "类型", "名称", "规格程式", "单位", "台班数", "单价（元）", "金额（元）"],
            rows: rows,
            footers: [["", "合计", "", "", "", "", "", Fmt.money(total)]],
            rightAligned: [false, false, false, false, false, true, true, true],
            widths: [0.5, 0.8, 2.6, 2.2, 0.7, 1.0, 1.2, 1.4]
        )
    }
}
