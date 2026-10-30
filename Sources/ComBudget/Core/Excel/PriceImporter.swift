import Foundation

// =============================================================================
// 价格库 Excel 导入
//
// 询价/价格册通常是这样几列：类型（主材/机械/仪表）、名称、规格、单位、单价。
// 列位置不固定 → 和定额导入一样做成「可配置 + 自动识别」，
// 导入是 upsert（类型+名称+规格+单位 唯一），重复导同一份清单不会翻倍。
// =============================================================================

/// 价格导入列配置（0-based；-1 表示该列不存在）
/// 默认值与 `PriceImporter.writeTemplate` 生成的模板保持一致
/// （类型 / 名称 / 规格程式 / 单位 / 单价 / 价格来源）
struct PriceImportConfig {
    var kindColumn: Int = 0
    var nameColumn: Int = 1
    var specColumn: Int = 2
    var unitColumn: Int = 3
    var priceColumn: Int = 4
    var sourceColumn: Int = 5
    var headerRow: Int = 0
    var sheetIndex: Int = 0

    static let kindAliases = ["类型", "资源类型", "类别"]
    static let nameAliases = ["名称", "材料名称", "设备名称", "资源名称", "品名"]
    static let specAliases = ["规格", "规格程式", "型号", "规格型号"]
    static let unitAliases = ["单位", "计量单位"]
    static let priceAliases = ["单价", "价格", "单价（元）", "单价(元)", "预算价", "信息价"]
    static let sourceAliases = ["来源", "备注", "说明", "价格来源", "期号"]

    static func detectColumns(from header: [String]) -> PriceImportConfig {
        var cfg = PriceImportConfig()
        for (i, raw) in header.enumerated() {
            let h = raw.trimmingCharacters(in: .whitespaces)
            if cfg.kindColumn == 0, kindAliases.contains(where: { h.contains($0) }) {
                cfg.kindColumn = i
            } else if cfg.nameColumn == 1, nameAliases.contains(where: { h.contains($0) }) {
                cfg.nameColumn = i
            } else if !specAliases.isEmpty, cfg.specColumn < 0, specAliases.contains(where: { h.contains($0) }) {
                cfg.specColumn = i
            } else if cfg.unitColumn == 2, unitAliases.contains(where: { h == $0 }) {
                cfg.unitColumn = i
            } else if cfg.priceColumn == 3, priceAliases.contains(where: { h.contains($0) }) {
                cfg.priceColumn = i
            } else if cfg.sourceColumn < 0, sourceAliases.contains(where: { h.contains($0) }) {
                cfg.sourceColumn = i
            }
        }
        return cfg
    }
}

enum PriceImporter {

    /// 读价格表（不写库），返回可入库的条目 + 被跳过的行 + 单价有问题的行
    static func read(url: URL, config: PriceImportConfig) throws
        -> (entries: [PriceEntry], skipped: Int, invalid: [String]) {
        let sheets = try XlsxReader.read(url: url)
        guard !sheets.isEmpty else { throw ImportError.emptyWorkbook }
        let sheet = sheets[min(max(config.sheetIndex, 0), sheets.count - 1)]
        let start = config.headerRow >= 0 ? config.headerRow + 1 : 0
        guard start < sheet.rows.count else { throw ImportError.noRows }

        var entries: [PriceEntry] = []
        var skipped = 0
        var invalid: [String] = []

        for r in start..<sheet.rows.count {
            let name = sheet.cell(r, config.nameColumn).trimmingCharacters(in: .whitespaces)
            let priceText = sheet.cell(r, config.priceColumn)
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "，", with: "")
                .trimmingCharacters(in: .whitespaces)
            let kindText = sheet.cell(r, config.kindColumn).trimmingCharacters(in: .whitespaces)

            if name.isEmpty && priceText.isEmpty { skipped += 1; continue }
            guard !name.isEmpty else { skipped += 1; continue }

            guard let price = Double(priceText), price >= 0 else {
                invalid.append("第 \(r + 1) 行 \(name)：单价「\(priceText)」不是有效数字")
                continue
            }

            var entry = PriceEntry(name: name,
                                   spec: config.specColumn >= 0 ? sheet.cell(r, config.specColumn) : "",
                                   unit: config.unitColumn >= 0 ? sheet.cell(r, config.unitColumn) : "",
                                   unitPrice: price,
                                   source: config.sourceColumn >= 0 ? sheet.cell(r, config.sourceColumn) : "")
            entry.kind = kind(of: kindText) ?? .mainMaterial
            entries.append(entry)
        }
        return (entries, skipped, invalid)
    }

    /// 类型的常见写法归一（「主要材料」「主材」「材料」都算主材）
    static func kind(of text: String) -> ResourceKind? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.contains("仪表") || t.contains("仪器") { return .instrument }
        if t.contains("机械") || t.contains("台班") { return .machine }
        if t.contains("设备") { return .equipment }
        if t.contains("材") { return .mainMaterial }
        return nil
    }

    /// 生成空白价格模板（界面「下载模板」按钮用）
    static func writeTemplate(to url: URL) throws {
        let sheet = XlsxSheetData(name: "价格库", rows: [
            [.text("资源类型"), .text("名称"), .text("规格程式"), .text("单位"), .text("单价（元）"), .text("价格来源")],
            [.text("主材"), .text("光缆接头盒"), .text("12芯"), .text("个"), .number(58), .text("示例价")],
            [.text("主材"), .text("螺栓（M12×100 以内）"), .text(""), .text("套"), .number(2.6), .text("示例价")],
            [.text("机械"), .text("汽车式起重机（5t）"), .text(""), .text("台班"), .number(680), .text("示例价")],
            [.text("仪表"), .text("地下管线探测仪"), .text(""), .text("台班"), .number(120), .text("示例价")]
        ], columnWidths: [10, 28, 16, 8, 12, 16])

        let help = XlsxSheetData(name: "填写说明", rows: [
            [.text("列"), .text("含义"), .text("是否必填")],
            [.text("A"), .text("资源类型：主材/机械/仪表/设备（写「材料」也算主材）"), .text("选填，默认主材")],
            [.text("B"), .text("名称（与定额库里的资源名称一致最好）"), .text("必填")],
            [.text("C"), .text("规格程式"), .text("选填")],
            [.text("D"), .text("单位（套/个/米/台班…）"), .text("必填，套价时要对单位")],
            [.text("E"), .text("单价（元）"), .text("必填")],
            [.text("F"), .text("价格来源 / 期号"), .text("选填")],
            [.blank, .blank, .blank],
            [.text("提示"), .text("重复导入同一份清单不会翻倍：按 类型+名称+规格+单位 覆盖更新。"), .blank],
            [.text("提示"), .text("套价时要求单位一致；名称不一致时会退化为「忽略括号型号」的模糊匹配。"), .blank]
        ], columnWidths: [6, 54, 14])

        try XlsxWriter.write(sheets: [sheet, help], to: url)
    }
}
