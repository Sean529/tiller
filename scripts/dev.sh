#!/usr/bin/env bash
# Builds a debug copy of Tiller in build/dev and opens it beside the everyday
# Tiller. It has its own bundle id, so its own settings, and its own data
# folder, so its own instance lock, profiles and chats: one Tiller runs every
# profile, and a launch that finds the lock held hands over to that one.
# Usage: scripts/dev.sh [app arguments...]   e.g. scripts/dev.sh -url https://example.com
# TILLER_DATA_DIR picks another data folder (default: Tiller-dev beside Tiller's).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="${TILLER_DATA_DIR:-$HOME/Library/Application Support/Tiller-dev}"

TILLER_OUT="$ROOT/build/dev" TILLER_BUNDLE_ID=dev.sorrycc.tiller.dev "$ROOT/scripts/bundle.sh" debug

echo "==> opening build/dev/Tiller.app (data in $DATA_DIR)"
if [ $# -gt 0 ]; then
    open --env TILLER_DATA_DIR="$DATA_DIR" "$ROOT/build/dev/Tiller.app" --args "$@"
else
    open --env TILLER_DATA_DIR="$DATA_DIR" "$ROOT/build/dev/Tiller.app"
fi
