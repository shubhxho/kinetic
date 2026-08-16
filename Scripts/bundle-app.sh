#!/usr/bin/env bash
#
# bundle-app.sh — wrap the SwiftPM products into a distributable .app (and DMG).
#
# SwiftPM emits bare Mach-O binaries plus sibling resource bundles. macOS needs an
# Info.plist, an icon and the usual directory layout before a binary can own a
# Dock icon, a menu bar and keyboard focus, so this assembles one.
#
# Usage: Scripts/bundle-app.sh [debug|release] [--dmg] [--skip-build]

set -euo pipefail

CONFIG="release"
MAKE_DMG=0
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --dmg) MAKE_DMG=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
DIST="$ROOT/dist"
APP="$DIST/Kinetic Studio.app"

# Version comes from the most recent tag so a build is traceable to a commit,
# with the short SHA appended when the working tree has moved past it.
VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || echo v1.0.0)"
VERSION="${VERSION#v}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "▸ building ($CONFIG)"
  swift build -c "$CONFIG" --package-path "$ROOT" >/dev/null
fi

for binary in KineticStudio kinetic; do
  if [[ ! -x "$BUILD_DIR/$binary" ]]; then
    echo "error: $BUILD_DIR/$binary not found — run without --skip-build" >&2
    exit 1
  fi
done

echo "▸ assembling bundle  $VERSION ($BUILD_NUMBER, $COMMIT)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/KineticStudio" "$APP/Contents/MacOS/Kinetic Studio"
# Ship the CLI inside the app so one download gives both, and so the app can
# offer to symlink it onto the PATH rather than asking for a second build.
cp "$BUILD_DIR/kinetic" "$APP/Contents/MacOS/kinetic"

# Resource bundles go in Contents/Resources only. Putting a copy beside the
# executable also works for Bundle.module, but codesign walks Contents/MacOS
# looking for nested *code* bundles, rejects a SwiftPM resource directory as
# "bundle format unrecognized", and then refuses to sign the app at all.
# Bundle.module finds them through Bundle.main.resourceURL from Resources.
for bundle in "$BUILD_DIR"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# MLX ships its GPU kernels as Metal sources compiled by Xcode's build rule.
# `swift build` has no Metal compilation step, so a command-line build produces
# no metallib and MLX reports the accelerator unavailable — the analytic
# controller, the phrase parser and the statistical detector all still work, only
# the neural paths are disabled. Stage a metallib from DerivedData if one exists.
# `|| true` matters: with `set -o pipefail`, find exiting non-zero because
# DerivedData does not exist — which is the normal case on a CI runner — would
# take the whole script down.
MLX_BUNDLE="$( { find "$HOME/Library/Developer/Xcode/DerivedData" \
  -name "mlx-swift_Cmlx.bundle" -maxdepth 6 2>/dev/null || true; } | head -1)"
if [[ -n "$MLX_BUNDLE" ]]; then
  cp -R "$MLX_BUNDLE" "$APP/Contents/Resources/"
  echo "  staged MLX Metal kernels"
else
  echo "  note: no MLX metallib found — neural features will report the GPU unavailable"
  echo "        (open this package once in Xcode to build them)"
fi

echo "▸ rendering the icon"
python3 "$ROOT/Scripts/make-icon.py" "$APP/Contents/Resources/Kinetic.icns" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Kinetic Studio</string>
  <key>CFBundleDisplayName</key><string>Kinetic Studio</string>
  <key>CFBundleIdentifier</key><string>com.kinetic.studio</string>
  <key>CFBundleExecutable</key><string>Kinetic Studio</string>
  <key>CFBundleIconFile</key><string>Kinetic</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>MIT licensed. Built from $COMMIT.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMainNibFile</key><string></string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Kinetic</string>
      <key>CFBundleURLSchemes</key><array><string>kinetic</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>URDF Robot Description</string>
      <key>CFBundleTypeExtensions</key><array><string>urdf</string></array>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>MuJoCo Model</string>
      <key>CFBundleTypeExtensions</key><array><string>xml</string><string>mjcf</string></array>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Universal Scene Description</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>usd</string><string>usda</string><string>usdc</string><string>usdz</string></array>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Kinetic Recording</string>
      <key>CFBundleTypeExtensions</key><array><string>kinlog</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

# An ad-hoc signature is what lets a locally built app run at all; it is not a
# substitute for a Developer ID signature and notarisation for distribution.
#
# Not `--deep`: SwiftPM's resource bundles are plain directories with no
# Info.plist, so codesign rejects them as "bundle format unrecognized" and the
# whole app ends up unsigned. Signing the Mach-O binaries explicitly and then the
# app is both correct and what Apple recommends over --deep.
# The nested CLI is signed first, then the app seals it along with everything
# else. The hardened runtime is deliberately not requested for an ad-hoc
# signature: it buys nothing without notarisation and can block launch.
SIGNED=1
codesign --force --sign - "$APP/Contents/MacOS/kinetic" >/dev/null 2>&1 || SIGNED=0
codesign --force --sign - "$APP" >/dev/null 2>&1 || SIGNED=0
if [[ "$SIGNED" -eq 1 ]] && codesign --verify --strict "$APP" >/dev/null 2>&1; then
  echo "  ad-hoc signed and verified"
else
  echo "  note: could not sign — the app will still run locally"
fi

echo "▸ done: $APP"

if [[ "$MAKE_DMG" -eq 1 ]]; then
  echo "▸ building disk image"
  DMG="$DIST/Kinetic-Studio-$VERSION.dmg"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp "$ROOT/README.md" "$STAGE/README.md"
  rm -f "$DMG"
  hdiutil create -volname "Kinetic Studio $VERSION" -srcfolder "$STAGE" \
    -ov -format ULFO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "▸ done: $DMG"
fi
