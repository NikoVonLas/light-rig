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
    #expect(selection.next(ports: [], host: "192.0.2.20", at: now) == .network("lightrig.local"))
    selection.failed(.network("lightrig.local"), at: now)
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

@Test @MainActor func previewClickMarksTheSamePointThatCanonReceives() throws {
    let usb = TestSerial()
    let suite = "canonrig-focus-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let client = RigClient(host: "127.0.0.1", defaults: defaults, ports: { ["/dev/cu.usbserial-test"] },
                           serialFactory: { usb }, now: { Date() })
    defer { client.disconnect() }
    client.connect()
    try usb.reply(["cameraConnected": .bool(true), "cameraCapabilities": .object(["focusPoint": .bool(true)]),
                   "cameraDiagnostics": .object(["jpegWidth": .number(1024), "jpegHeight": .number(576)])])
    let point = try #require(PreviewFocusMapping.point(x: 330, y: 120, viewWidth: 960, viewHeight: 360,
                                                       videoWidth: 1920, videoHeight: 1080))
    let aspect = 16.0 / 9
    let rect = try #require(PreviewFocusMapping.videoRect(in: CGSize(width: 960, height: 360), aspect: aspect))
    #expect(abs(rect.minX + point.x * rect.width - 330) < 1e-8)
    #expect(abs(rect.minY + point.y * rect.height - 120) < 1e-8)
    #expect(!client.focusPoint(point, videoAspect: 4.0 / 3))
    #expect(client.focusPoint(point, videoAspect: aspect))
    let message = try #require(usb.messages.last)
    #expect(message.type == "camera.focusPoint")
    #expect(message.payload["x"] == .number(point.x))
    #expect(message.payload["y"] == .number(point.y))
    #expect(!client.focusPoint(.zero, videoAspect: aspect))
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

@Test @MainActor func callLightSaveRequiresMatchingReadback() throws {
    let usb = TestSerial()
    let client = RigClient(host: "127.0.0.1", defaults: .standard, ports: { ["/dev/cu.usbserial-test"] },
                           serialFactory: { usb }, now: { Date() })
    client.connect()
    defer { client.disconnect() }
    try usb.reply()
    for matches in [false, true] {
        client.saveLightPreset(slot: 3, name: "Созвон", enabled: true, brightness: 69, mode: "rgb",
                               red: 255, green: 157, blue: 64, warm: 65, cool: 65, effect: "solid", speed: 40)
        let sent = try #require(usb.messages.last)
        var stored = sent.payload
        if !matches { stored["green"] = .number(0) }
        var reply = WireEnvelope(id: sent.id, type: "rig.state", payload: ["callLight": .object(stored)])
        reply.ok = true
        client.accept(try JSONEncoder().encode(reply))
        #expect(client.state.callLight?.green == (matches ? 157 : 0))
        #expect(client.profileNotice == (matches ? "Профиль «Созвон» сохранён на Light Rig"
                                                : "Light Rig вернул другой профиль. Повтори сохранение."))
    }
}

@Test @MainActor func toggleLightOffAndBackOnDuringOneCall() throws {
    let usb = TestSerial()
    let client = RigClient(host: "127.0.0.1", defaults: .standard, ports: { ["/dev/cu.usbserial-test"] },
                           serialFactory: { usb }, now: { Date() })
    client.connect()
    defer { client.disconnect() }
    for enabled in [true, false] {
        try usb.reply(["mode": .string("on_call"), "lightReady": .bool(true), "lightEnabled": .bool(enabled),
                       "lightOutput": .object(["lastRed": .number(0), "lastGreen": .number(0), "lastBlue": .number(0)])])
        #expect(client.state.lightEnabled == enabled)
        client.toggleLightPower()
        let sent = try #require(usb.messages.last)
        #expect(sent.type == "light.set")
        #expect(sent.payload == ["enabled": .bool(!enabled)])
    }
    for red in [0, 175] {
        try usb.reply(["lightReady": .bool(true), "lightOutput": .object([
            "lastRed": .number(Double(red)), "lastGreen": .number(0), "lastBlue": .number(0), "txFrames": .number(8)])])
        #expect(client.state.lightEnabled == (red > 0))
    }
}

@Test @MainActor func relaunchRestoresStoredPresetOnceAfterBoardAcceptsActiveVideo() throws {
    let usb = TestSerial()
    let client = RigClient(host: "127.0.0.1", defaults: .standard, ports: { ["/dev/cu.usbserial-test"] },
                           serialFactory: { usb }, now: { Date() })
    client.connect()
    defer { client.disconnect() }
    let board: [String: JSONValue] = ["homeAssistant": .object(["deviceId": .string("test-board")]),
        "mode": .string("on_call"), "lightReady": .bool(true), "lightEffect": .string("rainbow")]
    try usb.reply(board)
    var reporter = PresenceReporter(clientID: "test-mac", name: "Mac")
    for (accepted, expectedCount) in [(false, 0), (true, 1), (true, 1)] {
        let message = reporter.envelope(onCall: true, cameraInCall: true, automatic: true, preview: true)
        client.sendPresence(message)
        var reply = WireEnvelope(id: message.id, type: "rig.state", payload: board)
        reply.ok = accepted
        client.accept(try JSONEncoder().encode(reply))
        let restores = usb.messages.filter { $0.type == "light.applyPreset" }
        #expect(restores.count == expectedCount)
        if let restore = restores.first { #expect(restore.payload["slot"] == .number(3)) }
    }
}

@Test @MainActor func returningFromSettingsReappliesStoredLightOnce() throws {
    let usb = TestSerial()
    let client = RigClient(host: "127.0.0.1", defaults: .standard, ports: { ["/dev/cu.usbserial-test"] },
                           serialFactory: { usb }, now: { Date() })
    client.connect()
    defer { client.disconnect() }
    var reporter = PresenceReporter(clientID: "mac", name: "Mac")
    for (active, count) in [(true, 1), (false, 1), (true, 2), (true, 2)] {
        let state: [String: JSONValue] = ["homeAssistant": .object(["deviceId": .string("board")]),
            "presence": .object(["onCall": .bool(active)]), "lightReady": .bool(true)]
        try usb.reply(state)
        let message = reporter.envelope(onCall: active, cameraInCall: active, automatic: true, preview: active)
        client.sendPresence(message)
        var reply = WireEnvelope(id: message.id, type: "rig.state", payload: state)
        reply.ok = true
        client.accept(try JSONEncoder().encode(reply))
        #expect(usb.messages.filter { $0.type == "light.applyPreset" }.count == count)
    }
}

@Test @MainActor func firmwareTransfersThroughUSBAndConfirmsVersionAfterReconnect() async throws {
    let usb = TestSerial()
    var now = Date()
    let suite = "firmware-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let client = RigClient(host: nil, defaults: defaults, ports: { ["/dev/cu.usbserial-test"] },
                           serialFactory: { usb }, now: { now })
    client.connect()
    defer { client.disconnect() }
    let image = try #require(testFirmwareImage())
    let updates = ControllerFirmware(client: client, image: image, defaults: defaults, now: { now })
    var board: [String: JSONValue] = ["homeAssistant": .object(["deviceId": .string("test-board")]),
        "otaProtocol": .number(1), "firmware": .string("0.1.0"), "firmwareTarget": .string("Light-Rig-esp32s2")]
    try usb.reply(board)
    updates.observe(videoActive: true)
    now.addTimeInterval(10)
    updates.observe(videoActive: true)
    #expect(!client.firmwareTransferActive)
    updates.observe(videoActive: false)
    now.addTimeInterval(5)
    updates.observe(videoActive: false)
    var consumed = Set<String>()
    var received = Data()
    var stages = [String]()
    for _ in 0..<200 {
        try await Task.sleep(for: .milliseconds(10))
        if let command = usb.messages.last, command.type == "system.ota", consumed.insert(command.id).inserted {
            guard case .string(let op) = command.payload["op"] else { Issue.record("missing op"); return }
            stages.append(op)
            if op == "write" {
                #expect(command.payload["offset"] == .number(Double(received.count)))
                guard case .string(let base64) = command.payload["data"] else { Issue.record("missing chunk"); return }
                received.append(try #require(Data(base64Encoded: base64)))
            }
            var ack = WireEnvelope(id: command.id, type: "ack")
            ack.ok = true
            client.accept(try JSONEncoder().encode(ack))
            if op == "finish" {
                client.disconnect()
                client.connect()
                board["firmware"] = .string(image.version)
                try usb.reply(board)
            }
        }
        if !client.firmwareTransferActive { break }
    }
    #expect(stages == ["begin", "write", "write", "finish"])
    #expect(received == image.bytes)
    #expect(!client.firmwareTransferActive)
    #expect(!updates.canRetry)
    updates.observe(videoActive: false)
    #expect(!client.firmwareTransferActive)
}
