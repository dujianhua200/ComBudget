import SwiftUI

// =============================================================================
// 右侧子目属性面板：基本信息 / 费用构成 / 资源明细（主材·机械·仪表·设备）
// =============================================================================

struct InspectorView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ScrollView {
            if let item = app.selectedItem {
                content(item)
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
                .frame(maxWidth: .infinity)
                .padding(.top, 70)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func content(_ item: ProjectItem) -> some View {
        let cost = app.costs[item.id] ?? ItemCost()

        VStack(alignment: .leading, spacing: 9) {
            // 标题
            HStack(spacing: 6) {
                Text(item.quotaCode)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
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
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(3)

            FieldGroup(title: "基本信息") {
                FormRow(label: "名称") {
                    TextField("", text: Binding(
                        get: { item.quotaName },
                        set: { v in app.apply({ $0.quotaName = v }, to: item.id) }))
                        .textFieldStyle(.roundedBorder)
                }
                FormRow(label: "单位") {
                    TextField("", text: Binding(
                        get: { item.unit },
                        set: { v in app.apply({ $0.unit = v }, to: item.id) }))
                        .textFieldStyle(.roundedBorder)
                }
                FormRow(label: "工程量") {
                    NumberField(value: Binding(
                        get: { item.quantity },
                        set: { v in app.apply({ $0.quantity = v }, to: item.id) }), width: 90)
                }
                FormRow(label: "工日系数") {
                    NumberField(value: Binding(
                        get: { item.workdayCoeff },
                        set: { v in app.apply({ $0.workdayCoeff = v }, to: item.id) }),
                                fractionDigits: 0...3, width: 90)
                }
                FormRow(label: "定额工日") {
                    HStack(spacing: 6) {
                        Text("技 \(Fmt.workday(item.techWorkday))")
                        Text("普 \(Fmt.workday(item.laborWorkday))")
                    }
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
                FormRow(label: "技工单价") {
                    NumberField(value: Binding(
                        get: { item.techPrice },
                        set: { v in app.apply({ $0.techPrice = v }, to: item.id) }),
                                fractionDigits: 0...2, width: 90)
                }
                FormRow(label: "普工单价") {
                    NumberField(value: Binding(
                        get: { item.laborPrice },
                        set: { v in app.apply({ $0.laborPrice = v }, to: item.id) }),
                                fractionDigits: 0...2, width: 90)
                }
                FormRow(label: "备注") {
                    TextField("", text: Binding(
                        get: { item.note },
                        set: { v in app.apply({ $0.note = v }, to: item.id) }))
                        .textFieldStyle(.roundedBorder)
                }
            }

            FieldGroup(title: "费用构成") {
                kv("技工工日", Fmt.workday(cost.techWorkdays))
                kv("普工工日", Fmt.workday(cost.laborWorkdays))
                kv("人工费", Fmt.money(cost.labor))
                kv("主材费", Fmt.money(cost.mainMaterial))
                kv("机械费", Fmt.money(cost.machine))
                kv("仪表费", Fmt.money(cost.instrument))
                if cost.equipment > 0 { kv("设备费", Fmt.money(cost.equipment)) }
                Divider()
                kv("小计（直接费）", Fmt.money(cost.direct), bold: true)
            }

            resourcesSection(item)
        }
        .padding(10)
    }

    private func kv(_ k: String, _ v: String, bold: Bool = false) -> some View {
        HStack {
            Text(k).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(v)
                .font(.system(size: 11, weight: bold ? .semibold : .regular, design: .rounded))
                .monospacedDigit()
        }
    }

    // MARK: - 资源明细

    @ViewBuilder
    private func resourcesSection(_ item: ProjectItem) -> some View {
        FieldGroup(title: "资源明细（\(item.resources.count)）") {
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
            .padding(.top, 2)
        }
    }

    private func resourceRow(_ res: ItemResource, item: ProjectItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
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
                    Image(systemName: "xmark.circle").font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 6) {
                Text(res.spec.isEmpty ? "—" : res.spec)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 62, alignment: .leading)
                    .lineLimit(1)
                Text(res.unit)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .leading)
                NumberField(value: Binding(
                    get: { res.effectiveQtyPerUnit },
                    set: { v in var r = res; r.qtyOverride = v; app.updateResource(r) }),
                            fractionDigits: 0...4, width: 52)
                Text("×").font(.system(size: 9)).foregroundStyle(.tertiary)
                NumberField(value: Binding(
                    get: { res.unitPrice },
                    set: { v in var r = res; r.unitPrice = v; app.updateResource(r) }),
                            fractionDigits: 0...2, width: 58)
                Spacer()
                Text(Fmt.money(res.effectiveQtyPerUnit * item.quantity * res.unitPrice))
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
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
