#!/usr/bin/env bash
# Builds the Rust crates and the Swift app, then assembles and ad-hoc signs
# build/Tiller.app. Usage: scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/Tiller.app"
BUNDLE_ID="dev.sorrycc.tiller"
VERSION="0.1.0"
FRAMEWORK="Chromium Embedded Framework.framework"
HELPERS=("Helper" "Helper (GPU)" "Helper (Renderer)" "Helper (Plugin)" "Helper (Alerts)")

[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
export CEF_PATH="${CEF_PATH:-$HOME/.local/share/cef}"
if [ ! -d "$CEF_PATH/$FRAMEWORK" ]; then
    echo "CEF not found at $CEF_PATH. See README.md for the one-time download." >&2
    exit 1
fi

cargo_flags=()
[ "$CONFIG" = "release" ] && cargo_flags+=(--release)
echo "==> cargo build ($CONFIG)"
cargo build --manifest-path "$ROOT/Cargo.toml" --workspace "${cargo_flags[@]}"
RUST_OUT="$ROOT/target/$CONFIG"

echo "==> swift build ($CONFIG)"
SWIFT_OUT="$(swift build --package-path "$ROOT/app" -c "$CONFIG" --show-bin-path)"
# SwiftPM doesn't track the Rust static library, so a Rust-only change would
# not relink. Removing the executable forces the link step.
rm -f "$SWIFT_OUT/Tiller"
swift build --package-path "$ROOT/app" -c "$CONFIG" -Xlinker -L"$RUST_OUT" -Xlinker -dead_strip

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# write_plist <contents dir> <executable> <identifier> <is_helper>
write_plist() {
    local ui_element=""
    [ "$4" = "1" ] && ui_element="<key>LSUIElement</key><string>1</string>"
    local icon=""
    [ "$4" = "0" ] && icon="<key>CFBundleIconFile</key><string>Tiller</string>"
    cat > "$1/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tiller</string>
    <key>CFBundleDisplayName</key><string>Tiller</string>
    <key>CFBundleExecutable</key><string>$2</string>
    <key>CFBundleIdentifier</key><string>$3</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCameraUsageDescription</key><string>A website wants to use the camera.</string>
    <key>NSMicrophoneUsageDescription</key><string>A website wants to use the microphone.</string>
    <key>NSAppleEventsUsageDescription</key><string>Tiller asks Finder to copy Chrome's data when security software blocks reading it directly.</string>
    $ui_element
    $icon
</dict>
</plist>
PLIST
}

cp "$SWIFT_OUT/Tiller" "$APP/Contents/MacOS/Tiller"
# Debug builds keep their symbols for the debugger.
[ "$CONFIG" = "release" ] && strip -x "$APP/Contents/MacOS/Tiller"
cp "$RUST_OUT/tiller_mcp" "$APP/Contents/MacOS/tiller_mcp"
# Not in MacOS/, where `tiller` and `Tiller` would be the same file on a
# case-insensitive disk.
cp "$RUST_OUT/tiller" "$APP/Contents/Helpers/tiller"
cp "$ROOT/app/Resources/Tiller.icns" "$APP/Contents/Resources/Tiller.icns"
write_plist "$APP/Contents" "Tiller" "$BUNDLE_ID" 0

# ditto keeps the framework's symlinks and permissions intact.
ditto "$CEF_PATH/$FRAMEWORK" "$APP/Contents/Frameworks/$FRAMEWORK"

# Keep only the English and Chinese Chromium locales, and drop SwiftShader,
# the software renderer used only when the GPU is unavailable.
find "$APP/Contents/Frameworks/$FRAMEWORK/Resources" -maxdepth 1 -name '*.lproj' \
    ! -name 'en.lproj' ! -name 'en_*.lproj' ! -name 'zh_CN*.lproj' ! -name 'zh_TW*.lproj' \
    -exec rm -rf {} +
rm -f "$APP/Contents/Frameworks/$FRAMEWORK/Libraries/"{libvk_swiftshader.dylib,libvulkan.dylib,vk_swiftshader_icd.json}

for suffix in "${HELPERS[@]}"; do
    name="Tiller $suffix"
    helper="$APP/Contents/Frameworks/$name.app"
    mkdir -p "$helper/Contents/MacOS"
    cp "$RUST_OUT/tiller_helper" "$helper/Contents/MacOS/$name"
    id_suffix="$(echo "$suffix" | tr -d '()' | tr ' ' '.' | tr '[:upper:]' '[:lower:]')"
    write_plist "$helper/Contents" "$name" "$BUNDLE_ID.$id_suffix" 1
done

echo "==> ad-hoc signing"
codesign --force --sign - "$APP/Contents/Frameworks/$FRAMEWORK"
for suffix in "${HELPERS[@]}"; do
    codesign --force --sign - "$APP/Contents/Frameworks/Tiller $suffix.app"
done
codesign --force --sign - "$APP/Contents/MacOS/tiller_mcp"
codesign --force --sign - "$APP/Contents/Helpers/tiller"
codesign --force --sign - "$APP"

echo "==> verifying signature"
codesign --verify --deep --strict "$APP"

echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
