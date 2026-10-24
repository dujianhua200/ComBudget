import SwiftUI

// =============================================================================
// 主界面：左工程树 / 中内容 / （内容内再分 清单 + 属性面板）
// =============================================================================

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @State private var pendingDelete: Project?

    private var routeBinding: Binding<AppState.Route?> {
        Binding(get: { app.route },
                set: { newValue in if let r = newValue { app.select(r) } })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 238, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1180, minHeight: 720)
        .alert("提示", isPresented: Binding(
            get: { app.alertMessage != nil },
            set: { if !$0 { app.alertMessage = nil } })) {
            Button("好", role: .cancel) { }
        } message: {
            Text(app.alertMessage ?? "")
        }
        .confirmationDialog("删除工程？",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { p in
            Button("删除", role: .destructive) { app.deleteProject(id: p.id); pendingDelete = nil }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { p in
            Text("「\(p.name)」及其全部子目将被删除，且不可恢复。")
        }
    }

    // MARK: - 左栏

    private var sidebar: some View {
        List(selection: routeBinding) {
            Section("工程") {
                ForEach(app.projects) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.system(size: 12)).lineLimit(1)
                        Text("\(p.category) · \(p.specialty)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(AppState.Route.project(p.id))
                    .contextMenu {
                        Button("复制工程") { app.duplicateProject(id: p.id) }
                        Button("导出为 .combudget") { exportBundle(p) }
                        Divider()
                        Button("删除工程", role: .destructive) { pendingDelete = p }
                    }
                }
                if app.projects.isEmpty {
                    Text("还没有工程，点下方「新建工程」")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Section("资料") {
                Label("定额库（451 全册）", systemImage: "books.vertical")
                    .tag(AppState.Route.quota)
                Label("取费模板", systemImage: "percent")
                    .tag(AppState.Route.fee)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    app.newProject()
                } label: {
                    Label("新建工程", systemImage: "plus").font(.system(size: 11))
                }
                .buttonStyle(.borderless)

                Button {
                    let urls = FilePanels.open(ext: ProjectBundle.fileExtension, multiple: true)
                    for url in urls {
                        let ok = url.startAccessingSecurityScopedResource()
                        app.importBundle(from: url)
                        if ok { url.stopAccessingSecurityScopedResource() }
                    }
                } label: {
                    Label("导入工程", systemImage: "square.and.arrow.down").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                Spacer()
                if !app.bootMessage.isEmpty {
                    Text("\(app.projects.count) 个工程")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    // MARK: - 右侧

    @ViewBuilder
    private var detail: some View {
        switch app.route {
        case .project:
            BudgetEditorView()
        case .quota:
            QuotaBrowserView(pickerMode: false)
        case .fee:
            FeeTemplateView()
        case .none:
            WelcomeView()
        }
    }

    private func exportBundle(_ p: Project) {
        guard let url = FilePanels.save(name: "\(p.name).\(ProjectBundle.fileExtension)",
                                        ext: ProjectBundle.fileExtension) else { return }
        app.select(.project(p.id))
        app.exportBundle(to: url)
    }
}

// MARK: - 欢迎页

struct WelcomeView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            Text("通信工程概预算")
                .font(.system(size: 20, weight: .semibold))
            Text("已内置 451 定额全册（3091 条，含主材/机械/仪表关联）\n左侧新建工程即可开始编制")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("新建工程") { app.newProject() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("浏览定额库") { app.select(.quota) }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
