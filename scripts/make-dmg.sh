#!/bin/zsh
set -euo pipefail

# Wrap output/GLM 用量监控.app into a polished .dmg ready for GitHub Releases.
# Run scripts/build-app.sh first (or pass --build to do it automatically).

ROOT_DIR="$(cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="GLM 用量监控"
APP_PATH="$ROOT_DIR/output/$APP_NAME.app"

if [[ "${1:-}" == "--build" ]]; then
  "$ROOT_DIR/scripts/build-app.sh"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "✘ $APP_PATH not found. Run scripts/build-app.sh first (or pass --build)." >&2
  exit 1
fi

# Pull version out of Info.plist so the dmg filename matches the bundle.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.0.0")

DMG_DIR="$ROOT_DIR/output"
DMG_NAME="GLM 用量监控-${VERSION}.dmg"
DMG_PATH="$DMG_DIR/$DMG_NAME"
STAGING="$DMG_DIR/.dmg-staging"

# Re-stage so the dmg has exactly: the app + a /Applications symlink for drag-install.
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Make sure the app inside the staging dir is also ad-hoc signed
# (codesign on the original is preserved by cp -R, but re-sign defensively).
codesign --force --deep --sign - "$STAGING/$APP_NAME.app" >/dev/null 2>&1 || true

echo "Building $DMG_NAME …"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

# Ad-hoc sign the dmg itself so Gatekeeper has something to chew on.
codesign --force --sign - "$DMG_PATH" >/dev/null 2>&1 || true

rm -rf "$STAGING"

SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo "✓ $DMG_PATH  ($SIZE)"
