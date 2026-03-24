#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/scripts/build-macos-app.sh"
"$ROOT_DIR/scripts/build-dmg.sh"

echo "Release artifacts are in $ROOT_DIR/build"
