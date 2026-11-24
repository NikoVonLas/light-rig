import AppKit
import CanonRigCore
import SwiftUI

/// One window owner for both the menu bar and the setup wizard, including cold launch.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private weak var model: AppModel?
    private let tabs = NSSegmentedControl()
    private let navigationID = NSToolbarItem.Identifier("rig.navigation")

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Canon Rig"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.contentView = NSHostingView(rootView: ControlView(model: model, flow: model.onboarding))
        window.setFrameAutosaveName("CanonRigControlWindow")
        window.center()
        super.init(window: window)
        window.delegate = self
        tabs.segmentCount = RigWindowTab.allCases.count
        tabs.trackingMode = .selectOne
        tabs.segmentStyle = .rounded
        tabs.controlSize = .small
        let tabFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        tabs.font = tabFont
        tabs.target = self
        tabs.action = #selector(chooseTab(_:))
        tabs.setAccessibilityLabel("Раздел окна")
        tabs.segmentDistribution = .fit
        let horizontalPadding: CGFloat = 24
        for (index, tab) in RigWindowTab.allCases.enumerated() {
            tabs.setLabel(tab.rawValue, forSegment: index)
            let image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            tabs.setImage(image, forSegment: index)
            tabs.setImageScaling(.scaleProportionallyDown, forSegment: index)
            tabs.setToolTip(tab.rawValue, forSegment: index)
            let titleWidth = (tab.rawValue as NSString).size(withAttributes: [.font: tabFont]).width
            let iconWidth = image.map { ceil($0.size.width) + 8 } ?? 0
            tabs.setWidth(ceil(titleWidth) + iconWidth + 2 * horizontalPadding, forSegment: index)
        }
        tabs.sizeToFit()
        tabs.setContentCompressionResistancePriority(.required, for: .horizontal)
        tabs.widthAnchor.constraint(greaterThanOrEqualToConstant: tabs.fittingSize.width).isActive = true
        let toolbar = NSToolbar(identifier: "CanonRigMainNavigation")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
        selectTab(model.windowTab)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func selectTab(_ tab: RigWindowTab) {
        if let index = RigWindowTab.allCases.firstIndex(of: tab) { tabs.selectedSegment = index }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [navigationID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [navigationID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == navigationID else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Раздел окна"
        item.isBordered = false
        item.view = tabs
        return item
    }

    @objc private func chooseTab(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard RigWindowTab.allCases.indices.contains(index) else { return }
        model?.selectTab(RigWindowTab.allCases[index])
    }

    func present() {
        showWindow(nil)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model?.syncPreviewWithWindow()
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { model?.syncPreviewWithWindow() }

    func windowDidDeminiaturize(_ notification: Notification) { model?.syncPreviewWithWindow() }

    func windowDidMiniaturize(_ notification: Notification) { model?.stopPreview() }

    func windowWillClose(_ notification: Notification) {
        model?.stopPreview()
        if model?.onboarding.step == .tour { model?.onboarding.dismiss() }
    }
}

struct TourAnchors: PreferenceKey {
    static let defaultValue: [OnboardingFlow.TourStep: Anchor<CGRect>] = [:]
    static func reduce(value: inout [OnboardingFlow.TourStep: Anchor<CGRect>],
                       nextValue: () -> [OnboardingFlow.TourStep: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func tourTarget(_ step: OnboardingFlow.TourStep) -> some View {
        anchorPreference(key: TourAnchors.self, value: .bounds) { [step: $0] }
    }
}

struct InteractiveTour: View {
    @ObservedObject var flow: OnboardingFlow
    let anchors: [OnboardingFlow.TourStep: Anchor<CGRect>]
    private let accent = Color.accentColor

    var body: some View {
        GeometryReader { geometry in
            if let anchor = anchors[flow.tourStep] {
                let rect = geometry[anchor]
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(accent, lineWidth: 3)
                    .shadow(color: accent.opacity(0.35), radius: 8)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // Keep the card beside the real panels and above the exposure controls.
            card
                .frame(width: 300)
                .fixedSize(horizontal: false, vertical: true)
                .position(x: cardX(width: geometry.size.width), y: geometry.size.height * 0.48)
        }
    }

    private func cardX(width: CGFloat) -> CGFloat {
        switch flow.tourStep {
        case .focus: width - 180
        case .light: 180
        default: width / 2
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Знакомство", systemImage: "sparkle").foregroundStyle(accent)
                Spacer()
                Text("\(flow.tourStep.rawValue + 1) / \(OnboardingFlow.TourStep.allCases.count)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }.font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach(OnboardingFlow.TourStep.allCases, id: \.self) { step in
                    Capsule().fill(step.rawValue <= flow.tourStep.rawValue ? accent : Color.primary.opacity(0.12))
                        .frame(height: 3)
                }
            }.accessibilityHidden(true)
            HStack {
                if flow.tourStep != .preview {
                    Button("Назад") { flow.back() }.buttonStyle(.bordered)
                }
                Spacer()
                Button(flow.tourStep == .settings ? "Готово" : "Далее") { flow.next() }
                    .buttonStyle(.borderedProminent)
            }.controlSize(.large)
            Button("Завершить тур") { flow.complete() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Интерактивный тур")
    }

    private var title: String {
        switch flow.tourStep {
        case .preview: "Это превью камеры"
        case .exposure: "Настрой картинку"
        case .focus: "Наведи резкость"
        case .light: "Подбери свет"
        case .settings: "Всё под рукой"
        }
    }

    private var detail: String {
        switch flow.tourStep {
        case .preview:
            "Здесь видео с Cam Link через HDMI. Превью включается на вкладке «Камера». Переход в настройки, закрытие или сворачивание окна освобождает Cam Link."
        case .exposure:
            "Выдержка, диафрагма и ISO находятся под превью. Нажми на значение, чтобы выбрать другое. Для управления подключи USB камеры к LightController — изменения применяются сразу."
        case .focus:
            "Нажми на объект прямо в превью, чтобы камера навела на него резкость. Рамка покажет выбранную точку. В панели «Фокус» можно выбрать режим и область автофокуса или подстроить резкость кнопками «Ближе» и «Дальше»."
        case .light:
            "Выбери цвет и яркость, затем нажми «Сохранить для созвонов». В меню Canon Rig в строке меню включи «Свет на созвоне», чтобы этот профиль включался при захвате видео. Во время тура автосвет приостановлен."
        case .settings:
            "На вкладке «Настройки» можно настроить сеть и Home Assistant. USB и Wi-Fi выбираются автоматически. Здесь же можно снова пройти тур."
        }
    }
}
