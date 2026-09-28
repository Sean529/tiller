#!/usr/bin/env bash
# Builds the Rust crates and the Swift app, then assembles and ad-hoc signs
# build/Mini.app. Usage: scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/Mini.app"
BUNDLE_ID="dev.sorrycc.mini"
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
swift build --package-path "$ROOT/app" -c "$CONFIG" -Xlinker -L"$RUST_OUT"
SWIFT_OUT="$(swift build --package-path "$ROOT/app" -c "$CONFIG" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# write_plist <contents dir> <executable> <identifier> <is_helper>
write_plist() {
    local ui_element=""
    [ "$4" = "1" ] && ui_element="<key>LSUIElement</key><string>1</string>"
    cat > "$1/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Mini</string>
    <key>CFBundleDisplayName</key><string>Mini</string>
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
    $ui_element
</dict>
</plist>
PLIST
}

cp "$SWIFT_OUT/Mini" "$APP/Contents/MacOS/Mini"
cp "$RUST_OUT/mini_mcp" "$APP/Contents/MacOS/mini_mcp"
write_plist "$APP/Contents" "Mini" "$BUNDLE_ID" 0

# ditto keeps the framework's symlinks and permissions intact.
ditto "$CEF_PATH/$FRAMEWORK" "$APP/Contents/Frameworks/$FRAMEWORK"

for suffix in "${HELPERS[@]}"; do
    name="Mini $suffix"
    helper="$APP/Contents/Frameworks/$name.app"
    mkdir -p "$helper/Contents/MacOS"
    cp "$RUST_OUT/mini_helper" "$helper/Contents/MacOS/$name"
    id_suffix="$(echo "$suffix" | tr -d '()' | tr ' ' '.' | tr '[:upper:]' '[:lower:]')"
    write_plist "$helper/Contents" "$name" "$BUNDLE_ID.$id_suffix" 1
done

echo "==> ad-hoc signing"
codesign --force --sign - "$APP/Contents/Frameworks/$FRAMEWORK"
for suffix in "${HELPERS[@]}"; do
    codesign --force --sign - "$APP/Contents/Frameworks/Mini $suffix.app"
done
codesign --force --sign - "$APP/Contents/MacOS/mini_mcp"
codesign --force --sign - "$APP"

echo "==> done: $APP"
