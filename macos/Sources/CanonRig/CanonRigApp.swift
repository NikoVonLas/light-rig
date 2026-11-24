import AppKit
import CanonRigCore
import SwiftUI
#if CANON_RIG_UPDATES
import Sparkle
#endif

@main
struct CanonRigApp: App {
    @NSApplicationDelegateAdaptor(CanonRigApplicationDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Label(model.onCall ? "On call" : "Canon Rig",
                  systemImage: model.onCall ? "video.fill" : "video")
        }
        .menuBarExtraStyle(.window)

    }
}

@MainActor
final class CanonRigApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
#if CANON_RIG_UPDATES
    static let updates = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.updates.startUpdater()
    }
#endif
    func applicationDidUnhide(_ notification: Notification) { Self.model?.syncPreviewWithWindow() }

    func applicationDidHide(_ notification: Notification) { Self.model?.stopPreview() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.model?.openMainWindow()
        return true
    }
}
