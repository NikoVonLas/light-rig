"""USB integration checks. --cycle-ap changes board mode AP -> USB and reboots.

Does not change the Mac network or access/print credentials.
Run with the project's ESP-IDF Python environment (pyserial dependency).
"""
import argparse
import json
import time
import uuid

import serial


def request(port, kind="hello", payload=None, timeout=3):
    identifier = str(uuid.uuid4())
    port.write((json.dumps({"v": 1, "id": identifier, "type": kind,
                           "payload": payload or {}}) + "\n").encode())
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        line = port.readline()
        if not line.startswith(b"@rig "):
            continue
        try:
            reply = json.loads(line[5:])
        except (ValueError, UnicodeError):
            continue
        if reply.get("id") == identifier:
            return reply
    raise TimeoutError("No matching USB response")


def wait_mode(port, mode):
    until = time.monotonic() + 20
    while time.monotonic() < until:
        try:
            reply = request(port)
            if reply["payload"]["networkMode"] == mode and not reply.get("rebooting"):
                assert reply["payload"]["lightReady"]
                print(f"PASS: board mode {mode}, USB responsive, RGB ready")
                return reply
        except TimeoutError:
            pass
        time.sleep(0.2)
    raise TimeoutError(f"Board did not enter {mode}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--cycle-ap", action="store_true")
    args = parser.parse_args()
    with serial.Serial(port=None, baudrate=115200, timeout=0.2, write_timeout=2) as port:
        port.dtr = False
        port.rts = False
        port.port = args.port
        port.open()
        reply = request(port)
        assert reply["ok"] and reply["payload"]["lightReady"]
        print("PASS: hello, RGB ready; mode", reply["payload"]["networkMode"])
        reply = request(port, "network.configure", {"mode": "invalid"})
        assert reply["ok"] is False and not reply["rebooting"]
        print("PASS: invalid mode rejected without restart")
        # Exercise firmware line-overflow recovery without any command effects.
        port.write(b"x" * 8300 + b"\n")
        assert request(port)["ok"]
        print("PASS: oversized line discarded; next request succeeds")
        if args.cycle_ap:
            try:
                assert request(port, "network.configure", {"mode": "ap"})["rebooting"]
                reply = wait_mode(port, "ap")
                assert reply["payload"]["ipAddress"] == "192.168.4.1"
                print("PASS: AP initialized at 192.168.4.1 (wireless client not tested)")
            finally:
                reply = request(port, "network.configure", {"mode": "usb"}, timeout=5)
                assert reply["ok"] and reply["rebooting"]
                wait_mode(port, "usb")


if __name__ == "__main__":
    main()
