#!/usr/bin/env python3
"""Verify that every L("...") key used in the Swift sources has an English
translation and that format placeholders match.

Run from the repository root:

    python3 scripts/check-localization.py
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
TABLE = ROOT / "Sources" / "TaugeKit" / "Localization" / "en.json"
# The loader itself contains a doc-comment example, not a UI string.
SKIP_FILES = {"TaugeL10n.swift"}
ALLOWED_IDENTICAL = {
    "SFTP", "SSH", "HTTP", "SOCKS5", "SOCKS5h", "Termius", "Tauge",
    "tmux", "vim", "htop", "Ctrl", "Esc", "Tab", "OK",
}

CALL = re.compile(r'L\(\s*"((?:[^"\\]|\\.)*)"', re.S)
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[@d%]")


def swift_unescape(value: str) -> str:
    out: list[str] = []
    i = 0
    while i < len(value):
        ch = value[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        i += 1
        if i >= len(value):
            out.append("\\")
            break
        esc = value[i]
        i += 1
        mapping = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\", "0": "\0"}
        if esc in mapping:
            out.append(mapping[esc])
        elif esc == "u" and i < len(value) and value[i] == "{":
            end = value.index("}", i)
            out.append(chr(int(value[i + 1:end], 16)))
            i = end + 1
        else:
            out.append(esc)
    return "".join(out)


def main() -> int:
    table = json.loads(TABLE.read_text())
    used: dict[str, str] = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        if path.name in SKIP_FILES:
            continue
        text = path.read_text()
        for match in CALL.finditer(text):
            key = swift_unescape(match.group(1))
            used.setdefault(key, str(path.relative_to(ROOT)))

    missing = sorted(key for key in used if key not in table)
    empty = sorted(key for key, value in table.items() if not str(value).strip())
    mismatch = []
    for key in sorted(used):
        if key not in table:
            continue
        a = sorted(PLACEHOLDER.findall(key))
        b = sorted(PLACEHOLDER.findall(table[key]))
        if a != b:
            mismatch.append((key, table[key], a, b))

    if missing:
        print(f"missing translations ({len(missing)}):")
        for key in missing:
            print(f"  {used[key]}: {key!r}")
    if empty:
        print(f"empty translations ({len(empty)}): {empty}")
    for key, value, a, b in mismatch:
        print(f"placeholder mismatch: {key!r} -> {value!r} ({a} != {b})")

    print(f"{len(used)} source keys, {len(table)} table entries")
    if missing or empty or mismatch:
        return 1
    print("localisation table is complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
