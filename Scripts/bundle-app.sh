#!/usr/bin/env bash
#
# bundle-app.sh — wrap the SwiftPM executable into a proper .app.
#
# SwiftPM emits a bare Mach-O plus sibling resource bundles. macOS needs an
# Info.plist and the usual directory layout before the binary can own a Dock
# icon, a menu bar and keyboard focus, so this assembles one.
#
# Usage: Scripts/bundle-app.sh [debug|release]

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/dist/Kinetic Studio.app"
VERSION="1.0.0"

echo "▸ building ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT" >/dev/null

if [[ ! -x "$BUILD_DIR/KineticStudio" ]]; then
  echo "error: $BUILD_DIR/KineticStudio not found" >&2
  exit 1
fi

echo "▸ assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/KineticStudio" "$APP/Contents/MacOS/Kinetic Studio"

# Resource bundles must sit beside the executable for Bundle.module to find
# them, and in Resources for the app bundle lookup path.
for bundle in "$BUILD_DIR"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  cp -R "$bundle" "$APP/Contents/MacOS/"
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# MLX ships its GPU kernels as Metal sources compiled by Xcode's build rule.
# `swift build` has no Metal compilation step, so a command-line build produces
# no metallib and MLX falls back to reporting the accelerator unavailable — the
# analytic controller, the phrase parser and the statistical detector all still
# work, only the neural paths are disabled. If an Xcode build of mlx-swift is
# present anywhere in DerivedData, stage its bundle so the app gets the GPU.
MLX_BUNDLE="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -name "mlx-swift_Cmlx.bundle" -maxdepth 6 2>/dev/null | head -1)"
if [[ -n "$MLX_BUNDLE" ]]; then
  cp -R "$MLX_BUNDLE" "$APP/Contents/MacOS/"
  cp -R "$MLX_BUNDLE" "$APP/Contents/Resources/"
  echo "  staged MLX Metal kernels from $(basename "$(dirname "$MLX_BUNDLE")")"
else
  echo "  note: no MLX metallib found — neural features will report the GPU unavailable"
  echo "        (build mlx-swift once in Xcode, or open this package in Xcode, to enable them)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Kinetic Studio</string>
  <key>CFBundleDisplayName</key><string>Kinetic Studio</string>
  <key>CFBundleIdentifier</key><string>com.kinetic.studio</string>
  <key>CFBundleExecutable</key><string>Kinetic Studio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>URDF Model</string>
      <key>CFBundleTypeExtensions</key><array><string>urdf</string></array>
      <key>CFBundleTypeRole</key><string>Viewer</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Kinetic Recording</string>
      <key>CFBundleTypeExtensions</key><array><string>kinlog</string></array>
      <key>CFBundleTypeRole</key><string>Viewer</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper lets a locally built app run.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  echo "  (codesign unavailable — the app will still run locally)"

echo "▸ done: $APP"
