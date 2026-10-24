import SwiftUI

// =============================================================================
// 定额库浏览 / 检索 / 插入
// 内置 451 全册 3091 条，按册（series）与关键字过滤
// =============================================================================

struct QuotaBrowserView: View {
    @EnvironmentObject private var app: AppState
    var pickerMode: Bool = false
    /// 选中项变化时回调（弹窗里用来同步「插入」按钮状态）
    var onSelect: ((QuotaItem?) -> Void)? = nil

    @State private var keyword = ""
    @State private var series = ""
    @State private var results: [QuotaItem] = []
    @State private var selected: QuotaItem?
    @State private var quantity: Double = 1
    @State private var seriesList: [(series: String, book: String, count: Int)] = []
    @State private var totalCount = 0
    @State private var loading = false

    private var reloadKey: String { "\(keyword)|\(series)|\(totalCount)" }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                filterBar
                Divider()
                list
                Divider()
                footer
            }
            Divider()
            detail
                .frame(width: pickerMode ? 300 : 360)
        }
        .task(id: reloadKey) { reload() }
    }

    // MARK: - 过滤条

    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索定额编号 / 名称 / 工作内容", text: $keyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !keyword.isEmpty {
                    Button { keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor)))

            HStack(spacing: 8) {
                Picker("", selection: $series) {
                    Text("全部册").tag("")
                    ForEach(Array(seriesList.enumerated()), id: \.offset) { _, item in
                        Text("\(item.series)（\(item.count)）").tag(item.series)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 170)

                Text("\(results.count) / \(totalCount) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                if !pickerMode {
                    Button {
                        app.reimportSeed()
                        series = ""
                        totalCount = 0
                    } label: {
                        Label("重导入内置库", systemImage: "arrow.clockwise").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("从内置 quota451.sqlite 重新导入 451 全册")
                }
            }
        }
        .padding(8)
    }

    // MARK: - 列表

    private var list: some View {
        List(selection: Binding(
            get: { selected?.id },
            set: { id in
                selected = results.first { $0.id == id }
                onSelect?(selected)
            })) {
            ForEach(results) { item in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.code)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tint)
                        Text(item.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(item.unit)
                        Text("技 \(Fmt.workday(item.techWorkday))")
                        Text("普 \(Fmt.workday(item.laborWorkday))")
                        if !item.resourceSummary.isEmpty { Text(item.resourceSummary) }
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.vertical, 1)
                .tag(item.id)
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Text(app.bootMessage.isEmpty ? "内置 451 定额库" : app.bootMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if loading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - 详情

    @ViewBuilder
    private var detail: some View {
        if let q = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(q.code)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(q.isBuiltin ? "451" : "补充")
                            .font(.system(size: 9))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.gray.opacity(0.15)))
                        Spacer()
                    }
                    Text(q.name).font(.system(size: 14, weight: .semibold))

                    FieldGroup(title: "定额") {
                        kv("计量单位", q.unit)
                        kv("技工工日", Fmt.workday(q.techWorkday))
                        kv("普工工日", Fmt.workday(q.laborWorkday))
                        kv("册", q.bookShort)
                        kv("章", q.chapter)
                        if !q.section.isEmpty { kv("节", q.section) }
                    }

                    if !q.work.isEmpty {
                        FieldGroup(title: "工作内容") {
                            Text(q.work)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    FieldGroup(title: "资源消耗（\(q.resources.count)）") {
                        if q.resources.isEmpty {
                            Text("无").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        ForEach(q.resources) { res in
                            HStack(spacing: 4) {
                                Text("\(res.kind.rawValue) · \(res.name)")
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(Fmt.quantity(res.qtyPerUnit)) \(res.unit)")
                                    .font(.system(size: 10, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Text("工程量").font(.system(size: 11)).foregroundStyle(.secondary)
                        NumberField(value: $quantity, width: 80)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(Color(nsColor: .textBackgroundColor)))
                    }
                    Button {
                        app.addQuota(q, quantity: quantity)
                    } label: {
                        Label("插入到当前工程", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(app.project == nil)
                    if app.project == nil {
                        Text("请先在左侧选择或新建工程")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(12)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 24)).foregroundStyle(.tertiary)
                Text("选择左侧任一定额查看详情")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(v.isEmpty ? "—" : v).font(.system(size: 11)).monospacedDigit().lineLimit(1)
        }
    }

    // MARK: - 数据

    private func reload() {
        loading = true
        defer { loading = false }
        do {
            if totalCount == 0 {
                totalCount = try app.dbs.quota.count()
                seriesList = try app.dbs.quota.seriesList()
            }
            results = try app.dbs.quota.search(keyword: keyword,
                                               series: series.isEmpty ? nil : series)
            if let sel = selected, !results.contains(where: { $0.id == sel.id }) {
                selected = nil
            }
            if selected == nil, let first = results.first {
                selected = first
                onSelect?(first)
            }
        } catch {
            app.alertMessage = error.localizedDescription
        }
    }
}

// MARK: - 插入定额弹窗

struct QuotaPickerSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selection: QuotaItem?
    @State private var quantity: Double = 1

    let onInsert: (QuotaItem, Double) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("插入定额").font(.system(size: 14, weight: .semibold))
                Text("双击列表项或选中后点「插入」").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            QuotaBrowserView(pickerMode: true, onSelect: { selection = $0 })
                .frame(height: 400)

            Divider()
            HStack(spacing: 8) {
                if let item = selection {
                    Text(item.code).font(.system(size: 11, design: .monospaced))
                    Text(item.name).font(.system(size: 11)).lineLimit(1)
                } else {
                    Text("未选择定额").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("工程量").font(.system(size: 11)).foregroundStyle(.secondary)
                NumberField(value: $quantity, width: 80)
                Button("插入") {
                    if let item = selection { onInsert(item, quantity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
            .padding(12)
        }
        .frame(width: 860, height: 560)
    }
}
