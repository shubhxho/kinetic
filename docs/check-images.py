#!/usr/bin/env python3
"""Fail when a committed figure is missing, broken, or referenced but absent.

mdBook's HTML link checker already resolves <img src> inside docs/book.
This pass covers the source tree: README figures, markdown image links, and
the PNG/SVG files themselves (magic bytes / svg root). It does not open a
browser and it does not re-render Metal captures.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
MARKDOWN_IMAGE = re.compile(r"!\[[^\]]*\]\(([^)]+)\)")
HTML_SRC = re.compile(r"""(?:src|href)=["']([^"'#][^"']*)["']""")
TICK_PATH = re.compile(r"`(docs/src/images/[^`]+)`")
EXTERNAL = ("http://", "https://", "mailto:", "data:", "//")


def is_image_ref(path: str) -> bool:
    lower = path.lower().split("?", 1)[0]
    return lower.endswith((".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp"))


def iter_source_files(root: Path):
    yield root / "README.md"
    docs = root / "docs" / "src"
    for dirpath, _, files in os.walk(docs):
        for name in files:
            if name.endswith((".md", ".html")):
                yield Path(dirpath) / name


def referenced_images(root: Path) -> list[tuple[Path, str, Path]]:
    found = []
    for page in iter_source_files(root):
        text = page.read_text(encoding="utf-8", errors="ignore")
        candidates = []
        candidates.extend(MARKDOWN_IMAGE.findall(text))
        candidates.extend(HTML_SRC.findall(text))
        candidates.extend(TICK_PATH.findall(text))
        for raw in candidates:
            target = raw.strip()
            if not target or target.startswith(EXTERNAL):
                continue
            if "*" in target or "?" in target:
                continue
            if not is_image_ref(target):
                continue
            if target.startswith("docs/"):
                resolved = (root / target).resolve()
            else:
                resolved = (page.parent / target).resolve()
            found.append((page, raw, resolved))
    return found


def validate_image_file(path: Path) -> str | None:
    if not path.is_file():
        return "missing"
    data = path.read_bytes()
    if not data:
        return "empty"
    suffix = path.suffix.lower()
    if suffix == ".png":
        if not data.startswith(PNG_MAGIC):
            return "not a PNG (bad magic)"
    elif suffix == ".svg":
        text = data.decode("utf-8", errors="ignore")
        if "<svg" not in text.lower():
            return "not an SVG (no <svg>)"
    return None


def main(root: str) -> int:
    base = Path(root).resolve()
    broken = []
    checked = 0

    for page, raw, resolved in referenced_images(base):
        checked += 1
        problem = validate_image_file(resolved)
        if problem:
            broken.append(f"{page.relative_to(base)} -> {raw} ({problem})")

    images_dir = base / "docs" / "src" / "images"
    for path in sorted(images_dir.iterdir()) if images_dir.is_dir() else []:
        if path.suffix.lower() not in {".png", ".svg", ".jpg", ".jpeg", ".gif", ".webp"}:
            continue
        checked += 1
        problem = validate_image_file(path)
        if problem:
            broken.append(f"{path.relative_to(base)} ({problem})")

    for line in sorted(set(broken)):
        print(f"broken: {line}")
    print(f"checked {checked} image references and files under {base}")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
