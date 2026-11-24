import Foundation
import Testing
@testable import CanonRigCore

@Test func autoConnectionPrefersUSBAndFallsBackAfterUnplug() {
    var selection = RigConnectionSelection()
    let now = Date(timeIntervalSince1970: 100)
    let usb = RigEndpoint.usb("/dev/cu.usbserial-test")
    #expect(selection.next(ports: ["/dev/cu.usbserial-test"], host: "192.0.2.20", at: now) == usb)
    selection.succeeded(usb)
    #expect(selection.next(ports: [], host: "192.0.2.20", at: now) == .network("192.0.2.20"))
    #expect(selection.preferredUSB(ports: ["/dev/cu.usbserial-130"], at: now) == .usb("/dev/cu.usbserial-130"))
}

@Test func unresponsiveUSBDoesNotHideWorkingNetwork() {
    var selection = RigConnectionSelection()
    let now = Date(timeIntervalSince1970: 100)
    selection.failed(.usb("/dev/cu.usbserial-test"), at: now)
    #expect(selection.next(ports: ["/dev/cu.usbserial-test"], host: "canonrig.local", at: now) == .network("canonrig.local"))
    #expect(selection.preferredUSB(ports: ["/dev/cu.usbserial-test"], at: now.addingTimeInterval(20)) == nil)
    #expect(selection.preferredUSB(ports: ["/dev/cu.usbserial-test"], at: now.addingTimeInterval(31)) != nil)
}

@Test func changedDHCPAddressFallsBackToNameThenAccessPoint() {
    var selection = RigConnectionSelection()
    let now = Date(timeIntervalSince1970: 100)
    selection.failed(.network("192.0.2.20"), at: now)
    #expect(selection.next(ports: [], host: "192.0.2.20", at: now) == .network("canonrig.local"))
    selection.failed(.network("canonrig.local"), at: now)
    #expect(selection.next(ports: [], host: "192.0.2.20", at: now) == .network("192.168.4.1"))
    selection.failed(.network("192.168.4.1"), at: now)
    #expect(selection.next(ports: [], host: "192.0.2.20", at: now) == nil)
    #expect(selection.next(ports: [], host: "192.0.2.20", at: now.addingTimeInterval(31)) == .network("192.0.2.20"))
    selection.succeeded(.network("canonrig.local"))
    #expect(selection.next(ports: [], host: "canonrig.local", at: now) == .network("canonrig.local"))
}

@Test @MainActor func defaultConnectionIsAutomaticAndMQTTNeedsRealUSB() {
    let client = RigClient(host: "canonrig.local")
    #expect(client.connectionMode == .automatic)
    client.configureHomeAssistant(enabled: false, host: "", port: 8883, tls: true)
    #expect(client.lastError == "Настройка MQTT доступна по USB")
}

@MainActor private final class TestSerial: RigSerialConnection {
    var onMessage: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    var opened: [String] = []
    var messages: [WireEnvelope] = []
    var closed = false
    func open(_ path: String) throws { opened.append(path); closed = false }
    func close() { closed = true }
    func send(_ data: Data) {
        if let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data) { messages.append(envelope) }
    }
    func reply(_ payload: [String: JSONValue] = [:]) throws {
        onMessage?(try JSONEncoder().encode(WireEnvelope(type: "rig.state", payload: payload)))
    }
}

@Test @MainActor func clientSwitchesFromUSBToNetworkAndBackWithoutReplayingCameraCommands() throws {
    let suite = "canonrig-auto-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var ports = ["/dev/cu.usbserial-test"]
    var time = Date(timeIntervalSince1970: 100)
    var transports: [TestSerial] = []
    let client = RigClient(host: "127.0.0.1", defaults: defaults, ports: { ports }, serialFactory: {
        let transport = TestSerial(); transports.append(transport); return transport
    }, now: { time })
    defer { client.disconnect() }
    client.connect()
    #expect(client.activeConnectionMode == .usb)
    #expect(!client.isConnected) // An opened port is not a handshake.
    let usb = try #require(transports.first)
    try usb.reply(["networkMode": .string("router"), "wifiConnected": .bool(true),
                   "ipAddress": .string("127.0.0.1"), "cameraConnected": .bool(true),
                   "cameraCapabilities": .object(["autofocus": .bool(true)])])
    #expect(client.isConnected)
    #expect(defaults.string(forKey: "rigLastRouterIP") == "127.0.0.1")
    client.autofocus()
    #expect(client.pendingCameraID != nil)
    ports = []
    time = time.addingTimeInterval(1)
    client.maintainConnection()
    #expect(usb.closed)
    #expect(client.activeConnectionMode == .router)
    #expect(!client.isConnected && client.pendingCameraID == nil)
    #expect(client.cameraNotice?.contains("результат команды неизвестен") == true)
    // Late replies from the old transport must not confirm a new connection.
    try usb.reply()
    #expect(!client.isConnected)
    ports = ["/dev/cu.usbserial-test"]
    client.maintainConnection()
    #expect(client.activeConnectionMode == .usb)
    #expect(transports.count == 2)
    #expect(transports[1].messages.map(\.type) == ["hello"])
    try transports[1].reply()
    #expect(client.isConnected && client.connectionLabel == "USB")
}

@Test @MainActor func silentSerialTimesOutAndNetworkRemainsDiscoverable() throws {
    let suite = "canonrig-auto-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var time = Date(timeIntervalSince1970: 100)
    let usb = TestSerial()
    let client = RigClient(host: "127.0.0.1", defaults: defaults,
                          ports: { ["/dev/cu.usbserial-silent"] }, serialFactory: { usb }, now: { time })
    defer { client.disconnect() }
    client.connect()
    time = time.addingTimeInterval(6)
    client.maintainConnection()
    #expect(usb.closed && !client.isConnected)
    client.maintainConnection()
    #expect(client.activeConnectionMode == .router)
    #expect(usb.opened.count == 1)
}

@Test @MainActor func wifiSetupRequiresAcknowledgementAndFreshConnectionAfterReboot() throws {
    let suite = "canonrig-wifi-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let usb = TestSerial()
    var time = Date(timeIntervalSince1970: 100)
    let client = RigClient(host: "127.0.0.1", defaults: defaults,
                          ports: { ["/dev/cu.usbserial-test"] }, serialFactory: { usb }, now: { time })
    defer { client.disconnect() }
    client.connect()
    let initial: [String: JSONValue] = ["homeAssistant": .object(["deviceId": .string("board-a")]),
                                       "networkMode": .string("usb")]
    try usb.reply(initial)
    #expect(client.configureNetwork(mode: "router", ssid: "Example", password: "example-test-only"))
    let request = try #require(usb.messages.last)
    #expect(client.networkSetupStatus == .sending)
    try usb.reply(initial)
    #expect(client.networkSetupStatus == .sending)
    var ack = WireEnvelope(id: request.id, type: "rig.state", payload: initial)
    ack.ok = true; ack.rebooting = true
    client.accept(try JSONEncoder().encode(ack))
    #expect(client.networkSetupStatus == .waiting && !client.isConnected)
    var connected = initial
    connected["networkMode"] = .string("router")
    connected["networkSSID"] = .string("Example")
    connected["wifiConnected"] = .bool(false)
    client.connect()
    try usb.reply(connected)
    #expect(client.networkSetupStatus == .waiting)
    connected["wifiConnected"] = .bool(true)
    connected["ipAddress"] = .string("127.0.0.1")
    connected["homeAssistant"] = .object(["deviceId": .string("board-b")])
    try usb.reply(connected)
    #expect(client.networkSetupStatus == .waiting)
    connected["homeAssistant"] = .object(["deviceId": .string("board-a")])
    try usb.reply(connected)
    #expect(client.networkSetupStatus == .connected)
    client.cancelNetworkSetup()
    #expect(client.configureNetwork(mode: "router", ssid: "Example", password: "example-test-only"))
    time = time.addingTimeInterval(91)
    client.maintainConnection()
    if case .failed = client.networkSetupStatus {} else { Issue.record("Wi-Fi timeout must remain actionable") }
    #expect(usb.messages.filter { $0.type == "network.configure" }.count == 2)
}

@Test @MainActor func privateBoardSettingsRequireUSBAndMatchingReply() throws {
    let usb = TestSerial()
    let suite = "canonrig-settings-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let client = RigClient(host: "127.0.0.1", defaults: defaults, ports: { ["/dev/cu.usbserial-test"] },
                           serialFactory: { usb }, now: { Date() })
    defer { client.disconnect() }
    client.connect()
    var state: [String: JSONValue] = ["homeAssistant": .object([
        "deviceId": .string("board-test"), "credentialsPersistent": .bool(true)
    ])]
    try usb.reply(state)
    client.readUSBSettings()
    let request = try #require(usb.messages.last)
    #expect(request.type == "settings.read")
    state["usbSettings"] = .object(["username": .string("example")])
    try usb.reply(state)
    #expect(client.usbSettings == nil)
    var ack = WireEnvelope(id: request.id, type: "rig.state", payload: state)
    ack.ok = true
    client.accept(try JSONEncoder().encode(ack))
    #expect(client.usbSettings?["username"] == .string("example"))
    client.configureHomeAssistant(enabled: true, host: "mqtt.example.org", port: 8883, tls: true, username: "example")
    let save = try #require(usb.messages.last)
    #expect(save.type == "homeassistant.configure")
    #expect(save.payload["password"] == nil)
    #expect(save.payload["username"] == .string("example"))
    client.disconnect()
    #expect(client.usbSettings == nil)
}
