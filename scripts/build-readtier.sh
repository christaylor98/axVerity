#!/usr/bin/env bash
# axVerity read-tier build — AXVERITY_READ_INDEX_RAM_TIER_V1.
#
# Deliberately a SEPARATE build from scripts/build.sh. That script compiles the
# write path and must keep doing exactly that: it never reads readtier/, never
# reads registries/axverity-readtier.axreg, and its output (build/wp-slice) does
# not change because this one exists. UNWIRED_BY_DESIGN is enforced by the
# build graph, not by discipline.
#
# Same two-stage shape as every other M1 project here: compile each
# readtier/lib/*.m1 to readtier/lib_coreir/<name>.coreir, then compile+link the
# single outer readtier/src/rt_driver.m1 into readtier/build/rt-driver.
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
REG_LOCAL=$HERE/registries/axverity-readtier.axreg
LIB_OUT=$HERE/readtier/lib_coreir
BUILD_DIR=$HERE/readtier/build
mkdir -p "$LIB_OUT" "$BUILD_DIR"

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
    --reg       "$REG_LOCAL" \
    --no-verify \
    --out       "$out"
}

for src in "$HERE"/readtier/lib/*.m1; do
  name=$(basename "$src" .m1)
  echo "[compile] $name"
  compile "$src" "$LIB_OUT/$name.coreir"
done

echo "[compile] rt_driver"
compile "$HERE/readtier/src/rt_driver.m1" "$BUILD_DIR/rt_driver.coreir"

echo "[link]    $BUILD_DIR/rt-driver"
"$BRIDGE" build "$BUILD_DIR/rt_driver.coreir" \
  --lib-dir "$LIB_OUT" \
  --entries rt_driver \
  --reg       "$REG_TYPES" \
  --reg "$REG_BRIDGE" \
  --reg "$REG_GEN" \
  --reg "$REG_M1" \
  --reg "$REG_LOCAL" \
  --out "$BUILD_DIR/rt-driver" --exe $BRIDGE_FLAGS

echo "[done]    $BUILD_DIR/rt-driver"
