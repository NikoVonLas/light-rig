"""Bench EVF off then remote-mode recovery. HDMI requires visual verification.

No exposure changes, capture, session close, or sensor-sleep assertions.
Without --cycle, only the recovery sequence is sent.
"""
import argparse
import json

import serial
from camera_smoke import command
from usb_smoke import request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--cycle", action="store_true")
    args = parser.parse_args()
    with serial.Serial(port=None, baudrate=115200, timeout=.2, write_timeout=2) as port:
        port.dtr = port.rts = False
        port.port = args.port
        port.open()
        initial = request(port)["payload"]
        recoverable_hold = (not args.cycle and initial.get("cameraUSBConnected")
                            and initial.get("cameraDiagnostics", {}).get("pollingPaused"))
        if not initial["cameraConnected"] and not recoverable_hold:
            raise RuntimeError("Canon not ready; no commands sent")
        print("BEFORE", json.dumps(initial["cameraDiagnostics"]), flush=True)
        try:
            if args.cycle:
                try:
                    command(port, "camera.testEvfOff", timeout=60)
                except RuntimeError as error:
                    # A completed negative EVF readback is expected on this body.
                    # A transport timeout is NOT caught/replayed.
                    print("OFF RESULT", str(error), flush=True)
        finally:
            state = request(port)["payload"]
            recoverable = state["cameraConnected"] or (state.get("cameraUSBConnected")
                          and state.get("cameraDiagnostics", {}).get("pollingPaused"))
            if recoverable and state["cameraCommand"]["status"] not in ("queued", "running"):
                command(port, "camera.recoverVideo", timeout=45)
            else:
                raise RuntimeError("Camera unavailable/busy; manual reconnect required")
        final = request(port)["payload"]
        print("AFTER", json.dumps(final["cameraDiagnostics"]), flush=True)
        print("PTP ready:", final["cameraConnected"], "HDMI live image must be checked visually", flush=True)


if __name__ == "__main__":
    main()
