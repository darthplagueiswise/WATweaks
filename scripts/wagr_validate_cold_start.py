#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import sys

SOURCE_ROOT = pathlib.Path("src")
SOURCE_SUFFIXES = {".m", ".mm", ".x", ".xm", ".c", ".cc", ".cpp"}

# These operations are valid on-demand, but must not be reachable directly from
# an Objective-C/C constructor or Logos %ctor. The dogfood2 461->476 regression
# showed why runtime-catalog work and persisted per-selector reinstalls do not
# belong on WhatsApp's launch critical path.
FORBIDDEN = (
    "objc_getClassList",
    "objc_copyClassList",
    "objc_enumerateClasses",
    "class_copyIvarList",
    "class_copyMethodList",
    "class_copyPropertyList",
    "WAGRRuntimeValueReinstallPersistedHooks",
)

CONSTRUCTOR_RE = re.compile(
    r"__attribute__\s*\(\s*\(\s*constructor(?:\s*\([^)]*\))?\s*\)\s*\)"
    r"[^\{;]*\{",
    re.M,
)
LOGOS_CTOR_RE = re.compile(r"%ctor\s*(?:\([^)]*\))?\s*\{", re.M)


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def balanced_block(text: str, brace_offset: int) -> str:
    depth = 0
    in_string = False
    quote = ""
    escaped = False
    for i in range(brace_offset, len(text)):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                in_string = False
            continue
        if ch in ('"', "'"):
            in_string = True
            quote = ch
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[brace_offset : i + 1]
    return text[brace_offset:]


def constructor_blocks(text: str):
    for regex, kind in ((CONSTRUCTOR_RE, "constructor"), (LOGOS_CTOR_RE, "%ctor")):
        for match in regex.finditer(text):
            brace = text.find("{", match.start(), match.end())
            if brace >= 0:
                yield kind, match.start(), balanced_block(text, brace)


def main() -> int:
    violations: list[tuple[pathlib.Path, int, str, str]] = []
    if not SOURCE_ROOT.exists():
        print("ERROR: src/ not found", file=sys.stderr)
        return 2

    for path in sorted(SOURCE_ROOT.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in SOURCE_SUFFIXES:
            continue
        raw = path.read_text(encoding="utf-8", errors="ignore")
        text = strip_comments(raw)
        for kind, offset, block in constructor_blocks(text):
            for token in FORBIDDEN:
                if token in block:
                    line = text.count("\n", 0, offset) + 1
                    violations.append((path, line, kind, token))

    if violations:
        print("ERROR: cold-start-unsafe runtime work detected:", file=sys.stderr)
        for path, line, kind, token in violations:
            print(f"  {path}:{line}: {kind} directly references {token}", file=sys.stderr)
        print(
            "Move runtime enumeration/reinstall work behind an explicit UI/apply action. "
            "Constructors may register narrow hooks/callbacks, but must not build catalogs "
            "or reinstall arbitrary persisted selector hooks.",
            file=sys.stderr,
        )
        return 1

    print("Cold-start validation: no heavy runtime enumeration/reinstall in constructors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
