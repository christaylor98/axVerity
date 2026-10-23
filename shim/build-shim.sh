#!/usr/bin/env bash
# axVerity confined shim build — AXVERITY_SHIM_BUILD_V1.
#
# A THIRD build, separate from scripts/build.sh (write path) and
# scripts/build-readtier.sh (read tier), and it modifies neither. It co-feeds
# registries/axverity-readtier.axreg and links readtier/lib_coreir READ-ONLY —
# that is what "links the tiers in-process" means (contract §5.1), and it is
# why the shim needed no change anywhere in axVerity.
#
# The read tier must be built first: this links its .coreir, it does not compile
# it. Run scripts/build-readtier.sh if readtier/lib_coreir is empty.
set -euo pipefail

AXIS=${AXIS_COMPILER:-~/dev/axis-lang/target/release/axis}
BRIDGE=${BRIDGE_BINARY:-~/dev/axis-codegen-bridge-rs/target/release/axis-codegen-bridge}
# --no-fast: the bridge's native fast path (469079b) re-runs a function on memory it has
# already written when it bails, which corrupts the shim's ADMIT framing and the read
# tier's malformed-block count (make test catches both). Set BRIDGE_FLAGS= (empty)
# to build with the fast path once the bridge is fixed.
BRIDGE_FLAGS=${BRIDGE_FLAGS---no-fast}
M1DIR=${M1_DIR:-~/dev/axis-lang/axis-surface-m1-config}

REG_TYPES=${REG_TYPES:-~/dev/axRegistry/axis-types.axreg}
REG_BRIDGE=${REG_BRIDGE:-~/dev/axRegistry/axis-bridge.axreg}
REG_GEN=${REG_GEN:-~/dev/axRegistry/gen-working.axreg}
REG_M1=${REG_M1:-~/dev/axRegistry/m1-builtins.axreg}

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
REG_RT=$ROOT/registries/axverity-readtier.axreg
REG_SHIM=$HERE/registries/axverity-shim.axreg
RT_LIB=$ROOT/readtier/lib_coreir
LIB_OUT=$HERE/lib_coreir
BUILD_DIR=$HERE/build
mkdir -p "$LIB_OUT" "$BUILD_DIR"

[ -d "$RT_LIB" ] && [ -n "$(ls -A "$RT_LIB" 2>/dev/null)" ] \
  || { echo "error: $RT_LIB is empty — run scripts/build-readtier.sh first" >&2; exit 1; }

compile() {
  local src="$1"; local out="$2"
  "$AXIS" \
    --lexer     "$M1DIR/m1-lexer.yaml" \
    --parser    "$M1DIR/m1-parse.yaml" \
    --schema    "$M1DIR/m1-ast.yaml" \
    --normalize "$M1DIR/m1-normalize.yaml" \
    --file      "$src" \
    --reg       "$REG_TYPES" \
    --reg       "$REG_BRIDGE" \
    --reg       "$REG_GEN" \
    --reg       "$REG_M1" \
    --reg       "$REG_RT" \
    --reg       "$REG_SHIM" \
    --no-verify \
    --out       "$out"
}

for src in "$HERE"/lib/*.m1; do
  name=$(basename "$src" .m1)
  echo "[compile] $name"
  compile "$src" "$LIB_OUT/$name.coreir"
done

echo "[compile] shim"
compile "$HERE/src/shim.m1" "$BUILD_DIR/shim.coreir"

echo "[link]    $BUILD_DIR/axshim-bin"
"$BRIDGE" build "$BUILD_DIR/shim.coreir" \
  --lib-dir "$LIB_OUT" \
  --lib-dir "$RT_LIB" \
  --entries shim \
  --reg "$REG_TYPES" \
  --reg "$REG_BRIDGE" \
  --reg "$REG_GEN" \
  --reg "$REG_M1" \
  --reg "$REG_RT" \
  --reg "$REG_SHIM" \
  --out "$BUILD_DIR/axshim-bin" --exe $BRIDGE_FLAGS

echo "[done]    $BUILD_DIR/axshim-bin   (launch with shim/bin/axshim <store-root> <port>)"
