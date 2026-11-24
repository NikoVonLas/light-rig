# Hardware integration

## Replacement RGB strip — 2026-11-19

The firmware targets a three-channel WS2812B strip with DIN connected to IO17.
The MJ33 and T3 observations below concern the original LED board.

## RGB pin comparison — 2026-11-18

- RGB output during this test: **IO17 / GPIO17**, directly connected to the
  lamp-side green DATA wire. The user removed the 390 Ω series resistor and
  reports separate lamp power with common GND; DATA remains connected to IO17.
- IO17 is exposed on the T8 ESP32-S2 V1.1 header and is not connected to the
  display, SD card, USB host, or CH340 in the saved board schematic.
- This is a pin-isolation test. T3 timings, GRB order, frame length, brightness
  handling, and USB/Wi-Fi configuration are unchanged. Physical operation on
  IO17 has not yet been confirmed; older bench results below refer to IO18.
- IO7 was briefly flashed as an intermediate candidate; the user then selected
  IO17 instead. The IO17 build and app-only flash passed with hash verification;
  disassembly changes only GPIO 18 to 17. The board boots with RGB ready and
  previous network settings/Wi-Fi preserved. The user confirmed moving DATA to
  IO17. Red/green/blue at 15%, eight seconds each, and final OFF were acknowledged
  with healthy driver readback, but the user still observed constant cyan.
- Touching lamp-side DATA after the resistor with tweezers while the other hand
  touches GND reportedly turns the light off. This does not establish the cause.
  At the user's request, IO17 now enables internal pull-down and disables pull-up;
  initialization verifies these settings, and `lightOutput` exposes GPIO readback.
  The new build and app-only flash passed hash verification. After reconnecting
  USB, readback confirmed GPIO17, pullDown=true, pullUp=false, and lightReady=true.
  A further RGB cycle at 15%, five seconds each, followed by OFF was acknowledged;
  the user still observed constant cyan, including with the reported separate
  lamp supply. Lamp supply voltage under load and DATA waveform remain unmeasured.
- The legacy capture input remains GPIO18; capture is released before the RGB
  transmitter starts. BOOT cycles RGB colors/effects; holding for at least
  1.2 seconds and releasing turns RGB off.

## Onboarding bench — 2026-11-15

- Updated firmware on the physical LightController through CH340 at 115200 baud; esptool
  verified the written image hash. NVS was preserved. A protected backup of the
  overwritten address range 0x000000–0x19ffff is in the ignored `.artifacts/` folder.
- Higher-speed flash reads were unreliable on the current USB path; 115200-baud
  backup and programming completed successfully.
- USB handshake, stable board identity, asynchronous Wi-Fi scan (10 networks),
  unchanged network mode and RGB readiness passed on hardware.
- The macOS first-connection window appeared automatically; both USB and Wi-Fi
  choices and the populated network selector were checked visually.
- Router association and real outage recovery still need verification. The board
  currently reports `USB waiting Canon`; no camera-control commands were sent.

## Verified bench state — 2026-09-24

- Canon connected to the separate USB-A socket on GPIO19 D- / GPIO20 D+,
  VBUS from LightController 5V while LightController is powered only by Mac. Enumeration observed:
  VID:PID `04a9:32e7`, configuration 1, interface 0 alt 0 class 06/01/01.
  Bulk IN `0x81` / OUT `0x02`, max packet 64; interrupt IN `0x83`, packet 8.
  GetDeviceInfo (0x1001) and OpenSession (0x1002, session 1) now succeed on
  the physical camera: `Canon EOS M6 Mark II`, version string `3-1.0.1`,
  153 operations, 5 properties advertised in standard DeviceInfo.
  State reports `cameraConnected: true`, `CANON PTP READY`.
  EOS remote/event modes 1 now succeed; event polling reads exposure:
  f/1.4 (`0x10`), 1/40 s (`0x63`), ISO 400 (`0x58`). Camera supplied 22 aperture,
  28 shutter and 17 ISO choices. Status `EOS CONTROL READY` remains healthy.
  Verified writes AND restored original values: ISO 400→320→400, f/1.4→1.6→1.4,
  shutter 1/40→1/50→1/40, AF method face→single point→face, movie Servo On→Off→On.
  AF start/cancel and near/far step 1 returned OK (not proof of optical focus).
  AF method offers face/spot/single point/zone; movie Servo offers On/Off.
  FocusMode reports One Shot but no available choices, so remains read-only.
  Sleep/wake untested; HDMI continuity needs user confirmation.
  This does NOT validate supply margins, protection, or the future shared
  external-power circuit.

- MJ33 RGB: user confirmed T3 controls the whole ring, colors and OFF.
  GPIO18, GRB, MSB first, 512 transmitted slots (physical LED count unknown).
  Zero H/L = 0.7/1.8 us; one H/L = 1.2/1.3 us; final low reset = 300 us.
  This is an empirically working timing profile, not a confirmed chip identity.
- Green lamp-side data wire is detached from the original controller; common
  GND is required. User reports no 2.2 kohm series resistor. Do not assume
  the earlier suggested resistor divider was actually assembled.
- T3 runtime boots RGB OFF. BOOT cycles colors/effects; hold at least 1.2 s
  and release for OFF. Existing light.set RGB API uses the same output task.
- Yellow A / white B remain on the original power stage. Their control and
  dimming are NOT implemented in hardware yet; enabled CCT commands are
  rejected with A/B NOT WIRED instead of pretending to drive these channels.
- Display needs peripheral power GPIO14 HIGH as in the board vendor’s T-Display-S2 example.
  Framebuffer is now in PSRAM with an 8-row internal DMA buffer, leaving
  internal RAM for simultaneous Wi-Fi/HTTP/UART/USB-host tasks.

Older exploration below is reference, not a description of current wiring.

## Development board

LightController based on the TTGO T8 ESP32-S2 V1.1 with ST7789 240×135 display, 4 MB flash,
8 MB PSRAM, CH340C, and microSD. Flash and PSRAM sizes must be confirmed with
`esptool` before the first write.

### Display pin map

| Signal | GPIO |
| --- | ---: |
| MOSI | 35 |
| MISO | 4 |
| CLK | 36 |
| CS | 34 |
| DC | 37 |
| RESET | 38 |
| Backlight | 33 |

The usable button is BOOT on GPIO0. RST remains a hardware reset button.

## Dedicated Canon USB host connector

Keep the onboard USB-C routed to CH340 during development. Add a separate
USB-A female connector:

| USB-A | Connection |
| --- | --- |
| VBUS | protected 5 V through a current-limited high-side switch |
| D− | GPIO19 |
| D+ | GPIO20 |
| GND | common ground |

Before assembly, verify continuity and whether the exact board revision already
contains 22 Ω USB series resistors. Do not connect 5 V to a GPIO.

## Ring-light characterization gate

The lamp is marked **MJ33**. Listings for the common 33 cm version specify 5 V,
up to 3 A / 28 W, 10 brightness levels, three white-temperature modes, and RGB
effects. Some variants describe separate SMD 5050 RGBW emitters. These facts do
not establish the controller-to-ring signalling, so the gate below still
applies.

Do not remove the original controller until all of these are recorded:

1. Supply voltage and maximum current.
2. Number of wires from controller to LED assembly.
3. Idle voltage and waveforms for power, brightness, RGB, and mode buttons.
4. Controller and LED-driver IC markings.

Driver choice:

- 5 V/GND/DATA: addressable LEDs, ESP32 RMT plus 5 V level shifter.
- Independent PWM channels: logic-level MOSFET per RGB/RGBW/CCT channel.
- Two-wire polarity/current control: sized H-bridge or constant-current stage.

Do not assume WS2812/addressable signalling from the presence of animations.
Low-cost controllers commonly animate several analog RGB/CCT channels with PWM.

### Findings from the opened MJ33 controller

The ring cable has five conductors and the PCB labels/traces are visible:

| Wire | PCB label | Likely role |
| --- | --- | --- |
| Red | `+ (V)` | common +5 V |
| Green | `RGB` | digital RGB data from the controller MCU |
| Yellow | `A` | switched white channel through Q1 |
| White | `B` | switched white channel through Q2 |
| Black | `- (G)` | common ground |

This is a hybrid ring: two power PWM channels plus a separate RGB data line.
For user-defined presets and animations the production design must directly
drive A/B and RGB; merely emulating the five original buttons cannot create new
modes.

Before direct drive:

1. Measure the green-line idle/high voltage.
2. Feed it to an ESP input only through a 5 V-tolerant protection buffer.
3. Capture pulse widths while selecting static RGB and animations.
4. Confirm whether the protocol is WS2812-compatible.
5. Drive RGB through a 74AHCT125 (or equivalent 3.3→5 V buffer) and 220–470 Ω
   series resistor; drive A/B with correctly sized external logic-level
   MOSFETs. Do not pass LED current through LightController.

Firmware capture input is GPIO18. For the universal 3.3/5 V probe, use an
SN74LVC1G17 powered from LightController 3V3: controller RGB → A, Y → GPIO18, and common
GND. Add a 100 nF capacitor directly between the buffer's VCC and GND. Its input
is specified as tolerant to 5.5 V; never connect the unknown RGB line directly
to the ESP32-S2. Send `light.captureStart`, then select one mode on the original
controller. The next `rig.state` reports symbol count, minimum/maximum pulse
width, and a preliminary `ws2812Like` classification.

The firmware already implements the preset/effect layer independently of the
original controller: six persistent slots, arbitrary RGB values, A/B balance,
brightness, speed, and four effects. Once the green-line protocol is confirmed,
only the final frame-output backend needs to be enabled; custom modes do not
depend on the five original buttons.

## Power architecture

Use one external USB-C PD supply and a 15 V PD trigger. Split this into an
independently fused camera rail and a 5 V ESP/light/USB rail. Set the camera rail
only after reading the existing dummy-battery adapter label and confirming
polarity. Size each rail from measured load plus 30% headroom.
