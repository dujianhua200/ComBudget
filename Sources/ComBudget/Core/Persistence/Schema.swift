import Foundation

// =============================================================================
// 数据库表结构（SQLite）—— schema v2
//
// v2 相比 v1 的变化：人工拆成「技工/普工」两栏（与 451 定额原书一致），
// 定额库增加 series / book / work（工作内容）字段，并支持从内置 451 库整库导入。
//
// v3 相比 v2 的变化：
//   · 新增 resource_price 价格库（451 手册只有消耗量、没有单价，单价是另一本价格册）；
//   · project_item 增加 chapter / series（用于「按分册分组小计」）；
//   · project_item 增加 tech_workday_base / labor_workday_base / conv_note（定额换算：
//     保留定额原值时，换算后的工日和换算痕迹另存，便于审计回溯）。
//
// 设计要点：
// 1. quota_* 是定额库（内置 3091 条 451 全册 + 用户补充定额）。
// 2. project_item_resource 是「资源快照」：插入子目时把定额的主材/机械/仪表消耗量
//    复制到工程里，之后改定额库不影响已编工程，保证造价可复现。
// 3. 取费模板拆成 fee_template + fee_rate，费率项可增删、可排序、可选计算基数。
// 4. price_* 是独立的价格库：一套 sweeping price 可被多个工程复用，
//    套价时写到 project_item_resource.unit_price（工程自己的快照里）。
// =============================================================================

enum Schema {
    static let version = 3

    static let createAll = """
    CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT
    );

    -- ---------- 定额分类（册/章，用于筛选） ----------
    CREATE TABLE IF NOT EXISTS quota_category (
        code      TEXT PRIMARY KEY,
        name      TEXT NOT NULL,
        parent    TEXT,
        sort      INTEGER DEFAULT 0
    );

    -- ---------- 定额子目（451 定额主表） ----------
    CREATE TABLE IF NOT EXISTS quota_item (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        code          TEXT NOT NULL UNIQUE,
        name          TEXT NOT NULL,
        unit          TEXT DEFAULT '',
        chapter       TEXT DEFAULT '',
        section       TEXT DEFAULT '',
        series        TEXT DEFAULT '',
        book          TEXT DEFAULT '',
        work          TEXT DEFAULT '',
        tech_workday  REAL DEFAULT 0,
        labor_workday REAL DEFAULT 0,
        is_builtin    INTEGER DEFAULT 1,
        sort_index    INTEGER DEFAULT 0,
        created_at    REAL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_quota_name   ON quota_item(name);
    CREATE INDEX IF NOT EXISTS idx_quota_series ON quota_item(series);
    CREATE INDEX IF NOT EXISTS idx_quota_chapter ON quota_item(chapter);

    -- ---------- 定额资源（主材/机械/仪表/设备消耗量） ----------
    CREATE TABLE IF NOT EXISTS quota_resource (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        quota_id     INTEGER NOT NULL REFERENCES quota_item(id) ON DELETE CASCADE,
        kind         TEXT NOT NULL,
        name         TEXT DEFAULT '',
        spec         TEXT DEFAULT '',
        unit         TEXT DEFAULT '',
        qty_per_unit REAL DEFAULT 0,
        unit_price   REAL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_quota_res ON quota_resource(quota_id);

    -- ---------- 工程 ----------
    CREATE TABLE IF NOT EXISTS project (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        code            TEXT DEFAULT '',
        name            TEXT NOT NULL,
        category        TEXT DEFAULT '',
        specialty       TEXT DEFAULT '',
        scale           TEXT DEFAULT '',
        owner           TEXT DEFAULT '',
        contractor      TEXT DEFAULT '',
        compiler        TEXT DEFAULT '',
        reviewer        TEXT DEFAULT '',
        fee_template_id INTEGER DEFAULT 0,
        created_at      REAL DEFAULT 0,
        updated_at      REAL DEFAULT 0
    );

    -- ---------- 工程定额子目 ----------
    CREATE TABLE IF NOT EXISTS project_item (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id     INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
        sort_index     INTEGER DEFAULT 0,
        quota_code     TEXT DEFAULT '',
        quota_name     TEXT DEFAULT '',
        unit           TEXT DEFAULT '',
        quantity       REAL DEFAULT 0,
        workday_coeff  REAL DEFAULT 1,
        tech_workday   REAL DEFAULT 0,
        labor_workday  REAL DEFAULT 0,
        tech_price     REAL DEFAULT 114,
        labor_price    REAL DEFAULT 61,
        note           TEXT DEFAULT '',
        is_supplement  INTEGER DEFAULT 0,
        chapter        TEXT DEFAULT '',
        series         TEXT DEFAULT '',
        tech_workday_base  REAL DEFAULT 0,
        labor_workday_base REAL DEFAULT 0,
        conv_note      TEXT DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS idx_item_project ON project_item(project_id, sort_index);

    -- ---------- 子目资源快照 ----------
    CREATE TABLE IF NOT EXISTS project_item_resource (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id       INTEGER NOT NULL REFERENCES project_item(id) ON DELETE CASCADE,
        kind          TEXT NOT NULL,
        name          TEXT DEFAULT '',
        spec          TEXT DEFAULT '',
        unit          TEXT DEFAULT '',
        qty_per_unit  REAL DEFAULT 0,
        qty_override  REAL,
        unit_price    REAL DEFAULT 0,
        is_extra      INTEGER DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_item_res ON project_item_resource(item_id);

    -- ---------- 取费模板 ----------
    CREATE TABLE IF NOT EXISTS fee_template (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        name         TEXT NOT NULL,
        is_builtin   INTEGER DEFAULT 0,
        aux_rate     REAL DEFAULT 0.3,
        note         TEXT DEFAULT ''
    );

    CREATE TABLE IF NOT EXISTS fee_rate (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        template_id INTEGER NOT NULL REFERENCES fee_template(id) ON DELETE CASCADE,
        key         TEXT DEFAULT '',
        name        TEXT NOT NULL,
        grp         TEXT DEFAULT '措施费',
        base        TEXT DEFAULT '人工费',
        rate        REAL DEFAULT 0,
        sort_index  INTEGER DEFAULT 0,
        is_enabled  INTEGER DEFAULT 1,
        note        TEXT DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS idx_fee_rate_tpl ON fee_rate(template_id, sort_index);

    -- ---------- 价格库（451 手册只有消耗量，单价来自另一本价格册） ----------
    CREATE TABLE IF NOT EXISTS resource_price (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        kind       TEXT NOT NULL,
        name       TEXT NOT NULL,
        spec       TEXT DEFAULT '',
        unit       TEXT DEFAULT '',
        unit_price REAL NOT NULL DEFAULT 0,
        source     TEXT DEFAULT '',
        updated_at REAL DEFAULT 0
    );
    CREATE UNIQUE INDEX IF NOT EXISTS uk_resource_price
        ON resource_price(kind, name, spec, unit);
    CREATE INDEX IF NOT EXISTS idx_price_name ON resource_price(name);
    """

    static func migrate(_ db: SQLiteDB) throws {
        try db.exec(createAll)
        let rows = try db.query("SELECT value FROM meta WHERE key='schema_version';") { $0.text(0) }
        let current = Int(rows.first ?? "") ?? 0

        if rows.isEmpty {
            try db.run("INSERT INTO meta(key, value) VALUES('schema_version', ?);", [String(version)])
            return
        }
        guard current < version else { return }

        // v1 → v2：定额库结构变了（人工拆技工/普工），直接重建定额表并清空，稍后由内置库重新导入
        if current < 2 {
            try db.exec("""
            DROP TABLE IF EXISTS quota_resource;
            DROP TABLE IF EXISTS quota_item;
            """)
            try db.exec(createAll)
        }

        // v2 → v3：只加列，不破坏已有工程数据
        if current < 3 {
            try addColumn(db, table: "project_item", name: "chapter",
                          ddl: "chapter TEXT DEFAULT ''")
            try addColumn(db, table: "project_item", name: "series",
                          ddl: "series TEXT DEFAULT ''")
            try addColumn(db, table: "project_item", name: "tech_workday_base",
                          ddl: "tech_workday_base REAL DEFAULT 0")
            try addColumn(db, table: "project_item", name: "labor_workday_base",
                          ddl: "labor_workday_base REAL DEFAULT 0")
            try addColumn(db, table: "project_item", name: "conv_note",
                          ddl: "conv_note TEXT DEFAULT ''")
            // 老库的 project_item 没有 series/chapter，从定额库回填，保证分组小计可用
            try db.exec("""
            UPDATE project_item SET series = COALESCE(
                (SELECT series FROM quota_item WHERE quota_item.code = project_item.quota_code), series)
            WHERE series IS NULL OR series = '';
            UPDATE project_item SET chapter = COALESCE(
                (SELECT chapter FROM quota_item WHERE quota_item.code = project_item.quota_code), chapter)
            WHERE chapter IS NULL OR chapter = '';
            """)
            // 老库没有换算功能，定额原值就等于当时写库的工日值，先原样兜底
            try db.exec("""
            UPDATE project_item SET tech_workday_base = tech_workday
            WHERE tech_workday_base = 0 AND tech_workday <> 0;
            UPDATE project_item SET labor_workday_base = labor_workday
            WHERE labor_workday_base = 0 AND labor_workday <> 0;
            """)
        }

        try db.run("UPDATE meta SET value=? WHERE key='schema_version';", [String(version)])
    }

    /// ALTER TABLE ADD COLUMN（幂等：列已存在就跳过）
    private static func addColumn(_ db: SQLiteDB, table: String, name: String, ddl: String) throws {
        let exists = try db.query("PRAGMA table_info(\(table));") { $0.text(1) }
            .contains { $0 == name }
        guard !exists else { return }
        try db.exec("ALTER TABLE \(table) ADD COLUMN \(ddl);")
    }
}
