import Foundation

// =============================================================================
// 命令行工具 / 自检（不依赖 SwiftUI，可在只有 Command Line Tools 的机器上跑）
//
//   combudget-cli --selftest [--keep]      端到端自检（含内置 451 定额导入）
//   combudget-cli --verify-data            只校验内置定额库
//   combudget-cli --import-seed <src> <db> 把内置库导入指定数据库
// =============================================================================

let args = CommandLine.arguments

func findSeed() -> URL? {
    if let env = ProcessInfo.processInfo.environment["COMBUDGET_SEED"] {
        return URL(fileURLWithPath: env)
    }
    return SeedLibrary.locate()
}

if args.contains("--verify-data") {
    guard let seed = findSeed() else {
        print("未找到 \(SeedLibrary.fileName)")
        exit(1)
    }
    do {
        let tmp = NSTemporaryDirectory() + "cb-verify-\(UUID().uuidString).db"
        let adb = try AppDatabase(path: tmp)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let items = try adb.quota.count()
        let res = try adb.quota.resourceCount()
        print("内置定额：\(items) 条，资源：\(res) 条")
        print(adb.seedStatus)
        let books = try adb.quota.seriesList()
        print("分册：\(books.count) 个 → " + books.prefix(6).map { "\($0.series) \($0.count)" }.joined(separator: " / "))
        if let one = try adb.quota.item(code: "TXL1-001") {
            print("抽查 TXL1-001：\(one.name) | \(one.unit) | 技工 \(one.techWorkday) 普工 \(one.laborWorkday) | 资源 \(one.resources.count) 项")
            for r in one.resources {
                print("   - \(r.kind.rawValue) \(r.name) \(Fmt.quantity(r.qtyPerUnit))\(r.unit)")
            }
        }
    } catch {
        print("失败：\(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

if args.contains("--import-seed"), let srcIdx = args.firstIndex(of: "--import-seed"),
   args.count > srcIdx + 2 {
    let src = URL(fileURLWithPath: args[srcIdx + 1])
    let dst = args[srcIdx + 2]
    do {
        let db = try SQLiteDB(path: dst)
        try Schema.migrate(db)
        let r = try SeedLibrary.importQuota(from: src, into: db)
        print("导入完成：定额 \(r.items) 条，资源 \(r.resources) 条 → \(dst)")
    } catch {
        print("失败：\(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

// ---- 生成一个示例工程（用于界面演示/截图，主材价为假设值） ----
if args.contains("--make-demo"), let idx = args.firstIndex(of: "--make-demo"), args.count > idx + 1 {
    do {
        let adb = try AppDatabase(path: args[idx + 1])
        var p = Project.newDraft()
        p.name = "示例工程-架空光缆（主材价为假设值）"
        p.code = "DEMO-2026-001"
        p.specialty = "有线通信"
        p.owner = "示例建设单位"
        p.contractor = "示例施工单位"
        p.compiler = "示例"
        p.feeTemplateID = try adb.fee.templates().first?.id ?? 0
        let project = try adb.project.create(p)
        let picks: [(String, Double, [String: Double])] = [
            ("TXL1-001", 120, [:]),
            ("TXL3-101", 60, ["光缆": 3.2]),
            ("TXL1-003", 12, [:]),
            ("TXL2-001", 45, [:]),
            ("TXL1-005", 8, [:])
        ]
        for (code, qty, prices) in picks {
            guard let q = try adb.quota.item(code: code) else { continue }
            let item = try adb.project.insertItem(projectID: project.id, quota: q, quantity: qty,
                                                  techPrice: 114, laborPrice: 61)
            if !prices.isEmpty {
                var res = try adb.project.resources(itemID: item.id)
                for i in res.indices {
                    for (name, price) in prices where res[i].name.contains(name) {
                        res[i].unitPrice = price
                    }
                }
                try adb.project.replaceResources(itemID: item.id, resources: res)
            }
        }
        print("已生成示例工程 id=\(project.id)")
    } catch {
        print("失败：\(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

SelfTest.run()
exit(SelfTest.passed ? 0 : 1)
