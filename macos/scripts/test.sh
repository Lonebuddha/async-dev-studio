#!/bin/sh
set -eu
macos_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CLANG_MODULE_CACHE_PATH="$macos_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
sh "$macos_root/scripts/prepare-dependencies.sh"
swift run --package-path "$macos_root" --disable-sandbox StudioTests
