"""Non-mutating USB regression for presence/MQTT. Does not register test Macs."""
import argparse
import serial
from usb_smoke import request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    args = parser.parse_args()
    with serial.Serial(port=None, baudrate=115200, timeout=0.2, write_timeout=2) as port:
        port.dtr = port.rts = False
        port.port = args.port
        port.open()
        before = request(port, timeout=8)["payload"]
        assert "presence" in before and "homeAssistant" in before
        identity = [(c["id"], c["name"]) for c in before["presence"]["clients"]]
        config = {k: before["homeAssistant"][k] for k in ("enabled", "host", "port", "tls")}
        print("PASS: new presence/MQTT state; registered clients:", len(identity))
        invalid = {"clientId": "invalid/id", "name": "Not registered", "session": "test",
                   "sequence": 1, "onCall": False, "cameraInCall": None,
                   "automatic": False, "preview": False}
        for kind, payload in (
            ("presence.update", {}),
            ("presence.update", invalid),
            ("presence.update", dict(invalid, clientId="not-registered", sequence=-1)),
            ("presence.update", dict(invalid, clientId="not-registered", cameraInCall=True)),
            ("homeassistant.configure", {"enabled": "yes"}),
            ("homeassistant.configure", {"enabled": True, "host": "bad/host", "port": 1883, "tls": False}),
            ("homeassistant.configure", {"enabled": True, "host": "invalid.example", "port": 0, "tls": False}),
        ):
            reply = request(port, kind, payload)
            assert reply["ok"] is False, kind
            print("PASS: rejected invalid", kind)
        after = request(port)["payload"]
        assert [(c["id"], c["name"]) for c in after["presence"]["clients"]] == identity
        assert {k: after["homeAssistant"][k] for k in config} == config
        assert after["networkMode"] == before["networkMode"]
        assert after["lightReady"]
        assert "password" not in after["homeAssistant"] and "username" not in after["homeAssistant"]
        print("PASS: client slots and network/MQTT configuration unchanged; RGB ready")
        print("Camera:", after["cameraStatus"])


if __name__ == "__main__":
    main()
