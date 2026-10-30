import SwiftUI
import AppKit

// =============================================================================
// 原生清单表格：NSViewRepresentable 包 NSTableView
//
// 为什么不用 SwiftUI 的 Table：
//   · Table 的 TableColumnBuilder 单层最多 10 列，本清单有 14 列；
//   · Table 不支持拖拽重排；列宽/表头样式也不如 NSTableView 可控。
// 用真正的 NSTableView 得到的是：原生表头、隔行底纹、原生选中、列宽拖动、
// 单元格就地编辑、拖拽排序、右键菜单 —— 与系统 App 完全一致的手感。
// =============================================================================

/// 列定义
enum ItemColumnSpec: String, CaseIterable {
    case index, code, name, unit, qty, coeff, tech, labor, laborCost
    case material, machine, instrument, subtotal, note

    var title: String {
        switch self {
        case .index: return "序号"
        case .code: return "定额编号"
        case .name: return "定额名称"
        case .unit: return "单位"
        case .qty: return "工程量"
        case .coeff: return "工日系数"
        case .tech: return "技工"
        case .labor: return "普工"
        case .laborCost: return "人工费"
        case .material: return "主材费"
        case .machine: return "机械费"
        case .instrument: return "仪表费"
        case .subtotal: return "小计"
        case .note: return "备注"
        }
    }

    var width: CGFloat {
        switch self {
        case .index: return 40
        case .code: return 84
        case .name: return 180
        case .unit: return 48
        case .qty: return 74
        case .coeff: return 62
        case .tech: return 56
        case .labor: return 56
        case .laborCost: return 82
        case .material: return 80
        case .machine: return 72
        case .instrument: return 72
        case .subtotal: return 90
        case .note: return 100
        }
    }

    var alignment: NSTextAlignment {
        switch self {
        case .index, .unit: return .center
        case .qty, .coeff, .tech, .labor, .laborCost, .material, .machine, .instrument, .subtotal:
            return .right
        default: return .left
        }
    }

    /// 可直接编辑的列（数值可在表格里改，名称/备注也在表格里改，与旧版一致）
    var editable: Bool {
        switch self {
        case .name, .qty, .coeff, .note: return true
        default: return false
        }
    }

    var mono: Bool {
        switch self {
        case .code, .qty, .coeff, .tech, .labor, .laborCost, .material,
             .machine, .instrument, .subtotal: return true
        default: return false
        }
    }
}

struct ItemTable: NSViewRepresentable {
    @ObservedObject var app: AppState

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = .separatorColor
        table.headerView = NSTableHeaderView()
        table.floatsGroupRows = false

        for spec in ItemColumnSpec.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.rawValue))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = min(spec.width, 44)
            column.headerCell.alignment = spec.alignment
            table.addTableColumn(column)
        }

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([.budgetRow])
        context.coordinator.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.app = app
        guard let table = nsView.documentView as? NSTableView else { return }

        if coordinator.revision != app.revision {
            coordinator.revision = app.revision
            table.reloadData()
        }
        if let id = app.selectedItemID,
           let row = context.coordinator.rowIndex(ofItemID: id),
           table.selectedRow != row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

        /// 表格里的一行：可能是子目，也可能是分组标题 / 分组小计
        struct Row {
            enum Kind { case item, groupHeader, groupSubtotal }
            var kind: Kind = .item
            var item: ProjectItem?
            var group: ItemGroup?
        }

        var app: AppState
        weak var tableView: NSTableView?
        var revision = -1

        // ── 分组行的行模型缓存（revision 变了才重算）──
        private var rowCache: [Row] = []
        private var rowRevision = -1
        private var rowGrouping: GroupingKey = .none

        init(app: AppState) { self.app = app }

        /// 展开后的行序列：分组开启时 = 组标题 + 组内子目 + 组小计，顺序与清单一致
        func rows() -> [Row] {
            if rowRevision == app.revision, rowGrouping == app.grouping, !rowCache.isEmpty {
                return rowCache
            }
            rowRevision = app.revision
            rowGrouping = app.grouping
            guard app.grouping != .none, !app.groups.isEmpty else {
                rowCache = app.items.map { Row(kind: .item, item: $0) }
                return rowCache
            }
            var out: [Row] = []
            for g in app.groups {
                out.append(Row(kind: .groupHeader, group: g))
                for it in g.items { out.append(Row(kind: .item, item: it)) }
                out.append(Row(kind: .groupSubtotal, group: g))
            }
            rowCache = out
            return out
        }

        /// 某行对应的子目（分组标题/小计行返回 nil）
        func item(at row: Int) -> ProjectItem? {
            let list = rows()
            guard row >= 0, row < list.count else { return nil }
            return list[row].item
        }

        /// 子目 id 对应的行号（用于选中同步）
        func rowIndex(ofItemID id: Int64) -> Int? {
            rows().firstIndex { $0.item?.id == id }
        }

        /// 拖拽落点：落到分组行上时，取最近的一条真实子目行
        func nearestItemRow(_ row: Int) -> Int? {
            let list = rows()
            guard !list.isEmpty else { return nil }
            let clamped = min(max(row, 0), list.count - 1)
            if list[clamped].kind == .item { return clamped }
            for i in stride(from: clamped, through: 0, by: -1) where list[i].kind == .item { return i }
            for i in clamped..<list.count where list[i].kind == .item { return i }
            return nil
        }

        // 数据源
        func numberOfRows(in tableView: NSTableView) -> Int { rows().count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier.rawValue,
                  let spec = ItemColumnSpec(rawValue: id) else { return nil }
            let list = rows()
            guard row < list.count else { return nil }
            let entry = list[row]
            // 分组标题 / 分组小计行：整行都是只读的汇总文字
            if entry.kind != .item { return groupCell(spec: spec, entry: entry) }

            guard let item = entry.item else { return nil }
            let cost = app.costs[item.id] ?? ItemCost()

            let (text, color, weight): (String, NSColor, NSFont.Weight)
            switch spec {
            case .index:
                // 分组模式下表格行号 ≠ 子目序号，这里显示子目在清单里的真实序号
                let seq = (app.items.firstIndex(where: { $0.id == item.id }) ?? row) + 1
                (text, color, weight) = ("\(seq)", .secondaryLabelColor, .regular)
            case .code:
                (text, color, weight) = (item.quotaCode, .controlAccentColor, .regular)
            case .name:
                (text, color, weight) = (item.quotaName, .labelColor, .regular)
            case .unit:
                (text, color, weight) = (item.unit, .secondaryLabelColor, .regular)
            case .qty:
                (text, color, weight) = (Fmt.quantity(item.quantity), .labelColor, .regular)
            case .coeff:
                (text, color, weight) = (String(format: "%.2f", item.workdayCoeff), .labelColor, .regular)
            case .tech:
                (text, color, weight) = (Fmt.workday(cost.techWorkdays), .labelColor, .regular)
            case .labor:
                (text, color, weight) = (Fmt.workday(cost.laborWorkdays), .labelColor, .regular)
            case .laborCost:
                (text, color, weight) = (Fmt.money(cost.labor), .labelColor, .regular)
            case .material:
                (text, color, weight) = (Fmt.money(cost.mainMaterial), .labelColor, .regular)
            case .machine:
                (text, color, weight) = (Fmt.money(cost.machine), .labelColor, .regular)
            case .instrument:
                (text, color, weight) = (Fmt.money(cost.instrument), .labelColor, .regular)
            case .subtotal:
                (text, color, weight) = (Fmt.money(cost.direct), .labelColor, .medium)
            case .note:
                (text, color, weight) = (item.note, .secondaryLabelColor, .regular)
            }

            let field = NSTextField(string: text)
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = spec.editable ? .default : .none
            field.isEditable = spec.editable
            field.isSelectable = true
            field.alignment = spec.alignment
            field.textColor = color
            field.lineBreakMode = .byTruncatingTail
            field.font = spec.mono
                ? .monospacedDigitSystemFont(ofSize: 11, weight: weight)
                : .systemFont(ofSize: spec == .name ? 12 : 11, weight: weight)
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            field.identifier = tableColumn?.identifier
            if spec.editable { field.delegate = self }
            field.toolTip = spec == .name ? item.quotaName : nil
            return field
        }

        /// 分组标题行 / 分组小计行的单元格
        private func groupCell(spec: ItemColumnSpec, entry: Row) -> NSView? {
            let g = entry.group
            let isHeader = entry.kind == .groupHeader

            var text = ""
            var color: NSColor = .labelColor
            var weight: NSFont.Weight = .medium

            switch spec {
            case .code:
                text = isHeader ? (g?.key ?? "") : ""
                color = .controlAccentColor
            case .name:
                text = isHeader ? "\(g?.title ?? "分组")（\(g?.items.count ?? 0) 条）" : "小计"
                color = isHeader ? .labelColor : .secondaryLabelColor
                weight = isHeader ? .semibold : .medium
            case .tech:
                text = isHeader ? "" : Fmt.workday(g?.cost.techWorkdays ?? 0)
            case .labor:
                text = isHeader ? "" : Fmt.workday(g?.cost.laborWorkdays ?? 0)
            case .laborCost:
                text = isHeader ? "" : Fmt.money(g?.cost.labor ?? 0)
            case .material:
                text = isHeader ? "" : Fmt.money(g?.cost.mainMaterial ?? 0)
            case .machine:
                text = isHeader ? "" : Fmt.money(g?.cost.machine ?? 0)
            case .instrument:
                text = isHeader ? "" : Fmt.money(g?.cost.instrument ?? 0)
            case .subtotal:
                text = isHeader ? "" : Fmt.money(g?.cost.direct ?? 0)
                weight = .semibold
            default:
                text = ""
            }

            let field = NSTextField(string: text)
            field.isBordered = false
            field.drawsBackground = isHeader          // 标题行铺一层底纹，和小计/子目区分
            field.backgroundColor = .controlBackgroundColor
            field.focusRingType = .none
            field.isEditable = false
            field.isSelectable = false
            field.alignment = spec.alignment
            field.textColor = color
            field.lineBreakMode = .byTruncatingTail
            field.font = spec.mono
                ? .monospacedDigitSystemFont(ofSize: 11, weight: weight)
                : .systemFont(ofSize: 11, weight: weight)
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            return field
        }

        /// 分组标题/小计行不可选中（避免「选中了小计行」这种没意义的状态）
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            let list = rows()
            guard row >= 0, row < list.count else { return false }
            return list[row].kind == .item
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = tableView, let item = item(at: table.selectedRow) else { return }
            if app.selectedItemID != item.id { app.selectedItemID = item.id }
        }

        // 单元格编辑（失焦/回车提交，避免逐字符写库）
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  let table = tableView,
                  let raw = field.identifier?.rawValue,
                  let spec = ItemColumnSpec(rawValue: raw) else { return }
            let row = table.row(for: field)
            guard let item = item(at: row) else { return }
            let text = field.stringValue

            switch spec {
            case .name:
                if text != item.quotaName { app.apply({ $0.quotaName = text }, to: item.id) }
            case .note:
                if text != item.note { app.apply({ $0.note = text }, to: item.id) }
            case .qty:
                guard let v = UI.parseNumber(text), v >= 0 else {
                    field.stringValue = Fmt.quantity(item.quantity); return
                }
                app.apply({ $0.quantity = v }, to: item.id)
            case .coeff:
                guard let v = UI.parseNumber(text), v > 0 else {
                    field.stringValue = String(format: "%.2f", item.workdayCoeff); return
                }
                app.apply({ $0.workdayCoeff = v }, to: item.id)
            default:
                break
            }
        }

        // 拖拽排序
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let item = item(at: row) else { return nil }
            let pb = NSPasteboardItem()
            pb.setString("\(item.id)", forType: .budgetRow)
            return pb
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            op == .above ? .move : []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
            guard let s = info.draggingPasteboard.string(forType: .budgetRow),
                  let id = Int64(s), !app.items.isEmpty else { return false }
            // 分组模式下可能落在标题/小计行上，取最近的一条真实子目做落点
            guard let target = nearestItemRow(row), let dest = item(at: target) else { return false }
            app.moveItem(id: id, to: dest.id)
            return true
        }

        // 右键菜单
        func tableView(_ tableView: NSTableView, menuForEvent event: NSEvent) -> NSMenu? {
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)
            guard let item = item(at: row) else { return nil }
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

            let menu = NSMenu()
            let up = NSMenuItem(title: "上移", action: #selector(moveUp(_:)), keyEquivalent: "")
            up.target = self
            up.representedObject = item.id
            menu.addItem(up)

            let down = NSMenuItem(title: "下移", action: #selector(moveDown(_:)), keyEquivalent: "")
            down.target = self
            down.representedObject = item.id
            menu.addItem(down)

            menu.addItem(.separator())
            let del = NSMenuItem(title: "删除此行", action: #selector(deleteRow(_:)), keyEquivalent: "")
            del.target = self
            del.representedObject = item.id
            menu.addItem(del)
            return menu
        }

        @objc private func moveUp(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? Int64 { app.moveItemUp(id: id) }
        }

        @objc private func moveDown(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? Int64 { app.moveItemDown(id: id) }
        }

        @objc private func deleteRow(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? Int64 { app.deleteItem(id: id) }
        }
    }
}

extension NSPasteboard.PasteboardType {
    /// 清单行拖拽专用类型
    static let budgetRow = NSPasteboard.PasteboardType("com.dujianhua.combudget.row")
}

/// 数字解析（复用）
enum UI {
    static func parseNumber(_ s: String) -> Double? {
        let cleaned = s
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }
}
