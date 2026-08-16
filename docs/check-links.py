#!/usr/bin/env python3
"""Fail the docs build when a page links to a page that does not exist.

Hrefs in an mdBook are relative to the page that contains them, not to the book
root — resolving them any other way reports every cross-directory link as
broken.
"""

import os
import re
import sys
from urllib.parse import unquote, urldefrag

HREF = re.compile(r'(?:href|src)="([^"#][^"]*)"')
EXTERNAL = ("http://", "https://", "mailto:", "data:", "//")


def main(root: str) -> int:
    broken = []
    checked = 0

    for directory, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".html"):
                continue
            page = os.path.join(directory, name)
            with open(page, encoding="utf-8", errors="ignore") as handle:
                html = handle.read()

            for raw in HREF.findall(html):
                if raw.startswith(EXTERNAL):
                    continue
                target = unquote(urldefrag(raw).url)
                if not target:
                    continue
                resolved = os.path.normpath(os.path.join(directory, target))
                checked += 1
                if not os.path.exists(resolved):
                    broken.append((os.path.relpath(page, root), raw))

    for page, link in sorted(set(broken)):
        print(f"broken: {page} -> {link}")

    print(f"checked {checked} internal links across {root}")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "docs/book"))
