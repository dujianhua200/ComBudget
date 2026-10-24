import Foundation

// =============================================================================
// XLSX 写出：多工作表、文本/数值区分、列宽
// 用 inlineStr 写字符串，省掉共享字符串表，结构最简、Excel 完全兼容。
// =============================================================================

enum XlsxCell {
    case text(String)
    case number(Double)
    case blank

    /// 由字符串推断：纯数字（允许千分位逗号）写数值，其它写文本
    static func infer(_ s: String) -> XlsxCell {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        let cleaned = trimmed.replacingOccurrences(of: ",", with: "")
        let allowed = CharacterSet(charactersIn: "0123456789.-+")
        if !cleaned.isEmpty, cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }),
           let d = Double(cleaned) {
            return .number(d)
        }
        return .text(trimmed)
    }
}

struct XlsxSheetData {
    var name: String
    var rows: [[XlsxCell]]
    var columnWidths: [Double]

    init(name: String, rows: [[XlsxCell]], columnWidths: [Double] = []) {
        self.name = name
        self.rows = rows
        self.columnWidths = columnWidths
    }
}

enum XlsxWriter {

    static func write(sheets: [XlsxSheetData], to url: URL) throws {
        var entries: [ZipWriter.Entry] = []

        func xml(_ pair: (String, String)) -> ZipWriter.Entry {
            ZipWriter.Entry(name: pair.0, data: Data(pair.1.utf8))
        }

        var contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        """
        for i in sheets.indices {
            contentTypes += """
            <Override PartName="/xl/worksheets/sheet\(i + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            """
        }
        contentTypes += "</Types>"

        entries.append(xml(("[Content_Types].xml", contentTypes)))
        entries.append(xml(("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """)))

        var workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>
        """
        for (i, sheet) in sheets.enumerated() {
            workbook += "<sheet name=\"\(escape(sanitizeSheetName(sheet.name, index: i)))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        workbook += "</sheets></workbook>"
        entries.append(xml(("xl/workbook.xml", workbook)))

        var rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """
        for i in sheets.indices {
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        rels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        rels += "</Relationships>"
        entries.append(xml(("xl/_rels/workbook.xml.rels", rels)))

        entries.append(xml(("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border/></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
        </styleSheet>
        """)))

        for (i, sheet) in sheets.enumerated() {
            entries.append(xml(("xl/worksheets/sheet\(i + 1).xml", sheetXML(sheet))))
        }

        let data = ZipWriter.archive(entries: entries)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 单表 XML

    private static func sheetXML(_ sheet: XlsxSheetData) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        """
        if !sheet.columnWidths.isEmpty {
            s += "<cols>"
            for (i, w) in sheet.columnWidths.enumerated() {
                s += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(String(format: "%.1f", w))\" customWidth=\"1\"/>"
            }
            s += "</cols>"
        }
        s += "<sheetData>"
        for (r, row) in sheet.rows.enumerated() {
            s += "<row r=\"\(r + 1)\">"
            for (c, cell) in row.enumerated() {
                let ref = "\(columnName(c))\(r + 1)"
                switch cell {
                case .blank:
                    break
                case .number(let d):
                    s += "<c r=\"\(ref)\"><v>\(formatNumber(d))</v></c>"
                case .text(let t):
                    s += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(t))</t></is></c>"
                }
            }
            s += "</row>"
        }
        s += "</sheetData></worksheet>"
        return s
    }

    private static func formatNumber(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return String(format: "%.6f", d)
    }

    private static func columnName(_ index: Int) -> String {
        var idx = index + 1
        var name = ""
        while idx > 0 {
            let rem = (idx - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + rem))) + name
            idx = (idx - 1) / 26
        }
        return name
    }

    private static func sanitizeSheetName(_ name: String, index: Int) -> String {
        var s = name
        for ch in ["[", "]", ":", "*", "?", "/", "\\"] {
            s = s.replacingOccurrences(of: ch, with: "_")
        }
        if s.isEmpty { s = "Sheet\(index + 1)" }
        return String(s.prefix(31))
    }

    private static func escape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        // 去掉 XML 不允许的控制字符
        out = out.unicodeScalars
            .filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 }
            .map { String($0) }
            .joined()
        return out
    }
}
