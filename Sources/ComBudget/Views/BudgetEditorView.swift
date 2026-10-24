import SwiftUI

// =============================================================================
// 预算编制主界面
//
// 表格用 SwiftUI `Table`（底层是 NSTableView）：
//   原生表头、隔行底纹、原生选中、可拖列宽、列排序 —— 这是「原生感」的关键。
// 大规模行编辑仍走 AppState.apply（写库 → 重算），但只对数值列用可提交输入框，
// 名称/备注在右侧属性面板里改，避免逐字符写库打断输入。
// =============================================================================

struct BudgetEditorView: View {
    @EnvironmentObject private var app: AppState

    @State private var showImport = false
    @State private var showReport = false
    @State private var showProperties = false
    @State private var showQuotaPicker = false
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                tableArea
                if showInspector {
                    Divider()
                    InspectorView()
                        .frame(width: 340)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.tint)
                    .font(.system(size: 13))
                Text(app.project?.name ?? "未命名工程")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(app.project?.category ?? "") · \(app.project?.specialty ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
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
                    StatTile(title: "总造价", value: Fmt.money(app.summary.grandTotal),
                             tint: .accentColor, emphasized: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 7)
    }

    // MARK: - 工具条

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                showQuotaPicker = true
            } label: { Label("插入定额", systemImage: "plus.rectangle.on.rectangle") }
                .help("插入定额（⌘K）")
                .keyboardShortcut("k", modifiers: .command)

            Button {
                app.addBlankItem()
            } label: { Label("补充子目", systemImage: "plus.square.dashed") }
                .help("新增一条补充定额")

            Button {
                if let id = app.selectedItemID { app.deleteItem(id: id) }
            } label: { Label("删除", systemImage: "trash") }
                .disabled(app.selectedItemID == nil)
                .help("删除选中子目")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showImport = true
            } label: { Label("导入", systemImage: "square.and.arrow.down") }
                .help("从 Excel 批量导入定额行")

            Button {
                showReport = true
            } label: { Label("报表", systemImage: "tablecells") }
                .help("预算汇总 / 明细 / 主材 / 机械仪表")

            Menu {
                Button("导出 Excel…") {
                    if let url = FilePanels.save(name: "\(app.project?.name ?? "预算")-预算表.xlsx",
                                                 ext: "xlsx") { app.exportExcel(to: url) }
                }
                Button("导出 PDF…") {
                    if let url = FilePanels.save(name: "\(app.project?.name ?? "预算")-预算表.pdf",
                                                 ext: "pdf") { app.exportPDF(to: url) }
                }
                Divider()
                Button("打印…") { app.printReports() }
                Divider()
                Button("生成导入模板…") { writeTemplate() }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .help("导出 Excel / PDF / 打印")

            Button {
                showProperties = true
            } label: { Label("工程属性", systemImage: "info.circle") }
                .help("工程属性")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showInspector.toggle() }
            } label: { Label("属性面板", systemImage: "sidebar.right") }
                .help("显示 / 隐藏右侧属性面板")
        }
    }

    // MARK: - 表格

    private var tableArea: some View {
        Group {
            if app.items.isEmpty {
                emptyHint
            } else {
                // 注意：TableColumnBuilder 单层最多 10 列，故用 TableColumnGroup 分组表头
                Table(app.items, selection: $app.selectedItemID) {
                    TableColumnGroup("定额") {
                        TableColumn("序号") { item in
                            Text("\(index(of: item) + 1)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .width(38)

                        TableColumn("编号") { item in
                            Text(item.quotaCode)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tint)
                        }
                        .width(78)

                        TableColumn("名称") { item in
                            Text(item.quotaName)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .help(item.quotaName)
                        }
                        .width(min: 150, ideal: 230)

                        TableColumn("单位") { item in
                            Text(item.unit)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .width(46)
                    }

                    TableColumnGroup("工程量") {
                        TableColumn("数量") { item in
                            TextField("", value: Binding(
                                get: { item.quantity },
                                set: { v in app.apply({ $0.quantity = v }, to: item.id) }),
                                      format: .number.precision(.fractionLength(0...4)))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 11, design: .rounded))
                                .monospacedDigit()
                        }
                        .width(74)

                        TableColumn("系数") { item in
                            TextField("", value: Binding(
                                get: { item.workdayCoeff },
                                set: { v in app.apply({ $0.workdayCoeff = v }, to: item.id) }),
                                      format: .number.precision(.fractionLength(0...3)))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 11, design: .rounded))
                                .monospacedDigit()
                        }
                        .width(54)

                        TableColumn("技工") { item in
                            num(readonlyCost(item)?.techWorkdays, formatter: Fmt.workday)
                        }
                        .width(52)

                        TableColumn("普工") { item in
                            num(readonlyCost(item)?.laborWorkdays, formatter: Fmt.workday)
                        }
                        .width(52)
                    }

                    TableColumnGroup("费用（元）") {
                        TableColumn("人工费") { item in
                            num(readonlyCost(item)?.labor, formatter: Fmt.money)
                        }
                        .width(80)

                        TableColumn("主材费") { item in
                            num(readonlyCost(item)?.mainMaterial, formatter: Fmt.money)
                        }
                        .width(78)

                        TableColumn("机械费") { item in
                            num(readonlyCost(item)?.machine, formatter: Fmt.money)
                        }
                        .width(70)

                        TableColumn("仪表费") { item in
                            num(readonlyCost(item)?.instrument, formatter: Fmt.money)
                        }
                        .width(70)

                        TableColumn("小计") { item in
                            num(readonlyCost(item)?.direct, formatter: Fmt.money, bold: true)
                        }
                        .width(88)
                    }

                    TableColumn("备注") { item in
                        Text(item.note)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(item.note)
                    }
                    .width(min: 60, ideal: 110)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: ProjectItem.ID.self) { ids in
                    Button("上移") { ids.forEach { app.moveItemUp(id: $0) } }
                    Button("下移") { ids.forEach { app.moveItemDown(id: $0) } }
                    Divider()
                    Button("在属性面板中编辑") { app.selectedItemID = ids.first }
                    Button("删除", role: .destructive) { ids.forEach { app.deleteItem(id: $0) } }
                } primaryAction: { ids in
                    app.selectedItemID = ids.first
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Text("\(app.items.count) 条子目")
                Text("·")
                Text(app.status).lineLimit(1)
                Spacer()
                Text("数值列可直接改；名称/备注在右侧面板编辑")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "tablecells")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("清单为空").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("插入定额") { showQuotaPicker = true }
                Button("导入 Excel") { showImport = true }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 小工具

    private func index(of item: ProjectItem) -> Int {
        app.items.firstIndex { $0.id == item.id } ?? 0
    }

    private func readonlyCost(_ item: ProjectItem) -> ItemCost? {
        app.costs[item.id]
    }

    private func num(_ value: Double?, formatter: (Double) -> String,
                     bold: Bool = false) -> some View {
        Text(value.map(formatter) ?? "—")
            .font(.system(size: 11, weight: bold ? .medium : .regular, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
    }

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
