#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="GLM 用量监控"
BUNDLE_ID="com.jingcc.glm-pulse"
EXECUTABLE_NAME="glm-token-monitor-app"
APP_DIR="$ROOT_DIR/output/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

# Copy SwiftPM-generated resource bundle (Localizable.strings etc.)
SPM_BUNDLE="$BIN_DIR/${EXECUTABLE_NAME}_${EXECUTABLE_NAME}.bundle"
if [[ -d "$SPM_BUNDLE" ]]; then
  cp -R "$SPM_BUNDLE" "$RESOURCES_DIR/"
fi

# Copy top-level .lproj directories with InfoPlist.strings so macOS can
# localize the app's display name in the menu bar / Finder.
for lproj in "$ROOT_DIR/Resources"/*.lproj; do
  [[ -d "$lproj" ]] || continue
  base="$(basename "$lproj")"
  mkdir -p "$RESOURCES_DIR/$base"
  cp -R "$lproj/"* "$RESOURCES_DIR/$base/" 2>/dev/null || true
done

# Mirror Localizable.strings into Contents/Resources/<lang>.lproj so
# SwiftUI Text / String(localized:) lookups in Bundle.main succeed.
for src_lproj in "$ROOT_DIR/Sources/$EXECUTABLE_NAME"/*.lproj; do
  [[ -d "$src_lproj" ]] || continue
  base="$(basename "$src_lproj")"
  mkdir -p "$RESOURCES_DIR/$base"
  if [[ -f "$src_lproj/Localizable.strings" ]]; then
    cp "$src_lproj/Localizable.strings" "$RESOURCES_DIR/$base/Localizable.strings"
  fi
done

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RESOURCES_DIR/AppIcon.icns"
  ICON_FILE_LINE="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
else
  ICON_FILE_LINE=""
fi

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    ${ICON_FILE_LINE}
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.2</string>
    <key>CFBundleVersion</key>
    <string>202</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built app bundle:"
echo "$APP_DIR"
