import SwiftUI

// =============================================================================
// 右侧子目属性面板：用原生分组 Form（LabeledContent + Section），
// 与 macOS 系统设置/检查器一致的排版，而不是自绘圆角卡片。
// =============================================================================

struct InspectorView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let item = app.selectedItem {
                titleBar(item)
                Divider()
                form(item)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("选中一条子目后\n在此查看与调整属性")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 顶部标题

    private func titleBar(_ item: ProjectItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.quotaCode)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.14)))
                if item.isSupplement {
                    Text("补充")
                        .font(.system(size: 9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                }
                Spacer()
                Button {
                    app.deleteItem(id: item.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("删除该子目")
            }
            Text(item.quotaName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 表单

    private func form(_ item: ProjectItem) -> some View {
        let cost = app.costs[item.id] ?? ItemCost()

        return Form {
            Section("基本信息") {
                LabeledContent("名称") {
                    TextField("", text: Binding(
                        get: { item.quotaName },
                        set: { v in app.apply({ $0.quotaName = v }, to: item.id) }))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                LabeledContent("单位") {
                    TextField("", text: Binding(
                        get: { item.unit },
                        set: { v in app.apply({ $0.unit = v }, to: item.id) }))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                LabeledContent("工程量") {
                    TextField("", value: Binding(
                        get: { item.quantity },
                        set: { v in app.apply({ $0.quantity = v }, to: item.id) }),
                              format: .number.precision(.fractionLength(0...4)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                }
                LabeledContent("工日系数") {
                    TextField("", value: Binding(
                        get: { item.workdayCoeff },
                        set: { v in app.apply({ $0.workdayCoeff = v }, to: item.id) }),
                              format: .number.precision(.fractionLength(0...3)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                }
                LabeledContent("定额工日") {
                    Text("技 \(Fmt.workday(item.techWorkday)) · 普 \(Fmt.workday(item.laborWorkday))")
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("技工单价") {
                    TextField("", value: Binding(
                        get: { item.techPrice },
                        set: { v in app.apply({ $0.techPrice = v }, to: item.id) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                }
                LabeledContent("普工单价") {
                    TextField("", value: Binding(
                        get: { item.laborPrice },
                        set: { v in app.apply({ $0.laborPrice = v }, to: item.id) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                }
                LabeledContent("备注") {
                    TextField("", text: Binding(
                        get: { item.note },
                        set: { v in app.apply({ $0.note = v }, to: item.id) }))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            }

            Section("费用构成") {
                kv("技工工日", Fmt.workday(cost.techWorkdays))
                kv("普工工日", Fmt.workday(cost.laborWorkdays))
                kv("人工费", Fmt.money(cost.labor))
                kv("主材费", Fmt.money(cost.mainMaterial))
                kv("机械费", Fmt.money(cost.machine))
                kv("仪表费", Fmt.money(cost.instrument))
                if cost.equipment > 0 { kv("设备费", Fmt.money(cost.equipment)) }
                kv("小计（直接费）", Fmt.money(cost.direct), bold: true)
            }

            Section {
                if item.resources.isEmpty {
                    Text("该定额无主材/机械/仪表消耗量")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                ForEach(item.resources) { res in
                    resourceRow(res, item: item)
                }
                HStack(spacing: 4) {
                    ForEach([ResourceKind.mainMaterial, .equipment, .machine, .instrument]) { kind in
                        Button {
                            app.addResource(itemID: item.id, kind: kind)
                        } label: {
                            Text("+ \(kind.rawValue)").font(.system(size: 9))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            } header: {
                Text("资源明细（\(item.resources.count)）")
            } footer: {
                Text("单价为 0 表示尚未填价，主材费/机械费按 消耗量 × 单价 计入。")
                    .font(.system(size: 9))
            }
        }
        .formStyle(.grouped)
    }

    private func kv(_ k: String, _ v: String, bold: Bool = false) -> some View {
        LabeledContent(k) {
            Text(v)
                .font(.system(size: 11, weight: bold ? .semibold : .regular, design: .rounded))
                .monospacedDigit()
        }
    }

    // MARK: - 资源行

    private func resourceRow(_ res: ItemResource, item: ProjectItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(res.kind.rawValue)
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(color(for: res.kind).opacity(0.18)))
                TextField("名称", text: Binding(
                    get: { res.name },
                    set: { v in var r = res; r.name = v; app.updateResource(r) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                Button {
                    app.removeResource(itemID: item.id, resourceID: res.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("移除该资源")
            }
            HStack(spacing: 6) {
                Text(res.unit.isEmpty ? "—" : res.unit)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
                TextField("", value: Binding(
                    get: { res.effectiveQtyPerUnit },
                    set: { v in var r = res; r.qtyOverride = v; app.updateResource(r) }),
                          format: .number.precision(.fractionLength(0...4)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 10))
                    .frame(width: 62)
                Text("×").font(.system(size: 9)).foregroundStyle(.tertiary)
                TextField("", value: Binding(
                    get: { res.unitPrice },
                    set: { v in var r = res; r.unitPrice = v; app.updateResource(r) }),
                          format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 10))
                    .frame(width: 70)
                Spacer()
                Text(Fmt.money(res.effectiveQtyPerUnit * item.quantity * res.unitPrice))
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func color(for kind: ResourceKind) -> Color {
        switch kind {
        case .mainMaterial: return .blue
        case .machine:      return .purple
        case .instrument:   return .teal
        case .equipment:    return .orange
        }
    }
}
