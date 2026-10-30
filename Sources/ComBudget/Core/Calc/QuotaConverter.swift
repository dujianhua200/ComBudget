import Foundation

// =============================================================================
// 定额换算
//
// 451 定额的子目是「标准工况」下的消耗量，实际工程常常需要对它做换算：
//   · 人工、机械、仪表台班乘系数（高海拔、夜间、洞内作业等）
//   · 主材换规格后消耗量随之变化
//
// 换算的处理方式与「资源快照」保持一致：
//   · 换算只改 project_item.tech_workday / labor_workday（换算后的值）；
//   · 定额原值保存在 tech_workday_base / labor_workday_base，随时可还原；
//   · 资源消耗量的换算落到 qty_override（保留 qty_per_unit 定额原值）；
//   · 换算痕迹写进 conv_note，报表/审计能看出这一行走过什么系数。
//
// 注意：下面 preset 里的系数是「工程常用参考模板」，不是 451 号文强制规定。
//       实际应以招标文件、定额站解释或现场签证为准，界面里允许任意改。
// =============================================================================

struct ConversionRule: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var techCoeff: Double = 1        // 技工工日系数
    var laborCoeff: Double = 1       // 普工工日系数
    var machineCoeff: Double = 1     // 机械台班系数
    var instrumentCoeff: Double = 1  // 仪表台班系数
    var materialCoeff: Double = 1    // 主材消耗量系数
    var note: String = ""

    /// 是否等价于「不换算」
    var isIdentity: Bool {
        techCoeff == 1 && laborCoeff == 1 && machineCoeff == 1
            && instrumentCoeff == 1 && materialCoeff == 1
    }

    /// 换算说明，例如「技工×1.15 普工×1.15 机械×1.20」
    var summary: String {
        var parts: [String] = []
        if techCoeff != 1       { parts.append("技工×\(Fmt.coeff(techCoeff))") }
        if laborCoeff != 1      { parts.append("普工×\(Fmt.coeff(laborCoeff))") }
        if machineCoeff != 1    { parts.append("机械×\(Fmt.coeff(machineCoeff))") }
        if instrumentCoeff != 1 { parts.append("仪表×\(Fmt.coeff(instrumentCoeff))") }
        if materialCoeff != 1   { parts.append("主材×\(Fmt.coeff(materialCoeff))") }
        return parts.isEmpty ? "不换算（×1.0）" : parts.joined(separator: " ")
    }
}

enum ConversionPresets {
    static let disclaimer = "工程常用参考模板，非 451 号文强制规定，按招标文件或定额站解释核定"

    static let all: [ConversionRule] = [
        ConversionRule(name: "还原为定额原值", techCoeff: 1, laborCoeff: 1, machineCoeff: 1,
                       instrumentCoeff: 1, materialCoeff: 1, note: "清除本行的换算"),
        ConversionRule(name: "丘陵·水田地段", techCoeff: 1.15, laborCoeff: 1.15,
                       note: disclaimer),
        ConversionRule(name: "山区·高海拔", techCoeff: 1.30, laborCoeff: 1.30,
                       machineCoeff: 1.20, note: disclaimer),
        ConversionRule(name: "夜间施工", techCoeff: 1.20, laborCoeff: 1.20,
                       note: disclaimer),
        ConversionRule(name: "洞（隧）道内作业", techCoeff: 1.15, laborCoeff: 1.15,
                       instrumentCoeff: 1.10, note: disclaimer),
        ConversionRule(name: "冬雨季施工", techCoeff: 1.10, laborCoeff: 1.10,
                       note: disclaimer),
        ConversionRule(name: "市区繁华地段（降效）", techCoeff: 1.10, laborCoeff: 1.10,
                       machineCoeff: 1.05, note: disclaimer),
        ConversionRule(name: "拆除工程（不计主材）", techCoeff: 1, laborCoeff: 1,
                       materialCoeff: 0, note: "主材消耗量归零，只计安装/拆除人工")
    ]
}

enum QuotaConverter {

    /// 对一条子目套用换算（不改 id / 工程量，只改工日与资源消耗量）
    static func apply(_ rule: ConversionRule, to item: inout ProjectItem) {
        let baseTech = item.baseTech
        let baseLabor = item.baseLabor

        if rule.isIdentity {
            revoke(from: &item)
            return
        }

        item.techWorkdayBase = baseTech
        item.laborWorkdayBase = baseLabor
        item.techWorkday = baseTech * rule.techCoeff
        item.laborWorkday = baseLabor * rule.laborCoeff

        for i in item.resources.indices {
            switch item.resources[i].kind {
            case .mainMaterial: override(&item.resources[i], coeff: rule.materialCoeff)
            case .machine:      override(&item.resources[i], coeff: rule.machineCoeff)
            case .instrument:   override(&item.resources[i], coeff: rule.instrumentCoeff)
            case .equipment:    break   // 设备是手工补充的，不参与定额换算
            }
        }
        item.convNote = rule.name + "：" + rule.summary
    }

    /// 还原为定额原值（清换算痕迹）
    static func revoke(from item: inout ProjectItem) {
        item.techWorkday = item.baseTech
        item.laborWorkday = item.baseLabor
        for i in item.resources.indices { item.resources[i].qtyOverride = nil }
        item.convNote = ""
    }

    private static func override(_ res: inout ItemResource, coeff: Double) {
        guard coeff != 1 else {
            res.qtyOverride = nil
            return
        }
        res.qtyOverride = res.qtyPerUnit * coeff
    }

    /// 换算前后差额预览（换算向导里给用户看一眼再确认）
    static func preview(_ rule: ConversionRule, item: ProjectItem, auxRate: Double) -> (before: ItemCost, after: ItemCost) {
        let before = BudgetCalculator.cost(of: item, auxRate: auxRate)
        var copy = item
        apply(rule, to: &copy)
        let after = BudgetCalculator.cost(of: copy, auxRate: auxRate)
        return (before, after)
    }
}
