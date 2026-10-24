import Foundation

// =============================================================================
// Excel 模板批量导入
//
// 流程：读表 → 按列配置取「定额编号/工程量/备注」→ 批量匹配定额库
//      → 逐行校验（编号不存在 / 工程量异常 / 重复行）→ 生成报告
//      → 用户确认后一次性入库（事务）
//
// 列配置可自定义，所以模板本身不需要固定格式：
// 只要有一列是定额编号、一列是工程量，就能导。
// =============================================================================

/// 导入列配置（0-based 列号；-1 表示该列不存在）
struct ImportConfig {
    var codeColumn: Int = 0
    var quantityColumn: Int = 1
    var noteColumn: Int = 2
    var nameColumn: Int = -1
    var unitColumn: Int = -1
    var headerRow: Int = 0        // 表头所在行；-1 表示无表头
    var sheetIndex: Int = 0
    var defaultQuantity: Double = 1

    /// 常见表头别名，用于自动识别
    static let codeAliases = ["定额编号", "定额号", "编号", "子目编号", "定额编码"]
    static let quantityAliases = ["工程量", "数量", "工程数量"]
    static let noteAliases = ["备注", "说明", "工作内容"]
    static let nameAliases = ["定额名称", "名称", "子目名称"]
    static let unitAliases = ["单位", "计量单位"]

    static func detectColumns(from header: [String]) -> ImportConfig {
        var cfg = ImportConfig()
        for (i, raw) in header.enumerated() {
            let h = raw.trimmingCharacters(in: .whitespaces)
            if codeAliases.contains(where: { h.contains($0) }) && cfg.codeColumn == 0 {
                cfg.codeColumn = i
            } else if quantityAliases.contains(where: { h.contains($0) }) {
                cfg.quantityColumn = i
            } else if nameAliases.contains(where: { h.contains($0) }) {
                if cfg.nameColumn < 0 { cfg.nameColumn = i }
            } else if unitAliases.contains(where: { h == $0 }) {
                if cfg.unitColumn < 0 { cfg.unitColumn = i }
            } else if noteAliases.contains(where: { h.contains($0) }) {
                cfg.noteColumn = i
            }
        }
        return cfg
    }
}

enum ImportRowStatus: String {
    case ok        = "正常"
    case unknown   = "编号不存在"
    case badQty    = "工程量异常"
    case duplicate = "重复行"
    case empty     = "空行"
}

struct ImportRow: Identifiable {
    var id = UUID()
    var lineNo: Int              // 对应 Excel 行号（1-based，方便用户回表核对）
    var code: String
    var name: String
    var unit: String
    var quantity: Double?
    var note: String
    var status: ImportRowStatus
    var message: String = ""
    var quota: QuotaItem?

    /// 可入库：正常行 + 重复行（重复行只提示不拦截，用户可能确实要重复列项）
    var isImportable: Bool { status == .ok || status == .duplicate }
}

struct ImportReport {
    var fileName: String = ""
    var sheetName: String = ""
    var headers: [String] = []
    var rows: [ImportRow] = []

    var okCount: Int { rows.filter { $0.status == .ok }.count }
    var unknownCount: Int { rows.filter { $0.status == .unknown }.count }
    var badQtyCount: Int { rows.filter { $0.status == .badQty }.count }
    var duplicateCount: Int { rows.filter { $0.status == .duplicate }.count }
    var emptyCount: Int { rows.filter { $0.status == .empty }.count }
    var importableRows: [ImportRow] { rows.filter { $0.isImportable } }
    var hasBlockingIssue: Bool { unknownCount > 0 || badQtyCount > 0 }

    var summaryText: String {
        "共 \(rows.count) 行：可导入 \(importableRows.count)，编号不存在 \(unknownCount)，工程量异常 \(badQtyCount)，重复行 \(duplicateCount)，空行 \(emptyCount)"
    }
}

enum ExcelImporter {

    // MARK: - 分析（不写库）

    /// 读取并校验 Excel，返回报告；不做任何数据库写入
    static func analyze(url: URL, config: ImportConfig, quota: QuotaStore) throws -> ImportReport {
        let sheets = try XlsxReader.read(url: url)
        guard !sheets.isEmpty else { throw ImportError.emptyWorkbook }

        let idx = min(max(config.sheetIndex, 0), sheets.count - 1)
        let sheet = sheets[idx]

        var report = ImportReport(fileName: url.lastPathComponent, sheetName: sheet.name)
        let headerRowIndex = config.headerRow
        if headerRowIndex >= 0 && headerRowIndex < sheet.rows.count {
            report.headers = sheet.rows[headerRowIndex]
        }

        let startRow = headerRowIndex >= 0 ? headerRowIndex + 1 : 0
        guard startRow < sheet.rows.count else { throw ImportError.emptyWorkbook }

        // 一次取出所有编号对应定额，避免逐行查库
        var codes: [String] = []
        for r in startRow..<sheet.rows.count {
            let code = sheet.cell(r, config.codeColumn).trimmingCharacters(in: .whitespaces)
            if !code.isEmpty { codes.append(code) }
        }
        let map = try quota.items(codes: codes)

        var seen: Set<String> = []
        for r in startRow..<sheet.rows.count {
            let code = sheet.cell(r, config.codeColumn).trimmingCharacters(in: .whitespaces)
            let qtyText = sheet.cell(r, config.quantityColumn).trimmingCharacters(in: .whitespaces)
            let note = config.noteColumn >= 0 ? sheet.cell(r, config.noteColumn) : ""

            if code.isEmpty && qtyText.isEmpty && note.isEmpty {
                report.rows.append(ImportRow(lineNo: r + 1, code: "", name: "", unit: "",
                                             quantity: nil, note: "", status: .empty))
                continue
            }

            var row = ImportRow(lineNo: r + 1, code: code, name: "", unit: "",
                                quantity: nil, note: note, status: .ok)

            // 1) 工程量
            let cleanedQty = qtyText.replacingOccurrences(of: ",", with: "")
            if cleanedQty.isEmpty {
                row.quantity = config.defaultQuantity
                row.message = "工程量为空，按默认值 \(Fmt.quantity(config.defaultQuantity)) 处理"
            } else if let q = Double(cleanedQty), q > 0 {
                row.quantity = q
            } else {
                row.quantity = nil
                row.status = .badQty
                row.message = "工程量「\(qtyText)」不是有效正数"
            }

            // 2) 定额编号
            if code.isEmpty {
                row.status = .unknown
                row.message = "定额编号为空"
            } else if let q = map[code] {
                row.quota = q
                row.name = q.name
                row.unit = q.unit
            } else {
                row.status = .unknown
                row.message = "定额库中不存在编号 \(code)"
            }

            // 3) 重复行（同编号出现多次）——优先级低于前两类错误
            if row.status == .ok {
                if seen.contains(code) {
                    row.status = .duplicate
                    row.message = "与前面的行定额编号重复（仍可导入）"
                } else {
                    seen.insert(code)
                }
            } else if !code.isEmpty {
                seen.insert(code)
            }

            report.rows.append(row)
        }
        return report
    }

    /// 把报告里可导入的行写进工程（单事务，上百行也很快）
    static func commit(report: ImportReport, projectID: Int64,
                       techPrice: Double, laborPrice: Double,
                       store: ProjectStore) throws -> Int {
        let rows = report.importableRows
        guard !rows.isEmpty else { return 0 }
        return try store.transaction {
            var n = 0
            for row in rows {
                guard let quota = row.quota, let qty = row.quantity else { continue }
                _ = try store.insertItem(projectID: projectID, quota: quota, quantity: qty,
                                         techPrice: techPrice, laborPrice: laborPrice,
                                         note: row.note)
                n += 1
            }
            return n
        }
    }

    // MARK: - 生成空白导入模板

    static func writeTemplate(to url: URL) throws {
        let header: [XlsxCell] = [.text("定额编号"), .text("工程量"), .text("备注")]
        let sheet = XlsxSheetData(name: "定额清单", rows: [
            header,
            [.text("TXL1-001"), .number(12), .text("示例：架空光缆 1200m")],
            [.text("TXL1-003"), .number(4), .text("光缆接续 4 头")],
            [.text("TXS1-001"), .number(2), .text("光交箱 2 台")]
        ], columnWidths: [16, 12, 28])

        let help = XlsxSheetData(name: "填写说明", rows: [
            [.text("列")        , .text("含义"), .text("是否必填")],
            [.text("A")         , .text("定额编号（须与定额库一致）"), .text("必填")],
            [.text("B")         , .text("工程量（正数）"), .text("必填")],
            [.text("C")         , .text("备注（可空）"), .text("选填")],
            [.text("")          , .text(""), .text("")],
            [.text("提示"), .text("列位置可在导入向导里重新指定；表头行也可调整。"), .text("")],
            [.text("提示"), .text("编号不存在或工程量非正数的行会被拦下，不会写入工程。"), .text("")]
        ], columnWidths: [6, 46, 10])

        try XlsxWriter.write(sheets: [sheet, help], to: url)
    }
}

enum ImportError: LocalizedError {
    case emptyWorkbook
    case noRows

    var errorDescription: String? {
        switch self {
        case .emptyWorkbook: return "Excel 里没有可读取的工作表或数据行"
        case .noRows:        return "没有可导入的数据行"
        }
    }
}

// MARK: - 定额库导入

/// 定额库 Excel 列配置
struct QuotaImportConfig {
    var codeColumn: Int = 0
    var nameColumn: Int = 1
    var unitColumn: Int = 2
    var workdayColumn: Int = 3        // 技工工日
    var laborWorkdayColumn: Int = -1  // 普工工日（可选）
    var chapterColumn: Int = 4
    var sectionColumn: Int = 5
    var noteColumn: Int = -1
    var headerRow: Int = 0
    var sheetIndex: Int = 0
}

extension ExcelImporter {

    /// 从 Excel 读定额库（真实 451 数据入库用）
    static func readQuotaSheet(url: URL, config: QuotaImportConfig) throws -> (items: [QuotaItem], skipped: Int) {
        let sheets = try XlsxReader.read(url: url)
        guard !sheets.isEmpty else { throw ImportError.emptyWorkbook }
        let sheet = sheets[min(max(config.sheetIndex, 0), sheets.count - 1)]
        let start = config.headerRow >= 0 ? config.headerRow + 1 : 0
        guard start < sheet.rows.count else { throw ImportError.noRows }

        var items: [QuotaItem] = []
        var skipped = 0
        for r in start..<sheet.rows.count {
            let code = sheet.cell(r, config.codeColumn).trimmingCharacters(in: .whitespaces)
            let name = sheet.cell(r, config.nameColumn).trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty, !name.isEmpty else { skipped += 1; continue }

            let workdayText = sheet.cell(r, config.workdayColumn)
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            let laborText = config.laborWorkdayColumn >= 0
                ? sheet.cell(r, config.laborWorkdayColumn)
                    .replacingOccurrences(of: ",", with: "")
                    .trimmingCharacters(in: .whitespaces)
                : ""
            items.append(QuotaItem(
                code: code,
                name: name,
                unit: config.unitColumn >= 0 ? sheet.cell(r, config.unitColumn) : "",
                chapter: config.chapterColumn >= 0 ? sheet.cell(r, config.chapterColumn) : "",
                section: config.sectionColumn >= 0 ? sheet.cell(r, config.sectionColumn) : "",
                techWorkday: Double(workdayText) ?? 0,
                laborWorkday: Double(laborText) ?? 0,
                isBuiltin: false
            ))
        }
        return (items, skipped)
    }
}
