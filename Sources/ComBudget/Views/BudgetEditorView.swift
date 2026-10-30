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
    @State private var showConversion = false
    @State private var showPriceImport = false

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
        .sheet(isPresented: $showConversion) {
            if let id = app.selectedItemID { ConversionSheet(itemID: id) }
        }
        .sheet(isPresented: $showPriceImport) { PriceImportWizard() }
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

            Divider()

            // 撤销 / 重做：自己的 History 栈，一步 = 一次用户操作
            Button { app.undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                .disabled(!app.canUndo)
                .help(app.undoTitle)
            Button { app.redo() } label: { Label("重做", systemImage: "arrow.uturn.forward") }
                .disabled(!app.canRedo)
                .help(app.redoTitle)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showImport = true
            } label: { Label("导入", systemImage: "square.and.arrow.down") }
                .help("从 Excel 批量导入定额行")

            // 套价：451 手册只给消耗量，单价来自价格库/询价
            Menu {
                Button("按价格库套价（覆盖全部）") { app.applyPricesToProject(overwrite: true) }
                Button("只补未定价的资源") { app.applyPricesToProject(overwrite: false) }
                Divider()
                Button("导入价格清单…") { showPriceImport = true }
                Button("生成价格模板…") { writePriceTemplate() }
                Divider()
                Button("打开资源价格库") { app.select(.price) }
            } label: {
                Label("套价", systemImage: "yensign.circle")
            }
            .help("用价格库给主材/机械/仪表填单价")

            // 定额换算：人工/机械/仪表系数
            Menu {
                Button("换算选中子目…") { showConversion = true }
                    .disabled(app.selectedItemID == nil)
                if app.convertedItemCount > 0 {
                    Button("还原选中子目为定额原值") {
                        if let id = app.selectedItemID { app.revokeConversion(id: id) }
                    }
                }
                Divider()
                Menu("整工程套用") {
                    ForEach(ConversionPresets.all) { rule in
                        Button(rule.name) { app.convertProject(rule: rule) }
                    }
                }
            } label: {
                Label("换算", systemImage: "slider.horizontal.3")
            }
            .help("定额换算（人工/机械/仪表系数）")

            Picker("分组", selection: Binding(
                get: { app.grouping },
                set: { app.setGrouping($0) })) {
                ForEach(GroupingKey.allCases) { key in
                    Text(key.rawValue).tag(key)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 110)
            .help("按分册 / 章分组并显示分部小计")

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
                ItemTable(app: app)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Text("\(app.items.count) 条子目")
                if let hint = priceHint {
                    Text("·")
                    Text(hint)
                        .foregroundStyle(app.prices.isEmpty ? Color.secondary : Color.orange)
                        .help("451 手册不含单价，主材/机械/仪表需要在价格库里填价后套价")
                }
                Text("·")
                Text(app.status).lineLimit(1)
                Spacer()
                Text("双击单元格编辑 · 拖动行排序 · 列宽可拖")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
    }

    /// 底部状态栏的套价提示：让「主材费为 0」这件事有个明确解释
    private var priceHint: String? {
        let audit = app.priceAudit()
        guard audit.total > 0, audit.unpriced > 0 else { return nil }
        return "未定价资源 \(audit.unpriced)/\(audit.total)"
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

    private func writeTemplate() {
        guard let url = FilePanels.save(name: "定额导入模板.xlsx", ext: "xlsx") else { return }
        do {
            try ExcelImporter.writeTemplate(to: url)
            app.status = "已生成模板：\(url.lastPathComponent)"
        } catch {
            app.alertMessage = error.localizedDescription
        }
    }

    /// 价格清单模板（类型/名称/规格/单位/单价/来源 六列）
    private func writePriceTemplate() {
        guard let url = FilePanels.save(name: "价格库导入模板.xlsx", ext: "xlsx") else { return }
        app.writePriceTemplate(to: url)
    }
}
