#!/usr/bin/env python3
"""Parse ===ONECRATE_SYSCALL_5S=== lines from onecrate serial log; emit Markdown rate table (stdlib only)."""
from __future__ import annotations

import re
import sys
from pathlib import Path

# One line: ===ONECRATE_SYSCALL_5S t_rel=... total=... delta=... dps=...===
# Fields are `key=value` pairs; values must not contain '=' (so '-' does not swallow '===').
_ROW_RE = re.compile(
    r"===ONECRATE_SYSCALL_5S\s+"
    r"t_rel=(?P<t_rel>[^=\s]+)\s+"
    r"total=(?P<total>[^=\s]+)\s+"
    r"delta=(?P<delta>[^=\s]+)\s+"
    r"dps=(?P<dps>[^=\s]+)\s*==="
)


def extract_rows(text: str) -> list[tuple[str, str, str, str]]:
    rows: list[tuple[str, str, str, str]] = []
    for m in _ROW_RE.finditer(text):
        rows.append(
            (
                m.group("t_rel"),
                m.group("total"),
                m.group("delta"),
                m.group("dps"),
            )
        )
    return rows


def render_markdown(rows: list[tuple[str, str, str, str]]) -> str:
    lines = [
        "| interval_end_t | total | delta | dps |",
        "| --- | --- | --- | --- |",
    ]
    for t_rel, total, delta, dps in rows:
        lines.append(f"| {t_rel} | {total} | {delta} | {dps} |")
    return "\n".join(lines) + ("\n" if rows else "")


def main() -> int:
    if len(sys.argv) > 1:
        path = Path(sys.argv[1])
        text = path.read_text(encoding="utf-8", errors="replace")
    else:
        text = sys.stdin.read()
    rows = extract_rows(text)
    sys.stdout.write(render_markdown(rows))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
