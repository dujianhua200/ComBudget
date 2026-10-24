import SwiftUI

// =============================================================================
// 应用入口（SwiftUI）
// =============================================================================

@main
struct ComBudgetApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("通信工程概预算") {
            RootView()
                .environmentObject(app)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建工程") { app.newProject() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .printItem) {
                Button("打印报表…") { app.printReports() }
                    .keyboardShortcut("p", modifiers: .command)
            }
            CommandGroup(after: .importExport) {
                Button("导入工程（.combudget）…") {
                    for url in FilePanels.open(ext: ProjectBundle.fileExtension, multiple: true) {
                        let ok = url.startAccessingSecurityScopedResource()
                        app.importBundle(from: url)
                        if ok { url.stopAccessingSecurityScopedResource() }
                    }
                }
                Button("导出工程（.combudget）…") {
                    guard let p = app.project else { return }
                    if let url = FilePanels.save(name: "\(p.name).\(ProjectBundle.fileExtension)",
                                                 ext: ProjectBundle.fileExtension) {
                        app.exportBundle(to: url)
                    }
                }
            }
        }
    }
}
