#!/usr/bin/env python3
"""Regenerate the docs package manifests.

Author: Tim Isaev

Writes docs/DOCUMENT_MANIFEST.md and docs/PACKAGE_MANIFEST.json from the
current contents of docs/. Both manifests describe every file in the package
except themselves, and counts are plain `wc -c` / `wc -l` / `wc -w`
equivalents so the numbers can be checked by hand.

The package version and date come from the newest heading in docs/CHANGELOG.md
("## <version> — <date>"), so bumping the changelog is the only manual step.

Usage: tools/gen-doc-manifests.py [--check]
  --check  exit 1 if the manifests on disk differ from what would be written
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

DOCS = Path(__file__).resolve().parent.parent / "docs"
SELF_EXCLUDED = {"DOCUMENT_MANIFEST.md", "PACKAGE_MANIFEST.json"}


def package_version_and_date() -> tuple[str, str]:
    """Read the newest '## <version> — <date>' heading from the changelog."""
    for line in (DOCS / "CHANGELOG.md").read_text(encoding="utf-8").splitlines():
        m = re.match(r"^##\s+(\S+)\s+—\s+(.+?)\s*$", line)
        if m:
            return m.group(1), m.group(2)
    raise SystemExit("no '## <version> — <date>' heading found in docs/CHANGELOG.md")


def iso_date(human: str) -> str:
    """'24 July 2026' -> '2026-07-24'; pass through anything already ISO."""
    if re.match(r"^\d{4}-\d{2}-\d{2}$", human):
        return human
    months = {
        m: f"{i:02d}"
        for i, m in enumerate(
            "January February March April May June July August September "
            "October November December".split(),
            start=1,
        )
    }
    m = re.match(r"^(\d{1,2})\s+(\w+)\s+(\d{4})$", human)
    if not m or m.group(2) not in months:
        raise SystemExit(f"cannot parse changelog date: {human!r}")
    return f"{m.group(3)}-{months[m.group(2)]}-{int(m.group(1)):02d}"


def collect() -> list[dict]:
    entries = []
    for path in sorted(DOCS.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(DOCS).as_posix()
        if rel in SELF_EXCLUDED or path.name == ".DS_Store":
            continue
        data = path.read_bytes()
        entry = {
            "path": rel,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
        # Only Markdown carries prose counts; assets, schemas and examples are
        # recorded by size and hash alone (matches the manifests since 1.0).
        if path.suffix == ".md":
            text = data.decode("utf-8")
            entry["lines"] = text.count("\n")
            entry["words"] = len(text.split())
        entries.append(entry)
    return entries


def render(entries: list[dict], version: str, date_human: str) -> tuple[str, str]:
    md_entries = [e for e in entries if "lines" in e]
    md_words = sum(e["words"] for e in md_entries)
    md_lines = sum(e["lines"] for e in md_entries)

    rows = "\n".join(
        "| {} | {} | {} | {} | {}… |".format(
            e["path"], e["bytes"], e.get("lines", "—"), e.get("words", "—"), e["sha256"][:16]
        )
        for e in entries
    )
    doc_md = (
        f"# Alloy Documentation Package Manifest\n\n"
        f"**Package version:** {version}\n"
        f"**Generated:** {date_human}\n"
        f"**Files:** {len(entries)} plus this manifest and the JSON manifest\n"
        f"**Markdown volume:** {md_words:,} words across {md_lines:,} lines\n\n"
        f"The full SHA-256 values are in [`PACKAGE_MANIFEST.json`](PACKAGE_MANIFEST.json).\n\n"
        f"| Path | Bytes | Lines | Words | SHA-256 prefix |\n"
        f"| --- | --- | --- | --- | --- |\n"
        f"{rows}\n\n"
        f"Regenerate with `tools/gen-doc-manifests.py`.\n"
    )

    pkg = {
        "package": "Alloy Product Documentation",
        "version": version,
        "generatedAt": iso_date(date_human),
        "fileCount": len(entries),
        "markdownWords": md_words,
        "markdownLines": md_lines,
        "files": entries,
    }
    return doc_md, json.dumps(pkg, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    check = "--check" in sys.argv[1:]
    version, date_human = package_version_and_date()
    doc_md, pkg_json = render(collect(), version, date_human)

    targets = {
        DOCS / "DOCUMENT_MANIFEST.md": doc_md,
        DOCS / "PACKAGE_MANIFEST.json": pkg_json,
    }
    stale = [p for p, want in targets.items() if not p.exists() or p.read_text(encoding="utf-8") != want]

    if check:
        for p in stale:
            print(f"stale: {p.relative_to(DOCS.parent)}", file=sys.stderr)
        return 1 if stale else 0

    for p, want in targets.items():
        p.write_text(want, encoding="utf-8")
    print(f"manifests regenerated at version {version} ({len(collect())} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
