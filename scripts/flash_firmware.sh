#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
PORT=$($SCRIPT_DIR/find_serial_port.sh)

if [ ! -f "$PROJECT_DIR/.artifacts/lightcontroller-factory-4mb.bin" ] &&
   [ ! -f "$PROJECT_DIR/.artifacts/lilygo-factory-4mb.bin" ]; then
    echo "Refusing to flash without the factory backup." >&2
    exit 1
fi

. "$SCRIPT_DIR/esp-idf-env.sh"
RIG_FLASH_BAUD=${CANON_RIG_FLASH_BAUD:-115200}
exec idf.py -C "$PROJECT_DIR/firmware" -p "$PORT" -b "$RIG_FLASH_BAUD" flash
