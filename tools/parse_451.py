#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
451 定额电子手册 → 结构化数据（quota451.sqlite）

手册结构（单文件 HTML，按“页”切块）：
  <div class="page">
    <div class="pageHeader"><span>第四册 通信线路工程〈TXL〉第一章 第一节 一</span></div>
    <p class="pT0">第一章  施工测量、单盘检验与开挖路面</p>      ← 章
    <p class="dT1">第一节  施工测量与单盘检验</p>                ← 节
    <p class="dT2">一、施工测量</p>                              ← 子目组
    <div class="dBox"><span class="dFG">工作内容：</span>...</div> ← 工作内容
    <table class="dTable">
      <tr><td colspan="3">定额编号</td><td>TXL1-001</td><td>TXL1-002</td>...</tr>
      <tr><td colspan="3" rowspan="2">项目</td><td colspan="4">光（电）缆工程施工测量</td>...</tr>
      <tr><td>直埋</td><td>架空</td>...</tr>                      ← 子目的细分名称
      <tr><td colspan="3">定额单位</td><td colspan="4">百米</td>...</tr>
      <tr><td colspan="2">名称</td><td>单位</td><td colspan="5">数量</td></tr>
      <tr><td rowspan="2">人工</td><td>技工</td><td>工日</td><td>0.56</td>...</tr>
      <tr><td>普工</td><td>工日</td><td>0.14</td>...</tr>
      <tr><td rowspan="4">主要材料</td><td>光缆</td><td>m</td><td>102</td>...</tr>
      <tr><td rowspan="2">机械</td>...</tr>
      <tr><td rowspan="3">仪表</td>...</tr>
    </table>

跑法：  python3 tools/parse_451.py <手册.html> <输出.sqlite>
"""
import sys, re, json, sqlite3, html
from html.parser import HTMLParser

VOID = {"br", "hr", "img", "meta", "link", "input", "col"}


# --------------------------------------------------------------------------
# 通用：把一张 table 展开成二维网格（处理 rowspan / colspan）
# --------------------------------------------------------------------------
class TableGridParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows = []          # list[list[dict(text, rowspan, colspan)]]
        self.cur_row = None
        self.cur_cell = None
        self.in_table = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "table":
            self.in_table += 1
        elif tag == "tr" and self.in_table:
            self.cur_row = []
            self.rows.append(self.cur_row)
        elif tag in ("td", "th") and self.in_table and self.cur_row is not None:
            self.cur_cell = {
                "text": [],
                "rowspan": int(a.get("rowspan") or 1),
                "colspan": int(a.get("colspan") or 1),
            }
            self.cur_row.append(self.cur_cell)
        elif tag in ("br",) and self.cur_cell is not None:
            self.cur_cell["text"].append(" ")

    def handle_data(self, data):
        if self.cur_cell is not None:
            self.cur_cell["text"].append(data)

    def handle_endtag(self, tag):
        if tag in ("td", "th"):
            self.cur_cell = None
        elif tag == "tr":
            self.cur_row = None
        elif tag == "table":
            self.in_table = max(0, self.in_table - 1)


def table_to_grid(table_html):
    p = TableGridParser()
    p.feed(table_html)
    grid = []
    occupied = {}   # (row, col) -> True
    for r, row in enumerate(p.rows):
        out = []
        c = 0
        for cell in row:
            while occupied.get((r, c)):
                out.append("")
                c += 1
            text = clean_text("".join(cell["text"]))
            for dr in range(cell["rowspan"]):
                for dc in range(cell["colspan"]):
                    occupied[(r + dr, c + dc)] = True
            # colspan 复制文本：项目名称 / 定额单位 常跨多列
            for dc in range(cell["colspan"]):
                out.append(text)
            c += cell["colspan"]
        # 补齐被 rowspan 占位但本行没有起始单元格的列
        width = max([k[1] for k in occupied if k[0] >= r] + [-1]) + 1 if occupied else len(out)
        while len(out) < width:
            out.append("")
        grid.append(out)
    # 统一宽度
    w = max(len(r) for r in grid) if grid else 0
    return [r + [""] * (w - len(r)) for r in grid]


def clean_text(s):
    s = s.replace("\u00a0", " ").replace("\u2002", " ").replace("\u2003", " ")
    s = re.sub(r"[ \t\r\n]+", " ", s)
    return s.strip()


# --------------------------------------------------------------------------
# 主解析
# --------------------------------------------------------------------------
CODE_RE = re.compile(r"^[A-Z][A-Z0-9]{0,4}\d?-\d{2,4}[A-Z]?$")
NUM_RE = re.compile(r"^[（(]?\s*(-?\d+(?:\.\d+)?)\s*[）)]?$")
SUP_RE = re.compile(r"[①②③④⑤⑥⑦⑧⑨⑩]")


def norm_code(s):
    s = clean_text(s).replace(" ", "").replace("－", "-").replace("—", "-")
    return s


def parse_number(s):
    """'—' → None；'（0.02）' → 0.02（未计价/参考量）；'1.20' → 1.2"""
    s = clean_text(s)
    if not s or s in ("—", "-", "－", "／", "/"):
        return None
    s = SUP_RE.sub("", s)
    m = NUM_RE.match(s.replace(" ", ""))
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def parse_pages(html_text):
    """按 <div class="page"> 切页，返回 [(header_text, body_html)]"""
    pages = []
    # 每个 page 块以 <div class="page..."> 开头，到下一个同类 div 或 </div> 结束（粗略但够用）
    starts = [m.start() for m in re.finditer(r'<div class="page[ "]', html_text)]
    for i, st in enumerate(starts):
        en = starts[i + 1] if i + 1 < len(starts) else len(html_text)
        block = html_text[st:en]
        m = re.search(r'<div class="pageHeader"><span>(.*?)</span></div>', block, re.S)
        header = clean_text(re.sub(r"<[^>]+>", "", m.group(1))) if m else ""
        pages.append((header, block))
    return pages


def strip_tags(s):
    s = re.sub(r"<[^>]+>", "", s)
    return clean_text(html.unescape(s))


def main():
    src, out = sys.argv[1], sys.argv[2]
    raw = open(src, encoding="utf-8", errors="replace").read()
    pages = parse_pages(raw)
    print(f"页数：{len(pages)}")

    items = {}     # code -> dict
    order = 0

    cur_book = ""
    cur_book_code = ""
    cur_chapter = ""
    cur_section = ""
    cur_group = ""
    cur_work = ""

    for pi, (header, block) in enumerate(pages):
        # 页眉里的册/章信息
        mb = re.search(r"第([一二三四五六七八九十]+)册\s*(.*?)〈([A-Z0-9]+)〉", header)
        if mb:
            cur_book = f"第{mb.group(1)}册 {mb.group(2).strip()}"
            cur_book_code = mb.group(3)

        # 章 / 节 / 子目组标题
        for cls, target in (("pT0", "chapter"), ("dT1", "section"), ("dT2", "group")):
            m = re.search(r'<p class="%s"[^>]*>(.*?)</p>' % cls, block, re.S)
            if m:
                text = strip_tags(m.group(1))
                if target == "chapter" and text:
                    cur_chapter, cur_group = text, ""
                elif target == "section" and text:
                    cur_section, cur_group = text, ""
                elif target == "group" and text:
                    cur_group = text

        # 工作内容
        for m in re.finditer(r'<div class="dBox">(.*?)</div>', block, re.S):
            t = strip_tags(m.group(1))
            t = re.sub(r"^工作内容[：:]\s*", "", t)
            if t:
                cur_work = t[:300]

        # 定额表
        for tm in re.finditer(r'<table[^>]*class="dTable[^"]*"[^>]*>(.*?)</table>', block, re.S):
            grid = table_to_grid("<table>" + tm.group(1) + "</table>")
            parse_one_table(grid, items, order,
                            cur_book, cur_book_code, cur_chapter, cur_section, cur_group, cur_work)
            order += 1000

    # 统计
    with_res = sum(1 for v in items.values() if v["resources"])
    total_res = sum(len(v["resources"]) for v in items.values())
    print(f"定额条数：{len(items)}  含资源：{with_res}  资源行：{total_res}")

    write_sqlite(out, items)
    print(f"已写出：{out}")


def parse_one_table(grid, items, order_base, book, book_code, chapter, section, group, work):
    if not grid:
        return

    # 1) 找定额编号行
    code_row = None
    for r, row in enumerate(grid):
        joined = "".join(row)
        if "定额编号" in joined.replace(" ", "") or "定额编号" in joined:
            code_row = r
            break
    if code_row is None:
        return

    label_width = 0
    codes = []
    for c, cell in enumerate(grid[code_row]):
        t = norm_code(cell)
        if CODE_RE.match(t):
            codes.append((c, t))
        elif not codes:
            label_width = c + 1
    if not codes:
        return
    code_cols = [c for c, _ in codes]
    first_code_col = code_cols[0]

    # 2) 项目名称行（可能跨两行）
    name_row = None
    for r in range(code_row + 1, min(code_row + 4, len(grid))):
        if any("项" in grid[r][c].replace(" ", "") for c in range(first_code_col)):
            name_row = r
            break
    if name_row is None:
        name_row = code_row + 1

    # 3) 定额单位行
    unit_row = None
    for r in range(name_row, min(name_row + 6, len(grid))):
        if "定额单位" in "".join(grid[r]).replace(" ", ""):
            unit_row = r
            break
    if unit_row is None:
        return

    names = {}
    for c in code_cols:
        parts = []
        for r in range(name_row, unit_row):
            t = grid[r][c]
            t = t.replace("项", "", 1) if r == name_row and "项" in t and len(t) <= 3 else t
            t = SUP_RE.sub("", t)
            if t and t not in ("目", "项目"):
                parts.append(t)
        names[c] = " ".join(parts).strip()

    units = {c: grid[unit_row][c] if c < len(grid[unit_row]) else "" for c in code_cols}

    # 4) 资源区：找 “名称/单位” 表头行
    res_head = None
    name_col = unit_col = None
    for r in range(unit_row + 1, min(unit_row + 5, len(grid))):
        row = grid[r]
        for c, cell in enumerate(row):
            if "名" in cell and "称" in cell:
                if c + 1 < len(row) and "单位" in row[c + 1]:
                    res_head, name_col, unit_col = r, c, c + 1
                    break
        if res_head is not None:
            break
    if res_head is None:
        res_head, name_col, unit_col = unit_row + 1, max(first_code_col - 2, 0), max(first_code_col - 1, 0)

    # 5) 逐行解析资源（人工 → 主要材料 → 机械 → 仪表）
    tech = {c: 0.0 for c in code_cols}
    labor = {c: 0.0 for c in code_cols}
    resources = {c: [] for c in code_cols}
    cur_group = ""
    group_map = {"人工": "人工", "主要材料": "主材", "材料": "主材",
                 "机械": "机械", "仪表": "仪表", "设备": "设备"}

    for r in range(res_head + 1, len(grid)):
        row = grid[r]
        if not row:
            continue
        # 分组标签
        label_cells = [row[c] for c in range(min(name_col, len(row))) if row[c]]
        for cell in label_cells:
            key = cell.replace(" ", "")
            for k, v in group_map.items():
                if key.startswith(k):
                    cur_group = v
                    break
        if not cur_group:
            continue
        name = row[name_col] if name_col < len(row) else ""
        unit = row[unit_col] if unit_col < len(row) else ""
        if not name:
            continue
        if cur_group == "人工":
            key = name.replace(" ", "")
            for c in code_cols:
                v = parse_number(row[c]) if c < len(row) else None
                if v is None:
                    continue
                if key.startswith("技工"):
                    tech[c] += v
                elif key.startswith("普工"):
                    labor[c] += v
            continue
        for c in code_cols:
            v = parse_number(row[c]) if c < len(row) else None
            if v is None or v == 0:
                continue
            resources[c].append({
                "kind": cur_group,
                "name": name,
                "unit": unit,
                "qty": v,
            })

    # 6) 落库（同一编号可能出现在目录/续表/勘误中，这里按“信息量更大者胜 + 资源并集”合并）
    for i, (c, code) in enumerate(codes):
        cand = {
            "code": code,
            "name": (names.get(c) or group or code).strip(),
            "unit": units.get(c) or "",
            "book": book,
            "series": code.split("-")[0],
            "chapter": chapter,
            "section": section,
            "group": group,
            "work": work,
            "tech": round(tech[c], 4),
            "labor": round(labor[c], 4),
            "resources": resources[c],
            "order": order_base + i,
        }
        if code not in items:
            items[code] = cand
            continue
        old = items[code]
        cand["resources"] = merge_resources(old["resources"], cand["resources"])
        if (cand["tech"] + cand["labor"]) > (old["tech"] + old["labor"]):
            items[code] = cand
        else:
            old["resources"] = cand["resources"]


def merge_resources(a, b):
    """按 (kind, name, unit) 取并集，消耗量取较大值（同一条定额在续表里重复出现时互补）"""
    out = {}
    for r in list(a) + list(b):
        key = (r["kind"], r["name"], r["unit"])
        if key in out:
            out[key]["qty"] = max(out[key]["qty"], r["qty"])
        else:
            out[key] = dict(r)
    return list(out.values())


SCHEMA = """
DROP TABLE IF EXISTS quota_item;
DROP TABLE IF EXISTS quota_resource;
CREATE TABLE quota_item (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    unit TEXT DEFAULT '',
    chapter TEXT DEFAULT '',
    section TEXT DEFAULT '',
    series TEXT DEFAULT '',
    book TEXT DEFAULT '',
    work TEXT DEFAULT '',
    tech_workday REAL DEFAULT 0,
    labor_workday REAL DEFAULT 0,
    sort_index INTEGER DEFAULT 0
);
CREATE TABLE quota_resource (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    quota_code TEXT NOT NULL,
    kind TEXT NOT NULL,
    name TEXT NOT NULL,
    unit TEXT DEFAULT '',
    qty_per_unit REAL DEFAULT 0,
    unit_price REAL DEFAULT 0
);
CREATE INDEX idx_qr_code ON quota_resource(quota_code);
CREATE INDEX idx_qi_series ON quota_item(series);
"""


def write_sqlite(path, items):
    con = sqlite3.connect(path)
    con.executescript(SCHEMA)
    rows = sorted(items.values(), key=lambda x: x["order"])
    for it in rows:
        con.execute(
            "INSERT OR IGNORE INTO quota_item(code,name,unit,chapter,section,series,book,work,"
            "tech_workday,labor_workday,sort_index) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (it["code"], it["name"], it["unit"], it["chapter"], it["section"], it["series"],
             it["book"], it["work"], it["tech"], it["labor"], it["order"]))
        for res in it["resources"]:
            con.execute(
                "INSERT INTO quota_resource(quota_code,kind,name,unit,qty_per_unit,unit_price) "
                "VALUES(?,?,?,?,?,0)",
                (it["code"], res["kind"], res["name"], res["unit"], res["qty"]))
    con.commit()
    con.close()


if __name__ == "__main__":
    main()
