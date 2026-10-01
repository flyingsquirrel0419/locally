#!/usr/bin/env python3
"""Localization coverage check for the Locally app.

Scans App/**/*.swift for:
  - String(localized: "key") / String(localized: "key", table: "T") keys
  - Text("literal") / Label("literal") / Button("literal") raw literals
    (interpolation-free string literals, which SwiftUI auto-localizes from
    the default Localizable table)

Reports:
  1. Keys used in code but missing from the referenced xcstrings table.
  2. Keys missing an "en" or "ko" translation.
  3. Raw Text/Label/Button literals containing letters (candidates for
     extraction into the catalog).

Exit 0 when clean, 1 otherwise. Runs on Linux (pure Python, no Xcode).
"""
import json
import re
import sys
from pathlib import Path

APP = Path("App")
RESOURCES = APP / "Resources"

STRING_LOCALIZED_RE = re.compile(
    r'String\(\s*localized:\s*"([^"]+)"(?:\s*,\s*table:\s*"([^"]+)")?',
    re.S)
# Text("...") / Label("...") / Button("...") with a plain (non-interpolated)
# literal first argument.
RAW_VIEW_RE = re.compile(r'\b(?:Text|Label|Button)\(\s*"((?:[^"\\]|\\.)*)"')
PUNCT_ONLY_RE = re.compile(r'^[\W\d_]+$')
INTERPOLATION_RE = re.compile(r'\\\(')


def load_tables():
    tables = {}
    for path in RESOURCES.glob("*.xcstrings"):
        data = json.loads(path.read_text())
        tables[path.stem] = data.get("strings", {})
    return tables


def scan_sources():
    localized_refs = []  # (key, table, file, line)
    raw_literals = []    # (literal, file, line)
    for path in sorted(APP.rglob("*.swift")):
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        # Strip line comments crudely (URLs in strings are rare in this
        # codebase) and scan the whole file so multi-line calls match.
        scrubbed = re.sub(r'(?m)//.*$', '', text)
        for m in STRING_LOCALIZED_RE.finditer(scrubbed):
            lineno = scrubbed.count('\n', 0, m.start()) + 1
            localized_refs.append((m.group(1), m.group(2), path, lineno))
        for lineno, line in enumerate(text.splitlines(), 1):
            code = line.split("//")[0] if "//" in line else line
            if False:
                for m in STRING_LOCALIZED_RE.finditer(code):
                    localized_refs.append((m.group(1), m.group(2), path, lineno))
                localized_refs.append((m.group(1), m.group(2), path, lineno))
            for m in RAW_VIEW_RE.finditer(code):
                literal = m.group(1)
                # Skip interpolations (dynamic), punctuation-only ("·", "–"),
                # and empty strings.
                if INTERPOLATION_RE.search(literal):
                    continue
                if not literal or PUNCT_ONLY_RE.match(literal):
                    continue
                raw_literals.append((literal, path, lineno))
    return localized_refs, raw_literals


def main():
    tables = load_tables()
    localized_refs, raw_literals = scan_sources()

    problems = 0

    for key, table, path, lineno in localized_refs:
        table_name = table or "Localizable"
        strings = tables.get(table_name)
        if strings is None:
            print(f"MISSING TABLE: {table_name}.xcstrings (used at {path}:{lineno})")
            problems += 1
            continue
        entry = strings.get(key)
        if entry is None:
            print(f"MISSING KEY: {table_name}/{key} ({path}:{lineno})")
            problems += 1
            continue
        localizations = entry.get("localizations", {})
        for lang in ("en", "ko"):
            unit = localizations.get(lang, {}).get("stringUnit", {})
            if not unit.get("value"):
                print(f"MISSING {lang}: {table_name}/{key} ({path}:{lineno})")
                problems += 1

    # Raw Text/Label/Button literals are auto-localized from the default
    # table; they must exist there too (SwiftUI treats the literal as key).
    default_strings = tables.get("Localizable", {})
    for literal, path, lineno in raw_literals:
        if literal not in default_strings:
            print(f"RAW LITERAL NOT IN CATALOG: {literal!r} ({path}:{lineno})")
            problems += 1

    # Validate every catalog is parseable JSON with en+ko on every key.
    for name, strings in tables.items():
        for key, entry in strings.items():
            localizations = entry.get("localizations", {})
            for lang in ("en", "ko"):
                if not localizations.get(lang, {}).get("stringUnit", {}).get("value"):
                    print(f"CATALOG GAP: {name}/{key} missing {lang}")
                    problems += 1

    if problems:
        print(f"\n{problems} localization problem(s) found.")
        return 1
    print("Localization check clean: all keys present in en+ko.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
