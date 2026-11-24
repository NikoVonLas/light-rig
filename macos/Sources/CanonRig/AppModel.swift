import AppKit
import CanonRigCore
import Combine
import Foundation

enum RigWindowTab: String, CaseIterable {
    case camera = "Камера"
    case settings = "Настройки"

    var icon: String { self == .camera ? "video" : "gearshape" }
}

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

    @Published private(set) var windowTab = RigWindowTab.camera

    func selectTab(_ tab: RigWindowTab) {
        guard windowTab != tab else { return }
        windowTab = tab
        mainWindow?.selectTab(tab)
        syncPreviewWithWindow()
    }

    #if CANON_RIG_UPDATES
    lazy var updates = AppUpdates { [weak self] in
        guard let self else { return true }
        return self.updatesPaused || self.detector.videoIsActive
    }
    var updatesPaused: Bool { videoIsActive || onCall }
    #endif

    private var videoIsActive = false
    @Published var onCall = false
    @Published var automatic = UserDefaults.standard.object(forKey: "automaticCallLight") as? Bool ?? true {
        didSet {
            guard oldValue != automatic else { return }
            UserDefaults.standard.set(automatic, forKey: "automaticCallLight")
            lightUpdates.cancel()
            if automatic && onCall, let preset = client.state.callLight { restoreLightEditor(preset) }
            reportPresence()
        }
    }
    @Published var lightBrightness = 50 { didSet { if oldValue != lightBrightness { scheduleLightUpdate() } } }
    @Published var lightColorMode = LightColorMode.rgb {
        didSet {
            guard oldValue != lightColorMode else { return }
            if lightColorMode == .temperature && usesAnimatedColors { lightEffect = "solid" }
            scheduleLightUpdate()
        }
    }
    @Published var lightKelvin = 4500 { didSet { if oldValue != lightKelvin { scheduleLightUpdate() } } }
    @Published var wheel = WheelSelection(hue: 0, saturation: 0) {
        didSet { if oldValue != wheel { scheduleLightUpdate() } }
    }
    var usesAnimatedColors: Bool { lightEffect == "rainbow" || lightEffect == "color_cycle" }
    var lightColor: LightRGB { lightColorMode == .temperature ? .white(kelvin: lightKelvin) : wheel.rgb }
    @Published var lightEffect = "solid" { didSet { if oldValue != lightEffect { scheduleLightUpdate() } } }
    @Published var lightSpeed = 40 { didSet { if oldValue != lightSpeed { scheduleLightUpdate() } } }
    private let callPresetSlot = 3
    private var loadedLight: RigState.CallLight?
    private var loadedLightDevice = ""
    private var restoringLight = false
    @Published var routerSSID = ""
    @Published var routerPassword = ""
    @Published private(set) var previewEnabled = false

    init() {
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
        videoIsActive = detector.videoIsActive
        presenceCall.update(rawActive: videoIsActive)
        if onCall != presenceCall.isOnCall { lightUpdates.cancel() }
        onCall = presenceCall.isOnCall
        #if CANON_RIG_UPDATES
        updates.resumeWhenIdle()
        #endif
        if client.isConnected, let saved = client.state.callLight {
            if saved != loadedLight || client.state.deviceID != loadedLightDevice {
                restoreLightEditor(saved)
                loadedLight = saved
                loadedLightDevice = client.state.deviceID
            }
        } else { loadedLight = nil }
        reportPresence()
    }

    private func reportPresence() {
        if client.isConnected && client.state.supportsPresence {
            client.sendPresence(reporter.envelope(onCall: onCall, cameraInCall: videoIsActive,
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
        selectTab(.camera)
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

    func quit() {
        stopPreview()
        NSApp.terminate(nil)
    }

    func openMainWindow() {
        if mainWindow == nil { mainWindow = MainWindowController(model: self) }
        mainWindow?.present()
    }

    func enterApplication(withTour: Bool) {
        selectTab(.camera)
        if withTour { onboarding.startTour() } else { onboarding.complete() }
        onboardingWindow?.hideForApplication()
        openMainWindow()
    }

    func syncPreviewWithWindow() {
        guard windowTab == .camera, let window = mainWindow?.window,
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


    func toggleLightPower() {
        lightUpdates.cancel()
        client.toggleLightPower()
    }

    private func applyLight() {
        lightUpdates.cancel()
        let color = lightColor
        client.setLight(enabled: true, brightness: lightBrightness, mode: "rgb",
                        red: color.red, green: color.green, blue: color.blue,
                        effect: lightEffect, speed: lightSpeed)
    }

    private func restoreLightEditor(_ preset: RigState.CallLight) {
        lightUpdates.cancel()
        restoringLight = true
        defer { restoringLight = false }
        let color = LightRGB(red: preset.red, green: preset.green, blue: preset.blue)
        lightEffect = preset.effect
        if !usesAnimatedColors, let kelvin = stride(from: LightRGB.kelvinRange.lowerBound,
            through: LightRGB.kelvinRange.upperBound, by: 100).first(where: { LightRGB.white(kelvin: $0) == color }) {
            lightKelvin = kelvin
            lightColorMode = .temperature
        } else { lightColorMode = .rgb }
        wheel = WheelSelection(color: color)
        lightBrightness = preset.brightness
        lightSpeed = preset.speed
    }

    private func scheduleLightUpdate() {
        guard !restoringLight, client.isConnected else { return }
        lightUpdates.schedule { [weak self] in
            guard let self, self.client.isConnected else { return }
            self.applyLight()
        }
    }

    func saveLightPreset() {
        guard client.isConnected else { return }
        let color = lightColor
        client.saveLightPreset(slot: callPresetSlot, name: "Созвон", enabled: true,
                               brightness: lightBrightness, mode: "rgb",
                               red: color.red, green: color.green, blue: color.blue,
                               warm: 65, cool: 65, effect: lightEffect, speed: lightSpeed)
    }
}
