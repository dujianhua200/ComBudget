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

    // MARK: - 共用

    private static let feeHeader = ["序号", "费用名称", "计算基数", "费率", "金额（元）"]
    private static let feeWidths: [CGFloat] = [0.6, 2.2, 2.6, 0.9, 1.4]

    private static func dateText() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// 编制/审核/日期页脚
    private static func signFooter(_ p: Project) -> [[String]] {
        [["", "编制人：\(p.compiler)", "审核人：\(p.reviewer)", "", "日期：\(dateText())"]]
    }

    /// 科目排列顺序（报表与计算顺序一致）
    private static let orderedKinds: [FeeKind] = FeeKind.allCases.sorted { $0.order < $1.order }

    /// 中文序号：一、二、三…（概预算表的科目编号习惯）
    private static func cnIndex(_ i: Int) -> String {
        let names = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        return i < names.count ? names[i] : "\(i + 1)"
    }

    // MARK: - 表一 工程预算总表

    static func summaryTable(project: Project, template: FeeTemplate?, summary: BudgetSummary) -> ReportTable {
        let c = summary.itemCost
        var rows: [[String]] = []
        var emphasized: Set<Int> = []

        func line(_ no: String, _ name: String, _ base: String, _ rate: String,
                  _ amount: Double) -> [String] {
            [no, name, base, rate, Fmt.money(amount)]
        }

        rows.append(line("一", "建筑安装工程费", "直接费+措施费+间接费+利润+税金", "—", summary.total))
        rows.append(line("　1", "直接费", "", "—", c.direct))
        rows.append(line("　2", "措施费", "", "—", summary.measures))
        rows.append(line("　3", "间接费", "规费+企业管理费", "—", summary.indirect))
        rows.append(line("　4", "利润", "", "—", summary.profit))
        rows.append(line("　5", "税金", "", "—", summary.tax))
        rows.append(line("二", "设备工器具购置费", "单列，不计取费", "—", c.equipment))
        rows.append(line("三", "工程建设其他费", "见表五", "—", summary.otherFees))
        rows.append(line("四", "预备费", "基本预备费", "—", summary.contingency))

        emphasized.insert(rows.count)
        rows.append(line("", "工程总造价", "一+二+三+四", "—", summary.grandTotal))
        emphasized.insert(rows.count)
        rows.append(["", "工程总造价（大写）", Fmt.cnyUpper(summary.grandTotal), "", ""])

        return ReportTable(
            title: "工程预算总表（表一）",
            subtitle: head(project),
            header: feeHeader,
            rows: rows,
            footers: signFooter(project),
            rightAligned: [false, false, false, true, true],
            widths: feeWidths,
            emphasizedRows: emphasized
        )
    }

    // MARK: - 表二 建筑安装工程费用预算表

    static func installationTable(project: Project, template: FeeTemplate?,
                                  summary: BudgetSummary) -> ReportTable {
        let c = summary.itemCost
        var rows: [[String]] = []
        var emphasized: Set<Int> = []

        func add(_ no: String, _ name: String, _ base: String, _ rate: String, _ amount: Double) {
            rows.append([no, name, base, rate, Fmt.money(amount)])
        }

        // （一）直接费
        add("一", "直接费", "", "—", c.direct)
        emphasized.insert(rows.count - 1)
        add("　1", "人工费",
            "技工 \(Fmt.workday(c.techWorkdays)) 工日 + 普工 \(Fmt.workday(c.laborWorkdays)) 工日",
            "—", c.labor)
        add("　2", "主要材料费", "", "—", c.mainMaterial)
        add("　3", "辅助材料费", "人工费 × \(Fmt.rate(template?.auxMaterialRate ?? 0))",
            Fmt.rate(template?.auxMaterialRate ?? 0), c.auxMaterial)
        add("　4", "机械使用费", "详见表三乙", "—", c.machine)
        add("　5", "仪表使用费", "详见表三丙", "—", c.instrument)
        emphasized.insert(rows.count)
        add("", "直接费小计", "1+2+3+4+5", "—", c.direct)

        // （二）～（五）按科目顺序展开取费项
        var no = 1
        for kind in orderedKinds where kind.isInstallation {
            let lines = summary.feeLines.filter { FeeKind.of($0.group) == kind }
            guard !lines.isEmpty else { continue }
            let label = cnIndex(no)
            no += 1
            add(label, kind.rawValue, "", "—", summary.amount(of: kind))
            emphasized.insert(rows.count - 1)
            for (i, l) in lines.enumerated() {
                add("　\(i + 1)", l.name,
                    "\(l.baseLabel) \(Fmt.money(l.baseValue))", Fmt.rate(l.rate), l.amount)
            }
        }

        emphasized.insert(rows.count)
        add("", "建筑安装工程费合计", "直接费+措施费+间接费+利润+税金", "—", summary.total)

        return ReportTable(
            title: "建筑安装工程费用预算表（表二）",
            subtitle: head(project),
            header: feeHeader,
            rows: rows,
            footers: [["", "建筑安装工程费（大写）", Fmt.cnyUpper(summary.total), "", ""]]
                     + signFooter(project),
            rightAligned: [false, false, false, true, true],
            widths: feeWidths,
            emphasizedRows: emphasized
        )
    }

    // MARK: - 表五甲 工程建设其他费预算表

    static func otherFeeTable(project: Project, summary: BudgetSummary) -> ReportTable {
        var rows: [[String]] = []
        var emphasized: Set<Int> = []

        let others = summary.feeLines.filter { FeeKind.of($0.group) == .other }
        for (i, l) in others.enumerated() {
            rows.append(["\(i + 1)", l.name, "\(l.baseLabel) \(Fmt.money(l.baseValue))",
                         Fmt.rate(l.rate), Fmt.money(l.amount)])
        }
        emphasized.insert(rows.count)
        rows.append(["", "工程建设其他费合计", "", "—", Fmt.money(summary.otherFees)])

        let contingencies = summary.feeLines.filter { FeeKind.of($0.group) == .contingency }
        if !contingencies.isEmpty {
            for (i, l) in contingencies.enumerated() {
                rows.append(["\(i + 1)", l.name, "\(l.baseLabel) \(Fmt.money(l.baseValue))",
                             Fmt.rate(l.rate), Fmt.money(l.amount)])
            }
            emphasized.insert(rows.count)
            rows.append(["", "预备费合计", "", "—", Fmt.money(summary.contingency)])
        }

        return ReportTable(
            title: "工程建设其他费预算表（表五甲）",
            subtitle: head(project),
            header: feeHeader,
            rows: rows,
            footers: signFooter(project),
            rightAligned: [false, false, false, true, true],
            widths: feeWidths,
            emphasizedRows: emphasized
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
            title: grouping == .none
                ? "建筑安装工程量预算表（表三甲）"
                : "建筑安装工程量预算表（表三甲 · \(grouping.rawValue)）",
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
            let no = l.kind == .equipment ? "设备\(i + 1)" : "\(i + 1)"
            rows.append([no, l.kind.rawValue, l.name, l.spec, l.unit,
                         Fmt.quantity(l.qty), Fmt.money(l.price), Fmt.money(l.amount)])
        }
        let total = lines.reduce(0) { $0 + $1.amount }
        return ReportTable(
            title: "器材预算表（表四甲 · 国内器材）",
            subtitle: head(project),
            header: ["序号", "类别", "名称", "规格程式", "单位", "数量", "单价（元）", "金额（元）"],
            rows: rows,
            footers: [["", "合计", "", "", "", "", "", Fmt.money(total)]],
            rightAligned: [false, false, false, false, false, true, true, true],
            widths: [0.7, 0.8, 2.6, 2.2, 0.7, 1.0, 1.2, 1.4]
        )
    }

    /// 机械/仪表台班表（.machine → 表三乙，.instrument → 表三丙）
    static func machineTable(project: Project, items: [ProjectItem],
                             kind: ResourceKind = .machine) -> ReportTable {
        let lines = resourceLines(items: items, kinds: [kind])
        var rows: [[String]] = []
        for (i, l) in lines.enumerated() {
            rows.append(["\(i + 1)", l.name, l.spec, l.unit,
                         Fmt.quantity(l.qty), Fmt.money(l.price), Fmt.money(l.amount)])
        }
        let total = lines.reduce(0) { $0 + $1.amount }
        let title = kind == .machine
            ? "建筑安装工程机械使用费预算表（表三乙）"
            : "建筑安装工程仪器仪表使用费预算表（表三丙）"
        return ReportTable(
            title: title,
            subtitle: head(project),
            header: ["序号", "名称", "规格程式", "单位", "台班数", "单价（元）", "金额（元）"],
            rows: rows,
            footers: [["", "合计", "", "", "", "", Fmt.money(total)]],
            rightAligned: [false, false, false, false, true, true, true],
            widths: [0.6, 3.0, 2.6, 0.8, 1.0, 1.2, 1.4]
        )
    }
}
