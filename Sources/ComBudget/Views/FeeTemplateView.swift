import SwiftUI

// =============================================================================
// 取费模板：多套模板、逐项费率、可选计算基数
// =============================================================================

struct FeeTemplateView: View {
    @EnvironmentObject private var app: AppState

    @State private var selectedID: Int64?
    @State private var draft: FeeTemplate?
    @State private var dirty = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("取费模板").font(.system(size: 15, weight: .semibold))
                Text("费率可自定义，支持多套模板按专业切换；当前工程使用：\(app.currentTemplate?.name ?? "—")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    draft = app.newTemplate()
                    selectedID = nil
                    dirty = true
                } label: {
                    Label("新建模板", systemImage: "plus").font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(app.templates) { t in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name).font(.system(size: 12)).lineLimit(1)
                            Text(t.isBuiltin ? "内置" : "自定义")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .tag(t.id)
                    }
                }
                .frame(width: 236)
                .listStyle(.sidebar)
                .onChange(of: selectedID) { newValue in
                    draft = app.templates.first { $0.id == newValue }
                    dirty = false
                }

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
    }

    @ViewBuilder
    private func editor(_ tpl: FeeTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("模板名称").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("", text: Binding(
                    get: { draft?.name ?? "" },
                    set: { draft?.name = $0; dirty = true }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)

                Text("辅材费率").font(.system(size: 11)).foregroundStyle(.secondary)
                NumberField(value: Binding(
                    get: { draft?.auxMaterialRate ?? 0 },
                    set: { draft?.auxMaterialRate = $0; dirty = true }), width: 60)
                    .textFieldStyle(.roundedBorder)
                Text("%（辅材费 = 人工费 × 该费率）").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: 0) {
                Text("分组").frame(width: 70, alignment: .leading)
                Text("费用名称").frame(width: 160, alignment: .leading)
                Text("计算基数").frame(width: 165, alignment: .leading)
                Text("费率(%)").frame(width: 78, alignment: .trailing)
                Text("启用").frame(width: 44, alignment: .center)
                Text("备注").frame(maxWidth: .infinity, alignment: .leading)
                Text("").frame(width: 24)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(Array((draft?.rates ?? []).enumerated()), id: \.offset) { idx, rate in
                        rateRow(idx: idx, rate: rate)
                    }
                    Button {
                        draft?.rates.append(FeeRate(name: "新增费用", group: "措施费", base: .labor,
                                                    rate: 0, sortIndex: draft?.rates.count ?? 0))
                        dirty = true
                    } label: {
                        Label("添加费用项", systemImage: "plus").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                }
            }

            Divider()

            HStack {
                if dirty {
                    Text("有未保存的修改").font(.system(size: 10)).foregroundStyle(.orange)
                }
                Spacer()
                Button("另存为新模板") {
                    guard var t = draft else { return }
                    t.id = 0
                    t.name += " 副本"
                    t.isBuiltin = false
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
        .padding(12)
    }

    private func rateRow(idx: Int, rate: FeeRate) -> some View {
        HStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { rate.group },
                set: { v in draft?.rates[idx].group = v; dirty = true })) {
                ForEach(["措施费", "间接费", "利润", "税金"], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 70)

            TextField("", text: Binding(
                get: { rate.name },
                set: { v in draft?.rates[idx].name = v; dirty = true }))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 160, alignment: .leading)

            Picker("", selection: Binding(
                get: { rate.base },
                set: { v in draft?.rates[idx].base = v; dirty = true })) {
                ForEach(FeeBase.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 165)

            NumberField(value: Binding(
                get: { rate.rate },
                set: { v in draft?.rates[idx].rate = v; dirty = true }), width: 78)

            Toggle("", isOn: Binding(
                get: { rate.isEnabled },
                set: { v in draft?.rates[idx].isEnabled = v; dirty = true }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 44)

            TextField("", text: Binding(
                get: { rate.note },
                set: { v in draft?.rates[idx].note = v; dirty = true }))
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                draft?.rates.remove(at: idx)
                dirty = true
            } label: {
                Image(systemName: "xmark.circle").font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .frame(width: 24)
        }
        .font(.system(size: 11))
        .padding(.vertical, 2)
    }
}
