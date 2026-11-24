import Foundation
import Testing
@testable import CanonRigCore

@Test func presenceReportsIdentitySequenceAndUnknownVideo() {
    var a = PresenceReporter(clientID: "mac-a", name: String(repeating: "я", count: 40))
    var b = PresenceReporter(clientID: "mac-b", name: "Mac B")
    #expect(a.name.utf8.count <= 48)
    let first = a.envelope(onCall: true, cameraInCall: nil, automatic: true, preview: true)
    let next = a.envelope(onCall: false, cameraInCall: nil, automatic: false, preview: true)
    let other = b.envelope(onCall: true, cameraInCall: true, automatic: true, preview: false)
    #expect(first.type == "presence.update")
    #expect(first.payload["cameraInCall"] == .null)
    #expect(next.payload["cameraInCall"] == .bool(false))
    #expect(next.payload["sequence"] == .number(2))
    #expect(first.payload["session"] == next.payload["session"])
    #expect(first.payload["session"] != other.payload["session"])
    #expect(other.payload["clientId"] == .string("mac-b"))
}

@Test func presenceAndBrokerReadbackKeepUnknownDistinctFromOff() {
    let state = RigState(envelope: WireEnvelope(type: "rig.state", payload: [
        "presence": .object(["available": .bool(true), "onCall": .bool(true), "cameraInCall": .null,
            "clients": .array([.object(["id": .string("mac-a"), "name": .string("Mac A"),
                "available": .bool(false), "onCall": .null, "cameraInCall": .null])])]),
        "homeAssistant": .object(["enabled": .bool(true), "connected": .bool(false),
            "needsCredentials": .bool(true), "requiresAuth": .bool(true), "port": .number(8883), "tls": .bool(true)])
    ]))
    #expect(state.supportsPresence && state.presenceAvailable && state.aggregateCall == true)
    #expect(state.aggregateCamera == nil)
    #expect(state.presenceClients.first?.available == false)
    #expect(state.presenceClients.first?.onCall == nil)
    #expect(state.haEnabled && !state.haConnected && state.haNeedsCredentials && state.haRequiresAuth)
    #expect(state.haPort == 8883 && state.haTLS)
    #expect(!RigState(envelope: WireEnvelope(type: "rig.state")).supportsPresence)
}

@Test func previewFocusIgnoresLetterboxing() {
    func point(_ x: Double, _ y: Double) -> CGPoint? {
        PreviewFocusMapping.point(x: x, y: y, viewWidth: 1000, viewHeight: 1000,
                                  videoWidth: 1920, videoHeight: 1080)
    }
    #expect(point(500, 500) == CGPoint(x: 0.5, y: 0.5))
    #expect(abs((point(0, 218.75)?.y ?? 999)) < 1e-12)
    #expect(abs((point(1000, 781.25)?.y ?? 999) - 1) < 1e-12)
    #expect(point(500, 100) == nil)
    #expect(point(500, 900) == nil)
    #expect(point(.nan, 500) == nil)
    #expect(PreviewFocusMapping.point(x: 0, y: 0, viewWidth: 0, viewHeight: 100,
                                      videoWidth: 1920, videoHeight: 1080) == nil)
}

@Test func focusModesAndCapabilitiesDecodeWithoutInventingChoices() {
    let state = RigState(envelope: WireEnvelope(type: "rig.state", payload: [
        "cameraConnected": .bool(true),
        "cameraCapabilities": .object(["set": .bool(true), "autofocus": .bool(true), "focusStep": .bool(true)]),
        "cameraExposure": .object([
            "focusMode": .object(["raw": .number(0), "optionsKnown": .bool(true), "options": .array([])]),
            "movieServo": .object(["raw": .number(0), "optionsKnown": .bool(true), "options": .array([.number(0), .number(1)])])
        ])
    ]))
    #expect(state.cameraCanSet && state.cameraCanAF && state.cameraCanFocusStep)
    #expect(!state.cameraCanCancelAF)
    #expect(state.cameraFocusMode.options.isEmpty)
    #expect(CameraExposureKind.focusMode.label(state.cameraFocusMode.raw) == "One Shot")
    #expect(CameraExposureKind.movieServo.label(state.cameraMovieServo.raw) == "Выкл.")
    #expect(CameraExposureKind.afMethod.label(10) == "Точечный AF")
    #expect(!RigState(envelope: WireEnvelope(type: "rig.state")).cameraCanSet)
}

@Test @MainActor func cameraWriteWaitsForCorrelatedConfirmation() throws {
    let client = RigClient()
    var payload: [String: JSONValue] = [
        "cameraConnected": .bool(true), "cameraCapabilities": .object(["set": .bool(true)]),
        "cameraExposure": .object(["iso": .object(["raw": .number(88), "optionsKnown": .bool(true),
            "options": .array([.number(88), .number(91)])])])
    ]
    client.accept(try JSONEncoder().encode(WireEnvelope(type: "rig.state", payload: payload)))
    client.cameraSet(kind: .iso, property: client.state.cameraISO, value: 91)
    let identifier = try #require(client.pendingCameraID)
    #expect(client.cameraBusy)
    #expect(client.state.cameraISO.raw == 88) // No optimistic fake readback.
    payload["cameraCommand"] = .object(["id": .string("someone-else"), "status": .string("confirmed")])
    client.accept(try JSONEncoder().encode(WireEnvelope(type: "rig.state", payload: payload)))
    #expect(client.pendingCameraID == identifier)
    payload["cameraCommand"] = .object(["id": .string(identifier), "status": .string("confirmed")])
    payload["cameraExposure"] = .object(["iso": .object(["raw": .number(91)])])
    client.accept(try JSONEncoder().encode(WireEnvelope(type: "rig.state", payload: payload)))
    #expect(client.pendingCameraID == nil && !client.cameraBusy)
    #expect(client.state.cameraISO.raw == 91)
    #expect(client.cameraNotice == "Изменение подтверждено камерой")
    client.disconnect()
}

@Test @MainActor func cameraWriteRejectsUnavailableValueAndReportsErrors() throws {
    let client = RigClient()
    let payload: [String: JSONValue] = ["cameraConnected": .bool(true),
        "cameraCapabilities": .object(["set": .bool(true), "autofocus": .bool(true)])]
    client.accept(try JSONEncoder().encode(WireEnvelope(type: "rig.state", payload: payload)))
    client.cameraSet(kind: .iso, property: CameraProperty(), value: 91)
    #expect(client.pendingCameraID == nil)
    client.autofocus()
    let identifier = try #require(client.pendingCameraID)
    var rejection = WireEnvelope(id: identifier, type: "rig.state", payload: payload)
    rejection.ok = false
    rejection.error = "camera command busy"
    client.accept(try JSONEncoder().encode(rejection))
    #expect(client.pendingCameraID == nil)
    #expect(client.cameraNotice == "camera command busy")
    client.disconnect()
}

@Test func eosExposureValuesAreReadFromCamera() {
    let payload: [String: JSONValue] = [
        "cameraConnected": .bool(true), "cameraModel": .string("Canon EOS M6 Mark II"),
        "cameraExposure": .object([
            "aperture": .object(["raw": .number(16), "optionsKnown": .bool(true), "options": .array([.number(16), .number(19)])]),
            "shutter": .object(["raw": .number(99)]),
            "iso": .object(["raw": .number(88)])
        ])
    ]
    let state = RigState(envelope: WireEnvelope(type: "rig.state", payload: payload))
    #expect(CameraExposureKind.aperture.label(state.cameraAperture.raw) == "f/1.4")
    #expect(CameraExposureKind.shutter.label(state.cameraShutter.raw) == "1/40 с")
    #expect(CameraExposureKind.iso.label(state.cameraISO.raw) == "400")
    #expect(state.cameraAperture.options == [16, 19])
    #expect(state.cameraAperture.optionsKnown)
    #expect(!state.cameraISO.optionsKnown)
    var disconnected = payload
    disconnected["cameraConnected"] = .bool(false)
    #expect(RigState(envelope: WireEnvelope(type: "rig.state", payload: disconnected)).cameraISO.raw == nil)
}

@Test func eosUnknownAndMalformedValuesAreNotInvented() {
    #expect(CameraExposureKind.iso.label(nil) == "—")
    #expect(CameraExposureKind.iso.label(0) == "Auto")
    #expect(CameraExposureKind.shutter.label(0x65) == "1/50 с")
    #expect(CameraExposureKind.aperture.label(0x30) == "f/5.6")
    #expect(CameraExposureKind.iso.label(0xabcdef).contains("0xABCDEF"))
    for value in [Double.nan, .infinity, -1, 1.5, 4294967296] {
        #expect(CameraProperty(json: .object(["raw": .number(value)])).raw == nil)
    }
}

@Test func usbDetectionIsNotPTPSession() {
    let state = RigState(envelope: WireEnvelope(type: "rig.state", payload: [
        "cameraUSBConnected": .bool(true), "cameraPTPInterface": .bool(true),
        "cameraConnected": .bool(false), "cameraVendorID": .number(1193),
        "cameraProductID": .number(1), "cameraStatus": .string("CANON USB PTP IF")
    ]))
    #expect(state.cameraUSBConnected)
    #expect(state.cameraPTPInterface)
    #expect(!state.cameraConnected)
    #expect(state.cameraVendorID == 0x04a9)
    let disconnected = RigState(envelope: WireEnvelope(type: "rig.state"))
    #expect(!disconnected.cameraUSBConnected)
    #expect(disconnected.cameraVendorID == 0)
}

@Test @MainActor func liveEditsSendLatestValueAndKeepUpdating() async throws {
    let scheduler = LiveUpdateScheduler(interval: .milliseconds(10))
    var values: [Int] = []
    scheduler.schedule { values.append(1) }
    scheduler.schedule { values.append(2) }
    scheduler.schedule { values.append(3) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(values == [3])
    scheduler.schedule { values.append(4) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(values == [3, 4])
}

@Test @MainActor func offCancelsPendingLiveEdit() async throws {
    let scheduler = LiveUpdateScheduler(interval: .milliseconds(10))
    var sent = false
    scheduler.schedule { sent = true }
    scheduler.cancel()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!sent)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CANON_RIG_USB_TEST_PORT"] != nil))
@MainActor func physicalUSBHandshake() async throws {
    let client = RigClient()
    client.connectionMode = .usb
    client.serialPath = ProcessInfo.processInfo.environment["CANON_RIG_USB_TEST_PORT"]!
    client.connect()
    defer { client.disconnect() }
    for _ in 0..<200 {
        if client.isConnected { break }
        client.maintainConnection()
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(client.isConnected, "\(client.lastError ?? "No USB reply")")
    #expect(client.state.lightReady)
    #expect(["usb", "ap", "router"].contains(client.state.networkMode))
}

@Test func serialDecoderIgnoresLogsAndHandlesFragments() {
    var decoder = SerialLineDecoder()
    #expect(decoder.append(Data("ESP-ROM boot\r\n@ri".utf8)).isEmpty)
    let messages = decoder.append(Data("g {\"v\":1}\r\nI: log\n@rig {}\n".utf8))
    #expect(messages == [Data("{\"v\":1}".utf8), Data("{}".utf8)])
}

@Test func serialDecoderRecoversAfterOversizedLine() {
    var decoder = SerialLineDecoder()
    #expect(decoder.append(Data(repeating: 65, count: 10000)).isEmpty)
    #expect(decoder.append(Data("\n@rig {}\n".utf8)) == [Data("{}".utf8)])
}

@Test func networkReplyIncludesModeAndErrors() throws {
    let data = Data(#"{"v":1,"id":"test","type":"rig.state","payload":{"networkMode":"usb"},"ok":false,"error":"router credentials required","rebooting":false}"#.utf8)
    let reply = try JSONDecoder().decode(WireEnvelope.self, from: data)
    #expect(reply.ok == false)
    #expect(reply.error == "router credentials required")
    #expect(RigState(envelope: reply).networkMode == "usb")
}

@Test func legacyReplyStillDecodes() throws {
    let data = Data(#"{"v":1,"id":"test","type":"rig.state","payload":{}}"#.utf8)
    let reply = try JSONDecoder().decode(WireEnvelope.self, from: data)
    #expect(reply.ok == nil)
    #expect(RigState(envelope: reply).networkMode == "unknown")
}

@Test func videoCaptureIncludingPreviewActivatesLight() {
    let snapshot = CaptureSnapshot(microphoneApps: [], activeCameras: ["Cam Link 4K"],
                                   runningMeetingApps: ["Google Chrome"])
    #expect(snapshot.rawCallActive)
    #expect(!CaptureSnapshot(microphoneApps: ["Zoom"], activeCameras: [],
                           runningMeetingApps: ["Zoom"]).rawCallActive)
    #expect(CaptureSnapshot(microphoneApps: [], activeCameras: ["Cam Link 4K"],
                           runningMeetingApps: []).rawCallActive)
}

@Test func automationSynchronizesAfterReconnectAndToggle() {
    var automation = CallAutomation()
    let start = Date(timeIntervalSince1970: 1000)
    #expect(automation.update(rawActive: true, automatic: true, connected: false, at: start) == nil)
    #expect(automation.update(rawActive: true, automatic: true, connected: true, at: start.addingTimeInterval(2)) == true)
    #expect(automation.update(rawActive: true, automatic: true, connected: true, at: start.addingTimeInterval(3)) == nil)
    #expect(automation.update(rawActive: true, automatic: true, connected: false, at: start.addingTimeInterval(4)) == nil)
    #expect(automation.update(rawActive: true, automatic: true, connected: true, at: start.addingTimeInterval(5)) == true)
    #expect(automation.update(rawActive: false, automatic: false, connected: true, at: start.addingTimeInterval(6)) == nil)
    #expect(automation.update(rawActive: false, automatic: false, connected: true, at: start.addingTimeInterval(36)) == nil)
    #expect(automation.update(rawActive: false, automatic: true, connected: true, at: start.addingTimeInterval(37)) == false)
}

@Test func briefMicDropoutDoesNotSwitchOff() {
    let start = Date(timeIntervalSince1970: 1000)
    var automation = CallAutomation()
    _ = automation.update(rawActive: true, automatic: true, connected: false, at: start)
    #expect(automation.update(rawActive: true, automatic: true, connected: true, at: start.addingTimeInterval(2)) == true)
    #expect(automation.update(rawActive: false, automatic: true, connected: true, at: start.addingTimeInterval(3)) == nil)
    #expect(automation.update(rawActive: true, automatic: true, connected: true, at: start.addingTimeInterval(20)) == nil)
    #expect(automation.isOnCall)
}

@Test func callHysteresisDebouncesEntryAndExit() {
    let start = Date(timeIntervalSince1970: 1_000)
    var state = CallHysteresis(enterDelay: 2, exitDelay: 30)
    let entered0 = state.update(rawActive: true, at: start)
    let entered1 = state.update(rawActive: true, at: start.addingTimeInterval(1.9))
    let entered2 = state.update(rawActive: true, at: start.addingTimeInterval(2))
    #expect(!entered0)
    #expect(!entered1)
    #expect(entered2)
    #expect(state.isOnCall)
    let exited0 = state.update(rawActive: false, at: start.addingTimeInterval(3))
    let exited1 = state.update(rawActive: false, at: start.addingTimeInterval(32.9))
    let exited2 = state.update(rawActive: false, at: start.addingTimeInterval(33))
    #expect(!exited0)
    #expect(!exited1)
    #expect(exited2)
    #expect(!state.isOnCall)
}

@Test func wireEnvelopeRoundTrips() throws {
    let input = WireEnvelope(id: "test", type: "rig.setState",
                             payload: ["mode": .string("on_call")])
    let data = try JSONEncoder().encode(input)
    let output = try JSONDecoder().decode(WireEnvelope.self, from: data)
    #expect(output == input)
}
