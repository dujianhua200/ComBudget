# ComBudget · macOS 原生通信工程概预算软件

Apple Silicon 原生（arm64 单架构）、零第三方依赖、纯本地单机的通信工程概预算工具，
对标大宇翔概预算软件的「清单 + 属性面板」工作流。核心定额口径按 **451 号文（通信建设工程预算定额）** 搭建。

> **当前状态（已实测）**
> - `swift build` 通过，产物为 `Mach-O 64-bit executable arm64`，无 x86_64 切片、无 Rosetta 依赖。
> - 命令行自检 `--selftest` **30/30 项全部通过**：建库 → 生成 Excel → 校验导入（3 类错误全部拦下）→ 入库 → 计算 → 导出 Excel/PDF → `.combudget` 工程包往返。
> - GUI 已打包为 `build/ComBudget.app` 并实际启动截图验证（见 `docs/screenshots/`）。
> - 目录内 `docs/示例输出-预算表.pdf` / `.xlsx` 是自检真实产出的文件，可直接打开核对数字。

---

## 0. 关于 SwiftUI 的说明（重要，请先看这段）

需求写的是「优先 Swift + SwiftUI」。实测本机环境：

| 项 | 状态 |
|---|---|
| macOS | 26.x（arm64） |
| Swift | 6.4（Command Line Tools） |
| Xcode | **未安装**（`xcode-select -p` 指向 `/Library/Developer/CommandLineTools`） |
| SwiftUI 宏插件 | **缺失**：CLT 的 `usr/lib/swift/host/plugins/` 只有 `libSwiftMacros.dylib`、`libObservationMacros.dylib`，没有 `libSwiftUIMacros.dylib` |

这导致 `@State / @Binding / @EnvironmentObject / @StateObject` 全部无法展开（编译期报
`external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`），
即 **SwiftUI 界面在本机无法编译**，装 Xcode 才能解决（Xcode 自带该插件）。

因此界面层用 **AppKit（Cocoa）** 实现。这不是降级方案：

- 依然是纯原生 macOS 技术栈，**没有 Electron、没有 WKWebView、没有网页壳**；
- AppKit 的 `NSTableView` 对「上千行、多列、可编辑」的清单场景比 SwiftUI `Table` 更成熟，
  行高固定 + view 复用，滚动不掉帧；
- 三层布局（`NSSplitViewController` + 子视图控制器）与 macOS 原生交互（右键菜单、拖拽、sheet）都是系统一等公民。

**如果你后来装了 Xcode**，把 `Sources/ComBudget/UI/` 换成 SwiftUI 版本即可，数据层/计算层/导入导出层
完全不用改（它们是纯 Swift + Foundation，与 UI 框架零耦合）。需要我出 SwiftUI 版界面时告诉我，
我可以按现有 `AppState` 的接口直接改写。

---

## 1. 整体架构

```
┌──────────────────────────────────────────────────────────────┐
│ 表现层  AppKit ViewController                                 │
│   SidebarViewController   左侧工程树（NSOutlineView）          │
│   BudgetEditorViewController  中：清单表格（NSTableView 13 列）│
│   InspectorViewController    右：子目属性 + 资源明细           │
│   QuotaBrowserViewController / FeeTemplateViewController      │
│   Sheets：工程属性 / Excel 导入向导 / 报表预览                  │
└───────────────┬──────────────────────────────────────────────┘
                │ 读快照 + 调动作（单向数据流）
┌───────────────▼──────────────────────────────────────────────┐
│ 状态层  AppState（ViewModel）                                  │
│   projects / project / items / costs / summary / templates     │
│   规则：先写库 → 再改内存 → 最后重算 → 通知视图刷新            │
└───────────────┬──────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────┐
│ 领域层                                                        │
│   BudgetCalculator  量价计算 + 取费                            │
│   ReportBuilder     四张报表模型（界面/Excel/PDF 共用）        │
│   ExcelImporter     模板解析 + 校验 + 事务入库                  │
│   ProjectBundle     .combudget 工程包导出/导入                  │
└───────────────┬──────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────┐
│ 基础设施层（全部系统库，零第三方）                              │
│   SQLiteDB（libsqlite3）  Schema  QuotaStore/ProjectStore/FeeStore │
│   ZipReader/ZipWriter（libz 原始 inflate / store 打包）         │
│   XlsxReader（XMLParser）/ XlsxWriter（inlineStr 写 XML）      │
│   PDFExporter（Core Graphics 直接分页绘制）                     │
└──────────────────────────────────────────────────────────────┘
```

关键设计取舍：

1. **SQLite 是唯一真源**，内存里只放当前工程的快照，界面永远由快照驱动，避免「界面改了库没改」的半同步状态。
2. **资源快照**（`project_item_resource`）：插入子目时把定额的主材/机械/仪表消耗量与单价复制一份到工程里。
   之后修改定额库不会追溯改变已编工程 —— 造价可复现、可审计，这是概预算软件的硬要求。
3. **报表模型 `ReportTable` 只描述字符串化的表格**（标题/表头/行/页脚/列权/对齐），
   界面预览、Excel 导出、PDF 导出三处复用同一份数据，不会出现「三套表数字不一致」。
4. **零第三方依赖**：`.xlsx` 本质是 zip + XML，自研 ZIP（zlib 原始 inflate / store 打包）与 XML 解析约 400 行，
   换来的是不引入 ZIPFoundation / CoreXLSX 等依赖、不受其版本漂移影响、Apple Silicon 上无兼容性问题。

---

## 2. 目录结构

```
ComBudget/
├── Package.swift                  SwiftPM 清单（macOS 13+，Swift 5 语言模式）
├── build.sh                       一键编译 + 组装 .app + ad-hoc 签名
├── Packaging/Info.plist           .app 的 Info.plist（含 .combudget 文档类型注册）
├── docs/                          示例产物（预算表 PDF/XLSX、导入模板、界面截图）
└── Sources/ComBudget/
    ├── main.swift                 入口：--selftest 走自检，否则起 GUI
    ├── Core/
    │   └── Models.swift           领域模型：定额/工程/子目/取费/费用结果 + 格式化
    ├── Persistence/
    │   ├── SQLiteDB.swift         libsqlite3 薄封装（prepare/bind/step/事务）
    │   ├── Schema.swift           建表 DDL（下面第 3 节逐表说明）
    │   ├── QuotaStore.swift       定额检索/精确取/批量取/保存/批量导入/删除
    │   ├── ProjectStore.swift     工程与子目 CRUD、资源快照、排序、复制
    │   ├── FeeStore.swift         取费模板与费率明细
    │   ├── AppDatabase.swift      主库入口 + ProjectBundle（.combudget）
    │   └── SeedData.swift         示例定额 + 默认取费模板
    ├── Calc/
    │   ├── BudgetCalculator.swift 工日/人工/主材/机械/仪表/辅材 + 取费
    │   └── ReportBuilder.swift    汇总表/明细表/主材设备表/机械仪表表
    ├── Excel/
    │   ├── ZipArchive.swift       ZIP 读写（CRC32、deflate、中央目录）
    │   ├── XlsxReader.swift       sharedStrings + workbook + worksheet 解析
    │   ├── XlsxWriter.swift       多表、列宽、数值/文本区分
    │   └── ExcelImporter.swift    模板导入（列映射、校验、事务入库）+ 定额库导入
    ├── Export/
    │   └── Exporters.swift        Excel 导出 + PDF 分页绘制 + 打印
    ├── UI/
    │   ├── UIKitHelpers.swift     标签/按钮/表格列/数字解析等小工具
    │   ├── SidebarViewController.swift
    │   ├── BudgetEditorViewController.swift
    │   ├── InspectorViewController.swift
    │   ├── QuotaBrowserViewController.swift（含定额插入弹窗、定额库导入）
    │   ├── FeeTemplateViewController.swift
    │   ├── Sheets.swift           工程属性 / Excel 导入向导 / 报表预览
    │   └── AppState.swift         ViewModel
    └── App/
        ├── AppDelegate.swift      窗口、菜单、主分栏、页面路由
        └── SelfTest.swift         30 项端到端自检
```

---

## 3. 数据库设计

主库：`~/Library/Application Support/ComBudget/combudget.db`（WAL 模式，`PRAGMA foreign_keys=ON`）。
工程包 `.combudget` 是同一套表结构的一个 SQLite 文件（`VACUUM INTO` 快照后剔除其他工程）。

### 3.1 `quota_item` 定额子目（451 定额主表）

| 字段 | 类型 | 说明 |
|---|---|---|
| id | INTEGER PK | 自增 |
| code | TEXT UNIQUE | 定额编号，如 `TXL1-001` |
| name | TEXT | 定额名称 |
| unit | TEXT | 计量单位（100m / 头 / 根 / 台…） |
| chapter / section | TEXT | 章 / 节，用于左侧分类筛选 |
| workday | REAL | 综合工日（每单位工程量的工日） |
| note | TEXT | 工作内容（导入时也作为备注默认值） |
| is_builtin | INTEGER | 1=内置只读，0=用户补充定额 |
| created_at | REAL | 时间戳 |

索引：`idx_quota_name(name)`、`idx_quota_chapter(chapter)`；`code` 唯一索引保证导入不重复。

### 3.2 `quota_resource` 定额资源

| 字段 | 说明 |
|---|---|
| quota_id | 外键 → `quota_item.id`，ON DELETE CASCADE |
| kind | `主材` / `机械` / `仪表` / `设备` |
| name / spec / unit | 名称 / 规格程式 / 单位 |
| qty_per_unit | 定额消耗量（每单位工程量） |
| unit_price | 参考单价（元） |

### 3.3 `project` 工程

`id, code, name, category(工程类别), specialty(专业), scale(工程规模), owner(建设单位), contractor(施工单位),
compiler(编制人), reviewer(审核人), fee_template_id(取费标准), created_at, updated_at`

### 3.4 `project_item` 定额子目（清单一行）

| 字段 | 说明 |
|---|---|
| project_id | 外键 → `project.id`，CASCADE |
| sort_index | 排序号（拖拽后重写） |
| quota_code / quota_name / unit | 定额信息快照（名称可改，便于写「XX 段光缆敷设」这类工程化表述） |
| quantity | 工程量 |
| workday_coeff | 工日调整系数（默认 1.0，用于地形/难度调整） |
| unit_workday | 定额综合工日快照 |
| labor_price | 人工单价（默认 114 元/工日） |
| note | 备注 |
| is_supplement | 是否补充定额（手填行） |

索引：`idx_item_project(project_id, sort_index)`。

### 3.5 `project_item_resource` 子目资源快照

`item_id, kind, name, spec, unit, qty_per_unit, qty_override(NULL=沿用定额), unit_price, is_extra(补充资源)`

`qty_override` 允许用户在属性面板里改「用量」而不破坏定额原值，删除该项资源可恢复。

### 3.6 `fee_template` / `fee_rate` 取费模板

`fee_template`：`id, name, is_builtin, aux_rate(辅材费率 %), note`

`fee_rate`：`id, template_id, key, name, grp(措施费/间接费/利润/税金), base(计算基数), rate(%), sort_index, is_enabled, note`

`base` 可选：`人工费` / `人工费+机械费` / `直接费` / `直接费+措施费+间接费`。
一套模板即可覆盖不同专业的取费口径，也能保存多套随时切换。

### 3.7 `quota_category` / `meta`

`quota_category` 预留章节目录树；`meta` 存 `schema_version`，便于以后做结构升级。

---

## 4. 计算口径

```
工日         = 定额综合工日 × 工程量 × 工日调整系数
人工费       = 工日 × 人工单价            （451 号文：技工 114 元/工日）
主要材料费   = Σ(定额消耗量 × 工程量 × 材料单价)
机械使用费   = Σ(台班消耗量 × 工程量 × 台班单价)
仪表使用费   = Σ(台班消耗量 × 工程量 × 台班单价)
辅助材料费   = 人工费 × 辅材费率          （451 号文口径 0.3%，模板可改）
直接费       = 人工费 + (主材费 + 辅材费) + 机械费 + 仪表费
措施费/间接费/利润 = 各自基数 × 费率（逐项按 sort_index 顺序计算）
税金         = (直接费 + 措施费 + 间接费 + 利润) × 税率
建安工程费   = 直接费 + 措施费 + 间接费 + 利润 + 税金
设备费       = 单列，不参与取费
工程总造价   = 建安工程费 + 设备费
```

自检里用手算核对过：4 行子目 → `80.50 工日`、`人工费 9,177.00 = 80.5 × 114`、
`主材费 11,536.20`、`建安工程费 28,235.74`。

> 内置取费模板的费率是**示例值**（安全文明施工 3%、临时设施 1.5%、企业管理 25%、规费 12%、利润 8%、税金 9%），
> 界面上有明确提示。实际项目请按 451 号文与招标文件在「取费模板」里核定后使用。

---

## 5. 核心模块一：451 定额库

- **检索**：编号 / 名称 / 工作内容三字段模糊匹配 + 章节筛选，限 300 条；资源用一次 `IN` 查询批量补齐，不做 N+1。
- **插入**：`插入定额`（⌘K）弹窗检索 → 填工程量 → 一次性写入子目并复制资源快照。
- **换算**：工日调整系数、人工单价、每项资源用量（`qty_override`）、单价均可改，改完立刻重算。
- **补充定额**：`补充子目` 生成空白行，名称/单位/工日自填；`+主材 / +设备 / +机械 / +仪表` 添加补充资源。
- **定额库导入**：`定额库 → 导入定额…` 选 Excel、按表头把「编号/名称/单位/综合工日/章/节/工作内容」指到对应列，
  预览可导入条数后落库（`INSERT OR REPLACE`，同编号覆盖）。**真实 451 数据就用这条路进来。**
- **内置示例数据**：12 条覆盖线路/管道/设备三类，仅用于打通「检索→插入→计算→出表」链路，
  文件头与界面都有「非官方数值」提示，导入真实库后可直接删除（内置数据不允许删，示例数据标记为内置，
  如需清空可在「定额库」里用导入覆盖同名编号，或告诉我改成可删）。

---

## 6. 核心模块二：Excel 批量导入

### 6.1 模板格式（`空白模板` 按钮可导出 `.xlsx`）

| A | B | C |
|---|---|---|
| 定额编号 | 工程量 | 备注 |
| TXL1-001 | 12 | 架空光缆 1200m |

列位置不写死：导入向导会按表头别名自动识别（定额编号/编号/子目编号…、工程量/数量…），
也可以手动把任意列指到「定额编号 / 工程量 / 备注 / 名称 / 单位」，表头行也可调（支持无表头）。

### 6.2 校验规则（三级，优先级从高到低）

| 状态 | 触发条件 | 是否入库 |
|---|---|---|
| 编号不存在 | 编号为空，或定额库里查不到 | ❌ 拦截 |
| 工程量异常 | 工程量为 0 / 负数 / 非数字 | ❌ 拦截 |
| 重复行 | 与前面的行定额编号相同 | ✅ 只提示（可能确实要列两次） |
| 空行 | 三列全空 | 跳过 |
| 正常 | — | ✅ |

- 工程量为空时按默认值 1 处理并在「说明」列标注。
- 校验完给出汇总：`共 N 行：可导入 X，编号不存在 Y，工程量异常 Z，重复行 M，空行 K`。
- 入库走**单个事务**，上百行一次性写入（若逐条 fsync 会明显卡顿，这是性能关键点之一）。
- 导入完成后自动重算并刷新汇总条：工日 / 人工费 / 主材费 / 机械费 / 仪表费 / 直接费 / 措施费 / 间接费 / 利润 / 税金 / 建安工程费 / 工程总造价。

### 6.3 导出

`导出 Excel` 一次生成 4 个工作表：预算汇总表、定额明细表（表二）、主要材料（设备）表、机械仪表台班表。
`导出 PDF` 直接绘制 A4 横向多页 PDF（表头自动重复、页脚带页码）；`打印` 落临时 PDF 后交给系统打印面板。

---

## 7. 界面

```
┌──────────┬──────────────────────────────────────────────┬──────────────┐
│ 工程树    │ 工程名 · 类别 · 专业         [工程属性]        │ 子目属性      │
│  ├ 工程A  │ 工日 人工费 主材费 … 工程总造价（13 个汇总块） │  编号/名称    │
│  └ 工程B  │ [插入定额][补充子目][删除][导入Excel][空白模板] │  工程量 系数  │
│ 资源库    │ [报表][导出Excel][导出PDF][打印][属性面板]     │  费用构成     │
│  ├ 定额库 │ ┌──┬────┬──────┬──┬────┬──┬────┬─────────┐  │  资源明细     │
│  └ 取费模板│ │序号│编号│名称  │单位│工程量│系数│工日│ … 13 列 │  │  +主材+设备   │
│          │ └──┴────┴──────┴──┴────┴──┴────┴─────────┘  │               │
│ [新建工程]│ 共 N 条子目 · 状态                             │               │
└──────────┴──────────────────────────────────────────────┴──────────────┘
```

- 清单单元格双击即可编辑（名称 / 工程量 / 系数 / 备注），回车或失焦后写库并只刷新该行费用列 + 汇总条，
  不整表 reload，避免打断输入。
- 拖拽行可调整顺序（`NSTableView` 拖放 + 批量重写 `sort_index`）。
- 列宽按可视宽度等比分配，13 列一屏放得下；窗口变宽会自动摊开，也可手动拖列宽。
- `属性面板` 按钮可折叠右栏，给表格腾空间。

---

## 8. 编译 / 打包 / 运行

```bash
cd ComBudget

# 1) 直接跑核心自检（不弹窗，用来确认环境与逻辑）
swift build --disable-sandbox
./.build/debug/ComBudget --selftest            # 30 项检查
./.build/debug/ComBudget --selftest --keep     # 保留产物（PDF/XLSX/工程包）便于查看

# 2) 打包 .app（release + arm64 + ad-hoc 签名）
./build.sh                # 先编译再打包
./build.sh --selftest     # 先自检，通过后再打包

# 3) 运行
open build/ComBudget.app
```

`build.sh` 做了什么：`swift build -c release -target arm64-apple-macosx13.0` → 组装
`ComBudget.app/Contents/{MacOS,Resources}` → 拷 `Packaging/Info.plist` → `codesign --force --sign -`（ad-hoc）。
产物用 `lipo -info` 验证过是 **arm64 单架构**。

> `--disable-sandbox` 是因为 SwiftPM 编译 manifest 时会调用 `sandbox-exec`，在某些受限 shell 环境里会被拦。
> 你在自己的终端里通常不需要这个参数。

---

## 9. 用 Xcode 打包 M 芯片原生 App（详细步骤）

本机没装 Xcode，以下步骤在装了 Xcode 的机器上执行（Xcode 15 及以上、macOS 13+ SDK）：

1. **新建工程**
   Xcode → File → New → Project… → macOS → App → Next。
   Product Name：`ComBudget`；Team：选你的（纯本地可留 None）；Language：Swift；Interface：Storyboard（不要选 SwiftUI，本工程用 AppKit）。
2. **清掉模板自带的文件**
   删除 `AppDelegate.swift`、`ViewController.swift`、`Main.storyboard`、`Info.plist` 里的 `Main storyboard file base name` 键。
3. **导入源码**
   把 `Sources/ComBudget/` 下的所有 `.swift` 文件按原目录结构拖进工程（勾选 “Create groups”）。
   **不要**把 `main.swift` 加进来（Xcode 工程自带 `@main` 启动逻辑），其余文件全加。
   然后把 `main.swift` 里的 4 行启动代码搬到 `AppDelegate.swift` 顶部？不需要 —— 更简单的做法：
   保留 `main.swift`，删除 Xcode 自动生成的 `@main` 属性标记（AppDelegate 上加 `@main` 的那一行），
   让 `main.swift` 作为入口即可（工程里不要有第二个 `main` 符号）。
4. **Build Settings**
   - `MACOSX_DEPLOYMENT_TARGET = 13.0`
   - `ARCHS = arm64`（仅 Apple Silicon；需要兼容 Intel 时改 `$(ARCHS_STANDARD)`）
   - `ONLY_ACTIVE_ARCH = NO`（Release）
   - `SWIFT_VERSION = 5.0`
   - `ENABLE_HARDENED_RUNTIME = YES`（有正式签名时）
   - `PRODUCT_BUNDLE_IDENTIFIER = com.dujianhua.combudget`
   - `INFOPLIST_FILE` 指向 `Packaging/Info.plist`（或把里面的键合并进 Xcode 的 Info 页），
     其中已包含 `.combudget` 文档类型注册（双击工程文件即可导入）。
5. **链接的系统库**：`libsqlite3.tbd`、`libz.tbd`。
   `import SQLite3` / `import zlib` 通常由 SDK 模块自动带上；若链接报错，在
   Target → Build Phases → Link Binary With Libraries 里手动添加这两个 `.tbd`。
6. **签名**
   - 自用：Signing & Capabilities → Team 选 “None” → 勾选 “Sign to Run Locally”。
   - 分发：Developer ID Application 证书 + Hardened Runtime，然后 `notarytool` 公证。
7. **打包**
   Product → Archive → Organizer → Distribute App → Copy App（或 Developer ID）→ 得到 `.app` / `.dmg`。
8. **验证是 arm64 原生**

   ```bash
   lipo -info /path/to/ComBudget.app/Contents/MacOS/ComBudget
   # 期望：Non-fat file ... is architecture: arm64
   ```

---

## 10. 数据与备份

| 内容 | 位置 |
|---|---|
| 主库（工程列表 + 定额库 + 取费模板） | `~/Library/Application Support/ComBudget/combudget.db` |
| 单个工程另存 / 交接 | 右键工程 → 导出为 `.combudget`（自包含，含定额库与该工程用到的取费模板） |
| 全量备份 | 直接拷 `combudget.db`（含 `-wal/-shm` 时先退出程序） |

---

## 11. 需求对照（如实标注）

| # | 需求 | 状态 |
|---|---|---|
| — | 原生 App、不用 Electron、不套网页壳、Swift | ✅ AppKit 原生（SwiftUI 受本机环境限制，见第 0 节） |
| — | 仅 Apple Silicon、macOS 13+ | ✅ arm64 单架构，`LSMinimumSystemVersion=13.0` |
| — | 451 定额库结构（编号/名称/单位/工日/主材/机械/仪表/调整系数/费率） | ✅ 表结构 + 检索/插入/换算/补充齐全 |
| — | 内置「完整」451 定额数据 | ⚠️ **未内置真实数据**：官方定额数值属于受版权保护的纸质/电子出版物，我无法凭空编造可信数值。内置 12 条示例（标注「非官方」），真实库走「定额库 → 导入定额」（提供列映射向导）。你若给我 451 电子表，我可以做一次批量清洗入库并补上「章/节 + 主材/机械/仪表消耗量」全字段导入。 |
| 1 | 工程管理 + 属性 + 取费标准选择 | ✅ |
| 2 | Excel 模板批量导入 + 三类校验 + 汇总 + 导出三类表 | ✅（校验/事务/导出均自检覆盖） |
| 3 | 表格式清单：增删改、改主材数量、工日系数、补充主材/设备、备注、拖拽排序 | ✅ |
| 4 | 取费与自动计算、费率自定义、多套模板、实时汇总 | ✅（费率为示例值，需按文件核定） |
| 5 | 定额库只读基础库 + 补充定额 + 模糊搜索 + 分类筛选 | ✅ |
| 6 | 报表预览 / 打印 / 导出 PDF | ✅（4 张表，A4 横向多页，表头重复 + 页码） |
| 7 | SQLite 存储、`.combudget` 单工程保存、复制、备份 | ✅（导出/导入/复制工程均自检覆盖） |
| 8 | macOS 原生风格、三栏布局 | ✅ |
| 9 | M 芯片原生、上百行导入不卡 | ✅ 单事务批量写入 + 表格 view 复用；自检 100% 通过 |
| 10 | 不联网、不登录、不做 Windows | ✅ 全程无网络请求 |

**尚未做的（下一步可加）**：撤销/重做；清单按章节分组的小计（现在只有全局汇总）；
定额换算向导（系数库）；多工程批量汇总；`.combudget` 增量合并；SwiftUI 界面版本。

---

## 12. 快速上手三步

1. `./build.sh && open build/ComBudget.app`
2. 左下 `新建工程` → 填工程属性（类别/专业/取费标准）
3. `插入定额`（⌘K）挑几条 → 改工程量 → `报表` 预览 → `导出 Excel` / `导出 PDF`

导入真实定额的顺序反过来：先进「定额库 → 导入定额…」把 451 数据灌进去，再回工程里 `导入 Excel` 批量列项。
