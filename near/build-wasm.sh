#!/usr/bin/env bash
# Pinned, path-independent build of botled-registry.wasm + sha256 check.
#   near/build-wasm.sh          build and compare with near/wasm.sha256 (exit 1 on mismatch)
#   near/build-wasm.sh --pin    build and (re)write near/wasm.sha256
# Pins: rust 1.99.1 (same as the NEP-330 docker image sourcescan/cargo-near:0.23.0-rust-1.99.1), cargo-near 0.23.0,
# Cargo.lock (--locked). Paths are remapped so the output does not depend on the checkout location or $HOME.
# Official verification path (Docker): cd near/botled-registry && cargo near build reproducible-wasm
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
TOOLCHAIN=1.99.1
CARGO_NEAR=0.23.0
export PATH="$HOME/.cargo/bin:$PATH"
got_cn="$(cargo near --version | awk '{print $2}')"
[ "$got_cn" = "$CARGO_NEAR" ] || { echo "cargo-near $CARGO_NEAR required (have $got_cn)"; exit 2; }
rustup toolchain list | grep -q "^$TOOLCHAIN" || { echo "rustup toolchain install $TOOLCHAIN --profile minimal --target wasm32-unknown-unknown"; exit 2; }
export RUSTUP_TOOLCHAIN=$TOOLCHAIN
export SOURCE_DATE_EPOCH=0
export CARGO_INCREMENTAL=0
export RUSTFLAGS="--remap-path-prefix=$here=/botled --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-prefix=$(rustc --print sysroot)=/rustc"
mkdir -p "$here/target"
cd "$here/botled-registry"
cargo near build non-reproducible-wasm --locked --no-abi >/dev/null 2>"$here/target/build-wasm.log" || { cat "$here/target/build-wasm.log"; exit 1; }
wasm="$here/target/near/botled_registry/botled_registry.wasm"
sum="$(sha256sum "$wasm" | awk '{print $1}')"
echo "botled_registry.wasm $(stat -c %s "$wasm") bytes sha256 $sum"
if [ "${1:-}" = "--pin" ]; then
  echo "$sum  botled_registry.wasm  (rust $TOOLCHAIN, cargo-near $CARGO_NEAR, --locked, --no-abi)" > "$here/wasm.sha256"
  echo "pinned -> near/wasm.sha256"
elif [ -f "$here/wasm.sha256" ]; then
  want="$(awk '{print $1}' "$here/wasm.sha256")"
  [ "$sum" = "$want" ] && echo "OK matches near/wasm.sha256" || { echo "MISMATCH: expected $want"; exit 1; }
fi
