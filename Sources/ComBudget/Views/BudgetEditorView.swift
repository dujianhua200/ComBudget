import SwiftUI

// =============================================================================
// 预算编制主界面：工程头 + 汇总条 + 定额清单 + 右侧属性面板
// =============================================================================

enum Col {
    static let index: CGFloat = 36
    static let code: CGFloat = 78
    static let name: CGFloat = 158
    static let unit: CGFloat = 44
    static let qty: CGFloat = 66
    static let coeff: CGFloat = 48
    static let tech: CGFloat = 56
    static let labor: CGFloat = 56
    static let laborCost: CGFloat = 80
    static let material: CGFloat = 78
    static let machine: CGFloat = 62
    static let instrument: CGFloat = 62
    static let total: CGFloat = 84
    static let note: CGFloat = 92

    static let rowWidth: CGFloat = index + code + name + unit + qty + coeff + tech + labor
        + laborCost + material + machine + instrument + total + note + 140
}

struct BudgetEditorView: View {
    @EnvironmentObject private var app: AppState

    @State private var showImport = false
    @State private var showReport = false
    @State private var showProperties = false
    @State private var showQuotaPicker = false
    @State private var showInspector = true
    @State private var draggedID: Int64?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                grid
                if showInspector {
                    Divider()
                    InspectorView()
                        .frame(width: 344)
                }
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showProperties) {
            if let p = app.project { ProjectPropertiesView(project: p) }
        }
        .sheet(isPresented: $showQuotaPicker) {
            QuotaPickerSheet { quota, qty in
                app.addQuota(quota, quantity: qty)
                showQuotaPicker = false
            }
        }
        .sheet(isPresented: $showImport) { ImportWizardView() }
        .sheet(isPresented: $showReport) { ReportPreviewView() }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.tint)
                Text(app.project?.name ?? "未命名工程")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text("\(app.project?.category ?? "") · \(app.project?.specialty ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if !app.bootMessage.isEmpty {
                    Text(app.bootMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    StatTile(title: "技工工日", value: Fmt.workday(app.summary.itemCost.techWorkdays))
                    StatTile(title: "普工工日", value: Fmt.workday(app.summary.itemCost.laborWorkdays))
                    StatTile(title: "人工费", value: Fmt.money(app.summary.itemCost.labor))
                    StatTile(title: "主材费", value: Fmt.money(app.summary.itemCost.mainMaterial))
                    StatTile(title: "机械费", value: Fmt.money(app.summary.itemCost.machine))
                    StatTile(title: "仪表费", value: Fmt.money(app.summary.itemCost.instrument))
                    StatTile(title: "直接费", value: Fmt.money(app.summary.itemCost.direct))
                    StatTile(title: "措施费", value: Fmt.money(app.summary.measures))
                    StatTile(title: "间接费", value: Fmt.money(app.summary.indirect))
                    StatTile(title: "利润", value: Fmt.money(app.summary.profit))
                    StatTile(title: "税金", value: Fmt.money(app.summary.tax))
                    StatTile(title: "建安工程费", value: Fmt.money(app.summary.total), emphasized: true)
                    if app.summary.itemCost.equipment > 0 {
                        StatTile(title: "设备费", value: Fmt.money(app.summary.itemCost.equipment))
                    }
                    StatTile(title: "工程总造价", value: Fmt.money(app.summary.grandTotal),
                             tint: .accentColor, emphasized: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - 工具条

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                showQuotaPicker = true
            } label: { Label("插入定额", systemImage: "plus.rectangle.on.rectangle") }
                .help("插入定额（⌘K）")
                .keyboardShortcut("k", modifiers: .command)

            Button {
                app.addBlankItem()
            } label: { Label("补充子目", systemImage: "plus.square.dashed") }

            Button {
                if let id = app.selectedItemID { app.deleteItem(id: id) }
            } label: { Label("删除", systemImage: "trash") }
                .disabled(app.selectedItemID == nil)

            Divider()

            Button {
                showImport = true
            } label: { Label("导入 Excel", systemImage: "square.and.arrow.down") }

            Button {
                writeTemplate()
            } label: { Label("空白模板", systemImage: "doc.badge.plus") }

            Divider()

            Button {
                showReport = true
            } label: { Label("报表", systemImage: "tablecells") }

            Button {
                if let url = FilePanels.save(name: "\(app.project?.name ?? "预算")-预算表.xlsx", ext: "xlsx") {
                    app.exportExcel(to: url)
                }
            } label: { Label("导出 Excel", systemImage: "arrow.up.doc") }

            Button {
                if let url = FilePanels.save(name: "\(app.project?.name ?? "预算")-预算表.pdf", ext: "pdf") {
                    app.exportPDF(to: url)
                }
            } label: { Label("导出 PDF", systemImage: "arrow.up.doc.fill") }

            Button {
                app.printReports()
            } label: { Label("打印", systemImage: "printer") }

            Divider()

            Button {
                showProperties = true
            } label: { Label("工程属性", systemImage: "slider.horizontal.3") }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showInspector.toggle() }
            } label: { Label("属性面板", systemImage: "sidebar.right") }

            Divider()

            NumberField(value: $app.techPrice, fractionDigits: 0...2, width: 44)
                .help("技工单价（元/工日）")
            Text("技工").font(.system(size: 10)).foregroundStyle(.secondary)
            NumberField(value: $app.laborPrice, fractionDigits: 0...2, width: 44)
                .help("普工单价（元/工日）")
            Text("普工").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: - 清单

    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                Divider()
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(app.items.enumerated()), id: \.element.id) { index, item in
                            row(index: index, item: item)
                        }
                        if app.items.isEmpty {
                            emptyHint
                        }
                    }
                }
            }
            .frame(width: Col.rowWidth, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Text("共 \(app.items.count) 条子目")
                Text("·")
                Text(app.status).lineLimit(1)
                Spacer()
                Text("拖动行可排序 · 双击/回车编辑")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            cell("序号", Col.index, .center)
            cell("定额编号", Col.code, .leading)
            cell("定额名称", Col.name, .leading)
            cell("单位", Col.unit, .center)
            cell("工程量", Col.qty, .trailing)
            cell("系数", Col.coeff, .trailing)
            cell("技工", Col.tech, .trailing)
            cell("普工", Col.labor, .trailing)
            cell("人工费", Col.laborCost, .trailing)
            cell("主材费", Col.material, .trailing)
            cell("机械费", Col.machine, .trailing)
            cell("仪表费", Col.instrument, .trailing)
            cell("小计", Col.total, .trailing)
            cell("备注", Col.note, .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private func cell(_ text: String, _ width: CGFloat, _ align: TextAlignment) -> some View {
        Text(text)
            .frame(width: width, alignment: align == .trailing ? .trailing
                   : (align == .center ? .center : .leading))
            .padding(.horizontal, 3)
            .multilineTextAlignment(align)
    }

    private func row(index: Int, item: ProjectItem) -> some View {
        let cost = app.costs[item.id] ?? ItemCost()
        let selected = app.selectedItemID == item.id

        return HStack(spacing: 0) {
            Text("\(index + 1)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: Col.index, alignment: .center)

            Text(item.quotaCode)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tint)
                .lineLimit(1)
                .frame(width: Col.code, alignment: .leading)

            TextField("", text: Binding(
                get: { item.quotaName },
                set: { v in app.apply({ $0.quotaName = v }, to: item.id) }))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: Col.name, alignment: .leading)

            Text(item.unit)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: Col.unit, alignment: .center)

            NumberField(value: Binding(
                get: { item.quantity },
                set: { v in app.apply({ $0.quantity = v }, to: item.id) }), width: Col.qty)

            NumberField(value: Binding(
                get: { item.workdayCoeff },
                set: { v in app.apply({ $0.workdayCoeff = v }, to: item.id) }),
                        fractionDigits: 0...3, width: Col.coeff)

            num(Fmt.workday(cost.techWorkdays), Col.tech)
            num(Fmt.workday(cost.laborWorkdays), Col.labor)
            num(Fmt.money(cost.labor), Col.laborCost)
            num(Fmt.money(cost.mainMaterial), Col.material)
            num(Fmt.money(cost.machine), Col.machine)
            num(Fmt.money(cost.instrument), Col.instrument)
            num(Fmt.money(cost.direct), Col.total, bold: true)

            TextField("", text: Binding(
                get: { item.note },
                set: { v in app.apply({ $0.note = v }, to: item.id) }))
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Col.note, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(selected ? Color.accentColor.opacity(0.14)
                    : (index % 2 == 1 ? Color.gray.opacity(0.04) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { app.selectedItemID = item.id }
        .contextMenu {
            Button("上移") { app.moveItemUp(id: item.id) }
            Button("下移") { app.moveItemDown(id: item.id) }
            Divider()
            Button("删除此行", role: .destructive) { app.deleteItem(id: item.id) }
        }
        .draggable(String(item.id)) {
            Text(item.quotaName)
                .font(.system(size: 11))
                .padding(4)
                .background(Color.accentColor.opacity(0.15))
        }
        .dropDestination(for: String.self) { payload, _ in
            guard let first = payload.first, let id = Int64(first), id != item.id else { return false }
            app.moveItem(id: id, to: item.id)
            return true
        }
    }

    private func num(_ text: String, _ width: CGFloat, bold: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: bold ? .medium : .regular, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
            .padding(.horizontal, 3)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Text("清单为空").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("插入定额") { showQuotaPicker = true }
                Button("导入 Excel") { showImport = true }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - 动作

    private func writeTemplate() {
        guard let url = FilePanels.save(name: "定额导入模板.xlsx", ext: "xlsx") else { return }
        do {
            try ExcelImporter.writeTemplate(to: url)
            app.status = "已生成模板：\(url.lastPathComponent)"
        } catch {
            app.alertMessage = error.localizedDescription
        }
    }
}
