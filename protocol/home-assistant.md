# Home Assistant and two computers

Implementation is built, unit-tested and flashed to LightController (2026-09-24). USB
boot/regression checks pass; not yet validated against a real MQTT broker or
Home Assistant. The Mac application and firmware must be updated
together. Older firmware does not implement the new presence-driven automation.

## Connections

LightController owns MQTT, discovery, client leases and automatic lighting. The Mac only
detects capture activity and sends presence. USB remains available when the board
is in Router mode: Mac A can use USB and Mac B WebSocket over the router. Both Macs
can instead use WebSocket. This does not share the Cam Link video signal.

Set the board to Router mode once using its Wi-Fi settings over USB. Each Mac
chooses USB automatically when available, otherwise it discovers the board over
the network. Home Assistant requires a reachable MQTT broker, not Internet connectivity.
TLS certificate validation may additionally require working time synchronization.
No Mac network settings are changed. Board Wi-Fi retries after prolonged outages.

## Presence messages

`presence.update` payload (sent once per second):

```json
{
  "clientId": "a-per-installation-uuid",
  "name": "Work Mac",
  "session": "a-per-launch-uuid",
  "sequence": 1,
  "onCall": true,
  "cameraInCall": null,
  "automatic": true,
  "preview": true
}
```

- Two registered clients, identities/names persisted; status is never persisted.
- IDs/session: 1–36 ASCII letters, digits, hyphens or underscores; name 1–48 UTF-8 bytes.
- Same-session sequence must increase; duplicate/reordered reports do not renew leases.
- Another launch using the same client ID must wait for the old 8-second lease to expire.
- Clients are not automatically evicted. Replacing a registered Mac needs a future
  explicit unpair operation; do not erase NVS just to free a slot.
- Installation ID is kept in per-user preferences. Cloned preferences must not be
  reused by two machines; they would correctly conflict as the same client.
- `cameraInCall`: boolean or null; true without a call is invalid. Local preview
  is reported separately and also counts as video capture. The Mac bases `onCall`
  on any active video capture, with a 2-second enter and 3-second exit debounce.
  Microphone activity does not trigger light automation.

Aggregation: any fresh true wins. False only when every registered source is
fresh and false. Otherwise unknown. With no fresh clients, entities are unavailable.
Each Mac also has its own pair of entities, unavailable after its lease expires.

Automatic light turns on while at least one fresh client reports a call with
`automatic=true`, using shared saved profile slot 3. Ending one call cannot turn
off another client's automatic light. When all automatic claims end/expire,
light switches off. Explicit manual light controls remain overrides. Do not mix
old Mac builds (which directly switch light on/off on call transitions) with new ones.
LightController mode aggregates call/preview independently of automatic-light toggles.

## MQTT configuration and credentials

`homeassistant.configure` is accepted **only over USB**. For an existing broker
that does not require authentication, the settings UI can send:

```json
{"enabled":true,"host":"mqtt.example.lan","port":1883,"tls":false}
```

This is not a recommendation to disable broker authentication. Disabling the
integration uses `{"enabled":false}`. The reply confirms settings acceptance;
`homeAssistant.connected` separately confirms an MQTT connection.

Authenticated configuration additionally takes `username` and `password` and
requires `tls=true`. The controller stores the broker, optional CA, username
and password together in device NVS and reconnects after reboot. The MQTT password
is never returned. Omitting it reuses the stored password for the same host, port
and user. An empty username selects anonymous access. Disabling the integration
retains the configuration. Stock boards use unencrypted NVS.

TLS uses SNTP and the public root bundle by default. A USB client can supply
a PEM CA certificate (up to 3072 bytes) in `caPEM`. An empty value selects
the public root bundle. Plain MQTT
without credentials is appropriate only where the operator already permits it
on an isolated trusted LAN. Existing WebSocket/HTTP control is unauthenticated:
do not expose the board to the Internet or an untrusted Wi-Fi network.

## Discovery and state

Device ID derives from the LightController MAC: `canonrig_<12 hex digits>`.
Discovery: `homeassistant/binary_sensor/<device>/<entity>/config`.
Data prefix: `canonrig/<device>`. Entity keys: `call`, `camera`,
`<clientId>_call`, `<clientId>_camera`. All belong to one Canon Rig device.

- Discovery retained; regenerated on MQTT connection and HA birth (`homeassistant/status`).
- States ON/OFF/None, **not retained**, refreshed every 2 seconds, `expire_after=15`.
- Per-entity freshness availability plus shared retained device availability/LWT.
- Keepalive 10 seconds; bounded outbox, discarded on reconnect so stale call
  transitions are not replayed after outages.
- No audio/video, application names or meeting titles are published. Computer
  labels, IDs and call/camera booleans are published to the configured broker.

References: [HA MQTT discovery](https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery),
[binary sensor lifecycle](https://www.home-assistant.io/integrations/binary_sensor.mqtt/),
[Espressif MQTT](https://github.com/espressif/esp-mqtt).

## Validation

Pure C tests in `firmware/tests/test_presence_model.c` cover concurrent calls,
ending one while the other stays active, duplicate/reordered reports, conflicting
sessions, capacity, unknown camera state and source expiration. Swift tests cover
wire identity/session/sequence and tri-state camera reporting.

Bench verified after flashing: firmware hash, healthy USB replies, RGB driver
ready, Canon `EOS CONTROL READY`, presence/MQTT state, rejection of malformed
presence/configuration, oversized serial-line recovery. `scripts/presence_smoke.py`
confirmed no client slots or network/MQTT settings changed. No fake Macs registered.

Still required on hardware: two physical Mac connections; MQTT broker/HA discovery, broker reboot, LightController
power loss/LWT, HA restart and Wi-Fi outage/recovery. Do not present these as tested.
