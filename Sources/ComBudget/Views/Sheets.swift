import SwiftUI

// =============================================================================
// 三个弹窗：工程属性 / Excel 导入向导 / 报表预览
// =============================================================================

// MARK: - 工程属性

struct ProjectPropertiesView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Project

    init(project: Project) {
        _draft = State(initialValue: project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("工程属性").font(.system(size: 14, weight: .semibold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                row("工程名称") { TextField("", text: $draft.name).textFieldStyle(.roundedBorder) }
                row("工程编号") { TextField("", text: $draft.code).textFieldStyle(.roundedBorder) }
                row("工程类别") {
                    Picker("", selection: $draft.category) {
                        ForEach(ProjectCategory.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .labelsHidden()
                }
                row("专业") {
                    Picker("", selection: $draft.specialty) {
                        ForEach(Specialty.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .labelsHidden()
                }
                row("工程规模") { TextField("", text: $draft.scale).textFieldStyle(.roundedBorder) }
                row("建设单位") { TextField("", text: $draft.owner).textFieldStyle(.roundedBorder) }
                row("施工单位") { TextField("", text: $draft.contractor).textFieldStyle(.roundedBorder) }
                row("编制人") { TextField("", text: $draft.compiler).textFieldStyle(.roundedBorder) }
                row("审核人") { TextField("", text: $draft.reviewer).textFieldStyle(.roundedBorder) }
                row("取费标准") {
                    Picker("", selection: $draft.feeTemplateID) {
                        ForEach(app.templates) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    app.saveProject(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            content()
                .frame(width: 320)
        }
    }
}

// MARK: - Excel 导入向导

struct ImportWizardView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var url: URL?
    @State private var sheetNames: [String] = []
    @State private var headers: [String] = []
    @State private var config = ImportConfig()
    @State private var report: ImportReport?
    @State private var message = "支持 .xlsx；只需「定额编号 + 工程量」两列即可导入"
    @State private var messageColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Excel 批量导入").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Button("选择 Excel 文件") { pickFile() }
                Text(url?.lastPathComponent ?? "未选择文件")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !sheetNames.isEmpty {
                    Text("工作表").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("", selection: $config.sheetIndex) {
                        ForEach(Array(sheetNames.enumerated()), id: \.offset) { i, name in
                            Text(name).tag(i)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: config.sheetIndex) { _ in reloadHeaders() }

                    Text("表头行").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("", selection: $config.headerRow) {
                        Text("无表头").tag(-1)
                        ForEach(0..<6, id: \.self) { i in Text("第 \(i + 1) 行").tag(i) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .onChange(of: config.headerRow) { _ in reloadHeaders() }
                }
            }

            if !headers.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    columnPicker("定额编号", \.codeColumn, required: true)
                    columnPicker("工程量", \.quantityColumn, required: true)
                    columnPicker("备注", \.noteColumn, required: false)
                    columnPicker("名称", \.nameColumn, required: false)
                    columnPicker("单位", \.unitColumn, required: false)
                }
            }

            HStack(spacing: 8) {
                Button {
                    analyze()
                } label: {
                    Label("校验", systemImage: "checkmark.shield")
                }
                .disabled(url == nil)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(messageColor)
                    .lineLimit(2)
                Spacer()
            }

            if let report {
                reportList(report)
            } else {
                Text("校验后会逐行列出检查结果：编号不存在、工程量异常的行不会入库；重复行只提示。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("导入 \(report?.importableRows.count ?? 0) 条") {
                    if let report, app.commitImport(report) > 0 { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled((report?.importableRows.count ?? 0) == 0)
            }
        }
        .padding(16)
        .frame(width: 780)
    }

    // MARK: 子视图

    private func columnPicker(_ title: String,
                              _ keyPath: WritableKeyPath<ImportConfig, Int>,
                              required: Bool) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(required ? .primary : .secondary)
            Picker("", selection: Binding(
                get: { config[keyPath: keyPath] },
                set: { config[keyPath: keyPath] = $0; report = nil })) {
                if !required { Text("不使用").tag(-1) }
                ForEach(Array(headers.enumerated()), id: \.offset) { idx, h in
                    Text("\(columnName(idx)) 列 \(h.isEmpty ? "（空）" : h)").tag(idx)
                }
            }
            .labelsHidden()
            .frame(width: 260)
        }
    }

    private func reportList(_ report: ImportReport) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("行").frame(width: 42, alignment: .trailing)
                Text("定额编号").frame(width: 92, alignment: .leading)
                Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("工程量").frame(width: 70, alignment: .trailing)
                Text("状态").frame(width: 84, alignment: .leading)
                Text("说明").frame(width: 210, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(report.rows) { row in
                        HStack(spacing: 0) {
                            Text("\(row.lineNo)").frame(width: 42, alignment: .trailing)
                            Text(row.code)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 92, alignment: .leading)
                            Text(row.name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            Text(row.quantity.map { Fmt.quantity($0) } ?? "—")
                                .frame(width: 70, alignment: .trailing)
                            Text(row.status.rawValue)
                                .frame(width: 84, alignment: .leading)
                                .foregroundStyle(color(for: row.status))
                            Text(row.message)
                                .frame(width: 210, alignment: .leading)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .padding(.vertical, 2)
                        .background(row.isImportable ? Color.clear : Color.orange.opacity(0.08))
                    }
                }
            }
            .frame(height: 230)
        }
    }

    private func color(for status: ImportRowStatus) -> Color {
        switch status {
        case .ok:        return .green
        case .duplicate: return .orange
        case .unknown, .badQty: return .red
        case .empty:     return .secondary
        }
    }

    private func columnName(_ idx: Int) -> String {
        var i = idx + 1
        var s = ""
        while i > 0 {
            let r = (i - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            i = (i - 1) / 26
        }
        return s
    }

    // MARK: 动作

    private func pickFile() {
        guard let picked = FilePanels.open(ext: "xlsx").first else { return }
        url = picked
        report = nil
        do {
            let sheets = try XlsxReader.read(url: picked)
            sheetNames = sheets.map { $0.name }
            config.sheetIndex = 0
            reloadHeaders()
            message = "已读取 \(sheets.count) 个工作表，核对列映射后点「校验」"
            messageColor = .secondary
        } catch {
            message = error.localizedDescription
            messageColor = .red
        }
    }

    private func reloadHeaders() {
        guard let url else { return }
        do {
            let sheets = try XlsxReader.read(url: url)
            guard config.sheetIndex < sheets.count else { return }
            let sheet = sheets[config.sheetIndex]
            if config.headerRow >= 0 && config.headerRow < sheet.rows.count {
                headers = sheet.rows[config.headerRow]
            } else {
                headers = Array(repeating: "", count: max(sheet.columnCount, 5))
            }
            var detected = ImportConfig.detectColumns(from: headers)
            detected.headerRow = config.headerRow
            detected.sheetIndex = config.sheetIndex
            config = detected
            report = nil
        } catch {
            message = error.localizedDescription
            messageColor = .red
        }
    }

    private func analyze() {
        guard let url else { return }
        if let r = app.analyzeImport(url: url, config: config) {
            report = r
            message = r.summaryText
            messageColor = r.hasBlockingIssue ? .orange : .green
        }
    }
}

// MARK: - 报表预览

struct ReportPreviewView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    /// 勾选要导出/打印的表：投标文件常常只要表一 + 表二
    @State private var picked: Set<Int> = []

    private var tables: [ReportTable] { app.reportTables() }

    private var chosen: [ReportTable] { tables.indices.filter { picked.contains($0) }.map { tables[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("报表预览").font(.system(size: 14, weight: .semibold))
                Picker("", selection: $index) {
                    ForEach(Array(tables.enumerated()), id: \.offset) { i, t in
                        Text(t.title).tag(i)
                    }
                }
                .labelsHidden()
                .frame(width: 360)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)

            // 选表条：全选 / 常用（表一+表二）/ 逐张开关
            HStack(spacing: 6) {
                Text("导出范围").font(.system(size: 10)).foregroundStyle(.secondary)
                Button("全选") { picked = Set(tables.indices) }
                Button("只要计价表") { picked = Set(tables.indices.filter { $0 < 5 }) }
                Button("投标文件常用") { picked = [0, 1, 2] }
                Divider().frame(height: 12)
                ForEach(Array(tables.enumerated()), id: \.offset) { i, t in
                    Toggle(shortTitle(t.title), isOn: Binding(
                        get: { picked.contains(i) },
                        set: { on in
                            if on { picked.insert(i) } else { picked.remove(i) }
                        }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10))
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .onAppear { if picked.isEmpty { picked = Set(tables.indices) } }
            .onChange(of: tables.count) { _ in picked = Set(tables.indices) }

            Divider()

            if index < tables.count {
                ReportTableView(table: tables[index])
            }

            Divider()

            HStack(spacing: 8) {
                Text("\(index < tables.count ? tables[index].rows.count : 0) 行数据")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("已勾选 \(chosen.count)/\(tables.count) 张表")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard let url = FilePanels.save(name: saveName + ".xlsx", ext: "xlsx") else { return }
                    app.exportExcel(to: url, tables: chosen)
                } label: {
                    Label("导出 Excel", systemImage: "arrow.up.doc")
                }
                .disabled(chosen.isEmpty)
                Button {
                    guard let url = FilePanels.save(name: saveName + ".pdf", ext: "pdf") else { return }
                    app.exportPDF(to: url, tables: chosen)
                } label: {
                    Label("导出 PDF", systemImage: "arrow.up.doc.fill")
                }
                .disabled(chosen.isEmpty)
                Button { app.printReports(tables: chosen) } label: {
                    Label("打印", systemImage: "printer")
                }
                .disabled(chosen.isEmpty)
            }
            .font(.system(size: 11))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(10)
        }
        .frame(width: 980, height: 700)
    }

    private var saveName: String { "\(app.project?.name ?? "预算")-预算表" }

    /// 表全称太长，勾选用简称
    private func shortTitle(_ title: String) -> String {
        for no in ["表一", "表三甲", "表三乙", "表三丙", "表四甲", "表五甲", "表二"] {
            if title.contains(no) { return no }
        }
        return title
    }
}
