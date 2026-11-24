#!/bin/sh

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
export IDF_TOOLS_PATH="$PROJECT_DIR/.toolchains/espressif"
. "$PROJECT_DIR/.toolchains/esp-idf/export.sh"
