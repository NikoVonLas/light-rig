#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PORT=${1:-"$($PROJECT_DIR/scripts/find_serial_port.sh)"}
OUT_DIR="$PROJECT_DIR/.artifacts"
OUT_BIN="$OUT_DIR/lightcontroller-factory-4mb.bin"

mkdir -p "$OUT_DIR"

if [ -e "$OUT_BIN" ] || [ -e "$OUT_DIR/lilygo-factory-4mb.bin" ]; then
    printf '%s\n' "A factory backup already exists in $OUT_DIR." >&2
    exit 1
fi

if [ ! -x "$PROJECT_DIR/.venv/bin/esptool" ]; then
    printf '%s\n' "Missing .venv/bin/esptool; install the pinned development requirements first." >&2
    exit 1
fi

"$PROJECT_DIR/.venv/bin/esptool" --chip esp32s2 --port "$PORT" flash-id
"$PROJECT_DIR/.venv/bin/esptool" --chip esp32s2 --port "$PORT" read-flash 0x0 0x400000 "$OUT_BIN"
shasum -a 256 "$OUT_BIN" > "$OUT_BIN.sha256"
printf '%s\n' "Factory backup saved to $OUT_BIN"
