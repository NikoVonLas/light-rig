import AppKit
import CanonRigCore
import SwiftUI

@main
struct CanonRigApp: App {
    @NSApplicationDelegateAdaptor(CanonRigApplicationDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appTermination) {
                    Button("Выйти из Light Rig") { delegate.model.quit() }
                        .keyboardShortcut("q")
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Настройки") {
                        delegate.model.selectTab(.settings)
                        delegate.model.openMainWindow()
                    }
                    .keyboardShortcut(",")
                }
            }
    }


}

@MainActor
final class CanonRigApplicationDelegate: NSObject, NSApplicationDelegate {
    lazy var model = AppModel()
    private var menu: StatusMenuController?
#if CANON_RIG_UPDATES
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.updates.shouldWaitToQuit() else { return .terminateNow }
        return .terminateCancel
    }

#endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = StatusMenuController(model: model)
        #if CANON_RIG_UPDATES
        model.updates.start()
        #endif
    }
    func applicationDidUnhide(_ notification: Notification) { model.syncPreviewWithWindow() }

    func applicationDidHide(_ notification: Notification) { model.stopPreview() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.openMainWindow()
        return true
    }
}
