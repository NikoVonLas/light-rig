# Firmware

ESP-IDF firmware for LightController based on the TTGO T8 ESP32-S2 V1.1.

## Build

```sh
. ./scripts/esp-idf-env.sh
idf.py -C firmware set-target esp32s2
idf.py -C firmware build
```

## Flash and monitor

Keep the board USB DIP switches in CH340 mode (1/3 ON, 2/4 OFF). The factory
image is backed up in the ignored `.artifacts/` directory.

```sh
./scripts/flash_firmware.sh
. ./scripts/esp-idf-env.sh
idf.py -C firmware -p "$(./scripts/find_serial_port.sh)" monitor
```

Fresh boards start in USB-only mode. Connect the built-in USB-C to the Mac with
DIP 1/3 ON and 2/4 OFF; the separate USB host socket is for Canon, not a computer.
The Mac onboarding can scan nearby 2.4 GHz WPA2/WPA3 personal networks over USB,
then send `network.configure`. SSID/password and mode persist in NVS. USB remains
available while the board joins the router; wait for a confirmed IP before
moving to external power.

Router mode reconnects without the Mac: one background task owns connection
attempts, recovers from disconnect/lost-IP events and 20-second connection stalls,
and retries indefinitely with a 2–30-second backoff. Scan and reconnect operations
are serialized. USB-only scans temporarily start Wi-Fi and stop it afterward.
No password is returned in state or written to source control.

AP mode is still available explicitly in Settings. It advertises `LightController-XXXX`
and serves provisioning at `192.168.4.1`; router mode advertises `canonrig.local`.

## Status display

The LCD and its GPIO33 backlight turn off after 60 seconds without a state
change. The display stays on throughout an active call. A call ending starts
a fresh minute. Changes to the camera USB link, Wi-Fi, client presence or light
settings wake the display. Routine heartbeats, unchanged EOS polls and animated
LED frames leave the timer alone. The Mac USB-C connector uses a CH340 bridge,
so the firmware detects a serial client by its first command and expires it
after eight seconds of silence. The state API reports the LCD as `displayAwake`.

## Custom light modes

The ESP owns the preset model; it does not replay the original controller's
buttons. Six NVS-backed slots can contain white-channel balance or RGB plus
brightness, speed, and one of `solid`, `breathe`, `rainbow`, or `color_cycle`.
The macOS app edits these fields and sends `light.set`, `preset.save`, and
`light.applyPreset` messages.

RGB DATA uses **GPIO17 / IO17** connected to the strip's DIN, with common
ground. The WS2812B RGB backend sends 55 identical 24-bit GRB pixels
in one SPI3 DMA transfer at 800 kbit/s and latches them with 320 µs low. The output starts off.
A steady color stays latched until the next light command. Reapplying a
command or preset refreshes the strip after a separate power cycle.
Effects transmit each time the rendered RGB values change.
The internal pull-down is checked using GPIO configuration readback.
The legacy GPIO18 capture input is released before RGB output starts.

A short LightController BOOT press cycles RGB colors/effects. Hold it for at least
1.2 seconds and release to switch RGB off.

For example:

```json
{"v":1,"id":"demo","type":"light.set","payload":{"enabled":true,"mode":"rgb","red":255,"green":80,"blue":10,"brightness":45,"effect":"breathe","speed":30}}
```

## Safe bring-up boundary

White channels A/B are not implemented; enabled
CCT commands are rejected. The separate Canon USB host supports PTP control;
RGB pin tests do not require or send camera commands.
