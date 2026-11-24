import Foundation
import Testing
@testable import CanonRigCore

@Test @MainActor func renamedControllerRemembersPreviouslyOnboardedDevices() throws {
    let suite = "canonrig-onboarding-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["board-a"], forKey: "onboardedLilyGODevices.v1")
    defaults.set(["board-b"], forKey: "onboardedLightControllerDevices.v1")
    let flow = OnboardingFlow(defaults: defaults)
    for device in ["board-a", "board-b"] {
        #expect(!flow.observe(deviceID: device, connectedUSB: true, setup: .idle))
    }
    #expect(flow.observe(deviceID: "board-c", connectedUSB: true, setup: .idle))
}

@Test @MainActor func onboardingIsPerBoardAndOnlyCompletedAfterTour() throws {
    let suite = "canonrig-onboarding-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let flow = OnboardingFlow(defaults: defaults)
    #expect(!flow.observe(deviceID: "board-a", connectedUSB: false, setup: .idle))
    #expect(!flow.observe(deviceID: "", connectedUSB: true, setup: .idle))
    #expect(flow.observe(deviceID: "board-a", connectedUSB: true, setup: .idle))
    flow.continueUSB()
    #expect(flow.step == .invitation)
    flow.startTour()
    #expect(flow.step == .tour && flow.tourStep == .preview)
    flow.next()
    #expect(flow.tourStep == .exposure)
    flow.back()
    #expect(flow.tourStep == .preview)
    let beforeFinish = OnboardingFlow(defaults: defaults)
    #expect(beforeFinish.observe(deviceID: "board-a", connectedUSB: true, setup: .idle))
    for _ in OnboardingFlow.TourStep.allCases { flow.next() }
    #expect(flow.step == nil)
    let afterRestart = OnboardingFlow(defaults: defaults)
    #expect(!afterRestart.observe(deviceID: "board-a", connectedUSB: true, setup: .idle))
    #expect(afterRestart.observe(deviceID: "board-b", connectedUSB: true, setup: .idle))
}

@Test @MainActor func onboardingWaitsForSameBoardAndDoesNotRepeatAfterDismissal() throws {
    let suite = "canonrig-onboarding-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let flow = OnboardingFlow(defaults: defaults)
    flow.begin(deviceID: "board-a")
    flow.chooseWiFi()
    flow.waitForWiFi()
    flow.observe(deviceID: "board-a", connectedUSB: false, setup: .waiting)
    #expect(flow.step == .waiting)
    flow.observe(deviceID: "board-b", connectedUSB: true, setup: .connected)
    #expect(flow.step == .waiting)
    flow.observe(deviceID: "board-a", connectedUSB: true, setup: .failed("wrong password"))
    #expect(flow.step == .waiting)
    flow.observe(deviceID: "board-a", connectedUSB: true, setup: .connected)
    #expect(flow.step == .invitation && flow.usesWiFi)
    flow.dismiss()
    #expect(!flow.observe(deviceID: "board-a", connectedUSB: true, setup: .idle))
    let restarted = OnboardingFlow(defaults: defaults)
    #expect(restarted.observe(deviceID: "board-a", connectedUSB: true, setup: .idle))
}

@Test func scanDecodesStableIdentityAndUniqueNetworks() {
    let state = RigState(envelope: WireEnvelope(type: "rig.state", payload: [
        "homeAssistant": .object(["deviceId": .string("canonrig_test")]),
        "wifiScan": .object(["status": .string("ready"), "networks": .array([
            .object(["ssid": .string("Example"), "rssi": .number(-50)]),
            .object(["ssid": .string("Example"), "rssi": .number(-60)]),
            .object(["ssid": .string("Other"), "rssi": .number(-40)]),
            .object(["ssid": .string("Invalid"), "rssi": .number(999)])])])]))
    #expect(state.deviceID == "canonrig_test")
    #expect(state.supportsWiFiScan && state.wifiScanStatus == "ready")
    #expect(state.wifiNetworks.map(\.ssid) == ["Other", "Example"])
    #expect(!RigState(envelope: WireEnvelope(type: "rig.state")).supportsWiFiScan)
}

@Test @MainActor func skippingTourCompletesOnlyTheSelectedBoard() throws {
    let suite = "canonrig-onboarding-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let flow = OnboardingFlow(defaults: defaults)
    flow.begin(deviceID: "board-a")
    flow.complete() // Setup cannot be accidentally completed before the invitation.
    #expect(flow.step == .connection)
    flow.continueUSB()
    flow.complete()
    let restarted = OnboardingFlow(defaults: defaults)
    #expect(!restarted.observe(deviceID: "board-a", connectedUSB: true, setup: .idle))
    #expect(restarted.observe(deviceID: "board-b", connectedUSB: true, setup: .idle))
    restarted.continueUSB()
    restarted.startTour()
    restarted.dismiss() // Closing the main window is not the explicit skip/finish action.
    #expect(!restarted.observe(deviceID: "board-b", connectedUSB: true, setup: .idle))
    #expect(OnboardingFlow(defaults: defaults).observe(deviceID: "board-b", connectedUSB: true, setup: .idle))
    flow.replayTour(deviceID: "board-a") // Manual replay also works over Wi-Fi.
    #expect(flow.tourStep == .preview && flow.step == .tour)
}

@Test @MainActor func offlineTourDoesNotCompleteAnUnseenBoard() throws {
    let suite = "canonrig-onboarding-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let flow = OnboardingFlow(defaults: defaults)
    flow.replayTour(deviceID: "")
    #expect(flow.step == .tour)
    flow.complete()
    #expect(flow.step == nil)
    #expect(flow.observe(deviceID: "board-a", connectedUSB: true, setup: .idle))
}
