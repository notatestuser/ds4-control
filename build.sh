#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="DS4 Control"
APP="$APP_NAME.app"
# Release pipeline exports APP_VERSION (semver from the git tag) + APP_BUILD
# (monotonic int). Falls back to DS4_CONTROL_VERSION or a date for local builds.
VERSION="${APP_VERSION:-${DS4_CONTROL_VERSION:-$(date +%y.%-m.0)}}"
BUILD="${APP_BUILD:-$VERSION}"

echo "→ swift build (release)"
swift build -c release 2>&1 | tail -3
BIN="$(swift build -c release --show-bin-path)/DS4Control"

echo "→ assemble bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DS4Control"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# Icon: generate from Resources/icon.png if present, else skip.
if [ -f Resources/icon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 64 128 256 512; do
    sips -z $s $s Resources/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "→ code signing"
IDENTITY="${DS4_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
fi
if [ -n "$IDENTITY" ]; then
  echo "  identity: $IDENTITY"
  codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/DS4Control"
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
  echo "  no Apple Development identity found — ad-hoc signing"
  codesign --force --sign - "$APP/Contents/MacOS/DS4Control"
  codesign --force --sign - "$APP"
fi
codesign -vv "$APP" 2>&1 | head -3
echo "→ done: $APP"
