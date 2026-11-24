import AppKit
import CanonRigCore
import SwiftUI
#if CANON_RIG_UPDATES
import Sparkle
#endif

@main
struct CanonRigApp: App {
    @NSApplicationDelegateAdaptor(CanonRigApplicationDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Настройки…") {
                        delegate.model.selectTab(.settings)
                        delegate.model.openMainWindow()
                    }
                    .keyboardShortcut(",")
                }
            }
    }

    // A template status item takes its color from macOS. Keep the active
    // image in its original colors and let the idle symbol follow the menu bar.
    static let onCallIcon: NSImage = {
        let renderer = ImageRenderer(content:
            Image(systemName: "video.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.red)
                .frame(width: 22, height: 18))
        renderer.scale = 3
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)!
        image.isTemplate = false
        return image
    }()
}

@MainActor
final class CanonRigApplicationDelegate: NSObject, NSApplicationDelegate {
    lazy var model = AppModel()
    private var menu: StatusMenuController?
#if CANON_RIG_UPDATES
    static let updates = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

#endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = StatusMenuController(model: model)
        #if CANON_RIG_UPDATES
        Self.updates.startUpdater()
        #endif
    }
    func applicationDidUnhide(_ notification: Notification) { model.syncPreviewWithWindow() }

    func applicationDidHide(_ notification: Notification) { model.stopPreview() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.openMainWindow()
        return true
    }
}
