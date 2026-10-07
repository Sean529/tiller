#!/usr/bin/env bash
# Downloads CEF as README.md describes: the stock build, whose headers the Rust
# crates build against, into $CEF_PATH, and the third-party build with H.264
# and AAC, whose framework goes in the app, into ~/.local/share/cef-codecs.
# Folders already there are kept. The release workflow runs this.
set -euo pipefail

CEF_RS_TAG="cef-v154.2.0+154.0.28"
CODECS_URL="https://github.com/aiexkwan/aurix-cef/releases/download/cef-154.0.26-codecs/cef-154.0.26-macosarm64-slim.tar.zst"
# The codecs build is unsigned and made by a third party: this is the archive
# that was checked. Change both together.
CODECS_SHA256="b06ad1580f92385d26bf579bf483cc82f361bfd41fa56565515dcceb0f37ebd1"
FRAMEWORK="Chromium Embedded Framework.framework"
CEF_PATH="${CEF_PATH:-$HOME/.local/share/cef}"
CODECS_DIR="$HOME/.local/share/cef-codecs"

[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -d "$CEF_PATH/$FRAMEWORK" ]; then
    echo "==> CEF already at $CEF_PATH"
else
    echo "==> exporting CEF ($CEF_RS_TAG) to $CEF_PATH"
    git clone --quiet --depth 1 --branch "$CEF_RS_TAG" https://github.com/tauri-apps/cef-rs "$TMP/cef-rs"
    cargo run --quiet --manifest-path "$TMP/cef-rs/Cargo.toml" -p export-cef-dir -- --force "$CEF_PATH"
fi

if [ -d "$CODECS_DIR/$FRAMEWORK" ]; then
    echo "==> CEF with codecs already at $CODECS_DIR"
else
    echo "==> downloading CEF with codecs to $CODECS_DIR"
    curl -fsSL -o "$TMP/codecs.tar.zst" "$CODECS_URL"
    echo "$CODECS_SHA256  $TMP/codecs.tar.zst" | shasum -a 256 -c - >/dev/null
    mkdir -p "$CODECS_DIR"
    tar --use-compress-program=unzstd -xf "$TMP/codecs.tar.zst" -C "$CODECS_DIR"
fi
