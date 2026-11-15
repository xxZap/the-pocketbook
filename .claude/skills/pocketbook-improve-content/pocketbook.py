#!/usr/bin/env python3
"""Helper for the pocketbook-improve-content skill.

  extract <file.pocketbook> <out.json>
      Writes the pages' text, one entry per page, for rewriting:
      [{"index", "kind", "title", "text"}]. Drawings and images stay out.

  apply <file.pocketbook> <rewritten.json> <out.pocketbook>
      Puts the "text" of each entry back into the page with the same index and
      writes a new file. Everything else (titles, tags, drawings, images, dates,
      kind) is copied untouched. Refuses to overwrite the original file and
      checks that every @link to a page of the file survived the rewrite.
"""
import json
import os
import re
import sys

SUPPORTED_VERSION = 2


def load(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get("pages"), list):
        sys.exit(f"{path}: not a .pocketbook file (no 'pages' list)")
    if data.get("version", 1) > SUPPORTED_VERSION:
        sys.exit(f"{path}: version {data['version']} is newer than {SUPPORTED_VERSION}; update this script")
    return data


def links(text, titles):
    """@Title references to the given titles, case- and accent-insensitive enough for a check."""
    found = set()
    lowered = text.casefold()
    for title in titles:
        if title and ("@" + title.casefold()) in lowered:
            found.add(title)
    return found


def extract(src, out):
    data = load(src)
    entries = [
        {"index": i, "kind": p.get("kind") or "page", "title": p.get("title", ""), "text": p.get("text", "")}
        for i, p in enumerate(data["pages"])
    ]
    with open(out, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, indent=2)
    with_text = sum(1 for e in entries if e["text"].strip())
    print(f"{len(entries)} pages ({with_text} with text) -> {out}")


def apply(src, rewritten, out):
    if os.path.abspath(src) == os.path.abspath(out):
        sys.exit("refusing to overwrite the original file")
    data = load(src)
    pages = data["pages"]
    with open(rewritten, encoding="utf-8") as f:
        entries = json.load(f)
    titles = [p.get("title", "") for p in pages]
    problems = []
    for e in entries:
        i = e["index"]
        if not 0 <= i < len(pages):
            problems.append(f"index {i}: no such page")
            continue
        if e.get("title", titles[i]) != titles[i]:
            problems.append(f"page {i}: title changed ({titles[i]!r} -> {e['title']!r}); titles must stay identical")
        lost = links(pages[i].get("text", ""), titles) - links(e["text"], titles)
        if lost:
            problems.append(f"page {i} ({titles[i]!r}): lost links " + ", ".join("@" + t for t in sorted(lost)))
    if problems:
        sys.exit("not written:\n  " + "\n  ".join(problems))
    changed = 0
    for e in entries:
        if pages[e["index"]].get("text", "") != e["text"]:
            pages[e["index"]]["text"] = e["text"]
            changed += 1
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    print(f"{changed} of {len(pages)} pages rewritten -> {out}")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "extract":
        extract(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 5 and sys.argv[1] == "apply":
        apply(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)
