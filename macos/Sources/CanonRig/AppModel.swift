import AppKit
import CanonRigCore
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let client = RigClient()
    let onboarding = OnboardingFlow()
    private var onboardingWindow: OnboardingWindowController?
    private var mainWindow: MainWindowController?
    let preview = CameraPreviewController()
    private let detector = CallDetector()
    private var presenceCall = CallHysteresis(enterDelay: 2, exitDelay: 3)
    private var reporter = PresenceReporter(clientID: PresenceReporter.installationID(),
                                            name: Host.current().localizedName ?? "Mac")
    private var monitorTask: Task<Void, Never>?
    private var clientUpdates: AnyCancellable?
    private let lightUpdates = LiveUpdateScheduler()

    @Published var capture = CaptureSnapshot(microphoneApps: [], activeCameras: [], runningMeetingApps: [])
    @Published var onCall = false
    @Published var automatic = true
    @Published var lightBrightness = 50 { didSet { if oldValue != lightBrightness { scheduleLightUpdate() } } }
    @Published var lightColorMode = LightColorMode.rgb {
        didSet {
            guard oldValue != lightColorMode else { return }
            if lightColorMode == .temperature && usesAnimatedColors { lightEffect = "solid" }
            scheduleLightUpdate()
        }
    }
    @Published var lightKelvin = 4500 { didSet { if oldValue != lightKelvin { scheduleLightUpdate() } } }
    @Published var wheel = WheelSelection(hue: 85.0 / (220 * 6), saturation: 220.0 / 255) {
        didSet { if oldValue != wheel { scheduleLightUpdate() } }
    }
    var usesAnimatedColors: Bool { lightEffect == "rainbow" || lightEffect == "color_cycle" }
    var lightColor: LightRGB { lightColorMode == .temperature ? .white(kelvin: lightKelvin) : wheel.rgb }
    @Published var lightEffect = "solid" { didSet { if oldValue != lightEffect { scheduleLightUpdate() } } }
    @Published var lightSpeed = 40 { didSet { if oldValue != lightSpeed { scheduleLightUpdate() } } }
    private var callPresetSlot = 3
    @Published var deviceNetworkMode = "router"
    @Published var routerSSID = ""
    @Published var routerPassword = ""
    @Published private(set) var previewEnabled = false
    @Published var profileNotice: String?

    init() {
        CanonRigApplicationDelegate.model = self
        Task { [weak self] in self?.openMainWindow() }
        clientUpdates = client.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        client.connect()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    deinit {
        monitorTask?.cancel()
        preview.stop()
    }

    func tick() {
        client.maintainConnection()
        if onboarding.observe(deviceID: client.state.deviceID,
                              connectedUSB: client.isConnected && client.activeConnectionMode == .usb,
                              setup: client.networkSetupStatus) {
            presentOnboarding()
        }
        capture = detector.sample()
        presenceCall.update(rawActive: capture.rawCallActive)
        onCall = presenceCall.isOnCall
        if client.isConnected && client.state.supportsPresence {
            client.send(reporter.envelope(onCall: onCall, cameraInCall: capture.rawCallActive,
                                          automatic: automatic && onboarding.step == nil, preview: previewEnabled))
        }
    }

    func reconnect() {
        lightUpdates.cancel()
        client.connect()
    }

    func presentOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(model: self) { [weak self] in
                self?.routerPassword = ""
                self?.client.cancelNetworkSetup()
                self?.onboarding.dismiss()
            }
        }
        onboardingWindow?.present()
    }

    func restartOnboarding() {
        guard client.isConnected, !client.state.deviceID.isEmpty else { return }
        onboarding.begin(deviceID: client.state.deviceID)
        presentOnboarding()
    }

    func restartTour() {
        onboarding.replayTour(deviceID: client.isConnected ? client.state.deviceID : "")
        onboardingWindow?.hideForApplication()
        openMainWindow()
    }

    func beginOnboardingWiFi() {
        client.cancelNetworkSetup()
        routerPassword = ""
        if routerSSID.isEmpty { routerSSID = client.state.networkSSID }
        onboarding.chooseWiFi()
        client.scanWiFi()
    }

    func connectOnboardingWiFi() {
        guard client.isConnected, client.activeConnectionMode == .usb,
              client.state.deviceID == onboarding.deviceID else { return }
        if client.configureNetwork(mode: "router", ssid: routerSSID, password: routerPassword) {
            onboarding.waitForWiFi()
        }
        routerPassword = ""
    }

    func continueOnboardingUSB() {
        client.cancelNetworkSetup()
        routerPassword = ""
        onboarding.continueUSB()
    }

    func openMainWindow() {
        if mainWindow == nil { mainWindow = MainWindowController(model: self) }
        mainWindow?.present()
    }

    func enterApplication(withTour: Bool) {
        if withTour { onboarding.startTour() } else { onboarding.complete() }
        onboardingWindow?.hideForApplication()
        openMainWindow()
    }

    func configureDeviceNetwork() {
        client.configureNetwork(mode: deviceNetworkMode, ssid: routerSSID, password: routerPassword)
        routerPassword = "" // Never persist router credentials on the Mac.
    }

    func syncPreviewWithWindow() {
        guard let window = mainWindow?.window,
              window.isVisible, !window.isMiniaturized, !NSApp.isHidden else {
            stopPreview()
            return
        }
        guard !previewEnabled else { return }
        previewEnabled = true
        preview.start()
    }

    func stopPreview() {
        guard previewEnabled else { return }
        previewEnabled = false
        preview.stop()
    }


    func applyLight(enabled: Bool = true) {
        lightUpdates.cancel()
        let color = lightColor
        client.setLight(enabled: enabled, brightness: lightBrightness, mode: "rgb",
                        red: color.red, green: color.green, blue: color.blue,
                        effect: lightEffect, speed: lightSpeed)
    }

    private func scheduleLightUpdate() {
        guard client.isConnected else { return }
        lightUpdates.schedule { [weak self] in
            guard let self, self.client.isConnected else { return }
            self.applyLight()
        }
    }

    func saveLightPreset() {
        guard client.isConnected else { profileNotice = "Сначала подключись к LightController"; return }
        let color = lightColor
        client.saveLightPreset(slot: callPresetSlot, name: "Созвон", enabled: true,
                               brightness: lightBrightness, mode: "rgb",
                               red: color.red, green: color.green, blue: color.blue,
                               warm: 65, cool: 65, effect: lightEffect, speed: lightSpeed)
        profileNotice = "Профиль света «Созвон» отправлен на LightController"
    }
}
