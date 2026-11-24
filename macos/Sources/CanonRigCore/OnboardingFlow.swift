import Foundation

@MainActor
public final class OnboardingFlow: ObservableObject {
    public enum Step: Hashable { case connection, wifi, waiting, invitation, tour }
    public enum TourStep: Int, CaseIterable, Hashable, Sendable {
        case preview, exposure, focus, light, automation, settings
    }
    @Published public private(set) var step: Step?
    @Published public private(set) var tourStep: TourStep = .preview
    @Published public private(set) var deviceID = ""
    @Published public private(set) var usesWiFi = false
    private let defaults: UserDefaults
    private var dismissed = Set<String>()
    private let key = "onboardedLightControllerDevices.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let legacyKey = "onboardedLilyGODevices.v1"
        if let previous = defaults.stringArray(forKey: legacyKey) {
            let completed = Set(defaults.stringArray(forKey: key) ?? []).union(previous)
            defaults.set(completed.sorted(), forKey: key)
            defaults.removeObject(forKey: legacyKey)
        }
    }

    @discardableResult
    public func observe(deviceID: String, connectedUSB: Bool, setup: NetworkSetupStatus) -> Bool {
        if step == nil, connectedUSB, !deviceID.isEmpty,
           !dismissed.contains(deviceID), !(defaults.stringArray(forKey: key) ?? []).contains(deviceID) {
            begin(deviceID: deviceID)
            return true
        }
        if self.deviceID == deviceID, step == .waiting, setup == .connected {
            usesWiFi = true
            step = .invitation
        }
        return false
    }

    public func begin(deviceID: String) {
        guard !deviceID.isEmpty else { return }
        self.deviceID = deviceID
        usesWiFi = false
        step = .connection
    }
    public func chooseWiFi() { step = .wifi }
    public func waitForWiFi() { step = .waiting }
    public func continueUSB() { usesWiFi = false; step = .invitation }
    public func backToConnection() { step = .connection }
    public func startTour() {
        guard step == .invitation else { return }
        tourStep = .preview
        step = .tour
    }
    public func replayTour(deviceID: String) {
        self.deviceID = deviceID
        tourStep = .preview
        step = .tour
    }
    public func next() {
        guard step == .tour else { return }
        if let next = TourStep(rawValue: tourStep.rawValue + 1) { tourStep = next }
        else { complete() }
    }
    public func back() {
        guard step == .tour, let previous = TourStep(rawValue: tourStep.rawValue - 1) else { return }
        tourStep = previous
    }
    public func complete() {
        guard step == .invitation || step == .tour else { return }
        if !deviceID.isEmpty {
            var complete = Set(defaults.stringArray(forKey: key) ?? [])
            complete.insert(deviceID)
            defaults.set(complete.sorted(), forKey: key)
        }
        step = nil
    }
    public func dismiss() {
        if !deviceID.isEmpty { dismissed.insert(deviceID) }
        step = nil
    }
}
