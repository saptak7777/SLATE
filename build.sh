#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_DIR="$ROOT_DIR/scratch/build"

mkdir -p "$BUILD_DIR"

STAFF="$ROOT_DIR/bin/staff"
PACKAGER="$ROOT_DIR/bin/packager_bin"
MANIFEST="$ROOT_DIR/slate/build.staff"

SAFE="$BUILD_DIR/slate.safe"
ELF="$ROOT_DIR/bin/slate"

"$STAFF" "$MANIFEST" "$SAFE"
"$PACKAGER" "$SAFE" "$ELF"
chmod +x "$ELF"
echo "SLATE successfully built: $ELF"

