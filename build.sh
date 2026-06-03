#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="DS4 Control"
APP="$APP_NAME.app"
# Release pipeline exports APP_VERSION (semver from the git tag) + APP_BUILD
# (monotonic int). Falls back to DS4_CONTROL_VERSION or a date for local builds.
VERSION="${APP_VERSION:-${DS4_CONTROL_VERSION:-$(date +%y.%-m.0)}}"
BUILD="${APP_BUILD:-$VERSION}"

# SwiftPM generates each dependency's resource-bundle accessor to look for `X.bundle` at
# `Bundle.main.bundleURL` (the .app ROOT once packaged — where macOS forbids unsealed content)
# with a dev-machine-absolute `.build` fallback, so the shipped .app can't find them and crashes
# (`Bundle.module` fatalError on the first code/math render). We place the bundles in
# Contents/Resources (sealed, notarizable); to make the accessor look THERE, intercept the compiler
# via SWIFT_EXEC and rewrite `Bundle.main.bundleURL` → `(Bundle.main.resourceURL ?? …)` just before
# each compile. SwiftPM regenerates the accessor every build, so patching the file directly is wiped
# — patching between regeneration and compilation (here) survives. `resourceURL` is Contents/Resources
# in the .app and falls back to the executable dir for `swift run`/tests, so local runs still work.
WRAP="$(mktemp -t ds4-swiftc-wrap).sh"
cat > "$WRAP" <<'WRAP_EOF'
#!/bin/bash
patch_file() {
  local f="$1"
  if [ -f "$f" ] && grep -q 'Bundle\.main\.bundleURL' "$f" && ! grep -q 'resourceURL ?? Bundle.main.bundleURL' "$f"; then
    sed -i '' 's/Bundle\.main\.bundleURL/(Bundle.main.resourceURL ?? Bundle.main.bundleURL)/g' "$f"
  fi
}
for arg in "$@"; do
  case "$arg" in
    *resource_bundle_accessor.swift) patch_file "$arg" ;;
    @*) rf="${arg#@}"; [ -f "$rf" ] && grep -o '[^"]*resource_bundle_accessor.swift' "$rf" 2>/dev/null | while read -r s; do patch_file "$s"; done ;;
  esac
done
exec xcrun swiftc "$@"
WRAP_EOF
chmod +x "$WRAP"
export SWIFT_EXEC="$WRAP"
trap 'rm -f "$WRAP"' EXIT
# Force the accessors to regenerate+recompile this build so the interceptor definitely patches them
# (a no-op for a fresh CI checkout; matters for incremental local builds).
find .build -name resource_bundle_accessor.swift -delete 2>/dev/null || true

echo "→ swift build (release)"
swift build -c release 2>&1 | tail -3
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/DS4Control"

echo "→ assemble bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DS4Control"
cp Info.plist "$APP/Contents/Info.plist"

# SwiftPM dependency resource bundles (Highlightr's highlight.js + CSS, SwiftMath's fonts,
# MarkdownView/Litext resources). `Bundle.module` resolves these from the app's
# Contents/Resources at runtime; without them the first code-block render crashes in
# Highlightr.init → Bundle.module (assertionFailure / EXC_BREAKPOINT). Copy before signing
# so codesign seals them into the bundle.
echo "→ bundle SwiftPM resource bundles"
shopt -s nullglob
for b in "$BIN_DIR"/*.bundle; do
  cp -R "$b" "$APP/Contents/Resources/"
  echo "  + $(basename "$b")"
done
shopt -u nullglob

# Every *.bundle the release pipeline codesigns (it recurses with `find -name '*.bundle'`)
# needs an Info.plist, or codesign rejects it ("bundle format unrecognized"). Some SwiftPM
# resource bundles — and bundles nested inside them, e.g. SwiftMath's mathFonts.bundle — ship
# data-only with none. Synthesize a minimal one for any (top-level or nested) that lacks it.
while IFS= read -r -d '' bdir; do
  if [ -f "$bdir/Info.plist" ] || [ -f "$bdir/Contents/Info.plist" ]; then continue; fi
  name="$(basename "$bdir" .bundle)"
  cat > "$bdir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleIdentifier</key><string>sg.embeddedtech.ds4control.resources.$(echo "$name" | tr '_' '-')</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
  echo "  synthesized Info.plist: ${bdir#"$APP"/Contents/Resources/}"
done < <(find "$APP/Contents/Resources" -type d -name "*.bundle" -print0)
# Regression guard: Highlightr's bundle is what crashed v1.0.0 when absent. Fail the build
# rather than ship a .app that crashes on the first code-block render.
if [ ! -d "$APP/Contents/Resources/Highlightr_Highlightr.bundle" ]; then
  echo "  ERROR: Highlightr_Highlightr.bundle missing from app — markdown code rendering would crash"; exit 1
fi
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

echo "→ bundle ds4 (server + metal shaders + downloader)"
# The app resolves ds4Dir to Resources/ds4 at runtime (Paths.swift). Bundle only the
# small artifacts — ds4-server (~1 MB), the metal/ shader sources it compiles at runtime,
# and download_model.sh. The multi-hundred-GB model is downloaded to Application Support.
DS4_SRC="${DS4_SRC:-../ds4}"
DEST="$APP/Contents/Resources/ds4"
mkdir -p "$DEST"
for item in ds4-server download_model.sh metal; do
  if [ ! -e "$DS4_SRC/$item" ]; then
    echo "  ERROR: missing '$DS4_SRC/$item' — build ds4 first or set DS4_SRC=<ds4 checkout>"; exit 1
  fi
  rm -rf "$DEST/$item"; cp -R "$DS4_SRC/$item" "$DEST/$item"
done
chmod +x "$DEST/ds4-server" "$DEST/download_model.sh"

echo "→ code signing"
IDENTITY="${DS4_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
fi
if [ -n "$IDENTITY" ]; then
  echo "  identity: $IDENTITY"
  # Sign inside-out: nested ds4-server first, then the app binary, then the bundle.
  codesign --force --options runtime --sign "$IDENTITY" "$DEST/ds4-server"
  codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/DS4Control"
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
  echo "  no Apple Development identity found — ad-hoc signing"
  codesign --force --sign - "$DEST/ds4-server"
  codesign --force --sign - "$APP/Contents/MacOS/DS4Control"
  codesign --force --sign - "$APP"
fi
codesign -vv "$APP" 2>&1 | head -3
echo "→ done: $APP"
