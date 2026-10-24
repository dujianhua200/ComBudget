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

SelfTest.run()
exit(SelfTest.passed ? 0 : 1)
