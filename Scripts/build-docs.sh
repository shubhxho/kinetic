#!/usr/bin/env bash
#
# build-docs.sh — produce docs/book with the same mdBook binary CI uses.
#
# GitHub Pages, Vercel, and a local check all go through here so the three
# hosts cannot drift in version or flags.
#
# Usage: Scripts/build-docs.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MDBOOK_VERSION="0.5.4"
BIN_DIR="${MDBOOK_BIN_DIR:-$ROOT/.docs-tools}"
mkdir -p "$BIN_DIR"

need_download=1
if command -v mdbook >/dev/null 2>&1; then
  have="$(mdbook --version 2>/dev/null || true)"
  if [[ "$have" == "mdbook v${MDBOOK_VERSION}" ]]; then
    need_download=0
  fi
fi

if [[ "$need_download" -eq 1 ]]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)  asset="mdbook-v${MDBOOK_VERSION}-x86_64-unknown-linux-gnu.tar.gz" ;;
    Linux-aarch64) asset="mdbook-v${MDBOOK_VERSION}-aarch64-unknown-linux-gnu.tar.gz" ;;
    Darwin-arm64)  asset="mdbook-v${MDBOOK_VERSION}-aarch64-apple-darwin.tar.gz" ;;
    Darwin-x86_64) asset="mdbook-v${MDBOOK_VERSION}-x86_64-apple-darwin.tar.gz" ;;
    *)
      echo "error: no mdBook ${MDBOOK_VERSION} build for $(uname -s) $(uname -m)." >&2
      echo "       install it yourself and put it on PATH, or run: brew install mdbook" >&2
      exit 1
      ;;
  esac
  if [[ ! -x "$BIN_DIR/mdbook" ]] || ! "$BIN_DIR/mdbook" --version 2>/dev/null | grep -q "v${MDBOOK_VERSION}"; then
    echo "▸ downloading mdBook ${MDBOOK_VERSION} ($asset)"
    curl -sSL "https://github.com/rust-lang/mdBook/releases/download/v${MDBOOK_VERSION}/${asset}" \
      | tar -xz -C "$BIN_DIR"
  fi
  export PATH="$BIN_DIR:$PATH"
fi

echo "▸ $(mdbook --version)"
python3 "$ROOT/docs/check-images.py" "$ROOT"
mdbook build "$ROOT/docs"
python3 "$ROOT/docs/check-links.py" "$ROOT/docs/book"
echo "▸ docs/book"
