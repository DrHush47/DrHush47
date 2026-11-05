"""Renders assets/dark_mode.svg and assets/light_mode.svg from src/card.toml.

The ASCII portraits and the card frames come verbatim from src/portrait-<theme>.svg,
so only the text panel is generated. Both themes are produced in one pass - that
is the whole point: edit one file, get two consistent panels.

    python scripts/build.py           # rebuild both assets
    python scripts/build.py --check   # exit 1 if assets/ is out of date
"""

from __future__ import annotations

import calendar
import html
import json
import re
import sys
import tomllib
import unicodedata
from datetime import date, datetime, timezone
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
ASSETS = ROOT / "assets"
STATS = SRC / "stats.json"

PANEL_X = 482.4
FONT_SIZE = 16
CHAR_W = 9.6
LINE_H = 20.0
Y_START = 208.2
COLS = 53  # characters per value line; headers are one wider
BOTTOM_PAD = 24.0

FONT = "'Consolas', 'Menlo', 'DejaVu Sans Mono', monospace"

PALETTES = {
    "dark": {
        "bg": "#0d1117",
        "border": "#30363d",
        "header": "#58a6ff",
        "rule": "#3d444d",
        "key": "#ffa657",
        "dots": "#484f58",
        "value": "#c9d1d9",
    },
    "light": {
        "bg": "#ffffff",
        "border": "#d0d7de",
        "header": "#0969da",
        "rule": "#d0d7de",
        "key": "#953800",
        "dots": "#8c959f",
        "value": "#24292f",
    },
}


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def check_text(label: str, text: str) -> None:
    if not text:
        die(f"{label}: пустое значение")
    if any(ch in text for ch in "\r\n\t"):
        die(f"{label}: переводы строк и табы запрещены")
    wide = [ch for ch in text if unicodedata.east_asian_width(ch) in ("W", "F")]
    if wide:
        die(f"{label}: широкие символы ({', '.join(wide)}) ломают сетку - убери их")


def esc(text: str) -> str:
    return html.escape(text, quote=False)


def fmt_y(value: float) -> str:
    return f"{value:.1f}"


def header_line(y: float, title: str, p: dict[str, str]) -> str:
    dashes = "\u2500" * (COLS + 1 - 1 - (len(title) + 2))
    return (
        f'  <text x="{PANEL_X}" y="{fmt_y(y)}" font-family="{FONT}"'
        f' xml:space="preserve" font-size="{FONT_SIZE}">'
        f'<tspan fill="{p["rule"]}">\u2500</tspan>'
        f'<tspan fill="{p["header"]}"> {esc(title)} </tspan>'
        f'<tspan fill="{p["rule"]}">{dashes}</tspan></text>'
    )


def row_line(y: float, key: str, value: str, p: dict[str, str]) -> str:
    if key:
        prefix = f". {key}: "
        dots = COLS - len(prefix) - 1 - len(value)
        if dots < 2:
            die(f"строка '{key}': значение не влезает в панель ({len(value)} символов)")
        head = f'<tspan fill="{p["key"]}">{esc(prefix)}</tspan>'
        tail = " " + value
    else:
        # Continuation line (the (+/--) counters): right-aligned like a value,
        # but without a key of its own.
        dots = COLS - len(value)
        if dots < 2:
            die(f"строка-продолжение: значение не влезает в панель ({len(value)} символов)")
        head = ""
        tail = value
    return (
        f'  <text x="{PANEL_X}" y="{fmt_y(y)}" font-family="{FONT}"'
        f' xml:space="preserve" font-size="{FONT_SIZE}">'
        f'{head}'
        f'<tspan fill="{p["dots"]}">{"." * dots}</tspan>'
        f'<tspan fill="{p["value"]}">{esc(tail)}</tspan></text>'
    )


def plural(n: int, word: str) -> str:
    return f"{n} {word}" if n == 1 else f"{n} {word}s"


def human_age(created_at: object, today: date | None = None) -> str:
    """Calendar age from an ISO timestamp: '4 years, 5 months, 14 days'."""
    if not isinstance(created_at, str):
        return ""
    try:
        created = datetime.fromisoformat(created_at.replace("Z", "+00:00")).date()
    except ValueError:
        return ""

    today = today or datetime.now(timezone.utc).date()
    if created > today:
        return ""

    months = 0
    while add_months(created, months + 1) <= today:
        months += 1
    years, months = divmod(months, 12)
    days = (today - add_months(created, years * 12 + months)).days

    parts: list[str] = []
    if years:
        parts.append(plural(years, "year"))
    if months:
        parts.append(plural(months, "month"))
    if days or not parts:
        parts.append(plural(days, "day"))
    return ", ".join(parts)


def add_months(start: date, months: int) -> date:
    """Same day-of-month `months` later, clamped to the end of short months."""
    index = start.month - 1 + months
    year = start.year + index // 12
    month = index % 12 + 1
    return date(year, month, min(start.day, calendar.monthrange(year, month)[1]))


def stats_rows(stats: dict) -> list[list[str]]:
    """Rows for a block marked dynamic = "stats" (see scripts/fetch_stats.py)."""
    rows: list[list[str]] = []

    age = human_age(stats.get("created_at"))
    if age:
        rows.append(["Age", age])

    for key, label in (
        ("repos", "Repos"),
        ("stars", "Stars"),
        ("commits", "Commits"),
        ("followers", "Followers"),
        ("loc", "Lines of Code on GitHub"),
    ):
        value = stats.get(key)
        if isinstance(value, int) and not isinstance(value, bool):
            rows.append([label, f"{value:,}"])

    added = stats.get("loc_add")
    removed = stats.get("loc_del")
    if isinstance(added, int) and isinstance(removed, int):
        rows.append(["", f"({added:,}++, {removed:,}--)"])

    return rows


def load_stats() -> dict | None:
    """src/stats.json is optional: without it the stats block is skipped, so a
    fresh clone still builds and text edits never depend on the network."""
    if not STATS.exists():
        return None
    try:
        data = json.loads(STATS.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"warning: src/stats.json не читается ({exc}) - секция статистики пропущена", file=sys.stderr)
        return None
    if not isinstance(data, dict):
        print("warning: src/stats.json должен быть объектом - секция статистики пропущена", file=sys.stderr)
        return None
    return data


def expand_blocks(blocks: list[dict], stats: dict | None) -> list[dict]:
    """Expands dynamic blocks in place order; drops them when there is no data."""
    expanded: list[dict] = []
    for block in blocks:
        kind = block.get("dynamic")
        if kind is None:
            expanded.append(block)
            continue
        if kind != "stats":
            die(f"секция '{block.get('title', '')}': неизвестный dynamic = '{kind}'")
        rows = stats_rows(stats) if stats else []
        if not rows:
            continue
        merged = dict(block)
        merged["rows"] = list(block.get("rows", [])) + rows
        expanded.append(merged)
    return expanded


def render_panel(blocks: list[dict], p: dict[str, str]) -> tuple[list[str], float]:
    lines: list[str] = []
    y = Y_START
    for block in blocks:
        title = block.get("title", "")
        if title:
            check_text("заголовок секции", title)
            lines.append(header_line(y, title, p))
            y += LINE_H
        for row in block.get("rows", []):
            if not isinstance(row, list) or len(row) != 2:
                die(f"строка в секции '{title}' должна быть [ключ, значение]")
            key, value = (str(row[0]), str(row[1]))
            label = f"'{key}'" if key else "продолжение"
            if key:
                check_text(f"ключ {label}", key)
            check_text(f"значение {label}", value)
            lines.append(row_line(y, key, value, p))
            y += LINE_H
        y += LINE_H  # пустая строка между секциями
    return lines, y


def patch_geometry(svg: str, height: int) -> str:
    svg = re.sub(r'height="\d+(?:\.\d+)?"', f'height="{height}"', svg, count=1)
    svg = re.sub(
        r'viewBox="0 0 (\d+) \d+(?:\.\d+)?"',
        lambda m: f'viewBox="0 0 {m.group(1)} {height}"',
        svg,
        count=1,
    )
    svg = re.sub(
        r'(<rect[^>]*?height=")\d+(?:\.\d+)?"',
        lambda m: f'{m.group(1)}{height - 1}"',
        svg,
        count=1,
    )
    return svg


def build() -> dict[str, str]:
    config = tomllib.loads((SRC / "card.toml").read_text(encoding="utf-8-sig"))
    blocks = config.get("block", [])
    if not blocks:
        die("src/card.toml: нет ни одной секции [[block]]")
    blocks = expand_blocks(blocks, load_stats())
    if not blocks:
        die('src/card.toml: все секции пусты (для dynamic = "stats" нет данных)')

    rendered: dict[str, str] = {}
    for theme, palette in PALETTES.items():
        # Один портрет на тему: gh-ascii инвертирует плотность глифов для
        # тёмного фона, поэтому эти блоки принципиально разные.
        portrait = (SRC / f"portrait-{theme}.svg").read_text(encoding="utf-8").rstrip("\n")
        base_height = int(float(re.search(r'height="(\d+(?:\.\d+)?)"', portrait).group(1)))
        lines, panel_end = render_panel(blocks, palette)
        height = max(base_height, int(panel_end + BOTTOM_PAD))
        body = patch_geometry(portrait, height)
        head, rest = body.split("\n", 1)
        body = (
            head
            + "\n  <!-- generated by scripts/build.py from src/card.toml - edit the source, not this file -->\n"
            + rest
        )
        rendered[theme] = body + "\n" + "\n".join(lines) + "\n</svg>\n"

    return rendered


def main() -> None:
    rendered = build()
    check_only = "--check" in sys.argv[1:]
    stale: list[str] = []

    for theme, content in rendered.items():
        path = ASSETS / f"{theme}_mode.svg"
        try:
            ElementTree.fromstring(content)
        except ElementTree.ParseError as exc:
            die(f"{path.name}: невалидный XML после сборки ({exc})")

        if check_only:
            current = path.read_text(encoding="utf-8") if path.exists() else ""
            if current != content:
                stale.append(path.name)
            continue

        tmp = path.with_suffix(".svg.tmp")
        tmp.write_text(content, encoding="utf-8", newline="\n")
        tmp.replace(path)
        print(f"built {path.relative_to(ROOT)} ({len(content.encode('utf-8')):,} bytes)")

    if check_only:
        if stale:
            die("устарели: " + ", ".join(stale) + " - запусти python scripts/build.py")
        print("assets are up to date")


if __name__ == "__main__":
    main()
