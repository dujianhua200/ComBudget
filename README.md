# ComBudget · macOS 原生通信工程概预算（SwiftUI）

Apple Silicon 原生（arm64 单架构）、零第三方依赖、纯本地单机的通信工程概预算工具，
界面按大宇翔的「清单 + 属性面板」工作流设计，**内置 451 定额全册（3091 条子目 / 9948 条主材·机械·仪表关联）**。

| 项目 | 状态 |
|---|---|
| 定额数据 | 由官方电子手册《通信451定额电子手册全册(含补充册)_v2022.12.716》解析入库，编号与手册 **3091/3091 一一对应** |
| 界面 | SwiftUI（macOS 13+），三栏布局；已实际启动、截图核对 |
| 核心自检 | `./build.sh --check` → **35/35 通过**（本机 Command Line Tools 即可跑） |
| 打包 | GitHub Actions `macos-14`（arm64 + Xcode）编译并产出 `ComBudget.app`，产物已下载在本机实测运行 |
| 依赖 | 0 个第三方库：SQLite3 + zlib（系统库）、SwiftUI、Core Graphics |

---

## 1. 451 定额怎么进来的（重点）

### 1.1 数据管线

```
官方电子手册（单文件 HTML，4.8MB / 800 页 / 807 张表）
      │  tools/parse_451.py   ← 逐页解析 <table class="dTable">，处理 rowspan/colspan
      ▼
data/quota451.sqlite     quota_item 3091 条 ＋ quota_resource 9948 条
      │  首次启动 ATTACH + INSERT SELECT（毫秒级）
      ▼
~/Library/Application Support/ComBudget/combudget.db
```

手册每页是一张「列 = 定额子目」的横表，解析要点：

- 行结构：`定额编号` → `项目`（可能跨 2~3 行做三级细分）→ `定额单位` → `名称/单位/数量` → `人工(技工/普工)` → `主要材料` → `机械` → `仪表`；
- `rowspan` 用于「人工」「主要材料」「机械」「仪表」分组标签，`colspan` 用于「项目」「定额单位」跨列；
- `—` 视为无消耗量，`（0.02）` 括号值按参考量计入（如海缆施工船）；
- 同一编号若在目录/续表/勘误中重复出现，按「工日信息量更大者胜 + 资源并集」合并；
- 表格 class 有 `dTable`、`dTable smallRow`、`dTable" style=...` 多种写法，都覆盖到了。

### 1.2 质量核对（可复现）

```bash
python3 tools/parse_451.py <手册.html> data/quota451.sqlite
./.build/combudget-cli --verify-data      # 打印条数、分册、抽查 TXL1-001
```

已核对项：

- 手册中出现的定额编号 **3091 个，全部解析成功（漏 0 个）**；
- `TXL1-001`：名称「光（电）缆工程施工测量 直埋」、单位「百米」、技工 0.56 / 普工 0.14、仪表 2 项（地下管线探测仪 0.05、激光测距仪 0.04）——与手册 P2 完全一致；
- `TSD4-012`：技工 1.50、单位「个」、主材 膨胀螺栓（M10×80）4.04 套；
- `T5G1-045`：技工 0.17、单位「十米」、主材 硬质 PVC 管（槽）10.5 m；
- `TSW3-017`：三级名称「安装（吊装）ø3.2m 以下抛物面天线 楼房上（高度）10m 以下」正确拼接；
- 早期版本曾漏解析 39 条（`T5G*` / `TSW3-*`，因表格 class 带附加属性），已修复；`TXL2-041`、`TXL3-186` 因续表重复导致工日取 0，已用合并策略修正为 1.00/2.00、0.75/0.90。

**局限（如实说明）**：手册不含「主材/机械/仪表单价」（那是另一本价格库），所以资源单价默认 0，
需要你在工程里填（属性面板可改，主材费才会进造价）；取费模板的费率是**示例值**，需按 451 号文核定。

---

## 2. 计算口径

```
技工工日 = 定额技工工日 × 工程量 × 工日调整系数
普工工日 = 定额普工工日 × 工程量 × 工日调整系数
人工费   = 技工工日 × 114 元/工日 + 普工工日 × 61 元/工日     ← 单价可改，默认 451 号文口径
主材费   = Σ(定额消耗量 × 工程量 × 主材单价)
机械费   = Σ(台班消耗量 × 工程量 × 台班单价)
仪表费   = Σ(台班消耗量 × 工程量 × 台班单价)
辅材费   = 人工费 × 0.3%
直接费   = 人工费 + 主材费 + 辅材费 + 机械费 + 仪表费
建安费   = 直接费 + 措施费 + 间接费 + 利润 + 税金
设备费   = 单列，不参与取费
```

取费基数可选：人工费 / 人工费+机械费 / 直接费 / 直接费+措施费+间接费；费率项可增删排序，多套模板可切换。

自检里的手算校验：`TXL1-001` 工程量 100 → 技工 56、普工 14 工日 → 人工费 `56×114 + 14×61 = 7,238.00` ✔

---

## 3. 架构与目录

```
ComBudget/
├── Package.swift                     SwiftPM（macOS 13+，单 target）
├── build.sh                          本地打包（有 Xcode）/ --check 只跑核心自检
├── tools/
│   ├── check.sh                      用 swiftc 单独编译「Core + 自检入口」→ 不需要 Xcode
│   ├── parse_451.py                  手册 → quota451.sqlite（可复现）
│   └── selfcheck/                    自检与 --make-demo（示例工程）
├── data/quota451.sqlite              内置 451 定额库（2.2MB）
├── Packaging/Info.plist              .app 描述（含 .combudget 文档类型）
├── .github/workflows/build.yml       macOS runner 编译 + 打包 + 上传 artifact
├── docs/                             示例输出（预算表 PDF/XLSX）、界面截图
└── Sources/ComBudget/
    ├── ComBudgetApp.swift            @main + 菜单命令
    ├── AppState.swift                ViewModel（先写库→改内存→重算→刷新）
    ├── Core/                         ★ 不依赖 SwiftUI，可在纯 CLT 下编译测试
    │   ├── Core/Models.swift
    │   ├── Persistence/              SQLiteDB / Schema / QuotaStore / ProjectStore /
    │   │                             FeeStore / AppDatabase / SeedLibrary
    │   ├── Calc/                     BudgetCalculator / ReportBuilder
    │   ├── Excel/                    ZipArchive / XlsxReader / XlsxWriter / ExcelImporter
    │   └── Export/Exporters.swift    Excel 导出 + Core Graphics 分页 PDF + 打印
    └── Views/                        SwiftUI 界面
        ├── RootView.swift            三栏骨架 / 工程树 / 欢迎页
        ├── BudgetEditorView.swift    清单表格 + 工具条 + 汇总条
        ├── InspectorView.swift       子目属性 + 资源明细
        ├── QuotaBrowserView.swift    定额检索（3091 条）＋ 插入弹窗
        ├── FeeTemplateView.swift     取费模板编辑
        ├── Sheets.swift              工程属性 / 导入向导 / 报表预览
        └── Components.swift          数字输入框 / 汇总卡 / 报表预览表
```

设计要点：

1. **SQLite 是唯一真源**，界面只读内存快照；任何编辑「先写库、再改内存、最后重算」。
2. **资源快照**：插入子目时把定额的主材/机械/仪表消耗量复制进工程（`project_item_resource`），
   之后改定额库不会追溯改变已编工程 —— 造价可复现、可审计。
3. **报表模型复用**：界面预览 / Excel / PDF 共用 `ReportTable`，不会出现三套表数字不一致。
4. **零第三方**：`.xlsx` = zip + XML，自研 ZIP（zlib raw inflate / store）+ XMLParser，约 400 行，
   不引 ZIPFoundation / CoreXLSX，Apple Silicon 上无兼容性风险。

---

## 4. 数据库表

主库：`~/Library/Application Support/ComBudget/combudget.db`（WAL、外键开启）。

| 表 | 关键字段 | 说明 |
|---|---|---|
| `quota_item` | code(唯一) / name / unit / chapter / section / series / book / work / **tech_workday / labor_workday** / is_builtin | 451 子目，3091 条 |
| `quota_resource` | quota_id / kind(主材·机械·仪表·设备) / name / unit / qty_per_unit / unit_price | 定额消耗量 9948 条 |
| `project` | code / name / category / specialty / scale / owner / contractor / compiler / reviewer / fee_template_id | 工程 |
| `project_item` | project_id / sort_index / quota_code / quota_name / unit / quantity / workday_coeff / **tech_workday / labor_workday / tech_price / labor_price** / note / is_supplement | 清单行（定额快照） |
| `project_item_resource` | item_id / kind / name / spec / unit / qty_per_unit / **qty_override** / unit_price / is_extra | 资源快照（可改用量的同时保留定额原值） |
| `fee_template` / `fee_rate` | name / aux_rate；key / name / grp / base / rate / sort_index / is_enabled | 多套取费模板 |
| `meta` | schema_version | 结构版本（v2） |

`.combudget` 工程包 = 一份同结构 SQLite（`VACUUM INTO` 快照后剔除其它工程），
自包含定额库与取费模板，拷到别的机器可直接打开。

---

## 5. 界面

```
┌──────────┬────────────────────────────────────────────┬──────────────┐
│ 工程树    │ 工程名 · 类别 · 专业      [工具条 13 个动作]  │ 子目属性      │
│  ├ 工程A  │ 技工/普工工日 人工费 主材 机械 仪表 …总造价    │  编号/名称    │
│  └ 工程B  │ ┌──┬────┬──────┬──┬───┬──┬───┬───┬────┬──┐  │  工程量 系数  │
│ 资料      │ │序号│编号│名称  │单位│工程量│系数│技工│普工│人工费│…│  │  技工/普工单价│
│  ├ 定额库 │ └──┴────┴──────┴──┴───┴──┴───┴───┴────┴──┘  │  费用构成     │
│  └ 取费模板│ 拖动行排序 · 回车/失焦即写库并重算             │  资源明细     │
└──────────┴────────────────────────────────────────────┴──────────────┘
```

- 清单 14 列：序号/定额编号/名称/单位/工程量/系数/技工/普工/人工费/主材费/机械费/仪表费/小计/备注；
  名称、工程量、系数、备注可直接编辑，逐次写库并只重算汇总。
- 拖拽行调顺序；右键可上移/下移/删除；`⌘K` 插入定额。
- 属性面板可折叠（工具条最右），给表格腾空间；底部可改技工/普工单价（默认 114 / 61）。
- 定额库页面：3091 条按册（31 个分册）+ 关键字检索，右侧详情含工作内容与资源消耗，一键插入。

---

## 6. 构建

### 6.1 只验证核心层（本机 Command Line Tools 即可）

```bash
./build.sh --check            # 等价于 ./tools/check.sh
./tools/check.sh --keep       # 保留自检产物（PDF/XLSX/工程包）
./.build/combudget-cli --verify-data                  # 定额库体检
./.build/combudget-cli --make-demo <db 路径>          # 生成示例工程
```

### 6.2 打包 .app

**方式 A：GitHub Actions（推荐，当前用的就是这个）**
push 到 `main` 后自动跑 `.github/workflows/build.yml`：
`macos-14`（arm64 + 完整 Xcode）→ 核心自检 → `swift build -c release` → 组装 `.app`
→ ad-hoc 签名 → 上传 artifact `ComBudget-macos-arm64`（含 `quota451.sqlite`）。

```bash
gh run download <run-id> -n ComBudget-macos-arm64 -D ./dist
unzip -o ./dist/ComBudget-macos-arm64.zip && open ComBudget.app
```

**方式 B：本机装 Xcode 后**
`sudo xcode-select -s /Applications/Xcode.app` → `./build.sh`。

> **为什么必须 Xcode**：SwiftUI 的 `@State/@Binding/@EnvironmentObject` 是宏，
> 宏插件 `libSwiftUIMacros.dylib` 只在完整 Xcode 里；本机若只有 Command Line Tools，
> 编译界面会报 `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`。
> 这也是把打包放到 GitHub macOS runner 的原因 —— 核心层仍可本地验证，界面交给云端编译。

---

## 7. 需求对照

| # | 需求 | 状态 |
|---|---|---|
| — | 原生 App / 不用 Electron / 不套网页壳 / Swift + SwiftUI | ✅ SwiftUI 原生 |
| — | 仅 Apple Silicon、macOS 13+ | ✅ arm64 单架构，`LSMinimumSystemVersion=13.0` |
| — | 内置完整 451 定额（编号/名称/单位/工日/主材/机械/仪表/系数） | ✅ 3091 条 + 9948 条资源关联，技工/普工分列 |
| 1 | 工程管理 + 属性 + 取费标准选择 | ✅ |
| 2 | Excel 批量导入 + 三类校验 + 汇总 + 导出三类表 | ✅（校验/事务/导出均自检覆盖） |
| 3 | 清单增删改、改主材数量、工日系数、补充主材/设备、备注、拖拽排序 | ✅ |
| 4 | 取费与自动计算、费率自定义、多套模板、实时汇总 | ✅（费率为示例值待核定） |
| 5 | 定额库只读基础库 + 补充定额 + 模糊搜索 + 分类筛选 | ✅ 按册/关键字筛选 |
| 6 | 报表预览 / 打印 / 导出 PDF | ✅ 4 张表，A4 横向多页，表头重复 + 页码 |
| 7 | SQLite 存储、`.combudget` 单工程保存、复制、备份 | ✅ |
| 8 | macOS 原生风格、三栏布局 | ✅ |
| 9 | M 芯片原生、上百行导入不卡 | ✅ 单事务批量写入；表格 LazyVStack |
| 10 | 不联网、不登录、不做 Windows | ✅ |

**待办**：主材/机械/仪表价格库（批量填价 → 主材费自动成型）；撤销/重做；
按章节分组小计；定额换算向导；补充册章节号 `T5G*` 的册名映射（数据里有，界面按 series 展示）。

---

## 8. 数据与备份

| 内容 | 位置 |
|---|---|
| 主库（工程 + 定额 + 模板） | `~/Library/Application Support/ComBudget/combudget.db` |
| 单工程交接 | 右键工程 → 导出为 `.combudget`（自包含） |
| 全量备份 | 退出程序后拷 `combudget.db` |
| 内置定额库 | `data/quota451.sqlite`（仓库内，随 .app 一起分发） |
