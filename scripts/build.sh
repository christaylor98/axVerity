#!/usr/bin/env bash
# axVerity build — AXVERITY_WRITE_PATH_SLICE_V1. Compiles
# lib/*.m1 to lib_coreir/, each src/*.m1 --entries outer to build/, and
# links all 4 into one binary (build/wp-slice) the same way
# graphcore/scripts/build.sh links gcore-serve + its 3 workers — new code
# only, nothing from graphcore/ is read, ported, or depended on.
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

HERE=$(cd "$(dirname "$0")/.." && pwd)
REG_LOCAL=$HERE/registries/axverity-working2.axreg
LIB_OUT=$HERE/lib_coreir
BUILD_DIR=$HERE/build
mkdir -p "$LIB_OUT" "$BUILD_DIR"

compile() {
  local src="$1"; local out="$2"
  echo "[compile] $src -> $out"
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
    --reg       "$REG_LOCAL" \
    --no-verify \
    --out       "$out"
}

for src in "$HERE"/lib/*.m1; do
  name=$(basename "$src" .m1)
  compile "$src" "$LIB_OUT/$name.coreir"
done

compile "$HERE/src/hot_mem_write.m1"  "$BUILD_DIR/hot_mem_write.coreir"
compile "$HERE/src/mem_controller.m1" "$BUILD_DIR/mem_controller.coreir"
compile "$HERE/src/disk_controller.m1" "$BUILD_DIR/disk_controller.coreir"
compile "$HERE/src/flusher.m1"        "$BUILD_DIR/flusher.coreir"
compile "$HERE/src/ack_bench.m1"      "$BUILD_DIR/ack_bench.coreir"
compile "$HERE/src/tick.m1"           "$BUILD_DIR/tick.coreir"

echo "[eject]   $BUILD_DIR/hot_mem_write.coreir -> $BUILD_DIR/wp-slice"
"$BRIDGE" build "$BUILD_DIR/hot_mem_write.coreir" \
  --lib-dir "$LIB_OUT" \
  --lib "$BUILD_DIR/mem_controller.coreir" \
  --lib "$BUILD_DIR/disk_controller.coreir" \
  --lib "$BUILD_DIR/flusher.coreir" \
  --lib "$BUILD_DIR/ack_bench.coreir" \
  --lib "$BUILD_DIR/tick.coreir" \
  --entries hot_mem_write,mem_controller,disk_controller,flusher,ack_bench,tick \
  --reg "$REG_TYPES" \
  --reg "$REG_BRIDGE" \
  --reg "$REG_GEN" \
  --reg "$REG_M1" \
  --reg "$REG_LOCAL" \
  --out "$BUILD_DIR/wp-slice" --exe $BRIDGE_FLAGS

echo "[done]    $BUILD_DIR/wp-slice"
