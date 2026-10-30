import SwiftUI
import AppKit

// =============================================================================
// 资源价格库 / 价格导入向导 / 定额换算向导
//
// 451 定额手册只给「消耗量」，单价来自价格册或市场询价，
// 所以价格库是独立的一页：导入 → 检索 → 套价，三步闭环。
// 换算向导只做一件事：把系数写进子目，并留下 conv_note 痕迹（可还原）。
// =============================================================================

// MARK: - 资源价格库

struct PriceBookView: View {
    @EnvironmentObject private var app: AppState

    @State private var keyword = ""
    @State private var kindFilter: ResourceKind?
    @State private var selection: Int64?
    @State private var showImport = false
    @State private var showEditor = false
    @State private var draft = PriceEntry()
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .sheet(isPresented: $showImport) { PriceImportWizard() }
        .sheet(isPresented: $showEditor) {
            PriceEditorSheet(draft: $draft) { app.savePrice(draft) }
        }
        .confirmationDialog("清空价格库？", isPresented: $confirmClear) {
            Button("全部清空", role: .destructive) { app.clearPrices() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("价格库仅影响套价结果，不会改动已编制的清单；清空后可用 ⌘Z 撤销。")
        }
        .onAppear { app.reloadPrices() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "yensign.circle").foregroundStyle(.tint).font(.system(size: 13))
                Text("资源价格库").font(.system(size: 13, weight: .semibold))
                Text("451 手册不含单价，主材/机械/仪表的单价在这里维护")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showImport = true
                } label: { Label("导入清单", systemImage: "square.and.arrow.down") }
                    .help("从 Excel 导入价格（列可配置）")

                Button {
                    if let url = FilePanels.save(name: "价格库导入模板.xlsx", ext: "xlsx") {
                        app.writePriceTemplate(to: url)
                    }
                } label: { Label("模板", systemImage: "doc.badge.plus") }
                    .help("生成价格导入模板")

                Button {
                    draft = PriceEntry()
                    showEditor = true
                } label: { Label("新增", systemImage: "plus") }
                    .help("手工新增一条价格")

                Button {
                    guard let id = selection,
                          let e = app.prices.first(where: { $0.id == id }) else { return }
                    draft = e
                    showEditor = true
                } label: { Label("编辑", systemImage: "pencil") }
                    .disabled(selection == nil)

                Button {
                    if let id = selection { app.deletePrice(id: id); selection = nil }
                } label: { Label("删除", systemImage: "trash") }
                    .disabled(selection == nil)

                Button("清空…") { confirmClear = true }
                    .disabled(app.prices.isEmpty)
            }

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    TextField("按名称 / 规格 / 来源检索", text: $keyword)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 240)
                        .onSubmit { app.reloadPrices(keyword: keyword, kind: kindFilter) }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor)))

                Picker("类型", selection: $kindFilter) {
                    Text("全部类型").tag(Optional<ResourceKind>.none)
                    ForEach(ResourceKind.allCases) { k in Text(k.rawValue).tag(Optional(k)) }
                }
                .labelsHidden()
                .frame(width: 110)
                .onChange(of: kindFilter) { _ in app.reloadPrices(keyword: keyword, kind: kindFilter) }

                Button("检索") { app.reloadPrices(keyword: keyword, kind: kindFilter) }
                    .controlSize(.small)

                Spacer()
                Text("\(app.prices.count) 条")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: 表格

    @ViewBuilder
    private var content: some View {
        if app.prices.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "yensign.square")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("价格库为空").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("先用「模板」生成一份 Excel，填上单价后「导入清单」；\n导入按 类型+名称+规格+单位 覆盖，重复导同一份不会翻倍。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Button("生成模板") {
                    if let url = FilePanels.save(name: "价格库导入模板.xlsx", ext: "xlsx") {
                        app.writePriceTemplate(to: url)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(app.prices, selection: $selection) {
                TableColumn("类型") { e in
                    Text(e.kind.rawValue).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .width(56)

                TableColumn("名称") { e in
                    Text(e.name).font(.system(size: 11)).lineLimit(1)
                }
                .width(min: 140, ideal: 220)

                TableColumn("规格程式") { e in
                    Text(e.spec).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 80, ideal: 140)

                TableColumn("单位") { e in
                    Text(e.unit).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .width(52)

                TableColumn("单价（元）") { e in
                    Text(Fmt.money(e.unitPrice))
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 78, ideal: 96)

                TableColumn("来源") { e in
                    Text(e.source).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 90, ideal: 170)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Text("套价时按「类型+名称+规格+单位」精确匹配；单位不一致不会乱套。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            if let p = app.project {
                Text("当前工程：\(p.name)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("只补未定价资源") { app.applyPricesToProject(overwrite: false) }
                    .controlSize(.small)
                Button("套价（覆盖全部）") { app.applyPricesToProject(overwrite: true) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            } else {
                Text("先打开一个工程才能套价")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - 单条价格编辑

struct PriceEditorSheet: View {
    @Binding var draft: PriceEntry
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.id == 0 ? "新增价格" : "编辑价格")
                .font(.system(size: 14, weight: .semibold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("类型").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: $draft.kind) {
                        ForEach(ResourceKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                GridRow {
                    Text("名称").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("如：光缆接头盒", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                GridRow {
                    Text("规格程式").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("如：12芯（可留空）", text: $draft.spec)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                GridRow {
                    Text("单位").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("如：个 / 米 / 台班", text: $draft.unit)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                GridRow {
                    Text("单价").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", value: $draft.unitPrice,
                                  format: .number.precision(.fractionLength(0...4)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        Text("元").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("来源").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("如：2024 年第 3 期信息价", text: $draft.source)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
            }
            .font(.system(size: 12))

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { onSave(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

// MARK: - 价格清单导入向导

struct PriceImportWizard: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var url: URL?
    @State private var sheetNames: [String] = []
    @State private var headers: [String] = []
    @State private var config = PriceImportConfig()
    @State private var preview: (entries: [PriceEntry], skipped: Int, invalid: [String])?
    @State private var message = "支持 .xlsx；最少需要「名称 + 单价」两列"
    @State private var messageColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("导入价格清单").font(.system(size: 14, weight: .semibold))
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
                    columnPicker("类型", \.kindColumn)
                    columnPicker("名称", \.nameColumn)
                    columnPicker("规格程式", \.specColumn)
                    columnPicker("单位", \.unitColumn)
                    columnPicker("单价", \.priceColumn)
                    columnPicker("来源", \.sourceColumn)
                }
            }

            HStack(spacing: 8) {
                Button { analyze() } label: { Label("校验", systemImage: "checkmark.shield") }
                    .disabled(url == nil)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(messageColor)
                    .lineLimit(2)
                Spacer()
            }

            if let preview {
                previewList(preview)
            } else {
                Text("校验后会列出能识别的价格行，以及单价不是数字的行（这些行不会入库）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("导入 \(preview?.entries.count ?? 0) 条") {
                    guard let preview, !preview.entries.isEmpty else { return }
                    app.commitPriceImport(preview.entries,
                                          source: url?.lastPathComponent ?? "Excel 导入")
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled((preview?.entries.count ?? 0) == 0)
            }
        }
        .padding(14)
        .frame(width: 720, height: 560)
    }

    // MARK: 子视图

    private func columnPicker(_ title: String, _ keyPath: WritableKeyPath<PriceImportConfig, Int>)
        -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Picker("", selection: Binding(
                get: { config[keyPath: keyPath] },
                set: { config[keyPath: keyPath] = $0 })) {
                Text("（无此列）").tag(-1)
                ForEach(headers.indices, id: \.self) { i in
                    Text(columnLabel(i)).tag(i)
                }
            }
            .labelsHidden()
            .frame(width: 220)
        }
    }

    private func columnLabel(_ i: Int) -> String {
        let h = headers[i].trimmingCharacters(in: .whitespaces)
        return "\(excelColumnName(i))\(h.isEmpty ? "" : " · \(h)")"
    }

    /// 0 → A，1 → B …
    private func excelColumnName(_ i: Int) -> String {
        var n = i, out = ""
        repeat {
            out = String(UnicodeScalar(65 + n % 26)!) + out
            n = n / 26 - 1
        } while n >= 0
        return out
    }

    private func previewList(_ p: (entries: [PriceEntry], skipped: Int, invalid: [String]))
        -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("可导入 \(p.entries.count) 条")
                Text("跳过空行 \(p.skipped) 行")
                if !p.invalid.isEmpty {
                    Text("单价异常 \(p.invalid.count) 行").foregroundStyle(.orange)
                }
                Spacer()
            }
            .font(.system(size: 11))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(p.entries) { e in
                        HStack(spacing: 8) {
                            Text(e.kind.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .leading)
                            Text(e.name).font(.system(size: 11)).lineLimit(1)
                                .frame(minWidth: 180, alignment: .leading)
                            Text(e.spec).font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .leading)
                            Text(e.unit).font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .leading)
                            Text(Fmt.money(e.unitPrice))
                                .font(.system(size: 11, design: .rounded))
                                .monospacedDigit()
                                .frame(width: 84, alignment: .trailing)
                            Spacer()
                        }
                    }
                    if !p.invalid.isEmpty {
                        Divider().padding(.vertical, 4)
                        ForEach(p.invalid, id: \.self) { msg in
                            Text(msg).font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .frame(minHeight: 180)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    // MARK: 动作

    private func pickFile() {
        guard let picked = FilePanels.open(ext: "xlsx").first else { return }
        url = picked
        preview = nil
        do {
            let sheets = try XlsxReader.read(url: picked)
            sheetNames = sheets.map { $0.name }
            config.sheetIndex = 0
            reloadHeaders()
            message = "已读取 \(sheets.count) 个工作表"
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
            guard !sheets.isEmpty else { return }
            let sheet = sheets[min(max(config.sheetIndex, 0), sheets.count - 1)]
            let row = config.headerRow >= 0 ? config.headerRow : 0
            guard row < sheet.rows.count else { headers = []; return }
            headers = sheet.rows[row]
            // 表头存在时按列名自动认列（「单价（元）」之类也能认出来）
            if config.headerRow >= 0 { config = PriceImportConfig.detectColumns(from: headers) }
            preview = nil
        } catch {
            message = error.localizedDescription
            messageColor = .red
        }
    }

    private func analyze() {
        guard let url else { return }
        let parsed = app.previewPriceImport(url: url, config: config)
        guard let parsed else {
            message = app.alertMessage ?? "读取失败"
            messageColor = .red
            return
        }
        preview = parsed
        if parsed.entries.isEmpty {
            message = "没识别到价格行：检查「名称」「单价」两列是否选对"
            messageColor = .orange
        } else {
            message = "校验通过 \(parsed.entries.count) 条" +
                (parsed.invalid.isEmpty ? "" : "，\(parsed.invalid.count) 行单价异常已跳过")
            messageColor = parsed.invalid.isEmpty ? .green : .orange
        }
    }
}

// MARK: - 定额换算向导

struct ConversionSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    let itemID: Int64

    @State private var rule = ConversionPresets.all[1]
    @State private var applyToAll = false

    private var item: ProjectItem? { app.items.first { $0.id == itemID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("定额换算").font(.system(size: 14, weight: .semibold))
            if let item {
                Text("\(item.quotaCode)  \(item.quotaName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // 预设
            Picker("预设", selection: $rule) {
                ForEach(ConversionPresets.all) { r in
                    Text(r.name).tag(r)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            .onChange(of: rule) { _ in }

            // 系数（可手改，预设只是起点）
            GroupBox("系数") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    coeffRow("技工工日", \.techCoeff)
                    coeffRow("普工工日", \.laborCoeff)
                    coeffRow("机械台班", \.machineCoeff)
                    coeffRow("仪表台班", \.instrumentCoeff)
                    coeffRow("主材消耗量", \.materialCoeff)
                }
                .font(.system(size: 12))
            }

            if !rule.note.isEmpty {
                Text(rule.note)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            // 影响预览
            if let item {
                let pair = QuotaConverter.preview(rule, item: item,
                                                  auxRate: app.currentTemplate?.auxMaterialRate ?? 0.3)
                GroupBox("换算影响（本条子目，工程量 \(Fmt.quantity(item.quantity)) \(item.unit)）") {
                    HStack(spacing: 16) {
                        delta("人工费", before: pair.before.labor, after: pair.after.labor)
                        delta("机械费", before: pair.before.machine, after: pair.after.machine)
                        delta("仪表费", before: pair.before.instrument, after: pair.after.instrument)
                        delta("主材费", before: pair.before.mainMaterial, after: pair.after.mainMaterial)
                        delta("直接费", before: pair.before.direct, after: pair.after.direct)
                    }
                }
            }

            Toggle("套用到整个工程（\(app.items.count) 条子目）", isOn: $applyToAll)

            HStack {
                if let item, !item.convNote.isEmpty {
                    Text("当前痕迹：\(item.convNote)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("还原定额原值") {
                    if applyToAll {
                        if let revoke = ConversionPresets.all.first(where: { $0.isIdentity }) {
                            app.convertProject(rule: revoke)
                        }
                    } else {
                        app.revokeConversion(id: itemID)
                    }
                    dismiss()
                }
                Button(applyToAll ? "整工程套用" : "套用") {
                    if applyToAll { app.convertProject(rule: rule) }
                    else { app.convertItem(id: itemID, rule: rule) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 640)
    }

    private func coeffRow(_ title: String, _ keyPath: WritableKeyPath<ConversionRule, Double>)
        -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Stepper(value: Binding(
                get: { rule[keyPath: keyPath] },
                set: { rule[keyPath: keyPath] = max(0, $0) }),
                    in: 0...3, step: 0.05) {
                Text(Fmt.coeff(rule[keyPath: keyPath]))
                    .font(.system(size: 12, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            .frame(width: 150)
        }
    }

    private func delta(_ title: String, before: Double, after: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(Fmt.money(before)).font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                Text(Fmt.money(after))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(after > before ? .orange : (after < before ? .green : .primary))
            }
        }
    }
}
