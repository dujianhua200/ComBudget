import Foundation
import AppKit
import PDFKit

// =============================================================================
// 导出：Excel（.xlsx）与 PDF
//
// PDF 用 Core Graphics 直接分页绘制（A4 横向），而不是把 SwiftUI 视图截图：
//   · 矢量文字，打印清晰
//   · 分页、表头重复、页码由我们完全控制
// =============================================================================

enum ExportError: LocalizedError {
    case pdfContextFailed
    case printFailed

    var errorDescription: String? {
        switch self {
        case .pdfContextFailed: return "无法创建 PDF 上下文"
        case .printFailed:      return "打印任务未能完成"
        }
    }
}

// MARK: - Excel

enum ExcelExporter {
    /// 一次导出四张表到同一个工作簿（汇总/明细/主材/机械仪表）
    static func export(tables: [ReportTable], to url: URL) throws {
        let sheets: [XlsxSheetData] = tables.map { t in
            var rows: [[XlsxCell]] = []
            rows.append([.text(t.title)])
            if !t.subtitle.isEmpty { rows.append([.text(t.subtitle)]) }
            rows.append([])
            rows.append(t.header.map { .text($0) })
            for r in t.rows { rows.append(r.map { XlsxCell.infer($0) }) }
            for f in t.footers { rows.append(f.map { XlsxCell.infer($0) }) }

            let widths = t.widths.map { max(6.0, Double($0) * 12.0) }
            return XlsxSheetData(name: t.title, rows: rows, columnWidths: widths)
        }
        try XlsxWriter.write(sheets: sheets, to: url)
    }
}

// MARK: - PDF

enum PDFExporter {

    private static let pageSize = CGSize(width: 842, height: 595)   // A4 横向
    private static let margin: CGFloat = 28
    private static let lineH: CGFloat = 10.0

    static func export(tables: [ReportTable], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { throw ExportError.pdfContextFailed }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.pdfContextFailed
        }
        draw(tables: tables, into: ctx)
        ctx.closePDF()
    }

    /// 打印：先落一份临时 PDF，再交给 PDFKit 走系统打印面板
    /// （这样做的好处：分页/缩放/页码范围由系统面板处理，行为与预览一致）
    static func print(tables: [ReportTable]) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComBudget-print-\(UUID().uuidString).pdf")
        try export(tables: tables, to: tmp)
        guard let doc = PDFDocument(url: tmp) else { throw ExportError.printFailed }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = .landscape
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else {
            throw ExportError.printFailed
        }
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }

    // MARK: - 绘制

    private static func draw(tables: [ReportTable], into ctx: CGContext) {
        var pageIndex = 0
        let contentWidth = pageSize.width - margin * 2

        let headerFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 8)
        let footerFont = NSFont.systemFont(ofSize: 8, weight: .medium)
        let titleFont = NSFont.systemFont(ofSize: 14, weight: .bold)
        let subFont = NSFont.systemFont(ofSize: 8)

        for table in tables {
            let totalWeight = table.widths.reduce(0, +)
            let colWidths = table.widths.map { $0 / max(totalWeight, 0.0001) * contentWidth }

            var cursorY: CGFloat = margin

            func measure(_ cells: [String], _ font: NSFont) -> CGFloat {
                var lines = 1
                for (i, cell) in cells.enumerated() where i < colWidths.count {
                    let w = colWidths[i] - 5
                    if w <= 8 || cell.isEmpty { continue }
                    let r = (cell as NSString).boundingRect(
                        with: CGSize(width: w, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin],
                        attributes: [.font: font])
                    lines = max(lines, Int(ceil(r.height / lineH)))
                }
                return CGFloat(lines) * lineH + 4
            }

            func drawRow(_ cells: [String], _ font: NSFont, height: CGFloat, fill: NSColor?) {
                var x = margin
                for (i, cell) in cells.enumerated() where i < colWidths.count {
                    let w = colWidths[i]
                    let rect = CGRect(x: x, y: cursorY, width: w, height: height)
                    if let fill {
                        fill.setFill()
                        rect.fill()
                    }
                    NSColor(white: 0.45, alpha: 1).setStroke()
                    let path = NSBezierPath(rect: rect)
                    path.lineWidth = 0.4
                    path.stroke()

                    if !cell.isEmpty {
                        let para = NSMutableParagraphStyle()
                        let right = i < table.rightAligned.count && table.rightAligned[i]
                        para.alignment = right ? .right : .left
                        para.lineBreakMode = .byTruncatingTail
                        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
                        (cell as NSString).draw(with: CGRect(x: x + 2.5, y: cursorY + 2,
                                                             width: w - 5, height: height - 3),
                                                options: [.usesLineFragmentOrigin],
                                                attributes: attrs)
                    }
                    x += w
                }
                cursorY += height
            }

            func drawTitleBlock() {
                let para = NSMutableParagraphStyle()
                para.alignment = .center
                (table.title as NSString).draw(
                    with: CGRect(x: margin, y: cursorY, width: contentWidth, height: 20),
                    options: [.usesLineFragmentOrigin],
                    attributes: [.font: titleFont, .paragraphStyle: para])
                cursorY += 21

                guard !table.subtitle.isEmpty else { return }
                let r = (table.subtitle as NSString).boundingRect(
                    with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin], attributes: [.font: subFont])
                (table.subtitle as NSString).draw(
                    with: CGRect(x: margin, y: cursorY, width: contentWidth, height: r.height + 2),
                    options: [.usesLineFragmentOrigin],
                    attributes: [.font: subFont, .paragraphStyle: para])
                cursorY += r.height + 6
            }

            func beginPage() {
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                // 转成「左上角为原点、y 向下」的坐标系，方便自上而下排版
                ctx.translateBy(x: 0, y: pageSize.height)
                ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                pageIndex += 1
                cursorY = margin
            }

            func endPage() {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8),
                    .foregroundColor: NSColor.gray
                ]
                let text = "第 \(pageIndex) 页　·　ComBudget"
                let size = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: pageSize.width - margin - size.width,
                                      y: pageSize.height - margin + 8), withAttributes: attrs)
                ctx.restoreGState()
                ctx.endPDFPage()
            }

            beginPage()
            drawTitleBlock()
            drawRow(table.header, headerFont, height: measure(table.header, headerFont),
                    fill: NSColor(white: 0.93, alpha: 1))

            let bodyRows = table.rows + table.footers
            for (idx, row) in bodyRows.enumerated() {
                let isFooter = idx >= table.rows.count
                let h = measure(row, bodyFont)
                if cursorY + h > pageSize.height - margin - 16 {
                    endPage()
                    beginPage()
                    drawRow(table.header, headerFont, height: measure(table.header, headerFont),
                            fill: NSColor(white: 0.93, alpha: 1))
                }
                drawRow(row, isFooter ? footerFont : bodyFont, height: h,
                        fill: isFooter ? NSColor(white: 0.96, alpha: 1) : nil)
            }
            endPage()
        }
    }
}
