#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
. "$SCRIPT_DIR/esp-idf-env.sh"
exec idf.py -C "$PROJECT_DIR/firmware" build
