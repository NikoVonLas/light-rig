"""Explicit five-second EVF-off bench test; firmware restores original output.

No sensor-power claim is made. Keep Canon Rig closed during this test.
"""
import argparse
import json
import time

import serial
from usb_smoke import request


def report(state):
    return {k: state.get(k) for k in (
        "cameraConnected", "cameraStatus", "cameraDiagnostics", "cameraCommand")}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    args = parser.parse_args()
    with serial.Serial(port=None, baudrate=115200, timeout=.2, write_timeout=2) as port:
        port.dtr = port.rts = False
        port.port = args.port
        port.open()
        before = request(port)["payload"]
        print("BEFORE", json.dumps(report(before)), flush=True)
        if not before["cameraConnected"]:
            raise RuntimeError("Canon not ready; nothing changed")
        reply = request(port, "camera.testEvfOff")
        if not reply.get("ok"):
            raise RuntimeError(reply.get("error"))
        identifier = reply["id"]
        until = time.monotonic() + 60
        while time.monotonic() < until:
            state = request(port)["payload"]
            status = state["cameraCommand"]
            print("STATE", json.dumps(report(state)), flush=True)
            if status["id"] == identifier and status["status"] not in ("queued", "running"):
                if status["status"] != "confirmed":
                    raise RuntimeError(status["message"])
                if (state["cameraDiagnostics"]["evfOutput"] != before["cameraDiagnostics"]["evfOutput"]
                        or not state["cameraConnected"]):
                    raise RuntimeError("Original EVF output/control not restored")
                return
            time.sleep(1)
        raise TimeoutError("Test result unknown; check camera before retrying")


if __name__ == "__main__":
    main()
