import Foundation

// =============================================================================
// 领域模型：451 定额库 / 工程 / 定额子目 / 取费模板
//
// 与 451 定额原书一致：人工按「技工 / 普工」两栏分别计量，
// 因此 QuotaItem 与 ProjectItem 都拆成 techWorkday / laborWorkday，
// 人工费 = 技工工日×技工单价 + 普工工日×普工单价。
// =============================================================================

// MARK: - 枚举

enum Specialty: String, CaseIterable, Identifiable, Codable {
    case wired      = "有线通信"
    case wireless   = "无线通信"
    case power      = "电源配套"
    case pipeline   = "管道"
    case pole       = "杆路"
    case ftth       = "FTTH"
    case other      = "其他"

    var id: String { rawValue }
}

enum ProjectCategory: String, CaseIterable, Identifiable, Codable {
    case line      = "通信线路工程"
    case equipment = "通信设备工程"
    case pipeline  = "通信管道工程"
    case ftth      = "FTTH 接入工程"
    case power     = "电源配套工程"

    var id: String { rawValue }
}

/// 定额资源类型（与手册「主要材料 / 机械 / 仪表」三栏对应，设备为手工补充）
enum ResourceKind: String, CaseIterable, Identifiable, Codable {
    case mainMaterial = "主材"
    case machine      = "机械"
    case instrument   = "仪表"
    case equipment    = "设备"

    var id: String { rawValue }
    var isEquipment: Bool { self == .equipment }
}

// MARK: - 定额库

struct QuotaResource: Identifiable, Hashable {
    var id: Int64 = 0
    var quotaID: Int64 = 0
    var kind: ResourceKind = .mainMaterial
    var name: String = ""
    var spec: String = ""
    var unit: String = ""
    var qtyPerUnit: Double = 0     // 定额消耗量
    var unitPrice: Double = 0      // 定额原书不含单价，默认 0，由用户在工程里填

    var displayName: String { unit.isEmpty ? name : "\(name)（\(unit)）" }
}

/// 451 定额一条子目
struct QuotaItem: Identifiable, Hashable {
    var id: Int64 = 0
    var code: String = ""          // 定额编号，如 TXL1-001
    var name: String = ""          // 子目名称（项目 + 细分 层级拼接）
    var unit: String = ""          // 定额单位
    var chapter: String = ""       // 章
    var section: String = ""       // 节
    var series: String = ""        // 定额系列，如 TXL1 / TSD4
    var book: String = ""          // 册名
    var work: String = ""          // 工作内容
    var techWorkday: Double = 0    // 技工工日
    var laborWorkday: Double = 0   // 普工工日
    var isBuiltin: Bool = true
    var resources: [QuotaResource] = []

    var totalWorkday: Double { techWorkday + laborWorkday }

    var resourceSummary: String {
        let mats = resources.filter { $0.kind == .mainMaterial }
        guard !mats.isEmpty else { return "—" }
        return mats.prefix(3).map { $0.name }.joined(separator: "、")
            + (mats.count > 3 ? " 等\(mats.count)项" : "")
    }

    /// 册简称，如「第四册 通信线路工程」→「通信线路工程」
    var bookShort: String {
        if let range = book.range(of: "册") {
            return String(book[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return book
    }
}

// MARK: - 工程

struct Project: Identifiable, Hashable {
    var id: Int64 = 0
    var code: String = ""
    var name: String = ""
    var category: String = ProjectCategory.line.rawValue
    var specialty: String = Specialty.wired.rawValue
    var scale: String = ""
    var owner: String = ""
    var contractor: String = ""
    var compiler: String = ""
    var reviewer: String = ""
    var feeTemplateID: Int64 = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    static func newDraft() -> Project {
        Project(name: "新建工程")
    }
}

/// 工程定额子目（清单一行）
struct ProjectItem: Identifiable, Hashable {
    var id: Int64 = 0
    var projectID: Int64 = 0
    var sortIndex: Int = 0
    var quotaCode: String = ""
    var quotaName: String = ""
    var unit: String = ""
    var quantity: Double = 1
    var workdayCoeff: Double = 1
    var techWorkday: Double = 0
    var laborWorkday: Double = 0
    var techPrice: Double = 114
    var laborPrice: Double = 61
    var note: String = ""
    var isSupplement: Bool = false
    var resources: [ItemResource] = []

    var effectiveTechWorkday: Double { techWorkday * quantity * workdayCoeff }
    var effectiveLaborWorkday: Double { laborWorkday * quantity * workdayCoeff }
}

struct ItemResource: Identifiable, Hashable {
    var id: Int64 = 0
    var itemID: Int64 = 0
    var kind: ResourceKind = .mainMaterial
    var name: String = ""
    var spec: String = ""
    var unit: String = ""
    var qtyPerUnit: Double = 0
    var qtyOverride: Double? = nil
    var unitPrice: Double = 0
    var isExtra: Bool = false

    var effectiveQtyPerUnit: Double { qtyOverride ?? qtyPerUnit }
}

// MARK: - 取费

enum FeeBase: String, CaseIterable, Identifiable, Codable {
    case labor        = "人工费"
    case laborMachine = "人工费+机械费"
    case direct       = "直接费"
    case directPlus   = "直接费+措施费+间接费"

    var id: String { rawValue }
}

struct FeeRate: Identifiable, Hashable {
    var id: Int64 = 0
    var templateID: Int64 = 0
    var key: String = ""
    var name: String = ""
    var group: String = "措施费"
    var base: FeeBase = .labor
    var rate: Double = 0
    var sortIndex: Int = 0
    var isEnabled: Bool = true
    var note: String = ""
}

struct FeeTemplate: Identifiable, Hashable {
    var id: Int64 = 0
    var name: String = "默认取费模板"
    var isBuiltin: Bool = false
    var auxMaterialRate: Double = 0.3
    var note: String = ""
    var rates: [FeeRate] = []

    var sortedRates: [FeeRate] { rates.sorted { $0.sortIndex < $1.sortIndex } }
}

// MARK: - 计算结果

struct ItemCost {
    var techWorkdays: Double = 0
    var laborWorkdays: Double = 0
    var labor: Double = 0
    var mainMaterial: Double = 0
    var machine: Double = 0
    var instrument: Double = 0
    var equipment: Double = 0
    var auxMaterial: Double = 0

    var workdays: Double { techWorkdays + laborWorkdays }
    var material: Double { mainMaterial + auxMaterial }
    var direct: Double { labor + material + machine + instrument }
}

struct FeeLine: Identifiable, Hashable {
    var id = UUID()
    var key: String
    var name: String
    var group: String
    var baseLabel: String
    var baseValue: Double
    var rate: Double
    var amount: Double
}

struct BudgetSummary {
    var itemCost = ItemCost()
    var feeLines: [FeeLine] = []
    var measures: Double = 0
    var indirect: Double = 0
    var profit: Double = 0
    var tax: Double = 0

    var total: Double { itemCost.direct + measures + indirect + profit + tax }
    var grandTotal: Double { total + itemCost.equipment }
}

// MARK: - 格式化

enum Fmt {
    private static let moneyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = true
        return f
    }()

    private static let qtyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 4
        f.usesGroupingSeparator = false
        return f
    }()

    static func money(_ v: Double) -> String {
        moneyFormatter.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)
    }

    static func quantity(_ v: Double) -> String {
        guard v != 0 else { return "0" }
        return qtyFormatter.string(from: NSNumber(value: v)) ?? String(format: "%g", v)
    }

    static func workday(_ v: Double) -> String {
        v == 0 ? "—" : String(format: "%.2f", v)
    }

    static func rate(_ v: Double) -> String {
        String(format: "%.3f%%", v)
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
