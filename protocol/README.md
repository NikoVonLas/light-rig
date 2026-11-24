# Transports

The same v1 envelope runs over WebSocket `/ws` and CH340 USB serial at
115200 baud, 8N1, no flow control. Native ESP USB GPIO19/20 remains reserved
for the Canon host connector.

USB requests are one UTF-8 JSON object followed by LF (maximum 8192 bytes).
Responses are `@rig ` followed by JSON and LF. Ignore boot logs and lines
without that prefix. Oversized lines are dropped until LF; the next request
can succeed. Only one host application may own the serial port; close the
monitor/app before flashing. `hello` returns `rig.state` without changing light.

`network.scan` is USB-only and asynchronous. State includes optional
`wifiScan: {status: idle|scanning|ready|failed, networks: [{ssid, rssi}]}`.
Only nearby WPA2/WPA3 personal networks are listed, deduplicated by SSID, up to 16.
Missing `wifiScan` means older firmware: clients must offer manual SSID entry.
`networkSSID` reports the configured router SSID, never its password.
`homeAssistant.deviceId` is the stable board identity even with MQTT disabled.

`lightOutput` optionally reports the configured RGB `gpio`, readback `valid`,
and hardware `pullUp` / `pullDown` settings. Current output is IO17 with internal
pull-down enabled and pull-up disabled. These fields describe pad configuration,
not proof of a correct waveform or physical lamp response. The WS2812B firmware
also reports `profile`, `transport` (`spi-dma`), the completed frame count `txFrames`, and the
brightness-scaled `lastRed`, `lastGreen`, `lastBlue` of the last completed frame.

`lightEnabled` reports the current power setting, including at zero brightness.
Sending only `enabled` in `light.set` preserves the last color, brightness, speed and effect.

`callLight` reports the stored RGB call preset (red, green, blue, brightness, effect and speed).
A successful `preset.save` reply includes the preset after NVS commit. Older firmware may omit it.

`network.configure` accepts payload `mode`: `usb`, `ap`, or `router`.
For router mode, optional `ssid` and `password` must be supplied together;
omitting both reuses the board's stored credentials. Current provisioning
supports WPA2 passphrases of 8–63 bytes and SSIDs of 1–32 bytes. Credentials
are device NVS configuration, never echoed in responses or saved by the Mac
app. For AP mode an optional USB-only `apPassword` replaces the random per-device
passphrase. The USB-only `settings.read` reply includes the AP passphrase, MQTT
username and CA in `payload.usbSettings`. MQTT and router passwords are never returned.

Responses keep type `rig.state`, echo request `id`, and add `ok`, optional
`error`, and `rebooting`. `payload.networkMode` reports the current boot mode,
not the pending mode. Successful configuration saves NVS and reboots in one
second; RGB boots OFF. USB remains available in all modes. USB-only mode
does not start Wi-Fi/HTTP/mDNS at boot; a USB scan temporarily starts the radio.
HTTP OTA still needs AP or router mode.

Defaults: USB-only on a fresh board; migrate saved router credentials to
router mode if no explicit mode was stored. AP address is `192.168.4.1`;
router mode uses DHCP and `canonrig.local`. Router association failure does
not switch the Mac's network or open an unsolicited AP; recover over USB.
AP currently retains the original board-specific credentials scheme; it is
for a trusted local setup, not a secure shared-network deployment. WebSocket
and HTTP endpoints are not yet authenticated or encrypted.

## Camera discovery status

`rig.state` now includes `cameraUSBConnected`, `cameraVendorID`,
`cameraProductID`, and `cameraPTPInterface`. PTP-interface detection requires
alternate setting 0, class/subclass/protocol 06/01/01, and both bulk IN and OUT
endpoints on that same interface. For Canon, firmware claims the interface,
reads standard GetDeviceInfo and opens PTP session 1. Only successful info
parsing and an OK response to OpenSession set `cameraConnected: true`.
On the verified M6 Mark II, firmware checks
advertised operations, enables EOS remote mode 1 (`0x9114`) and event mode 1
(`0x9115`), then reads `GetEvent` (`0x9116`) once per second. Startup never
changes exposure/focus. Explicit camera commands below can now change them.
No capture, mode-dial or EVF-output commands are issued.

Additional diagnostic fields: `cameraModel`, `cameraFirmware` (raw camera
version string), `cameraOperationCount`, `cameraPropertyCount`. The counts
come from standard DeviceInfo, not a complete EOS remote-property listing.
While the Canon stays attached, a failed USB interface claim is retried every
two seconds. The camera status includes the hexadecimal ESP error code.
Disconnect cancels the retry and clears camera discovery/info fields.
While waiting, the host checks for already enumerated devices every two seconds.
`cameraUSBLineAttached` reports the ESP32-S2 port's physical connection bit,
sampled about once a second. `cameraGeneration` changes on USB discovery and
disconnect. If a device stays electrically attached without a USB device object
for ten checks, the host restarts the camera port and tries enumeration again.
An empty port with no physical attach indication gets a slower retry after
30 checks. The short read-only `GET /api/camera/link` response carries the
line, USB and PTP flags, connection generation, port restart count and status.
It also reports the number of USB host device objects (`objects`) and the
largest available internal DMA-capable block in bytes (`largestDMA`).
The ESP32-S2 USB controller uses internal DMA memory for its endpoints.
The board places eligible Wi-Fi and lwIP allocations in PSRAM to leave
space for USB discovery while the router connection is active.
Failures after the interface is claimed still require reconnecting the camera.
USB transfer timeouts cancel and drain callbacks before releasing memory.

Bench verified: EOS M6 Mark II, `3-1.0.1`, 153 operations, 5 properties,
`EOS CONTROL READY`. Current exposure verified: aperture raw `0x10` (f/1.4),
shutter `0x63` (1/40 s), ISO `0x58` (400). Available option counts: 22/28/17.

`cameraExposure` contains `aperture`, `shutter`, `iso`, `focusMode`, `afMethod`,
and `movieServo` objects. Each has:

- `raw`: Canon EOS property code value, or null when unknown. Zero is a valid
  value (Auto for exposure, One Shot for focusMode, Off for movieServo).
  These are NOT ordinary ISO numbers or aperture decimals.
- `optionsKnown`: whether the camera supplied a supported enumeration format.
- `options`: raw values supplied by the camera, up to 128 per property.

Events `0xc189` and `0xc18a` update these properties. A malformed
event block is rejected atomically; a polling error stops further transactions,
clears exposure, and reports `EOS read failed`. Disconnect clears all values.
Clients must not show stale exposure when their transport is disconnected.
Sleep/wake and the effect of continuous event polling on auto-sleep remain
untested. HDMI coexistence with EOS event mode needs visual confirmation.

Protocol reference: [libgphoto2 EOS initialization and property handling](https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/config.c),
[event layout](https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/ptp-pack.c).
Our bounded event parser is implemented independently; no libgphoto2 dependency.

## Camera control

Experimental `camera.prepareFocus` reads native AF/JPEG geometry from a single
Canon Live View frame and restores the original EVF output. `camera.focusPoint`
accepts normalized top-left `x`, `y` in `[0,1]`, only with valid geometry.
The controller selects the point, starts AF, then releases AF after one second.
All three operations must succeed for the command to return `accepted`. The
Mac client excludes letterboxing and rejects mismatched preview aspect ratios.
The Mac briefly marks the clicked position on the preview. The mark indicates
the requested point. Optical focus lock requires separate confirmation.
The M6 II has reported a 6960×4623 AF grid and a 1024×576 Live View frame.
In earlier sessions EVF outputs 3 and 2 returned DeviceBusy (`0x2019`).
Advertised operations include TouchAF,
GetViewFinderData and KeepDeviceOn, but not PowerDown or Initiate/TerminateViewfinder.
No automatic camera sleep/wake is enabled. KeepDeviceOn alone is not proof of wake.
Bench-only `camera.testEvfOff` now tests libgphoto2's EOS viewfinder-off fallback
(`EVFOutputDevice=0`) for five seconds, then restores the original output on the
firmware task even if the requesting client disconnects. It requires a known
nonzero original output and the exact M6 II model. Display stages are
`TEST EVF OFF 5s` and `TEST EVF RESTORE`. Run `scripts/camera_evf_smoke.py --port PORT`.
Actual hardware result: Canon accepted the write (`0x2001`), but subsequent EOS
events did not confirm output 0 (cached output stayed 1, EVF mode 2). Restoring
output 1 succeeded and PTP control remained ready. This is **not evidence of
sensor shutdown**, and the bench result is deliberately reported as failed.
No automatic use of this operation is enabled. Firmware build and flash hash
verification passed; network configuration was not erased.
User observation after the EVF-off test: HDMI showed the computer-connection icon
instead of live video, including in the call. Closing the Mac app did not clear
it. Unplugging Canon USB restored video; reconnecting USB briefly blinked but
retained live video. Restoring EVF output 1 alone therefore did NOT restore HDMI.
Bench-only `camera.recoverVideo` now sends RemoteMode 0 -> 1, EventMode 0 -> 1,
clears cached EOS values and reads fresh events. It does not close the session,
capture a photo, or claim physical wake. Display stage: `VIDEO REMOTE RESET`.
`scripts/camera_video_recovery_smoke.py --port PORT --cycle` tests EVF off then
recovery; omit `--cycle` for recovery only. On 2026-09-26 all recovery operations
were accepted and EOS readback returned output 1/mode 2 with USB control ready.
Actual live HDMI recovery still awaits visual confirmation. Neither command is
connected to call automation.
The user later clarified that no interruption was observed during that combined
test, so it does NOT establish an off/on cycle. For separate visual confirmation,
`camera.holdEvfOff` sends output 0 and pauses EOS polling without a timed restore.
The display shows `EVF HOLD: CHECK HDMI`. Only explicit `camera.recoverVideo`
restores the saved output and performs the remote-mode reset; ordinary camera
commands are blocked during the hold. Physical USB disconnect clears the hold.
This bench-only state is not a sensor-sleep claim and is not persisted across reboot.
Observed result of the held EVF-output-0 test: live HDMI video continued. Explicit
recovery resumed polling; the user observed a blink during the multi-command
recovery, then live video. It remains unknown which recovery step caused it.
To isolate this, `camera.testRemoteOff` / `camera.testRemoteOn` each send exactly
one Canon transaction: SetRemoteMode (0x9114) with 0 / 1. EOS polling stays paused
after either command, with `TEST REMOTE OFF` / `TEST REMOTE ON` on the display.
They do not write EVF properties, toggle EventMode, or automatically restore.
Additional user-authorized, bench-only tests: `camera.testTerminateLV` sends
0x9152 once even though this M6 II does not advertise it; `camera.testEvfModeOff`
writes EVFMode (0xd1b1)=0 only when a nonzero original mode is known, saving it
before the write. These commands do not assert sensor shutdown. Accepted tests
pause polling and await visual observation, without a timed restoration.
The mode-write test also pauses after rejection so saved-state restoration can
be handled explicitly. `camera.recoverVideo` first restores the saved property
(EVFMode or EVFOutputDevice, depending on the held test), then resets remote/event
mode. A lost transport response is not replayed; manual USB reconnect may be needed.
Actual direct-LV tests on M6 II with clean HDMI: TerminateViewfinder returned
0x2005 (OperationNotSupported), then EVFMode=0 returned 0x2019 (DeviceBusy).
Neither test established Live View shutdown. Recovery then failed when trying
to reassert saved EVFMode=2; firmware stopped camera polling and requested a
physical Canon USB reconnect. Do not describe this run as restored or ready.
After the user reconnected Canon USB, two read-only snapshots confirmed
`EOS CONTROL READY`, USB connected, polling resumed, EVFMode=2, output=1,
and exposure values/options available again. No new camera writes were sent
during that recovery verification; HDMI image still needs user observation.
Split-test observation: after `camera.testRemoteOff` returned PTP OK (0x2001),
the user confirmed the computer icon appeared on HDMI. The subsequent isolated
`camera.testRemoteOn` also returned PTP OK; visual confirmation of video return
is pending. This establishes the icon after RemoteMode=0, not sensor shutdown.
Use a separate visual observation after each command; use `camera.recoverVideo`
to return to normal control after the experiment. These are bench-only commands.
Bench-only commands `camera.pausePolling` and `camera.wake` now support testing
the native auto-off timer without EOS event traffic. Pause retains the PTP session
and does not change the camera's power timer or HDMI/EVF configuration. It reports
`cameraDiagnostics.pollingPaused=true`, not a sleeping state. Wake sends advertised
KeepDeviceOn and verifies EOS event readback before resuming polling. Physical
sleep and HDMI recovery still need observation; USB disappearance is not proof of
sleep and requires manual recovery if there is no reachable USB device. Run
`scripts/camera_idle_smoke.py --port PORT --seconds 90` with the Mac app closed.
The bench script also accepts `--timer RAW` and restores the original timer, but
only if both values are advertised by the camera. `cameraExposure.autoPowerOff`
exposes the 0xd114 value/options; `camera.set` accepts `autoPowerOff` with the same
advertised-options guard as exposure writes. The connected M6 II currently returns
raw 0 and no writable options, so a timer change from the camera menu is needed
for the native-auto-off experiment. A 10-second pause/resume test succeeded:
KeepDeviceOn and subsequent EOS event readback restored control. This was NOT a
physical sleep/wake test. The original app partition is backed up locally at
`.artifacts/pre-camera-idle-app.bin`; neither flashing step erased NVS.
Latest post-flash check also returned DeviceBusy on reasserting the existing
ISO 400; property reads still work and EVF output remains 1. This is broader
than Live View preparation: current write readiness requires further diagnosis.
Earlier successful exposure/focus bench results should not be read as a claim
that writes were successful in this latest camera state.

The Light Rig display shows mode, camera connection, exposure, AF/Servo, RGB and
last command status. Initialize the light driver before starting this display:
the screen reads light state and requires its mutex to exist.

All commands require a nonempty unique envelope `id` (max 64 chars). One command
may be queued/executing at a time. `ok:true` only acknowledges enqueueing, NOT
successful execution. Read `cameraCommand` (`id`, `status`, `message`) in state.
Statuses: `queued`, `running`, `confirmed` (property readback matches),
`accepted` (focus operation returned PTP OK, not proof of sharp focus),
`unconfirmed` (write accepted, readback not matched), or `failed`.
Only the latest result is retained. Client waits for its matching ID and never
automatically replays a timed-out write or focus action.

- `camera.set`: `{ "property": "iso", "value": 88 }`. Property names match
  `cameraExposure`; value must be an integer raw code in the camera's current
  nonempty options. Writes use `0x9110` DATA records (length/property/value),
  then check events without updating cached values optimistically.
- `camera.autofocus`: empty payload, operation `0x9154`.
- `camera.autofocusCancel`: empty payload, operation `0x9160`.
- `camera.focusStep`: `{ "direction": "near", "step": 1 }`; direction near/far,
  integer step 1–3. Operation `0x9155`, far adds `0x8000` to the step.

`cameraCapabilities`: `set`, `autofocus`, `cancelAF`, `focusStep` come from
advertised operations and session state. Advertisement alone cannot guarantee
an operation is allowed in every shooting mode; Canon rejection is reported.
Property writes additionally require a known value and camera-supplied options.
Commands run only on the USB client task. Session generation protects queued
commands from executing against a newly connected camera; USB/PTP desync stops
control until reconnection. Normal camera rejection does not destroy the session.

Bench verified and restored: ISO 400→320→400, f/1.4→f/1.6→f/1.4,
1/40→1/50→1/40, face AF→single-point→face AF, movie Servo On→Off→On.
AF start/cancel and near/far step 1 returned PTP OK; optical result needs preview.
Current focusMode reports One Shot but an empty options list, so it is read-only.
Current afMethod options are 2 (face), 10 (spot), 1 (single point), 4 (zone).

### Bundled Light Rig firmware

The macOS release includes the same ESP32-S2 application image published alongside
its DMG. Its ESP image descriptor supplies the firmware version independently of
the app version. The Mac checks the target and transfers only a newer image while
video is idle. It waits for the same device to reconnect and report the target version.

Firmware 0.2.0 advertises `firmwareTarget`, `otaProtocol: 1` and `otaProgress`.
USB serial and WebSocket use `system.ota` requests with `begin`, `write`, `finish`
and `abort`, each with a session UUID and a correlated `ack`. Writes carry an
exact byte offset and up to 1536 bytes of Base64-decoded data. One session owns the
inactive OTA partition. Incomplete transfers expire after 20 seconds. Validation
precedes boot selection. The LCD stays awake and displays progress and restart.

Legacy 0.1.0 requires a reachable router or AP for its first upload to `/api/ota`.
The Mac checks the board identity at `/health` first and shows progress. This older
firmware can first show the new update screen after reboot. Later transfers also
work with only USB. Installation preserves NVS settings and the saved call profile.
