import Foundation

// =============================================================================
// XLSX 读取：sharedStrings + workbook + worksheet，全部用系统 XMLParser
// 只关心「单元格值」，不处理样式/公式/图表——概预算导入只需要值。
// =============================================================================

struct XlsxSheet {
    var name: String
    var rows: [[String]]

    var columnCount: Int { rows.map { $0.count }.max() ?? 0 }
    var rowCount: Int { rows.count }

    /// 第 r 行（0-based）单元格
    func cell(_ r: Int, _ c: Int) -> String {
        guard r >= 0, r < rows.count, c >= 0, c < rows[r].count else { return "" }
        return rows[r][c]
    }
}

enum XlsxReader {

    /// 读取工作簿全部工作表
    static func read(url: URL) throws -> [XlsxSheet] {
        let zip = try ZipReader(url: url)
        let shared = try readSharedStrings(zip)
        let sheets = try readWorkbookMeta(zip)
        let rels = try readWorkbookRels(zip)

        var result: [XlsxSheet] = []
        for meta in sheets {
            let target = rels[meta.rId] ?? "worksheets/sheet1.xml"
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard zip.contains(path) else { continue }
            let data = try zip.data(for: path)
            let rows = try SheetParser(shared: shared).parse(data)
            result.append(XlsxSheet(name: meta.name, rows: rows))
        }
        return result
    }

    // MARK: - sharedStrings.xml

    private static func readSharedStrings(_ zip: ZipReader) throws -> [String] {
        guard zip.contains("xl/sharedStrings.xml") else { return [] }
        let data = try zip.data(for: "xl/sharedStrings.xml")
        return try SharedStringsParser().parse(data)
    }

    // MARK: - workbook.xml

    private static func readWorkbookMeta(_ zip: ZipReader) throws -> [(name: String, rId: String)] {
        guard zip.contains("xl/workbook.xml") else { throw ZipError.entryNotFound("xl/workbook.xml") }
        let data = try zip.data(for: "xl/workbook.xml")
        return try WorkbookParser().parse(data)
    }

    private static func readWorkbookRels(_ zip: ZipReader) throws -> [String: String] {
        let path = "xl/_rels/workbook.xml.rels"
        guard zip.contains(path) else { return [:] }
        let data = try zip.data(for: path)
        return try RelsParser().parse(data)
    }
}

// MARK: - 解析器

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var items: [String] = []
    private var buffer = ""
    private var inSI = false
    private var skip = false     // 跳过 rPh（注音）等非正文

    func parse(_ data: Data) throws -> [String] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "si" { inSI = true; buffer = "" }
        if elementName == "rPh" { skip = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inSI && !skip { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "rPh" { skip = false }
        if elementName == "si" { items.append(buffer); inSI = false; buffer = "" }
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    private var sheets: [(name: String, rId: String)] = []

    func parse(_ data: Data) throws -> [(name: String, rId: String)] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return sheets
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "sheet", let name = attributeDict["name"] else { return }
        let rId = attributeDict["r:id"] ?? attributeDict["id"] ?? "rId1"
        sheets.append((name, rId))
    }
}

private final class RelsParser: NSObject, XMLParserDelegate {
    private var map: [String: String] = [:]

    func parse(_ data: Data) throws -> [String: String] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return map
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Relationship", let id = attributeDict["Id"],
              let target = attributeDict["Target"] else { return }
        // 只关心 worksheet 关系
        if target.contains("worksheets/") { map[id] = target }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private var cells: [Int: [Int: String]] = [:]
    private var currentRow = -1
    private var currentCol = -1
    private var cellType = ""
    private var cellText = ""
    private var capture = false
    private var maxRow = 0
    private var maxCol = -1

    init(shared: [String]) { self.shared = shared }

    func parse(_ data: Data) throws -> [[String]] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()

        guard maxRow >= 0, maxCol >= 0 else { return [] }
        var grid = [[String]](repeating: [String](repeating: "", count: maxCol + 1), count: maxRow + 1)
        for (r, cols) in cells {
            for (c, v) in cols where r <= maxRow && c <= maxCol {
                grid[r][c] = v
            }
        }
        return grid
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "row":
            if let r = attributeDict["r"], let v = Int(r) {
                currentRow = v - 1
            } else {
                currentRow += 1
            }
            currentCol = -1
            maxRow = max(maxRow, currentRow)
        case "c":
            cellText = ""
            cellType = attributeDict["t"] ?? ""
            if let ref = attributeDict["r"] {
                currentCol = Self.columnIndex(ref)
            } else {
                currentCol += 1
            }
            maxCol = max(maxCol, currentCol)
        case "v", "t":
            capture = true   // t 用于 inlineStr，v 用于普通值/共享字符串索引
        case "f":
            capture = false  // 公式文本不要
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture { cellText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "v" || elementName == "t" { capture = false }
        if elementName == "c", currentRow >= 0, currentCol >= 0 {
            let raw = cellText.trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String
            if cellType == "s" {
                let idx = Int(raw) ?? -1
                value = (idx >= 0 && idx < shared.count) ? shared[idx] : ""
            } else {
                value = raw
            }
            cells[currentRow, default: [:]][currentCol] = value
        }
    }

    /// "AB12" → 27（0-based 列号）
    static func columnIndex(_ ref: String) -> Int {
        var col = 0
        for ch in ref.uppercased() {
            guard let ascii = ch.asciiValue, ascii >= 65, ascii <= 90 else { break }
            col = col * 26 + Int(ascii - 64)
        }
        return max(col - 1, 0)
    }
}
