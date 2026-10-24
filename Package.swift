// swift-tools-version: 5.9
// ComBudget — macOS 原生通信工程概预算软件（Apple Silicon / arm64）
// 零第三方依赖：SQLite3 + zlib（系统库）+ SwiftUI
import PackageDescription

let package = Package(
    name: "ComBudget",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ComBudget", path: "Sources/ComBudget")
    ],
    swiftLanguageVersions: [.v5]
)
