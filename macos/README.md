# macOS controller

Native SwiftUI menu-bar application. It discovers `canonrig.local`, controls the
rig over WebSocket, and detects calls from public CoreAudio/CoreMediaIO state;
it never records audio or video.

```sh
cd macos
swift test
swift run CanonRig
```

Light automation follows system-wide video capture, including the Canon Rig preview.
It stays active until the last video consumer releases the camera.
Detection is debounced for two seconds on entry and three seconds on exit.
The call-light toggle is in the menu bar panel. The app polls video activity only.

The interface exposes one light profile, “Созвон”, without a preset list.
“Сохранить свет для созвонов” stores it in the previously selected call slot
(wire index 3 by default), preserving existing board presets behind the scenes.
The editor reads the stored color from the controller. It confirms a save after
the controller commits the preset and returns matching color, brightness and effect.
Color, brightness, and effect edits apply live (latest value every 150 ms,
including while dragging). Editing turns RGB on; OFF cancels pending edits.
Preset loading and automatic call transitions also cancel pending edits so
an old slider update cannot override them. Saving a persistent preset is still
explicit; editing alone never writes NVS.
Automation resends current state after reconnection or being re-enabled.
Turning automation off leaves manual light control available.

The Mac chooses its connection automatically. It prefers an available USB serial
connection, then tries the last known router IP, `canonrig.local`, and the LightController
access-point address. Only a valid `rig.state` reply confirms the connection.
Silent/failed routes have a retry cooldown so they cannot block other routes.
Plugging in USB takes priority; unplugging it resumes network discovery. Camera
commands interrupted by a disconnect are never automatically replayed.

On the first confirmed USB connection to each board, a dedicated setup window
opens automatically. Completion is stored per stable board ID on this Mac;
closing an unfinished tour suppresses it for this session and resumes it on the
next launch. Settings also offers a manual restart of the setup flow.

The flow offers Wi-Fi or USB, scans WPA2/WPA3 personal networks through the board
(with manual SSID entry for older firmware/hidden networks), and waits for a
correlated configuration acknowledgement plus a post-reboot Wi-Fi/IP report from
the same board. A 90-second timeout offers retry or USB; no passwords or camera
commands are automatically replayed. After confirmed Wi-Fi or choosing USB, a second screen offers an interactive tour
or immediate entry to the app. The tour runs over the real main window, highlights
preview/exposure/focus/light/automation/settings, and opens the focus and light
panels without changing device settings. Back, Next, and Finish remain available.
Only explicit skip/finish persists completion per board; closing an unfinished
window suppresses it for this launch. Settings can replay the tour over USB, Wi-Fi, or without a connected board.
An offline tour does not mark any board as configured.
The menu bar and wizard share a single native main-window controller, so starting
the tour also works when the main window has never been opened. Launching or
reopening the app brings up the control window.

For first setup, connect the board's built-in USB-C to the Mac, enter the 2.4 GHz
Wi-Fi SSID and password under Network, and save. LightController stores these in NVS and
reboots; the Mac clears the password after sending. Leave USB connected until
the app shows Wi-Fi connected and an IP, then return the board to external power.
The Mac learns the router IP from board replies. Network credentials are not
stored on the Mac. No Mac network settings are changed; to use the board's AP,
join that network manually. USB stays available in every board network mode.
Close serial monitors before using USB, and close the app before flashing.

Opening or restoring the control window starts the Cam Link preview. Closing or
minimizing it, or hiding the app, releases the capture input. The main view is a video monitor: exposure controls overlay the bottom
of the frame; focus/light panels open from the upper corners. Connection and
call-detection diagnostics are in a settings sheet instead of around the frame.
Camera controls now offer immediate selection of ISO, shutter, aperture, AF area
and video Servo AF from camera-supplied lists. No Apply button. Current values
come from camera events; writes are confirmed by readback, not guessed locally.
During a command, controls wait for its correlated result; state is polled every
250 ms, with no automatic command replay on timeout. AF start/cancel and three
near/far step sizes are available when advertised by Canon. Focus command
acceptance is not an optical focus-lock confirmation: check the Cam Link image.
For manual focus stepping, turn off video Servo to prevent automatic refocusing.
One Shot/Servo/MF remains read-only if Canon provides no choices (current bench).
A/B white channels and camera sleep/wake remain unimplemented.
Click-to-focus is still pending: camera coordinate geometry must be verified
before mapping a click in HDMI preview into Canon sensor coordinates.

The capture-process implementation is adapted from the MIT-licensed
`xbsd/avindicator` project; see `THIRD_PARTY_NOTICES.md`.
# macOS app

Build the signed local app bundle:

```sh
../scripts/build_macos_app.sh
```

The result is `.build/app/Canon Rig.app`. On first launch macOS asks for camera
permission; this is required for the direct Cam Link preview. The microphone is
not recorded: the app only reads CoreAudio process activity for diagnostics.

Interactive-tour verification (2026-11-15): Swift tests passed (33 reported,
physical USB handshake skipped); release app rebuilt and opened. All six tour
steps, real focus/light panel opening, highlights, and completion were checked
in the native app. LightController and Cam Link were unavailable during this UI check;
USB/Wi-Fi invitation transitions were verified in unit tests, not by a new
provisioning run. Firmware was unchanged. Apple Notes sync was unavailable
(get-note-content timed out).

## GitHub Releases and automatic updates

The macOS release workflow builds one DMG for Intel and Apple Silicon. Use a
stable version tag such as `v0.1.1`. Pushing the tag creates a GitHub Release
with the DMG and `appcast.xml`. Publishing a stable release in GitHub's UI also
triggers the workflow. For repositories with immutable releases enabled, push
the tag and let the workflow attach the files before publication.

The release repository's latest stable release and assets must be publicly
readable. Install the first update-enabled DMG into Applications on each Mac.
It checks the latest release feed roughly hourly while running. Sparkle verifies
the feed and downloaded DMG against the public key embedded in the app and
can install a downloaded update on quit. Open **Настройки → Обновления** to
change automatic checks and installation or check manually. Active video
(including preview) pauses checks and defers installation and relaunch. Builds made by `build_macos_app.sh` remain local builds.

Configure the repository Actions secret `SPARKLE_PRIVATE_KEY` once, using the
base64-encoded 32-byte Ed25519 seed exported by Sparkle's `generate_keys`.
Keep the original signing key in the macOS Keychain or an encrypted backup
for subsequent releases. Each build derives the public key from this secret.
The application bundle uses local ad-hoc signing. Apple Developer ID signing
and notarization are separate from update signing.
