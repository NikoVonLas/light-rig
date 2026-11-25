# Light Rig architecture

The ESP32-S2 firmware controls the light and Canon camera. It exposes the JSON wire
protocol over USB serial and `/ws` on its HTTP server. In router mode, it advertises
`_canonrig._tcp` through mDNS. The protocol contract is in `protocol/`.

The macOS application uses `RigClient` for commands and state. Automatic connection
selection prefers USB. `LocalRigDiscovery` browses Wi-Fi and Ethernet with Apple's
Network framework. DNS-SD resolves each discovered service and its IPv4 address on
the interface that advertised it. `LocalWebSocket` binds the WebSocket connection
to that interface through `NWParameters.requiredInterface`.

Path monitors supply physical interfaces for the saved-address fallback. The client
retains the previous URLSession address fallbacks for system routing. Discovery
continues across service changes. Failed endpoints have a retry cooldown. Only a
`rig.state` reply confirms a connection. The client does not replay interrupted
camera commands. USB remains available while network discovery runs.

The app declares its Bonjour service and local-network usage in `Info.plist`.
No external networking dependency or firmware change is required. Local-interface
selection does not override VPN firewall policies or Wi-Fi client isolation.
Legacy firmware HTTP uploads retain their existing URLSession transport.
