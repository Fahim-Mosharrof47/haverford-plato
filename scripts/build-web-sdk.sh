#!/usr/bin/env bash
set -euo pipefail

# Builds the WebAssembly package for the Skilly web SDK (core/web-sdk).
# Browser sibling of scripts/generate-mobile-sdk-bindings.sh.
#
# Requirements (clean toolchain — see note below):
#   rustup target add wasm32-unknown-unknown
#   cargo install wasm-pack
#
# NOTE: a host with BOTH Homebrew rust and rustup at the same version can fail
# the wasm32 build with "can't find crate for `core`". Prefer a single rustup
# toolchain (or run this in CI). wasm-pack drives the wasm32 build itself.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/sdk/web/generated"

# Pin rustc to the rustup toolchain. On hosts that also have a Homebrew rust on
# PATH, the toolchain cargo otherwise resolves `rustc` from PATH (Homebrew's,
# which has no wasm32 std) and fails with "can't find crate for `core`".
if command -v rustup >/dev/null 2>&1; then
  TOOLCHAIN_BIN="$(dirname "$(rustup which rustc)")"
  export PATH="$TOOLCHAIN_BIN:$PATH"
  export RUSTC="$TOOLCHAIN_BIN/rustc"
fi

cd "$REPO_ROOT/core/web-sdk"

wasm-pack build \
  --target web \
  --release \
  --out-dir "$OUT_DIR" \
  --out-name skilly_core_web_sdk

echo "Generated web SDK (wasm + JS bindings) in $OUT_DIR"
