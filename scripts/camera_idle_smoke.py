"""Bench test only: pause EOS event polling, then restore it with KeepDeviceOn.

Does not assert physical sleep from host inactivity. No exposure/EVF settings
are changed. Optional --timer uses only camera-advertised values and restores
the original timer in finally. Keep Light Rig closed while this owns serial.
"""
import argparse
import json
import time

import serial
from camera_smoke import command
from usb_smoke import request


def report(state):
    return {key: state.get(key) for key in (
        "cameraConnected", "cameraUSBConnected", "cameraStatus", "cameraDiagnostics")}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--seconds", type=int, default=90)
    parser.add_argument("--timer", type=int, help="Temporary raw autoPowerOff value (must be advertised)")
    args = parser.parse_args()
    if not 10 <= args.seconds <= 660:
        parser.error("--seconds must be between 10 and 660")
    with serial.Serial(port=None, baudrate=115200, timeout=0.2, write_timeout=2) as port:
        port.dtr = port.rts = False
        port.port = args.port
        port.open()
        initial = request(port)["payload"]
        if not initial["cameraConnected"]:
            raise RuntimeError("Canon must be connected and ready before the test")
        print("BEFORE", json.dumps(report(initial)), flush=True)
        armed = False
        restore_timer = None
        try:
            if args.timer is not None:
                timer = initial.get("cameraExposure", {}).get("autoPowerOff", {})
                original = timer.get("raw")
                if (not timer.get("optionsKnown") or args.timer not in timer.get("options", [])
                        or original not in timer.get("options", [])):
                    raise RuntimeError("Timer values/restoration not advertised by camera; no changes made")
                if args.timer != original:
                    restore_timer = original
                    command(port, "camera.set", {"property": "autoPowerOff", "value": args.timer})
            # Arm restoration before sending, in case the reply is lost.
            armed = True
            command(port, "camera.pausePolling")
            started = time.monotonic()
            while time.monotonic() - started < args.seconds:
                time.sleep(max(0, min(5, args.seconds - (time.monotonic() - started))))
                state = request(port)["payload"]  # Board snapshot only; no Canon USB transaction.
                print("IDLE", round(time.monotonic() - started), json.dumps(report(state)), flush=True)
                if not state["cameraUSBConnected"]:
                    print("USB disappeared; this does not prove sleep or a software wake path", flush=True)
                    break
        finally:
            if armed or restore_timer is not None:
                state = request(port)["payload"]
                if state["cameraUSBConnected"] and state.get("cameraDiagnostics", {}).get("pollingPaused"):
                    command(port, "camera.wake")
                    restored = request(port)["payload"]
                    print("RESTORED", json.dumps(report(restored)), flush=True)
                    if not restored["cameraConnected"]:
                        raise RuntimeError("Camera control not restored")
                elif not state["cameraConnected"]:
                    raise RuntimeError("Camera requires manual wake/reconnect; no automatic wake verified")
                if restore_timer is not None:
                    command(port, "camera.set", {"property": "autoPowerOff", "value": restore_timer})
                    actual = request(port)["payload"]["cameraExposure"]["autoPowerOff"]["raw"]
                    if actual != restore_timer:
                        raise RuntimeError("Original auto-off timer restoration not confirmed")
                    print("TIMER RESTORED", actual, flush=True)


if __name__ == "__main__":
    main()
