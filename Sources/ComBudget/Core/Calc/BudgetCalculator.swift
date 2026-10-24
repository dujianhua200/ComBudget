import Foundation

// =============================================================================
// 计算引擎（451 号文口径）
//
//   技工工日 = 定额技工工日 × 工程量 × 工日调整系数
//   普工工日 = 定额普工工日 × 工程量 × 工日调整系数
//   人工费   = 技工工日×技工单价 + 普工工日×普工单价      （技工 114、普工 61 元/工日，可改）
//   主要材料费 / 机械费 / 仪表费 = Σ(定额消耗量 × 工程量 × 单价)
//   辅助材料费 = 人工费 × 辅材费率（默认 0.3%）
//   直接费   = 人工费 + 主材费 + 辅材费 + 机械费 + 仪表费
//   造价     = 直接费 + 措施费 + 间接费 + 利润 + 税金
//   设备费   = 单列，不计入建安工程费
// =============================================================================

enum BudgetCalculator {

    /// 单条子目的费用构成
    static func cost(of item: ProjectItem, auxRate: Double) -> ItemCost {
        var c = ItemCost()
        c.techWorkdays = item.effectiveTechWorkday
        c.laborWorkdays = item.effectiveLaborWorkday
        c.labor = c.techWorkdays * item.techPrice + c.laborWorkdays * item.laborPrice

        for res in item.resources {
            let qty = res.effectiveQtyPerUnit * item.quantity
            let amount = qty * res.unitPrice
            switch res.kind {
            case .mainMaterial: c.mainMaterial += amount
            case .machine:      c.machine += amount
            case .instrument:   c.instrument += amount
            case .equipment:    c.equipment += amount
            }
        }
        c.auxMaterial = c.labor * auxRate / 100.0
        return c
    }

    /// 全工程汇总（取费按模板顺序逐项计算）
    static func summarize(items: [ProjectItem], template: FeeTemplate?) -> BudgetSummary {
        let auxRate = template?.auxMaterialRate ?? 0
        var sum = BudgetSummary()

        for item in items {
            let c = cost(of: item, auxRate: auxRate)
            sum.itemCost.techWorkdays += c.techWorkdays
            sum.itemCost.laborWorkdays += c.laborWorkdays
            sum.itemCost.labor += c.labor
            sum.itemCost.mainMaterial += c.mainMaterial
            sum.itemCost.auxMaterial += c.auxMaterial
            sum.itemCost.machine += c.machine
            sum.itemCost.instrument += c.instrument
            sum.itemCost.equipment += c.equipment
        }

        guard let tpl = template else { return sum }

        for rate in tpl.sortedRates where rate.isEnabled {
            let base: Double
            switch rate.base {
            case .labor:        base = sum.itemCost.labor
            case .laborMachine: base = sum.itemCost.labor + sum.itemCost.machine
            case .direct:       base = sum.itemCost.direct
            case .directPlus:   base = sum.itemCost.direct + sum.measures + sum.indirect + sum.profit
            }
            let amount = base * rate.rate / 100.0
            sum.feeLines.append(FeeLine(key: rate.key, name: rate.name, group: rate.group,
                                        baseLabel: rate.base.rawValue, baseValue: base,
                                        rate: rate.rate, amount: amount))
            switch rate.group {
            case "措施费": sum.measures += amount
            case "间接费": sum.indirect += amount
            case "利润":   sum.profit += amount
            case "税金":   sum.tax += amount
            default:       break
            }
        }
        return sum
    }

    /// 每行费用（表格展示用，key = item.id）
    static func rowCosts(items: [ProjectItem], template: FeeTemplate?) -> [Int64: ItemCost] {
        let auxRate = template?.auxMaterialRate ?? 0
        var map: [Int64: ItemCost] = [:]
        map.reserveCapacity(items.count)
        for item in items { map[item.id] = cost(of: item, auxRate: auxRate) }
        return map
    }
}
