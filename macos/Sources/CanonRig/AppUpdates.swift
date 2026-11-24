#if CANON_RIG_UPDATES
import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppUpdates: NSObject, SPUUpdaterDelegate {
    private let callIsActive: () -> Bool
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    var updater: SPUUpdater { controller.updater }

    private var retryBackgroundCheck = false
    private var resumeInstallation: (() -> Void)?
    private var installerPreparing = false
    private var installsOnQuit = false
    private var waitingToQuit = false

    init(callIsActive: @escaping () -> Bool) { self.callIsActive = callIsActive }

    func start() { controller.startUpdater() }

    func checkNow() {
        guard !callIsActive(), updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try allowCheck(updateCheck)
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        try allowCheck(updateCheck)
    }

    private func allowCheck(_ check: SPUUpdateCheck) throws {
        guard callIsActive() else { return }
        if check == .updatesInBackground { retryBackgroundCheck = true }
        throw NSError(domain: "CanonRig.Updates", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Обновления приостановлены до окончания видеозвонка."])
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        installerPreparing = true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        installsOnQuit = true
        return false // Keep Sparkle's normal install-on-quit scheduling.
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        installsOnQuit = true
        guard callIsActive() else { return false }
        resumeInstallation = installHandler
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        installerPreparing = false
        resumeInstallation = nil
    }

    // Sparkle can also install a prepared update when the user quits, without
    // calling the relaunch delegate. Keep the host alive until video is idle.
    func shouldWaitToQuit() -> Bool {
        guard (installerPreparing || installsOnQuit), callIsActive() else { return false }
        waitingToQuit = true
        return true
    }

    func resumeWhenIdle() {
        guard waitingToQuit || resumeInstallation != nil || retryBackgroundCheck,
              !callIsActive() else { return }
        if waitingToQuit {
            waitingToQuit = false
            NSApp.terminate(nil)
        } else if let install = resumeInstallation {
            resumeInstallation = nil
            install()
        } else if updater.canCheckForUpdates {
            retryBackgroundCheck = false
            if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
        }
    }
}

struct AppUpdateSettings: View {
    let updates: AppUpdates
    let paused: Bool
    @State private var checks = false
    @State private var downloads = false
    @State private var canCheck = false

    var body: some View {
        Section {
            Toggle("Автоматически проверять обновления", isOn: Binding(
                get: { checks }, set: { updates.updater.automaticallyChecksForUpdates = $0 }))
            Toggle("Автоматически устанавливать обновления", isOn: Binding(
                get: { downloads }, set: { updates.updater.automaticallyDownloadsUpdates = $0 }))
                .disabled(!checks)
            LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            Button("Проверить обновления") { updates.checkNow() }
                .disabled(paused || !canCheck)
        } footer: {
            Text(paused ? "Обновления приостановлены до окончания видеозвонка." :
                    "Во время видеозвонка проверка и установка откладываются.")
        }
        .onReceive(updates.updater.publisher(for: \.automaticallyChecksForUpdates)) { checks = $0 }
        .onReceive(updates.updater.publisher(for: \.automaticallyDownloadsUpdates)) { downloads = $0 }
        .onReceive(updates.updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}
#endif
