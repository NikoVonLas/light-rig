# Light Rig

## Current working connection modes

- **USB**: built-in CH340 bridge, 115200 baud. Works without Wi-Fi and leaves
  GPIO19/20 dedicated to the separate Canon USB-host connector.
- **Light Rig AP**: board creates its own network at `192.168.4.1`; join it manually.
- **Router**: board joins a configured 2.4 GHz WPA2 network; use DHCP IP or
  `lightrig.local`. Router association still needs verification on the user's network.

The Mac automatically prefers USB and falls back to the board's network address.
For first-time Wi-Fi setup, connect Light Rig to the Mac over USB and enter the
2.4 GHz SSID/password in the app. Light Rig persists them and reconnects after power
cycles. USB stays available in AP/router modes. Mode changes reboot the board
with RGB OFF. Mac network settings are never changed by the application.
Fresh boards default to USB-only.

Bench verified: native Mac client USB handshake, malformed/oversized command
recovery, and board AP → USB reboot cycle. Wireless client traffic is not yet
bench verified. The replacement RGB strip uses a WS2812B profile on IO17 (GRB, 800 kbit/s). Canon PTP session and EOS
exposure control now work: the Mac app reads and changes ISO, shutter, aperture,
AF area and video Servo AF using camera-supplied options. AF start/cancel and
near/far focus-step commands return OK on the camera. FocusMode (One Shot/Servo/MF)
is read-only when the camera offers no choices. Sleep/wake and white A/B
power-stage control remain unfinished. Older milestone description below is
historical; see `protocol/README.md` for current transport and security limits.

Controller for a Canon EOS M6 Mark II, an HDMI Cam Link, and a USB-powered
ring light. The Canon HDMI output remains connected directly to conferencing
software. An ESP32-S2 handles Canon PTP control, RGB lighting and the local
status display. A native macOS app detects calls and provides controls over
a Cam Link preview that runs while the control window is open. Camera sleep/wake is not implemented.
Click-to-focus transport exists, but is not working on the current camera state:
USB Live View preparation returns DeviceBusy (`0x2019`), so no guessed AF
coordinates are sent.

## Repository layout

New: [Home Assistant + two Macs](protocol/home-assistant.md). Firmware flashed;
USB regression passed. Two physical Macs and a real MQTT/HA connection remain unverified.
MQTT discovery and multi-client automatic lighting live on Light Rig. Mac builds
send independent presence heartbeats; camera-in-call remains unknown during a
call until consumer-aware detection is implemented. Configure broker credentials and an optional CA over USB. The board stores them in NVS.

- `firmware/` — ESP-IDF firmware for Light Rig based on the TTGO T8 ESP32-S2 V1.1.
- `macos/` — SwiftUI menu-bar/control application.
- `protocol/` — versioned wire protocol shared by both sides.
- `hardware/` — wiring, power, and validation notes.
- `scripts/` — reproducible board backup and development helpers.

## Confirmed development board

- USB serial: CH340, VID `0x1A86`, PID `0x7523`.
- USB-C routing DIP for CH340 development: switches 1/3 ON, 2/4 OFF.
- Native USB OTG: GPIO19 is D− and GPIO20 is D+.

The serial path can change after reconnecting. Scripts discover it by USB VID/PID
instead of relying on a particular port name.

## Safety

- Back up the factory flash before the first write.
- Never connect the LED ring until its voltage, current, and signalling have
  been measured.
- Camera USB VBUS must be current-limited and switchable.
- Do not power the ring from the camera.
- Wi-Fi credentials and pairing tokens are provisioned at runtime and are not
  stored in the repository.

## First development milestone

The first flashable build is deliberately hardware-safe. It brings up the
ST7789 display, the BOOT button, Wi-Fi provisioning, mDNS, the local HTTP /
WebSocket API, rollback-capable OTA, persistent custom light presets, and a
protected-input RGB waveform probe. The signed macOS app includes direct Cam
Link preview, call detection, exposure controls, and the light editor. Camera
PTP commands and physical ring-light output remain locked until the USB host
connector and MJ33 output stages have been electrically assembled and tested.

See `firmware/README.md` and `macos/README.md` for build and run instructions.
