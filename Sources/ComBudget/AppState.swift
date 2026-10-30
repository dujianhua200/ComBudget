import Foundation
import Combine
import AppKit

// =============================================================================
// 应用状态（MVVM 的 ViewModel）
// 数据流：SQLite（唯一真源）→ AppState 内存快照 → SwiftUI 视图
// 任何修改：先写库 → 再改内存 → 最后重算，界面与库不会脱节。
// =============================================================================

@MainActor
final class AppState: ObservableObject {

    enum Route: Hashable {
        case project(Int64)
        case quota
        case fee
        case price
    }

    // MARK: - 数据

    let dbs: AppDatabase

    @Published var projects: [Project] = []
    @Published var project: Project?
    @Published var items: [ProjectItem] = []
    @Published var costs: [Int64: ItemCost] = [:]
    @Published var summary = BudgetSummary()
    @Published var templates: [FeeTemplate] = []

    @Published var route: Route?
    @Published var selectedItemID: Int64?
    /// 变更版本号：每次重算 +1，供 NSTableView 判断是否需要 reload
    @Published var revision: Int = 0

    // ── 撤销 / 重做 ──
    /// 撤销栈（每步登记的是「一次用户操作」，而不是一个字段）
    let history = History()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var undoTitle = "撤销"
    @Published private(set) var redoTitle = "重做"

    // ── 分组小计 ──
    @Published var grouping: GroupingKey = .none
    @Published private(set) var groups: [ItemGroup] = []

    // ── 价格库 ──
    @Published var prices: [PriceEntry] = []

    @Published var status: String = "就绪"
    @Published var alertMessage: String?
    @Published var bootMessage: String = ""

    /// 人工单价（新插入子目时套用，可在工具条修改）
    @Published var techPrice: Double = UserDefaults.standard.object(forKey: "techPrice") as? Double ?? 114 {
        didSet { UserDefaults.standard.set(techPrice, forKey: "techPrice") }
    }
    @Published var laborPrice: Double = UserDefaults.standard.object(forKey: "laborPrice") as? Double ?? 61 {
        didSet { UserDefaults.standard.set(laborPrice, forKey: "laborPrice") }
    }

    // MARK: - 初始化

    init(path: String? = nil) {
        var database: AppDatabase
        do {
            let p = try path ?? AppDatabase.defaultPath()
            database = try AppDatabase(path: p)
        } catch {
            // 主库不可用时退到临时库，保证程序能启动（只影响持久化）
            let fallback = NSTemporaryDirectory() + "combudget-fallback-\(UUID().uuidString).db"
            database = try! AppDatabase(path: fallback)
            alertMessage = "无法打开主数据库，已切换到临时库：\(error.localizedDescription)"
        }
        dbs = database
        bootMessage = database.seedStatus
        reloadAll(selectFirst: true)
        reloadPrices()

        // 调试用：COMBUDGET_ROUTE=quota|fee|price 可直接打开对应页面（截图/排障）
        if let r = ProcessInfo.processInfo.environment["COMBUDGET_ROUTE"] {
            switch r {
            case "quota": select(.quota)
            case "fee":   select(.fee)
            case "price": select(.price)
            default:      break
            }
        }
    }

    // MARK: - 载入

    func reloadAll(selectFirst: Bool = false) {
        do {
            projects = try dbs.project.list()
            templates = try dbs.fee.templates()
            if let current = project, let fresh = try dbs.project.project(id: current.id) {
                project = fresh
                loadItems()
            } else if selectFirst, let first = projects.first {
                select(.project(first.id))
            } else if projects.isEmpty {
                project = nil
                items = []
                costs = [:]
                summary = BudgetSummary()
                route = nil
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func select(_ r: Route) {
        route = r
        guard case .project(let id) = r else { return }
        do {
            guard let p = try dbs.project.project(id: id) else { return }
            project = p
            selectedItemID = nil
            loadItems()
            status = "已打开工程：\(p.name)"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func loadItems() {
        guard let p = project else { items = []; return }
        do {
            items = try dbs.project.items(projectID: p.id)
            if selectedItemID == nil || !items.contains(where: { $0.id == selectedItemID }) {
                selectedItemID = items.first?.id
            }
            recalc()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func recalc() {
        costs = BudgetCalculator.rowCosts(items: items, template: currentTemplate)
        summary = BudgetCalculator.summarize(items: items, template: currentTemplate)
        groups = BudgetGrouping.group(items: items, costs: costs, key: grouping)
        revision &+= 1
    }

    // MARK: - 撤销 / 重做

    /// 把一次已发生的变更登记进撤销栈（界面所有写操作都走这里）
    func record(_ label: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        history.register(label, undo: undo, redo: redo)
        syncHistory()
    }

    private func syncHistory() {
        canUndo = history.canUndo
        canRedo = history.canRedo
        undoTitle = history.undoLabel.map { "撤销 “\($0)”" } ?? "撤销"
        redoTitle = history.redoLabel.map { "重做 “\($0)”" } ?? "重做"
    }

    func undo() {
        guard history.undo() else { return }
        refreshItems()
        status = "已撤销"
    }

    func redo() {
        guard history.redo() else { return }
        refreshItems()
        status = "已重做"
    }

    /// 重新从库读一遍当前工程的子目（撤销/重做后统一刷新，避免内存与库不一致）
    func refreshItems() {
        guard let p = project else { return }
        do {
            items = try dbs.project.items(projectID: p.id)
            if selectedItemID == nil || !items.contains(where: { $0.id == selectedItemID }) {
                selectedItemID = items.first?.id
            }
            recalc()
            syncHistory()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 把子目快照写回库（含资源），撤销/重做用它回到某个时点
    func writeBack(_ snapshot: ProjectItem) {
        do {
            _ = try dbs.project.restoreItem(snapshot)
            if let idx = items.firstIndex(where: { $0.id == snapshot.id }) { items[idx] = snapshot }
            recalc()
        } catch { alertMessage = error.localizedDescription }
    }

    /// 批量写回（整套edo/undo）
    func writeBackAll(_ snapshots: [ProjectItem]) {
        do {
            for snap in snapshots { _ = try dbs.project.restoreItem(snap) }
            if let p = project { try dbs.project.touch(id: p.id) }
        } catch { alertMessage = error.localizedDescription }
    }

    var currentTemplate: FeeTemplate? {
        guard let id = project?.feeTemplateID else { return templates.first }
        return templates.first { $0.id == id } ?? templates.first
    }

    var selectedItem: ProjectItem? {
        guard let id = selectedItemID else { return nil }
        return items.first { $0.id == id }
    }

    // MARK: - 工程

    func newProject() {
        do {
            var draft = Project.newDraft()
            draft.feeTemplateID = templates.first?.id ?? 0
            draft.compiler = NSUserName()
            let created = try dbs.project.create(draft)
            projects = try dbs.project.list()
            select(.project(created.id))
            status = "已新建工程，请填写工程属性"
            record("新建工程",
                   undo: { [weak self] in self?.deleteProjectSilently(created.id) },
                   redo: { [weak self] in self?.restoreProjectSnapshot(created, items: []) })
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func saveProject(_ p: Project) {
        do {
            try dbs.project.update(p)
            project = p
            projects = try dbs.project.list()
            recalc()
            status = "工程属性已保存"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteProject(id: Int64) {
        guard let snapshot = try? dbs.project.project(id: id) else { return }
        let itemSnapshots = (try? dbs.project.items(projectID: snapshot.id)) ?? []
        do {
            try dbs.project.delete(id: id)
            if project?.id == id { project = nil; items = []; route = nil }
            projects = try dbs.project.list()
            if project == nil, let first = projects.first { select(.project(first.id)) }
            status = "工程已删除（⌘Z 可撤销）"
            record("删除工程《\(snapshot.name)》",
                   undo: { [weak self] in self?.restoreProjectSnapshot(snapshot, items: itemSnapshots) },
                   redo: { [weak self] in self?.deleteProjectSilently(id) })
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func duplicateProject(id: Int64) {
        do {
            guard let src = try dbs.project.project(id: id) else { return }
            let newID = try dbs.project.duplicate(projectID: id, newName: src.name + " 副本")
            projects = try dbs.project.list()
            select(.project(newID))
            status = "已复制工程"
            record("复制工程",
                   undo: { [weak self] in self?.deleteProjectSilently(newID) },
                   redo: { [weak self] in
                       guard let self else { return }
                       if let s = self.projectSnapshotCache[newID] {
                           self.restoreProjectSnapshot(s.project, items: s.items)
                       }
                   })
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 工程快照缓存：复制出来的工程 id → 快照，供「重做」还原
    private var projectSnapshotCache: [Int64: (project: Project, items: [ProjectItem])] = [:]

    private func restoreProjectSnapshot(_ p: Project, items: [ProjectItem]) {
        do {
            _ = try dbs.project.restoreProject(p)
            for item in items { _ = try dbs.project.restoreItem(item) }
            projects = try dbs.project.list()
            select(.project(p.id))
        } catch { alertMessage = error.localizedDescription }
    }

    private func deleteProjectSilently(_ id: Int64) {
        do {
            let snapshot = try dbs.project.project(id: id)
            let itemSnapshots = try dbs.project.items(projectID: id)
            if let snapshot { projectSnapshotCache[id] = (snapshot, itemSnapshots) }
            try dbs.project.delete(id: id)
            projects = try dbs.project.list()
            if project?.id == id { project = nil; self.items = []; route = nil }
            if let first = projects.first { select(.project(first.id)) }
        } catch { alertMessage = error.localizedDescription }
    }

    // MARK: - 子目

    /// 通用字段修改（不整表 reload，避免打断输入）
    /// 一次调用 = 一步撤销，所以要带上语义化的动作名（「修改工程量」之类）
    func apply(_ mutate: (inout ProjectItem) -> Void, to itemID: Int64,
               undoLabel: String = "修改子目") {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        let before = items[idx]
        mutate(&items[idx])
        do {
            try dbs.project.updateItem(items[idx])
            try dbs.project.touch(id: items[idx].projectID)
            recalc()
            let after = items[idx]
            record(undoLabel,
                   undo: { [weak self] in self?.writeBack(before) },
                   redo: { [weak self] in self?.writeBack(after) })
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func addQuota(_ quota: QuotaItem, quantity: Double) {
        guard let p = project else { return }
        do {
            let item = try dbs.project.insertItem(projectID: p.id, quota: quota, quantity: quantity,
                                                  techPrice: techPrice, laborPrice: laborPrice)
            loadItems()
            selectedItemID = item.id
            status = "已插入 \(quota.code) \(quota.name)"
            let snapshot = item
            record("插入 \(quota.code)",
                   undo: { [weak self] in self?.removeItemSnapshot(snapshot) },
                   redo: { [weak self] in self?.restoreSnapshot(snapshot) })
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func addBlankItem() {
        guard let p = project else { return }
        do {
            let item = try dbs.project.insertBlankItem(projectID: p.id,
                                                      techPrice: techPrice, laborPrice: laborPrice)
            loadItems()
            selectedItemID = item.id
            status = "已添加补充定额行"
            let snapshot = item
            record("新增补充子目",
                   undo: { [weak self] in self?.removeItemSnapshot(snapshot) },
                   redo: { [weak self] in self?.restoreSnapshot(snapshot) })
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteItem(id: Int64) {
        guard let snapshot = items.first(where: { $0.id == id }) else { return }
        do {
            try dbs.project.deleteItem(id: id)
            loadItems()
            status = "已删除子目"
            record("删除子目",
                   undo: { [weak self] in self?.restoreSnapshot(snapshot) },
                   redo: { [weak self] in self?.removeItemSnapshot(snapshot) })
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func removeItemSnapshot(_ snapshot: ProjectItem) {
        do { try dbs.project.deleteItem(id: snapshot.id) } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func restoreSnapshot(_ snapshot: ProjectItem) {
        do { _ = try dbs.project.restoreItem(snapshot) } catch {
            alertMessage = error.localizedDescription
        }
    }

    func moveItem(id: Int64, to targetID: Int64) {
        guard let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == targetID }), from != to else { return }
        let before = items.map { $0.id }
        let moved = items.remove(at: from)
        items.insert(moved, at: to)
        guard let p = project else { return }
        let ids = items.map { $0.id }
        for i in ids.indices { items[i].sortIndex = i + 1 }
        do {
            try dbs.project.reorder(projectID: p.id, orderedIDs: ids)
            let projectID = p.id
            record("调整行顺序",
                   undo: { [weak self] in self?.applyOrder(before, projectID: projectID) },
                   redo: { [weak self] in self?.applyOrder(ids, projectID: projectID) })
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func applyOrder(_ ids: [Int64], projectID: Int64) {
        do { try dbs.project.reorder(projectID: projectID, orderedIDs: ids) } catch {
            alertMessage = error.localizedDescription
        }
    }

    func moveItemUp(id: Int64) {
        guard let idx = items.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        moveItem(id: id, to: items[idx - 1].id)
    }

    func moveItemDown(id: Int64) {
        guard let idx = items.firstIndex(where: { $0.id == id }), idx + 1 < items.count else { return }
        moveItem(id: id, to: items[idx + 1].id)
    }

    // MARK: - 子目资源

    func addResource(itemID: Int64, kind: ResourceKind) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        let before = items[idx].resources
        items[idx].resources.append(ItemResource(itemID: itemID, kind: kind,
                                                 name: "补充\(kind.rawValue)", spec: "", unit: "",
                                                 qtyPerUnit: 1, qtyOverride: nil,
                                                 unitPrice: 0, isExtra: true))
        persistResources(itemIndex: idx)
        let after = items[idx].resources
        let ownerID = itemID
        record("补充\(kind.rawValue)",
               undo: { [weak self] in self?.writeResources(before, itemID: ownerID) },
               redo: { [weak self] in self?.writeResources(after, itemID: ownerID) })
    }

    func updateResource(_ res: ItemResource) {
        guard let idx = items.firstIndex(where: { $0.id == res.itemID }),
              let rIdx = items[idx].resources.firstIndex(where: { $0.id == res.id }) else { return }
        let before = items[idx].resources
        items[idx].resources[rIdx] = res
        persistResources(itemIndex: idx)
        let after = items[idx].resources
        let ownerID = res.itemID
        record("修改资源 \(res.name)",
               undo: { [weak self] in self?.writeResources(before, itemID: ownerID) },
               redo: { [weak self] in self?.writeResources(after, itemID: ownerID) })
    }

    func removeResource(itemID: Int64, resourceID: Int64) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        let before = items[idx].resources
        items[idx].resources.removeAll { $0.id == resourceID }
        persistResources(itemIndex: idx)
        let after = items[idx].resources
        record("移除资源",
               undo: { [weak self] in self?.writeResources(before, itemID: itemID) },
               redo: { [weak self] in self?.writeResources(after, itemID: itemID) })
    }

    func persistResources(itemIndex idx: Int) {
        let item = items[idx]
        do {
            try dbs.project.replaceResources(itemID: item.id, resources: item.resources)
            items[idx].resources = try dbs.project.resources(itemID: item.id)
            recalc()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 直接写一整套资源（撤销/重做用），写完顺带刷新内存
    func writeResources(_ snapshot: [ItemResource], itemID: Int64) {
        do {
            try dbs.project.replaceResources(itemID: itemID, resources: snapshot)
            if let idx = items.firstIndex(where: { $0.id == itemID }) {
                items[idx].resources = try dbs.project.resources(itemID: itemID)
            }
            recalc()
        } catch { alertMessage = error.localizedDescription }
    }

    /// 批量把某类资源的价格设为指定值（主材批量填价用）
    func batchSetPrice(itemID: Int64, kind: ResourceKind, price: Double) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        for i in items[idx].resources.indices where items[idx].resources[i].kind == kind {
            items[idx].resources[i].unitPrice = price
        }
        persistResources(itemIndex: idx)
    }

    // MARK: - Excel 导入

    func analyzeImport(url: URL, config: ImportConfig) -> ImportReport? {
        do { return try ExcelImporter.analyze(url: url, config: config, quota: dbs.quota) } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func commitImport(_ report: ImportReport) -> Int {
        guard let p = project else { return 0 }
        let before = items
        do {
            let n = try ExcelImporter.commit(report: report, projectID: p.id,
                                             techPrice: techPrice, laborPrice: laborPrice,
                                             store: dbs.project)
            loadItems()
            status = "导入完成：写入 \(n) 条子目"
            let snapshot = try dbs.project.items(projectID: p.id)
            let added = snapshot.filter { s in !before.contains(where: { $0.id == s.id }) }
            let ids = added.map { $0.id }
            record("导入 \(n) 条子目",
                   undo: { [weak self] in self?.deleteItems(ids) },
                   redo: { [weak self] in self?.writeBackAll(added) })
            return n
        } catch {
            alertMessage = error.localizedDescription
            return 0
        }
    }

    func deleteItems(_ ids: [Int64]) {
        do {
            for id in ids { try dbs.project.deleteItem(id: id) }
        } catch { alertMessage = error.localizedDescription }
    }

    // MARK: - 报表

    func reportTables() -> [ReportTable] {
        guard let p = project else { return [] }
        return [
            ReportBuilder.summaryTable(project: p, template: currentTemplate, summary: summary),
            ReportBuilder.detailTable(project: p, items: items, costs: costs,
                                      summary: summary, grouping: grouping),
            ReportBuilder.materialTable(project: p, items: items),
            ReportBuilder.machineTable(project: p, items: items)
        ]
    }

    func exportExcel(to url: URL) {
        do {
            try ExcelExporter.export(tables: reportTables(), to: url)
            status = "已导出 Excel：\(url.lastPathComponent)"
        } catch { alertMessage = error.localizedDescription }
    }

    func exportPDF(to url: URL) {
        do {
            try PDFExporter.export(tables: reportTables(), to: url)
            status = "已导出 PDF：\(url.lastPathComponent)"
        } catch { alertMessage = error.localizedDescription }
    }

    func printReports() {
        do { try PDFExporter.print(tables: reportTables()) } catch {
            alertMessage = error.localizedDescription
        }
    }

    func exportBundle(to url: URL) {
        guard let p = project else { return }
        do {
            try ProjectBundle.export(db: dbs.db, projectID: p.id, to: url)
            status = "工程已另存为 \(url.lastPathComponent)"
        } catch { alertMessage = error.localizedDescription }
    }

    func importBundle(from url: URL) {
        do {
            let ids = try ProjectBundle.importBundle(db: dbs.db, from: url)
            projects = try dbs.project.list()
            if let first = ids.first { select(.project(first)) }
            status = "已导入 \(ids.count) 个工程"
        } catch { alertMessage = error.localizedDescription }
    }

    // MARK: - 定额库

    func reimportSeed() {
        do {
            bootMessage = try dbs.reimportSeed()
            status = bootMessage
        } catch { alertMessage = error.localizedDescription }
    }

    // MARK: - 取费模板

    func saveTemplate(_ tpl: FeeTemplate) {
        do {
            var t = tpl
            try dbs.fee.save(&t)
            templates = try dbs.fee.templates()
            recalc()
            status = "取费模板已保存：\(t.name)"
        } catch { alertMessage = error.localizedDescription }
    }

    func deleteTemplate(id: Int64) {
        do {
            try dbs.fee.delete(id: id)
            templates = try dbs.fee.templates()
            status = "取费模板已删除"
        } catch { alertMessage = error.localizedDescription }
    }

    func newTemplate() -> FeeTemplate {
        var tpl = SeedLibrary.defaultFeeTemplate()
        tpl.id = 0
        tpl.isBuiltin = false
        tpl.name = "新取费模板"
        return tpl
    }
}
