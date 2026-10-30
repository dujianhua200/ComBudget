import Foundation

// =============================================================================
// 取费模板的导入 / 导出（JSON）
//
// 为什么要这个功能：费率不是软件说了算——各省通信管理局、各运营商招标文件、
// 各时期的 451 配套文件给的费率都不一样，甚至同一个单位不同专业都不同。
// 把模板做成一份纯文本 JSON，就能：发给同事、进 Git 做版本管理、
// 中标后照着招标文件的费率表改一次然后长期复用。
//
// 文件格式刻意保持简单：一个数组，每项是完整模板，字段中文可读，
// 用文本编辑器直接改也看得懂。
// =============================================================================

enum FeeTemplateIO {

    static let formatID = "combudget.fee-template"

    struct File: Codable {
        var format: String = FeeTemplateIO.formatID
        var version: Int = 1
        var exportedAt: Date = Date()
        var templates: [FeeTemplate]
    }

    enum IOError: LocalizedError {
        case badFormat(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .badFormat(let got):
                return "不是 ComBudget 取费模板文件（format=\(got)）"
            case .empty:
                return "文件里没有取费模板"
            }
        }
    }

    // MARK: - 导出

    static func encode(_ templates: [FeeTemplate]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(File(templates: normalized(templates)))
    }

    static func write(_ templates: [FeeTemplate], to url: URL) throws {
        try encode(templates).write(to: url)
    }

    static func fileName(for tpl: FeeTemplate) -> String {
        let safe = tpl.name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "")
        return "取费模板-\(safe).json"
    }

    // MARK: - 导入

    static func decode(_ data: Data) throws -> [FeeTemplate] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file: File
        do {
            file = try decoder.decode(File.self, from: data)
        } catch {
            // 也容忍「裸数组」写法（手写模板时少包一层）
            if let bare = try? decoder.decode([FeeTemplate].self, from: data), !bare.isEmpty {
                return normalized(bare)
            }
            throw error
        }
        guard file.format == formatID else { throw IOError.badFormat(file.format) }
        guard !file.templates.isEmpty else { throw IOError.empty }
        return normalized(file.templates)
    }

    static func read(_ url: URL) throws -> [FeeTemplate] {
        try decode(try Data(contentsOf: url))
    }

    // MARK: - 内部

    /// 入库前整理：清掉旧 id（导入方自己会重新分配）、补齐缺省字段、
    /// 去掉空名称的费用项，并按 sortIndex 排序
    private static func normalized(_ list: [FeeTemplate]) -> [FeeTemplate] {
        list.map { raw in
            var t = raw
            t.id = 0
            t.isBuiltin = false
            t.rates = t.sortedRates.enumerated().map { idx, r in
                var copy = r
                copy.id = 0
                copy.templateID = 0
                copy.sortIndex = idx
                if copy.key.isEmpty { copy.key = copy.name }
                return copy
            }
            return t
        }
    }

    /// 名字撞车时换个不撞的名字返回（内置模板永远不会被覆盖）
    static func uniqueName(_ name: String, among existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        var n = 2
        while existing.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }
}
