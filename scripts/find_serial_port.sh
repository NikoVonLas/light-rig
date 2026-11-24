#!/bin/sh
set -eu

for port in /dev/cu.usbserial-* /dev/cu.wchusbserial*; do
    if [ -e "$port" ]; then
        printf '%s\n' "$port"
        exit 0
    fi
done

printf '%s\n' "No CH340 serial port found" >&2
exit 1
