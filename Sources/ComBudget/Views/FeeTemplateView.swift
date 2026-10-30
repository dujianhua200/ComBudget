import SwiftUI
import UniformTypeIdentifiers

// =============================================================================
// 取费模板：多套模板、逐项费率、可选计算基数，可导出成 JSON 带走
//
// 费率这块是概预算里最容易「一方一价」的地方：各省通信管理局、各运营商
// 招标文件给的费率都不同，所以模板必须能自己改、能带走、能给别人。
// 界面按 451 的科目顺序分组，改动即时可用「试算」看到总造价差多少。
// =============================================================================

struct FeeTemplateView: View {
    @EnvironmentObject private var app: AppState

    @State private var selectedID: Int64?
    @State private var draft: FeeTemplate?
    @State private var dirty = false

    @State private var showImporter = false
    @State private var showExporter = false
    @State private var importMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                templateList
                    .frame(width: 236)
                Divider()
                if let tpl = draft {
                    editor(tpl)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "percent").font(.system(size: 24)).foregroundStyle(.tertiary)
                        Text("选择左侧模板，或新建一个").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            if selectedID == nil, let first = app.templates.first {
                selectedID = first.id
                draft = first
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let n = app.importTemplates(from: url)
                importMessage = n > 0 ? "已导入 \(n) 份模板" : (app.alertMessage ?? "导入失败")
            case .failure(let error):
                importMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $showExporter,
                      document: TemplateDocument(templates: exportCandidates),
                      contentType: .json,
                      defaultFilename: FeeTemplateIO.fileName(for: draft ?? FeeTemplate())) { result in
            switch result {
            case .success: importMessage = ""
            case .failure(let error): importMessage = error.localizedDescription
            }
        }
    }

    /// 导出内容：有勾选就导出所选模板，否则导出全部（一份文件里多份也支持）
    private var exportCandidates: [FeeTemplate] {
        guard let d = draft else { return app.templates }
        var list = [d]
        if d.id == 0 { list = app.templates }
        return list
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Text("取费模板").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text("当前工程使用：\(app.currentTemplate?.name ?? "—")")
                Text("费率为示例值，请按招标文件与当地文件核定")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            if !importMessage.isEmpty {
                Text(importMessage).font(.system(size: 10))
                    .foregroundStyle(importMessage.hasPrefix("已") ? Color.green : Color.red)
            }
            Spacer()
            Button { showImporter = true } label: {
                Label("导入模板", systemImage: "square.and.arrow.down").font(.system(size: 11))
            }
            .help("导入同事给的 / 自己存档的取费模板 JSON")
            Button { showExporter = true } label: {
                Label("导出 JSON", systemImage: "square.and.arrow.up").font(.system(size: 11))
            }
            .help("导出成 JSON：可进 Git 管版本，也可发给同事")
            Button {
                draft = app.newTemplate()
                selectedID = nil
                dirty = true
            } label: {
                Label("新建模板", systemImage: "plus").font(.system(size: 11))
            }
            .help("以内置 451 口径为底稿，新建一套自己的费率")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 模板列表

    private var templateList: some View {
        List(selection: $selectedID) {
            ForEach(app.templates) { t in
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name).font(.system(size: 12)).lineLimit(1)
                    Text("\(t.isBuiltin ? "内置" : "自定义")　\(t.rates.count) 项费率")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .tag(t.id)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selectedID) { newValue in
            draft = app.templates.first { $0.id == newValue }
            dirty = false
        }
    }

    // MARK: - 编辑区

    @ViewBuilder
    private func editor(_ tpl: FeeTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            metaBar
            columnHeader
            Divider()

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(groupedIndices, id: \.0.rawValue) { kind, indices in
                        groupHeader(kind, indices)
                        ForEach(indices, id: \.self) { idx in rateRow(idx: idx) }
                    }
                    Button { appendRate() } label: {
                        Label("添加费用项", systemImage: "plus").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                }
            }

            Divider()
            footer(tpl)
        }
        .padding(12)
    }

    private var metaBar: some View {
        HStack(spacing: 8) {
            Text("模板名称").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", text: Binding(
                get: { draft?.name ?? "" },
                set: { draft?.name = $0; dirty = true }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)

            Text("辅材费率").font(.system(size: 11)).foregroundStyle(.secondary)
            NumberField(value: Binding(
                get: { draft?.auxMaterialRate ?? 0 },
                set: { draft?.auxMaterialRate = $0; dirty = true }), width: 58)
                .textFieldStyle(.roundedBorder)
            Text("%（辅材费 = 人工费 × 该费率）").font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("科目").frame(width: 74, alignment: .leading)
            Text("费用名称").frame(width: 150, alignment: .leading)
            Text("计算基数").frame(width: 160, alignment: .leading)
            Text("费率(%)").frame(width: 72, alignment: .trailing)
            Text("启用").frame(width: 38, alignment: .center)
            Text("备注").frame(maxWidth: .infinity, alignment: .leading)
            Text("顺序").frame(width: 46, alignment: .center)
            Text("").frame(width: 22)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    /// 按 451 科目顺序排好：[措施费, 规费, 企业管理费, 利润, 税金, 其他费, 预备费]
    private var groupedIndices: [(FeeKind, [Int])] {
        guard let rates = draft?.rates else { return [] }
        let order = FeeKind.allCases.sorted { $0.order < $1.order }
        var buckets: [FeeKind: [Int]] = [:]
        for (idx, r) in rates.enumerated() {
            buckets[Foolproof.kind(of: r.group), default: []].append(idx)
        }
        return order.compactMap { k in
            guard let v = buckets[k], !v.isEmpty else { return nil }
            return (k, v)
        }
    }

    private func appendRate() {
        let count = draft?.rates.count ?? 0
        draft?.rates.append(FeeRate(name: "新增费用", group: FeeKind.measures.rawValue,
                                    base: .labor, rate: 0, sortIndex: count))
        dirty = true
    }

    @ViewBuilder
    private func groupHeader(_ kind: FeeKind, _ indices: [Int]) -> some View {
        let enabled = indices.filter { draft?.rates[$0].isEnabled ?? false }
        let sum = enabled.reduce(0.0) { $0 + (draft?.rates[$1].rate ?? 0) }
        let amount = draft.map { app.trialSummarize($0).amount(of: kind) } ?? 0
        HStack(spacing: 6) {
            Label {
                Text(kind.rawValue).font(.system(size: 11, weight: .semibold))
            } icon: {
                Image(systemName: icon(of: kind)).font(.system(size: 9))
            }
            Text(enabled.count == indices.count ? "\(indices.count) 项" : "\(enabled.count)/\(indices.count) 项")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Text("费率合计 \(Fmt.rate(sum))").font(.system(size: 9)).foregroundStyle(.tertiary)
            Text("试算 \(Fmt.money(amount))").font(.system(size: 9))
                .foregroundStyle(amount > 0 ? Color.secondary : Color(red: 0.6, green: 0.6, blue: 0.62))
            Spacer()
            Button { appendRate(in: kind) } label: {
                Image(systemName: "plus.circle").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("在「\(kind.rawValue)」下加一项")
        }
        .foregroundStyle(.secondary)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func icon(of kind: FeeKind) -> String {
        switch kind {
        case .measures:    return "shield"
        case .regulation:  return "banknote"
        case .admin:       return "building.2"
        case .profit:      return "chart.line.uptrend.xyaxis"
        case .tax:         return "doc.text"
        case .other:       return "folder"
        case .contingency: return "archivebox"
        }
    }

    private func appendRate(in kind: FeeKind) {
        let count = draft?.rates.count ?? 0
        draft?.rates.append(FeeRate(name: "新增\(kind.rawValue)", group: kind.rawValue,
                                    base: kind == .tax ? .beforeTax : .labor,
                                    rate: 0, sortIndex: count))
        dirty = true
    }

    private func rateRow(idx: Int) -> some View {
        let rate = draft?.rates[idx] ?? FeeRate()
        return HStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { Foolproof.kind(of: rate.group) },
                set: { v in draft?.rates[idx].group = v.rawValue; dirty = true })) {
                ForEach(FeeKind.allCases.sorted { $0.order < $1.order }) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 74)

            TextField("", text: Binding(
                get: { rate.name },
                set: { v in draft?.rates[idx].name = v
                    if draft?.rates[idx].key.isEmpty == true { draft?.rates[idx].key = v }
                    dirty = true }))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 150, alignment: .leading)

            Picker("", selection: Binding(
                get: { rate.base },
                set: { v in draft?.rates[idx].base = v; dirty = true })) {
                ForEach(FeeBase.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 160)
            .help(rate.base.full)

            NumberField(value: Binding(
                get: { rate.rate },
                set: { v in draft?.rates[idx].rate = v; dirty = true }), width: 72)

            Toggle("", isOn: Binding(
                get: { rate.isEnabled },
                set: { v in draft?.rates[idx].isEnabled = v; dirty = true }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 38)

            TextField("", text: Binding(
                get: { rate.note },
                set: { v in draft?.rates[idx].note = v; dirty = true }))
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Button { move(idx, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(idx == 0)
                Button { move(idx, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(idx == (draft?.rates.count ?? 0) - 1)
            }
            .font(.system(size: 8))
            .buttonStyle(.borderless)
            .frame(width: 46)

            Button { draft?.rates.remove(at: idx); dirty = true } label: {
                Image(systemName: "xmark.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .frame(width: 22)
        }
        .font(.system(size: 11))
        .padding(.vertical, 2)
    }

    /// 排序：影响报表里的列报顺序（同组内序号由 sortIndex 决定）
    private func move(_ idx: Int, by step: Int) {
        guard let rates = draft?.rates, rates.indices.contains(idx) else { return }
        let target = idx + step
        guard rates.indices.contains(target) else { return }
        draft?.rates.swapAt(idx, target)
        draft?.rates = draft?.rates.enumerated().map { i, r -> FeeRate in
            var copy = r
            copy.sortIndex = i
            return copy
        } ?? []
        dirty = true
    }

    @ViewBuilder
    private func footer(_ tpl: FeeTemplate) -> some View {
        let trial = app.trialSummarize(tpl)
        let current = app.summary.total
        HStack(alignment: .top, spacing: 12) {
            if dirty { Text("有未保存的修改").font(.system(size: 10)).foregroundStyle(.orange) }
            Text("试算总造价 \(Fmt.money(trial.grandTotal))")
                .font(.system(size: 10))
            Text("建安 \(Fmt.money(trial.total))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if abs(trial.total - current) > 0.005, app.project != nil {
                let delta = trial.total - current
                Text("\(delta >= 0 ? "+" : "−")\(Fmt.money(abs(delta))) vs 当前模板")
                    .font(.system(size: 10))
                    .foregroundStyle(delta >= 0 ? Color.orange : Color.green)
            }
            Spacer()
            if tpl.id != 0 && !tpl.isBuiltin {
                Button(role: .destructive) {
                    app.deleteTemplate(id: tpl.id)
                    selectedID = nil
                    draft = nil
                } label: { Text("删除模板") }
            }
            Button("另存为新模板") {
                guard var t = draft else { return }
                t.id = 0
                t.isBuiltin = false
                if !t.name.hasSuffix(" 副本") { t.name += " 副本" }
                app.saveTemplate(t)
                selectedID = app.templates.last?.id
                draft = app.templates.last
                dirty = false
            }
            Button("保存") {
                guard let t = draft else { return }
                app.saveTemplate(t)
                draft = app.templates.first { $0.id == t.id } ?? t
                dirty = false
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!dirty)
        }
    }
}

// MARK: - 科目识别：老旧模板里的分组文案也能落到一个科目上

enum Foolproof {
    static func kind(of group: String) -> FeeKind {
        FeeKind.of(group) ?? .measures
    }
}

// MARK: - 导出文档

struct TemplateDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(templates: [FeeTemplate]) {
        data = (try? FeeTemplateIO.encode(templates)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
