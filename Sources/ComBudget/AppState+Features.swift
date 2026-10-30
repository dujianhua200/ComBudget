import Foundation

// =============================================================================
// AppState 的功能扩展：价格库 / 分组小计 / 定额换算
//
// 拆出来单独一个文件，是为了让 AppState.swift 保持「数据流骨架」的体量，
// 这几个后加的模块各自成段，改起来不互相干扰。
// 规则不变：先写库 → 再改内存 → 最后重算 → 登记一步撤销。
// =============================================================================

extension AppState {

    // MARK: - 价格库

    /// 重新读价格库（可按关键字/类型过滤；界面搜索框直接调这里）
    func reloadPrices(keyword: String = "", kind: ResourceKind? = nil) {
        do {
            prices = try dbs.price.search(keyword: keyword, kind: kind)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 新增/更新一条价格（按 类型+名称+规格+单位 upsert）
    func savePrice(_ entry: PriceEntry) {
        do {
            try dbs.price.upsert(entry)
            reloadPrices()
            status = "价格已保存：\(entry.name)"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deletePrice(id: Int64) {
        guard let snapshot = try? dbs.price.entry(id: id) else { return }
        do {
            try dbs.price.delete(id: id)
            reloadPrices()
            status = "已删除价格"
            record("删除价格",
                   undo: { [weak self] in self?.savePrice(snapshot) },
                   redo: { [weak self] in self?.deletePriceSilently(id) })
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 撤销「清空价格库」时的重做分支：只删，不登记历史
    func deletePriceSilently(_ id: Int64) {
        do {
            try dbs.price.delete(id: id)
            reloadPrices()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 清空价格库（可按来源清，例如只删某次 Excel 导入的那一批）
    func clearPrices(source: String? = nil) {
        do {
            let before = try dbs.price.all(source: source)
            try dbs.price.clear(source: source)
            reloadPrices()
            status = "已清空价格库（⌘Z 可撤销）"
            record("清空价格库",
                   undo: { [weak self] in self?.restorePrices(before) },
                   redo: { [weak self] in
                       guard let self else { return }
                       try? self.dbs.price.clear(source: source)
                       self.reloadPrices()
                   })
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 整批写回价格（撤销「清空」用）
    private func restorePrices(_ list: [PriceEntry]) {
        do {
            _ = try dbs.price.save(list)
            reloadPrices()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 价格审计：当前工程还有多少资源没价（套价前给用户一个底）
    /// - Returns: (资源总数, 单价为 0 的条数, 涉及的子目数)
    func priceAudit() -> (total: Int, unpriced: Int, items: Int) {
        var total = 0, unpriced = 0
        var itemSet: Set<Int64> = []
        for item in items {
            for res in item.resources {
                total += 1
                if res.unitPrice == 0 {
                    unpriced += 1
                    itemSet.insert(item.id)
                }
            }
        }
        return (total, unpriced, itemSet.count)
    }

    // MARK: - 价格 Excel 导入

    /// 试读一份价格清单（不写库），界面用它先给用户看「能认出几行、哪几行单价有问题」
    func previewPriceImport(url: URL, config: PriceImportConfig = PriceImportConfig())
        -> (entries: [PriceEntry], skipped: Int, invalid: [String])? {
        do {
            return try PriceImporter.read(url: url, config: config)
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    /// 导入入库（upsert，重复导不翻倍），登记一步撤销
    @discardableResult
    func commitPriceImport(_ entries: [PriceEntry], source: String) -> Int {
        guard !entries.isEmpty else { return 0 }
        do {
            let n = try dbs.price.save(entries, source: source)
            reloadPrices()
            status = "价格导入完成：\(n) 条（重复条目已覆盖更新）"
            record("导入 \(n) 条价格",
                   undo: { [weak self] in
                       guard let self else { return }
                       try? self.dbs.price.clear(source: source)
                       self.reloadPrices()
                   },
                   redo: { [weak self] in self?.restorePrices(entries) })
            return n
        } catch {
            alertMessage = error.localizedDescription
            return 0
        }
    }

    /// 生成空白价格模板
    func writePriceTemplate(to url: URL) {
        do {
            try PriceImporter.writeTemplate(to: url)
            status = "已生成价格模板：\(url.lastPathComponent)"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - 套价

    /// 用价格库给整个工程重新套价
    /// - Parameter overwrite: true 覆盖已填单价；false 只补没填价的（手填优先）
    @discardableResult
    func applyPricesToProject(overwrite: Bool = true) -> PriceApplyResult {
        guard let p = project else { return PriceApplyResult() }
        let before = items
        do {
            let result = try dbs.project.applyPrices(projectID: p.id, overwrite: overwrite)
            refreshItems()
            status = result.summary
            record("套价（\(overwrite ? "覆盖全部" : "只补空价")）",
                   undo: { [weak self] in self?.writeBackAll(before) },
                   redo: { [weak self] in
                       guard let self else { return }
                       _ = try? self.dbs.project.applyPrices(projectID: p.id, overwrite: overwrite)
                       self.refreshItems()
                   })
            return result
        } catch {
            alertMessage = error.localizedDescription
            return PriceApplyResult()
        }
    }

    /// 只给一条子目套价（在属性面板里改完资源名后想立刻补价时用）
    @discardableResult
    func applyPricesToItem(id: Int64, overwrite: Bool = true) -> Int {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              let index = try? dbs.project.priceIndex(), !index.isEmpty else { return 0 }
        let before = items[idx].resources
        var n = 0
        for i in items[idx].resources.indices {
            let res = items[idx].resources[i]
            guard res.unitPrice == 0 || overwrite else { continue }
            guard let hit = index.lookup(kind: res.kind, name: res.name,
                                         spec: res.spec, unit: res.unit) else { continue }
            if res.unitPrice != hit.price {
                items[idx].resources[i].unitPrice = hit.price
                n += 1
            }
        }
        guard n > 0 else {
            if before.allSatisfy({ $0.unitPrice > 0 }) { status = "该子目资源已有单价" }
            else { status = "价格库里没有匹配上这些资源（注意名称与单位要一致）" }
            return 0
        }
        persistResources(itemIndex: idx)
        let after = items[idx].resources
        record("套价 \(n) 项资源",
               undo: { [weak self] in self?.writeResources(before, itemID: id) },
               redo: { [weak self] in self?.writeResources(after, itemID: id) })
        status = "已给 \(n) 项资源套价"
        return n
    }

    // MARK: - 分组小计

    func setGrouping(_ key: GroupingKey) {
        grouping = key
        recalc()
        status = key == .none ? "已取消分组" : "已\(key.rawValue)分组：\(groups.count) 组"
    }

    /// 全工程合计（与分组小计同一口径，界面用于对账）
    var groupTotal: GroupCost {
        BudgetGrouping.total(items: items, costs: costs)
    }

    // MARK: - 定额换算

    /// 对一条子目套换算规则（工日 + 机械/仪表台班 + 主材消耗量）
    func convertItem(id: Int64, rule: ConversionRule) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let before = items[idx]
        QuotaConverter.apply(rule, to: &items[idx])
        persistResources(itemIndex: idx)          // 写资源（qty_override）+ 重算
        do { try dbs.project.updateItem(items[idx]) } catch {
            alertMessage = error.localizedDescription
        }
        let after = items[idx]
        record("换算 \(rule.name)",
               undo: { [weak self] in self?.writeBack(before) },
               redo: { [weak self] in self?.writeBack(after) })
        status = "已换算：\(rule.summary)"
    }

    /// 整工程套同一条规则（批量换算，例如全线路按山区系数调整）
    func convertProject(rule: ConversionRule) {
        guard !items.isEmpty else { return }
        let before = items
        var after = items
        for i in after.indices { QuotaConverter.apply(rule, to: &after[i]) }
        do {
            for item in after {
                try dbs.project.updateItem(item)
                try dbs.project.replaceResources(itemID: item.id, resources: item.resources)
            }
            refreshItems()
            status = "整工程已换算：\(rule.name)（\(after.count) 条子目）"
            record("整工程换算 \(rule.name)",
                   undo: { [weak self] in self?.writeBackAll(before) },
                   redo: { [weak self] in self?.writeBackAll(after) })
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 还原为定额原值
    func revokeConversion(id: Int64) {
        guard let revoke = ConversionPresets.all.first(where: { $0.isIdentity }) else { return }
        convertItem(id: id, rule: revoke)
        status = "已还原为定额原值"
    }

    /// 有换算痕迹的子目数量（界面提示用）
    var convertedItemCount: Int {
        items.filter { !$0.convNote.isEmpty }.count
    }
}
