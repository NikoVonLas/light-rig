import AppKit
import Combine
import SwiftUI

struct MenuPanelField: View {
    private let shape = RoundedRectangle(cornerRadius: 18)

    var body: some View {
        shape.fill(.primary.opacity(0.035))
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.primary.opacity(0.23), .primary.opacity(0.07), .primary.opacity(0.17)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
            }
    }
}

struct MenuPanelSurface: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 14, style: .circular)

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: shape)
                .containerBackground(.clear, for: .window)
        } else if #available(macOS 15, *) {
            content
                .background(.regularMaterial, in: shape)
                .containerBackground(.clear, for: .window)
        } else {
            content.background(.regularMaterial)
        }
    }
}

/// Preserve the opening position relative to the physical display's menu bar.
/// Global screen coordinates can change when macOS makes another display primary.
struct MenuPanelAnchor {
    let displayUUID: UUID
    let rightInset: CGFloat

    init(displayUUID: UUID, panel: CGRect, screen: CGRect) {
        self.displayUUID = displayUUID
        rightInset = screen.maxX - panel.maxX
    }

    func origin(size: CGSize, screen: CGRect, menuBarBottom: CGFloat) -> CGPoint {
        CGPoint(x: max(screen.minX, min(screen.maxX - size.width, screen.maxX - rightInset - size.width)),
                y: max(screen.minY, menuBarBottom - size.height))
    }
}

private extension NSScreen {
    var displayNumber: NSNumber? { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }

    // visibleFrame can include the menu bar on a secondary display. Quartz
    // exposes its actual bounds even when that display is not the main screen.
    var menuBarBottom: CGFloat {
        if let displayNumber,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let display = CGDisplayBounds(displayNumber.uint32Value)
            let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
            for window in windows where window[kCGWindowLayer as String] as? Int == menuLevel {
                guard let values = window[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = values["X"], let y = values["Y"], let width = values["Width"], let height = values["Height"],
                      abs(x - display.minX) <= 1, abs(width - display.width) <= 1,
                      abs(y - display.minY) <= 1, height > 0, height < 100 else { continue }
                return frame.maxY - (y + height - display.minY)
            }
        }
        return min(visibleFrame.maxY, frame.maxY - max(safeAreaInsets.top, NSStatusBar.system.thickness))
    }

    var menuDisplayUUID: UUID? {
        guard let id = displayNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id.uint32Value)?.takeRetainedValue() else { return nil }
        return UUID(uuidString: CFUUIDCreateString(nil, uuid) as String)
    }
}

private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class StatusMenuController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = StatusPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
    private var iconUpdates: AnyCancellable?
    private var localEvents: Any?
    private var outsideClicks: Any?
    private var anchor: MenuPanelAnchor?
    private var contentSize = CGSize.zero

    init(model: AppModel) {
        super.init()
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(toggle)
        iconUpdates = model.$onCall.removeDuplicates().sink { [weak self] onCall in
            let button = self?.item.button
            button?.image = CameraStatusImage.make(onAir: onCall)
            button?.setAccessibilityLabel(onCall ? "Light Rig — на созвоне" : "Light Rig — свободен")
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        let content = MenuBarContent(model: model, dismiss: { [weak self] in self?.dismiss() })
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                self?.resize(to: size)
            }
        let host = NSHostingView(rootView: content)
        let initialSize = host.fittingSize
        host.sizingOptions = []
        panel.contentView = host
        resize(to: initialSize)
        NotificationCenter.default.addObserver(self, selector: #selector(screenLayoutChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowMoved),
                                               name: NSWindow.didMoveNotification, object: panel)
    }

    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, contentSize != size else { return }
        contentSize = size
        DispatchQueue.main.async { [weak self] in self?.positionPanel() }
    }

    @objc private func toggle() {
        if anchor != nil { dismiss(); return }
        guard let button = item.button, let window = button.window, let screen = window.screen,
              let uuid = screen.menuDisplayUUID else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let panelRect = CGRect(x: buttonRect.maxX - contentSize.width, y: 0, width: contentSize.width, height: contentSize.height)
        anchor = MenuPanelAnchor(displayUUID: uuid, panel: panelRect, screen: screen.frame)
        positionPanel()
        button.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            guard let self, !panel.frame.contains(NSEvent.mouseLocation) else { return }
            dismiss()
        }
        localEvents = NSEvent.addLocalMonitorForEvents(matching: [clicks, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { dismiss(); return nil }
            } else if event.window !== panel && event.window !== item.button?.window && !panel.frame.contains(NSEvent.mouseLocation) {
                dismiss()
            }
            return event
        }
    }

    private func positionPanel() {
        guard let anchor, let screen = NSScreen.screens.first(where: { $0.menuDisplayUUID == anchor.displayUUID })
                ?? item.button?.window?.screen ?? NSScreen.screens.first else { return }
        let origin = anchor.origin(size: contentSize, screen: screen.frame, menuBarBottom: screen.menuBarBottom)
        let frame = CGRect(origin: origin, size: contentSize)
        if panel.frame != frame { panel.setFrame(frame, display: true); panel.invalidateShadow() }
    }

    @objc private func windowMoved() {
        DispatchQueue.main.async { [weak self] in self?.positionPanel() }
    }

    @objc private func screenLayoutChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, anchor != nil else { return }
            positionPanel()
            panel.orderFrontRegardless()
        }
    }

    private func dismiss() {
        anchor = nil
        if let localEvents { NSEvent.removeMonitor(localEvents); self.localEvents = nil }
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks); self.outsideClicks = nil }
        panel.orderOut(nil)
        item.button?.highlight(false)
    }
}
