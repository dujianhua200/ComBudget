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

    // ---- v3 新增 ----
    /// 所属章（用于分组小计，插入时从定额库复制快照）
    var chapter: String = ""
    /// 定额系列（如 TXL1，分组小计的首选分组键）
    var series: String = ""
    /// 定额原工日（换算前的值，换算后仍然保留，便于回溯）
    var techWorkdayBase: Double = 0
    var laborWorkdayBase: Double = 0
    /// 换算痕迹，例如「洞内作业：技工×1.15 普工×1.15」
    var convNote: String = ""

    var effectiveTechWorkday: Double { techWorkday * quantity * workdayCoeff }
    var effectiveLaborWorkday: Double { laborWorkday * quantity * workdayCoeff }

    /// 尚未参与换算时的定额原值（老数据兜底）
    var baseTech: Double { techWorkdayBase == 0 ? techWorkday : techWorkdayBase }
    var baseLabor: Double { laborWorkdayBase == 0 ? laborWorkday : laborWorkdayBase }

    /// 分组键：优先用系列（TXL1/TGD2…），没有系列的补充定额归入「补充子目」
    var groupKey: String { series.isEmpty ? (isSupplement ? "补充子目" : "未分类") : series }
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

// =============================================================================
// 费用口径（451 号文 / 概预算编制规程）
//
//   建筑安装工程费 = 直接费 + 措施费 + 间接费 + 利润 + 税金
//     · 直接费 = 人工费（技工 + 普工）+ 材料费（主要材料 + 辅助材料）
//                + 机械使用费 + 仪表使用费
//     · 间接费 = 规费 + 企业管理费
//     · 税金   =（直接费 + 措施费 + 间接费 + 利润）× 税率
//   工程总造价 = 建筑安装工程费 + 设备工器具购置费 + 工程建设其他费 + 预备费
//
// 所有费率都是模板里的可编辑项：地区文件、招标文件怎么说就怎么改，
// 内置模板只是常用取值，界面里明确标注为「示例费率，需核定」。
// =============================================================================

/// 费用类别（决定金额归到哪个科目、报表怎么分组）
enum FeeKind: String, CaseIterable, Identifiable, Codable {
    case measures    = "措施费"
    case regulation  = "规费"
    case admin       = "企业管理费"
    case profit      = "利润"
    case tax         = "税金"
    case other       = "工程建设其他费"
    case contingency = "预备费"

    var id: String { rawValue }

    /// 计算与列报顺序（税金排在利润之后，预备费最后）
    var order: Int {
        switch self {
        case .measures:    return 0
        case .regulation:  return 1
        case .admin:       return 2
        case .profit:      return 3
        case .tax:         return 4
        case .other:       return 5
        case .contingency: return 6
        }
    }

    /// 是否计入建筑安装工程费（其他费、预备费单列在总造价里）
    var isInstallation: Bool { self != .other && self != .contingency }

    /// 旧模板里「间接费」是笼统的一项，现在拆成规费 + 企业管理费
    static func of(_ group: String) -> FeeKind? {
        if let k = FeeKind(rawValue: group) { return k }
        if group == "间接费" { return .admin }
        return nil
    }
}

enum FeeBase: String, CaseIterable, Identifiable, Codable {
    case labor        = "人工费"
    case laborMachine = "人工费+机械费"
    case direct       = "直接费"
    case beforeTax    = "税前造价"
    case installation = "建筑安装工程费"
    case projectTotal = "建安工程费+设备费+其他费"
    /// 旧模板兼容项
    case directPlus   = "直接费+措施费+间接费"

    var id: String { rawValue }

    /// 报表里基数写全称，列宽有限时用短名
    var full: String {
        switch self {
        case .beforeTax:    return "直接费+措施费+间接费+利润"
        case .projectTotal: return "建安工程费+设备费+其他费"
        default:            return rawValue
        }
    }
}

struct FeeRate: Identifiable, Hashable, Codable {
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

struct FeeTemplate: Identifiable, Hashable, Codable {
    var id: Int64 = 0
    var name: String = "默认取费模板"
    var isBuiltin: Bool = false
    var auxMaterialRate: Double = 0.3
    var note: String = ""
    var rates: [FeeRate] = []

    var sortedRates: [FeeRate] { rates.sorted { $0.sortIndex < $1.sortIndex } }
}

// MARK: - 价格库

/// 价格库一条记录（451 手册只有消耗量，单价来自价格册/市场价）
struct PriceEntry: Identifiable, Hashable {
    var id: Int64 = 0
    var kind: ResourceKind = .mainMaterial
    var name: String = ""
    var spec: String = ""
    var unit: String = ""
    var unitPrice: Double = 0
    var source: String = ""
    var updatedAt: Date = Date()

    /// 匹配用的归一化 key：去掉空格与全角括号内容无关性不做处理，
    /// 只规范空白字符，避免「螺栓 M12」与「螺栓 M12」因空格差异匹配不上
    var matchName: String {
        name.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 套价结果（用于界面告知「哪些资源没匹配上」，避免悄悄漏価格）
struct PriceApplyResult {
    var matched: Int = 0          // 成功套价的资源条数
    var unchanged: Int = 0        // 单价已存在且不允许覆盖，跳过的条数
    var missing: [String] = []    // 价格库里没有的资源（名称｜单位）
    var fuzzy: Int = 0            // 其中靠「名称匹配/忽略单位」命中的条数（需人工复核）

    var summary: String {
        "套价 \(matched) 项" + (unchanged > 0 ? "，跳过 \(unchanged) 项已填价" : "")
        + (missing.isEmpty ? "" : "，\(missing.count) 项无价格")
        + (fuzzy > 0 ? "，其中 \(fuzzy) 项为模糊匹配需复核" : "")
    }
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
    /// 直接费构成在 itemCost 里（人工/主材/辅材/机械/仪表）
    var measures: Double = 0       // 措施费
    var regulation: Double = 0     // 规费（社保、公积金、工伤保险…）
    var admin: Double = 0          // 企业管理费
    var profit: Double = 0
    var tax: Double = 0
    var otherFees: Double = 0      // 工程建设其他费（表五）
    var contingency: Double = 0    // 预备费

    var indirect: Double { regulation + admin }
    /// 建筑安装工程费
    var total: Double { itemCost.direct + measures + indirect + profit + tax }
    /// 直接费 + 措施费 + 间接费 + 利润（税前造价，税金的计算基数）
    var beforeTax: Double { itemCost.direct + measures + indirect + profit }

    /// 某个费用科目的合计
    func amount(of kind: FeeKind) -> Double {
        switch kind {
        case .measures:    return measures
        case .regulation:  return regulation
        case .admin:       return admin
        case .profit:      return profit
        case .tax:         return tax
        case .other:       return otherFees
        case .contingency: return contingency
        }
    }
    /// 工程总造价 = 建安工程费 + 设备购置费 + 其他费 + 预备费
    var grandTotal: Double {
        total + itemCost.equipment + otherFees + contingency
    }
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

    /// 系数：统一两位小数（工程口径习惯写成 1.15 / 1.30，而不是 1.3）
    static func coeff(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // MARK: - 人民币大写（预算表的「合计（大写）」栏）

    private static let upperDigits = ["零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖"]
    private static let upperUnits = ["", "拾", "佰", "仟"]
    private static let upperSections = ["", "万", "亿", "万亿"]

    private static func pow10(_ n: Int) -> Int {
        (0..<n).reduce(1) { acc, _ in acc * 10 }
    }

    /// 12345.67 → 壹万贰仟叁佰肆拾伍元陆角柒分（金额表惯用的大写写法）
    static func cnyUpper(_ amount: Double) -> String {
        guard amount >= 0.005 || amount <= -0.005 else { return "零元整" }
        let negative = amount < 0
        let value = Int64(round(min(abs(amount), 1e12) * 100))
        let yuan = value / 100
        let jiao = Int((value / 10) % 10)
        let fen = Int(value % 10)

        var result = ""
        var rest = yuan
        var sec = 0
        var needZero = false          // 低一节有前导零，高位接上去时要补「零」
        while rest > 0 {
            let g = Int(rest % 10000)
            var s = ""
            var zeroFlag = false
            for p in 0..<4 {
                let d = (g / pow10(p)) % 10
                if d == 0 {
                    if !s.isEmpty { zeroFlag = true }
                } else {
                    s = upperDigits[d] + upperUnits[p] + (zeroFlag ? "零" : "") + s
                    zeroFlag = false
                }
            }
            if !s.isEmpty {
                result = s + upperSections[sec] + (needZero ? "零" : "") + result
                needZero = g < 1000
            } else if !result.isEmpty {
                needZero = true
            }
            rest /= 10000
            sec += 1
        }
        var out = result + "元"
        if jiao == 0 && fen == 0 {
            out += "整"
        } else {
            out += jiao > 0 ? "\(upperDigits[jiao])角" : "零"
            out += fen > 0 ? "\(upperDigits[fen])分" : "整"
        }
        return (negative ? "负" : "") + out
    }
}
