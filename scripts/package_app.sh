#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
APP="$ROOT/build/WonderBox.app"
if [[ "${PREVIEW:-0}" == "1" ]]; then
  APP="$ROOT/build/WonderBox-AI-Preview.app"
fi
CONTENTS="$APP/Contents"

cd "$ROOT"
# UNIVERSAL=1 builds one binary for Apple Silicon and Intel (release downloads); default is the host arch.
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64
  BIN_DIR="$ROOT/.build/apple/Products/${(C)CONFIGURATION}"
else
  swift build -c "$CONFIGURATION"
  BIN_DIR="$ROOT/.build/$CONFIGURATION"
fi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources"
cp "$BIN_DIR/WonderBox" "$CONTENTS/MacOS/WonderBox"
cp "$BIN_DIR/WonderFanHelper" "$CONTENTS/Helpers/WonderFanHelper"
cp "$BIN_DIR/WonderMaintenanceHelper" "$CONTENTS/Helpers/WonderMaintenanceHelper"
cp "Sources/WonderBox/Resources/Info.plist" "$CONTENTS/Info.plist"
if [[ "${PREVIEW:-0}" == "1" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.wondercraft.WonderBox.AIPreview" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName WonderBox AI Preview" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName WonderBox AI Preview" "$CONTENTS/Info.plist"
fi
cp "Sources/WonderBox/Resources/PrivacyInfo.xcprivacy" "$CONTENTS/Resources/PrivacyInfo.xcprivacy"
cp "LICENSE" "$CONTENTS/Resources/LICENSE"
cp "Sources/WonderBox/Resources/com.wondercraft.WonderBox.FanHelper.plist" "$CONTENTS/Resources/com.wondercraft.WonderBox.FanHelper.plist"

# String catalogs → <language>.lproj/Localizable.strings; the app resolves them through Bundle.main.
python3 scripts/compile_localization.py "$CONTENTS/Resources"

swift scripts/generate_icon.swift "$ROOT/build/AppIcon-1024.png"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/build/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ROOT/build/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$ICONSET"

codesign --force --sign - "$CONTENTS/Helpers/WonderFanHelper"
codesign --force --sign - "$CONTENTS/Helpers/WonderMaintenanceHelper"
codesign --force --deep --sign - "$APP"

echo "$APP"
