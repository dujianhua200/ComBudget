import Foundation

// =============================================================================
// 按「分册 / 章」分组小计
//
// 大宇翔一类软件的清单和报表都支持分部小计，这里与之对齐：
//   · 分组键默认用 project_item.series（如 TXL1 / TGD2，共 31 个分组粒度适中）；
//     451 手册里的 chapter 字段只有 3 个取值（多为「总 说 明」），粒度太粗，
//     所以 chapter 只作为可选项保留。
//   · 分组结果同时供界面表格、明细表 Excel / PDF 复用，避免三套口径不一致。
// =============================================================================

enum GroupingKey: String, CaseIterable, Identifiable {
    case none   = "不分组"
    case series = "按分册"
    case chapter = "按章"

    var id: String { rawValue }

    func key(of item: ProjectItem) -> String {
        switch self {
        case .none:    return ""
        case .series:  return item.groupKey
        case .chapter: return item.chapter.isEmpty ? "未分类" : item.chapter
        }
    }
}

/// 一组子目及其小计
struct ItemGroup: Identifiable {
    var key: String = ""
    var items: [ProjectItem] = []
    var cost = GroupCost()

    var id: String { key }
    /// 界面标题：如果没有友好名称，直接显示分组键
    var title: String { key.isEmpty ? "全部子目" : key }
}

struct GroupCost {
    var techWorkdays: Double = 0
    var laborWorkdays: Double = 0
    var labor: Double = 0
    var mainMaterial: Double = 0
    var auxMaterial: Double = 0
    var machine: Double = 0
    var instrument: Double = 0
    var equipment: Double = 0

    var direct: Double { labor + mainMaterial + auxMaterial + machine + instrument }

    mutating func add(_ c: ItemCost) {
        techWorkdays += c.techWorkdays
        laborWorkdays += c.laborWorkdays
        labor += c.labor
        mainMaterial += c.mainMaterial
        auxMaterial += c.auxMaterial
        machine += c.machine
        instrument += c.instrument
        equipment += c.equipment
    }
}

enum BudgetGrouping {

    /// 按分组键归类；保持清单原有顺序（不是字典序，否则和表格对不上）
    static func group(items: [ProjectItem], costs: [Int64: ItemCost], key: GroupingKey) -> [ItemGroup] {
        guard key != .none else { return [] }

        var groups: [ItemGroup] = []
        var indexOf: [String: Int] = [:]

        for item in items {
            let k = key.key(of: item)
            let idx: Int
            if let i = indexOf[k] {
                idx = i
            } else {
                groups.append(ItemGroup(key: k))
                idx = groups.count - 1
                indexOf[k] = idx
            }
            groups[idx].items.append(item)
            groups[idx].cost.add(costs[item.id] ?? ItemCost())
        }
        return groups
    }

    /// 全工程合计（和分组小计口径一致，用于对账）
    static func total(items: [ProjectItem], costs: [Int64: ItemCost]) -> GroupCost {
        var t = GroupCost()
        for item in items { t.add(costs[item.id] ?? ItemCost()) }
        return t
    }
}
