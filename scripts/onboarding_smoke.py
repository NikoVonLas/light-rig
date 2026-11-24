"""Read-only board checks plus a Wi-Fi scan; never provision or print credentials."""
import argparse
import time

import serial

from usb_smoke import request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    args = parser.parse_args()
    with serial.Serial(port=None, baudrate=115200, timeout=.2, write_timeout=2) as port:
        port.dtr = port.rts = False
        port.port = args.port
        port.open()
        deadline = time.monotonic() + 25
        while True:
            try:
                before = request(port)["payload"]
                break
            except TimeoutError:
                if time.monotonic() >= deadline:
                    raise
        assert before["homeAssistant"]["deviceId"]
        assert before["lightReady"]
        assert "wifiScan" in before
        assert request(port, "network.scan")["ok"]
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            state = request(port)["payload"]
            scan = state["wifiScan"]
            if scan["status"] == "failed":
                raise AssertionError("Board Wi-Fi scan failed")
            if scan["status"] == "ready":
                break
            time.sleep(.4)
        else:
            raise TimeoutError("Board Wi-Fi scan did not finish")
        networks = scan["networks"]
        assert len(networks) <= 16
        assert len({n["ssid"] for n in networks}) == len(networks)
        assert state["networkMode"] == before["networkMode"]
        assert state["lightReady"]
        assert state["homeAssistant"]["deviceId"] == before["homeAssistant"]["deviceId"]
        print("PASS: USB handshake, stable board identity, Wi-Fi scan, mode preserved, RGB ready")
        print("Networks found:", len(networks))
        print("Camera:", state["cameraStatus"], "Wi-Fi connected:", state["wifiConnected"])


if __name__ == "__main__":
    main()
