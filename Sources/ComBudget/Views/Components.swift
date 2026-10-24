import SwiftUI
import AppKit

// =============================================================================
// 通用组件
// =============================================================================

/// 数字输入框（工程量 / 单价 / 费率）
struct NumberField: View {
    @Binding var value: Double
    var fractionDigits: ClosedRange<Int> = 0...4
    var alignment: TextAlignment = .trailing
    var width: CGFloat = 66
    var editable: Bool = true

    var body: some View {
        TextField("", value: $value,
                  format: .number.precision(.fractionLength(fractionDigits)))
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .font(.system(size: 12, design: .rounded))
            .monospacedDigit()
            .frame(width: width)
            .disabled(!editable)
    }
}

/// 汇总小卡
struct StatTile: View {
    let title: String
    let value: String
    var tint: Color = .primary
    var emphasized: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: emphasized ? 14 : 12,
                              weight: emphasized ? .semibold : .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(minWidth: 74, alignment: .leading)
    }
}

/// 属性分组卡片
struct FieldGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// 表单一行
struct FormRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 56
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            content
        }
    }
}

/// 只读表格预览（报表预览用）
struct ReportTableView: View {
    let table: ReportTable

    private func widths(total: CGFloat) -> [CGFloat] {
        let sum = table.widths.reduce(0, +)
        return table.widths.map { $0 / max(sum, 0.0001) * total }
    }

    var body: some View {
        GeometryReader { geo in
            let ws = widths(total: max(geo.size.width - 24, 700))
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(table.title)
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                    if !table.subtitle.isEmpty {
                        Text(table.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    rowView(table.header, ws: ws, bold: true, background: .gray.opacity(0.12))
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        rowView(row, ws: ws)
                    }
                    ForEach(Array(table.footers.enumerated()), id: \.offset) { _, row in
                        rowView(row, ws: ws, bold: true, background: .gray.opacity(0.08))
                    }
                }
                .padding(10)
            }
        }
    }

    private func rowView(_ cells: [String], ws: [CGFloat], bold: Bool = false,
                         background: Color? = nil) -> some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { i in
                let right = i < table.rightAligned.count && table.rightAligned[i]
                Text(cells[i])
                    .font(.system(size: 11, weight: bold ? .semibold : .regular))
                    .monospacedDigit()
                    .lineLimit(2)
                    .frame(width: i < ws.count ? ws[i] : 60,
                           alignment: right ? .trailing : .leading)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 3)
                    .overlay(Rectangle().stroke(Color.gray.opacity(0.3), lineWidth: 0.4))
            }
        }
        .background(background ?? Color.clear)
    }
}

// MARK: - 文件面板

enum FilePanels {
    static func save(name: String, ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if !ext.isEmpty {
            panel.allowedContentTypes = [.init(filenameExtension: ext) ?? .data]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func open(ext: String, multiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        if !ext.isEmpty {
            panel.allowedContentTypes = [.init(filenameExtension: ext) ?? .data]
        }
        return panel.runModal() == .OK ? panel.urls : []
    }
}
