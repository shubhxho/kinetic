#!/usr/bin/env python3
"""Fail when a committed figure is missing, broken, cropped, or unreferenced.

mdBook's HTML link checker already resolves <img src> inside docs/book.
This pass covers the source tree: README figures, markdown image links, PNG
magic / pixel size, and SVG XML. It does not open a browser and it does not
re-render Metal captures.
"""

from __future__ import annotations

import os
import re
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
MARKDOWN_IMAGE = re.compile(r"!\[[^\]]*\]\(([^)]+)\)")
HTML_SRC = re.compile(r"""(?:src|href)=["']([^"'#][^"']*)["']""")
TICK_PATH = re.compile(r"`((?:docs/src/images/|images/)[^`]+)`")
CODE_PATH = re.compile(r"<code>((?:docs/src/images/|images/)[^<]+)</code>")
EXTERNAL = ("http://", "https://", "mailto:", "data:", "//")

# Headless kinetic render default. Documented in cli.md and introduction.md.
SCENE_SIZE = (1600, 1000)
SCENE_FILES = {
    "arm.png",
    "chain.png",
    "dominoes.png",
    "go2.png",
    "mixed.png",
    "quadruped.png",
    "stack.png",
    "stack-light.png",
}
# Diagram PNGs are 3x rasters of the sibling SVG viewBox.
DIAGRAM_SCALE = 3


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
        candidates.extend(CODE_PATH.findall(text))
        for raw in candidates:
            target = raw.strip().rstrip("/.")
            if not target or target.startswith(EXTERNAL):
                continue
            if "*" in target or "?" in target:
                continue
            if not is_image_ref(target):
                continue
            if target.startswith("docs/"):
                resolved = (root / target).resolve()
            elif target.startswith("images/"):
                resolved = (root / "docs" / "src" / target).resolve()
            else:
                resolved = (page.parent / target).resolve()
            found.append((page, raw, resolved))
    return found


def png_size(data: bytes) -> tuple[int, int] | None:
    if len(data) < 24 or not data.startswith(PNG_MAGIC):
        return None
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def svg_viewbox(path: Path) -> tuple[float, float] | None:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return None
    vb = root.get("viewBox")
    if not vb:
        return None
    parts = vb.replace(",", " ").split()
    if len(parts) != 4:
        return None
    try:
        return float(parts[2]), float(parts[3])
    except ValueError:
        return None


def validate_image_file(path: Path) -> str | None:
    if not path.is_file():
        return "missing"
    data = path.read_bytes()
    if not data:
        return "empty"
    suffix = path.suffix.lower()
    if suffix == ".png":
        size = png_size(data)
        if size is None:
            return "not a PNG (bad magic)"
        if path.name in SCENE_FILES and size != SCENE_SIZE:
            return f"{size[0]}x{size[1]}, expected {SCENE_SIZE[0]}x{SCENE_SIZE[1]}"
        sibling = path.with_suffix(".svg")
        if sibling.is_file():
            vb = svg_viewbox(sibling)
            if vb is None:
                return "sibling SVG has no viewBox"
            expected = (int(vb[0] * DIAGRAM_SCALE), int(vb[1] * DIAGRAM_SCALE))
            if size != expected:
                return (
                    f"{size[0]}x{size[1]}, expected {expected[0]}x{expected[1]} "
                    f"({DIAGRAM_SCALE}x SVG viewBox)"
                )
    elif suffix == ".svg":
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            return "SVG is not UTF-8"
        try:
            ET.fromstring(data)
        except ET.ParseError as exc:
            return f"SVG XML parse error: {exc}"
        if "<svg" not in text.lower():
            return "not an SVG (no <svg>)"
        if svg_viewbox(path) is None:
            return "SVG missing viewBox"
    return None


def main(root: str) -> int:
    base = Path(root).resolve()
    broken = []
    checked = 0
    referenced: set[Path] = set()

    for page, raw, resolved in referenced_images(base):
        checked += 1
        referenced.add(resolved)
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
        if path.resolve() not in referenced:
            broken.append(f"{path.relative_to(base)} (unreferenced)")

    for line in sorted(set(broken)):
        print(f"broken: {line}")
    print(f"checked {checked} image references and files under {base}")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
