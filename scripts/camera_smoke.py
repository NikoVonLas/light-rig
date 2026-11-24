"""Explicit camera-control bench tests. Restores changed properties in finally.

--exercise changes exposure and AF settings briefly. --focus additionally moves
the lens (original optical focus distance cannot be restored exactly).
No network settings, capture, EVF output, or camera power commands are sent.
"""
import argparse
import time
import serial
from usb_smoke import request


def command(port, kind, payload=None, timeout=16):
    reply = request(port, kind, payload)
    if not reply.get("ok"):
        raise RuntimeError(reply.get("error", "Rejected"))
    identifier = reply["id"]
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        status = reply["payload"]["cameraCommand"]
        if status["id"] == identifier and status["status"] not in ("queued", "running"):
            print(kind, payload or {}, status, flush=True)
            if status["status"] not in ("confirmed", "accepted"):
                raise RuntimeError(status["message"])
            return reply
        time.sleep(0.15)
        reply = request(port)
    raise TimeoutError("Camera command result unknown; no automatic replay")


def exercise_property(port, name):
    current = request(port)["payload"]["cameraExposure"][name]
    original = current["raw"]
    alternatives = [v for v in current["options"] if v != original and (name != "iso" or v != 0)]
    if original is None or not current["optionsKnown"] or not alternatives:
        print("SKIP: no alternatives for", name, flush=True)
        return
    chosen = min(alternatives, key=lambda v: abs(v - original))
    try:
        command(port, "camera.set", {"property": name, "value": chosen})
    finally:
        command(port, "camera.set", {"property": name, "value": original})
        actual = request(port)["payload"]["cameraExposure"][name]["raw"]
        if actual != original:
            raise RuntimeError(f"RESTORE FAILED for {name}: {actual} != {original}")
        print("RESTORED", name, original, flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--exercise", action="store_true")
    parser.add_argument("--focus", action="store_true")
    parser.add_argument("--validate", action="store_true", help="Reject malformed/unsupported writes; reassert original ISO")
    args = parser.parse_args()
    with serial.Serial(port=None, baudrate=115200, timeout=0.2, write_timeout=2) as port:
        port.dtr = port.rts = False
        port.port = args.port
        port.open()
        state = request(port)["payload"]
        print({k: v for k, v in state.items() if k.startswith("camera")}, flush=True)
        if args.validate:
            for kind, payload in (
                ("camera.set", {"property": "iso", "value": "400"}),
                ("camera.set", {"property": "iso", "value": 1.5}),
                ("camera.set", {"property": "anything", "value": 1}),
                ("camera.focusStep", {"direction": "near", "step": 0}),
                ("camera.focusStep", {"direction": "up", "step": 1}),
            ):
                reply = request(port, kind, payload)
                assert reply["ok"] is False, reply
                print("REJECTED", payload, flush=True)
            original = state["cameraExposure"]["iso"]["raw"]
            try:
                command(port, "camera.set", {"property": "iso", "value": 0xffffffff})
            except RuntimeError as error:
                assert "not in the camera" in str(error), error
            else:
                raise AssertionError("Camera accepted unadvertised ISO")
            checked = request(port)["payload"]
            assert checked["cameraConnected"] and checked["cameraExposure"]["iso"]["raw"] == original
            command(port, "camera.set", {"property": "iso", "value": original})
            print("PASS: invalid commands did not alter ISO or break PTP", flush=True)
        if args.exercise:
            for name in ("iso", "aperture", "shutter", "afMethod", "movieServo"):
                exercise_property(port, name)
        if args.focus:
            command(port, "camera.autofocus")
            command(port, "camera.autofocusCancel")
            for direction in ("near", "far"):
                command(port, "camera.focusStep", {"direction": direction, "step": 1})


if __name__ == "__main__":
    main()
