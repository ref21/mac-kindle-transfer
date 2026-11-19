#!/bin/bash
# Builds the libmtp dependency if needed, then runs the unit tests.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh --deps-only
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
exec swift test --disable-sandbox --cache-path .cache "$@"
