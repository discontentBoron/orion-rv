#!/usr/bin/env bash

set -euo pipefail

# ------------------------------------------------------------
# Orion-RV benchmark build script
#
# Usage:
#   ./build_script.sh prog_name
#
# Input:
#   benchmarks/<name>.c
#
# Output:
#   build/bench/<name>.elf
#   build/bench/<name>.bin
#   build/bench/<name>.hex
#   build/bench/<name>.dump
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BENCH_NAME="${1:-}"

if [[ -z "$BENCH_NAME" ]]; then
    echo "Usage: $0 <benchmark_name>"
    echo
    echo "Example:"
    echo "  $0 general_balanced"
    exit 1
fi

SRC="$SCRIPT_DIR/${BENCH_NAME}.c"
START="$SCRIPT_DIR/start.S"
LINKER="$SCRIPT_DIR/link.ld"

BUILD_DIR="$PROJECT_ROOT/build/bench"
ELF="$BUILD_DIR/${BENCH_NAME}.elf"
BIN="$BUILD_DIR/${BENCH_NAME}.bin"
HEX="$BUILD_DIR/${BENCH_NAME}.hex"
DUMP="$BUILD_DIR/${BENCH_NAME}.dump"

GCC="riscv32-unknown-elf-gcc"
OBJCOPY="riscv32-unknown-elf-objcopy"
OBJDUMP="riscv32-unknown-elf-objdump"
HEX_SCRIPT="$SCRIPT_DIR/elf_to_hex.py"

# ------------------------------------------------------------
# Check required files/tools
# ------------------------------------------------------------

if [[ ! -f "$SRC" ]]; then
    echo "ERROR: benchmark source not found:"
    echo "  $SRC"
    exit 1
fi

if [[ ! -f "$START" ]]; then
    echo "ERROR: startup file not found:"
    echo "  $START"
    exit 1
fi

if [[ ! -f "$LINKER" ]]; then
    echo "ERROR: linker script not found:"
    echo "  $LINKER"
    exit 1
fi

if [[ ! -f "$HEX_SCRIPT" ]]; then
    echo "ERROR: HEX conversion script not found:"
    echo "  $HEX_SCRIPT"
    exit 1
fi

command -v "$GCC" >/dev/null 2>&1 || {
    echo "ERROR: $GCC not found"
    exit 1
}

command -v "$OBJCOPY" >/dev/null 2>&1 || {
    echo "ERROR: $OBJCOPY not found"
    exit 1
}

command -v "$OBJDUMP" >/dev/null 2>&1 || {
    echo "ERROR: $OBJDUMP not found"
    exit 1
}

# ------------------------------------------------------------
# Create output directory
# ------------------------------------------------------------

mkdir -p "$BUILD_DIR"

echo
echo "============================================================"
echo " Building Orion-RV benchmark: $BENCH_NAME"
echo "============================================================"
echo
echo "Source : $SRC"
echo "Output : $BUILD_DIR"
echo

# ------------------------------------------------------------
# 1. Compile + link
# ------------------------------------------------------------

echo "[1/4] Compiling and linking..."

"$GCC" \
    -march=rv32im \
    -mabi=ilp32 \
    -O2 \
    -ffreestanding \
    -fno-builtin \
    -fno-pic \
    -nostdlib \
    -nostartfiles \
    -nodefaultlibs \
    -msmall-data-limit=0 \
    -Wl,--gc-sections \
    -T "$LINKER" \
    "$START" \
    "$SRC" \
    -o "$ELF"

echo "      -> $ELF"

# ------------------------------------------------------------
# 2. Generate binary containing only .text
# ------------------------------------------------------------

echo "[2/4] Extracting .text..."

"$OBJCOPY" \
    --only-section=.text \
    -O binary \
    "$ELF" \
    "$BIN"

echo "      -> $BIN"

# ------------------------------------------------------------
# 3. Convert binary to Verilog $readmemh format
# ------------------------------------------------------------

echo "[3/4] Generating HEX..."

python3 "$HEX_SCRIPT" \
    "$BIN" \
    "$HEX"

echo "      -> $HEX"

# ------------------------------------------------------------
# 4. Generate disassembly
# ------------------------------------------------------------

echo "[4/4] Generating disassembly..."

"$OBJDUMP" \
    -d \
    "$ELF" \
    > "$DUMP"

echo "      -> $DUMP"

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Build complete"
echo "============================================================"

printf "ELF : %s\n" "$ELF"
printf "BIN : %s\n" "$BIN"
printf "HEX : %s\n" "$HEX"
printf "DUMP: %s\n" "$DUMP"

echo
echo "HEX size:"
wc -l "$HEX"

echo
echo "Text section:"
"$OBJDUMP" -h "$ELF" | grep -E '\.text|Idx|LOAD' || true

echo
echo "Done."