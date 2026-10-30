import Foundation

// =============================================================================
// 撤销 / 重做栈
//
// 不依赖 AppKit 的 UndoManager，自己维护两个栈，原因：
//   1. UndoManager 绑在 responder chain / window 上，SwiftUI 生命周期里拿不稳定的窗口，
//      菜单项的 enable 状态经常闪断；自己管，行为确定、可单测。
//   2. 这是一份纯 Swift 代码，能进 tools/check.sh 的自检。
//
// 登记单位 = 「一次用户操作」，而不是「一个字段」：
//   改一次工程量 = 一步；删一条子目 = 一步；导一次 Excel = 一步。
// 这样 ⌘Z 的手感和「重做」才符合预算编制的直觉。
// =============================================================================

public final class History {

    private struct Entry {
        let label: String
        let undo: () -> Void
        let redo: () -> Void
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []

    /// 最多记住多少步（够用即可，避免长时间编制占内存）
    public var limit: Int = 200

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isEmpty: Bool { undoStack.isEmpty && redoStack.isEmpty }

    /// 下一步撤销/重做的动作名，用于菜单标题（「撤销 修改工程量」）
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    public init() {}

    /// 变更已发生后登记：只需给出「回到变更前」和「重做」两段闭包
    public func register(_ label: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        undoStack.append(Entry(label: label, undo: undo, redo: redo))
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()          // 有了新的操作，旧的重做分支作废
    }

    /// 登记 + 立即执行 redo（插入类操作用它最顺手）
    public func perform(_ label: String, redo: @escaping () -> Void, undo: @escaping () -> Void) {
        register(label, undo: undo, redo: redo)
        redo()
    }

    @discardableResult
    public func undo() -> Bool {
        guard let entry = undoStack.popLast() else { return false }
        entry.undo()
        redoStack.append(entry)
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let entry = redoStack.popLast() else { return false }
        entry.redo()
        undoStack.append(entry)
        return true
    }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
