#!/bin/zsh
# Release build -> build/Prune.app (ad-hoc signed). Also copies the `majortom` CLI next to it.
# OUT_DIR=<folder> builds there instead of build/ (e.g. while a copy in build/ is running).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="${OUT_DIR:-$ROOT/build}"
mkdir -p "$OUT"
APP="$OUT/Prune.app"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
# Notifications, privacy grants and the login item are keyed to the bundle id; override it if you like.
BUNDLE_ID="${BUNDLE_ID:-studio.prune.app}"

swift build -c release --product MajorTomApp
swift build -c release --product majortom
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MajorTomApp" "$APP/Contents/MacOS/Prune"
cp "$BIN_DIR/majortom" "$OUT/majortom"

# App icon: drawn by scripts/make-icon.swift (CoreGraphics) -> iconset -> .icns. design/AppIcon.icns is the
# committed output; the 512 px previews of all candidates live in design/icon-candidates/.
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" --iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/design/AppIcon.icns"
rm -rf "$ICONSET"
cp "$ROOT/design/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Prune</string>
  <key>CFBundleDisplayName</key><string>Prune</string>
  <key>CFBundleExecutable</key><string>Prune</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $APP"
