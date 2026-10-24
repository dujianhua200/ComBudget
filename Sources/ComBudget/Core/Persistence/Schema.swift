import Foundation

// =============================================================================
// 数据库表结构（SQLite）—— schema v2
//
// v2 相比 v1 的变化：人工拆成「技工/普工」两栏（与 451 定额原书一致），
// 定额库增加 series / book / work（工作内容）字段，并支持从内置 451 库整库导入。
//
// 设计要点：
// 1. quota_* 是定额库（内置 3091 条 451 全册 + 用户补充定额）。
// 2. project_item_resource 是「资源快照」：插入子目时把定额的主材/机械/仪表消耗量
//    复制到工程里，之后改定额库不影响已编工程，保证造价可复现。
// 3. 取费模板拆成 fee_template + fee_rate，费率项可增删、可排序、可选计算基数。
// =============================================================================

enum Schema {
    static let version = 2

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
        is_supplement  INTEGER DEFAULT 0
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
        try db.exec("""
        DROP TABLE IF EXISTS quota_resource;
        DROP TABLE IF EXISTS quota_item;
        """)
        try db.exec(createAll)
        try db.run("UPDATE meta SET value=? WHERE key='schema_version';", [String(version)])
    }
}
