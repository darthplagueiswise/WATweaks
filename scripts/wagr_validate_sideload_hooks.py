#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import sys

SOURCE_ROOT = pathlib.Path("src")
SOURCE_SUFFIXES = {".m", ".mm", ".x", ".xm", ".c", ".cc", ".cpp"}
SELF_SYMBOL = re.compile(r"\bWAGR[A-Za-z0-9_]*\b")
CALL_TOKEN = "MSHookFunction"


def _strip_comments(text: str) -> str:
    # Preserve newlines so diagnostics keep useful source line numbers.
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def _first_argument(text: str, token_offset: int) -> tuple[str, int] | None:
    open_paren = text.find("(", token_offset + len(CALL_TOKEN))
    if open_paren < 0:
        return None

    depth = 0
    in_string = False
    quote = ""
    escaped = False
    for index in range(open_paren + 1, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                in_string = False
            continue
        if char in ('"', "'"):
            in_string = True
            quote = char
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            if depth == 0:
                return text[open_paren + 1:index], open_paren
            depth -= 1
        elif char == "," and depth == 0:
            return text[open_paren + 1:index], open_paren
    return None


def main() -> int:
    violations: list[tuple[pathlib.Path, int, str]] = []
    if not SOURCE_ROOT.exists():
        print("ERROR: src/ not found", file=sys.stderr)
        return 2

    for path in sorted(SOURCE_ROOT.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in SOURCE_SUFFIXES:
            continue
        try:
            raw = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            raw = path.read_text(encoding="utf-8", errors="ignore")
        text = _strip_comments(raw)
        offset = 0
        while True:
            hit = text.find(CALL_TOKEN, offset)
            if hit < 0:
                break
            parsed = _first_argument(text, hit)
            if parsed is not None:
                first_arg, open_paren = parsed
                match = SELF_SYMBOL.search(first_arg)
                if match:
                    line = text.count("\n", 0, open_paren) + 1
                    compact = " ".join(first_arg.split())
                    violations.append((path, line, compact))
            offset = hit + len(CALL_TOKEN)

    if violations:
        print("ERROR: sideload-unsafe self inline hook(s) detected:", file=sys.stderr)
        for path, line, argument in violations:
            print(f"  {path}:{line}: MSHookFunction first argument -> {argument}", file=sys.stderr)
        print(
            "Use direct composition for WATweaks-owned code. For Objective-C methods, "
            "prefer runtime IMP replacement; reserve fishhook for imported symbols.",
            file=sys.stderr,
        )
        return 1

    print("Sideload hook validation: no MSHookFunction target resolves to a WAGR* self symbol")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
