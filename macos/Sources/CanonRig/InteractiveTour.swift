import AppKit
import CanonRigCore
import SwiftUI

/// One window owner for both the menu bar and the setup wizard, including cold launch.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private weak var model: AppModel?
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() {
        showWindow(nil)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model?.syncPreviewWithWindow()
    }
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
    private let accent = Color(red: 0.39, green: 0.80, blue: 0.31)

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
                Text(title).font(.system(size: 20, weight: .semibold, design: .rounded))
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
                    .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
            }.controlSize(.large)
            Button("Завершить тур") { flow.complete() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.4)))
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
        case .automation: "Свет включится на звонке"
        case .settings: "Всё под рукой"
        }
    }

    private var detail: String {
        switch flow.tourStep {
        case .preview:
            "Здесь видео с Cam Link через HDMI. Когда окно открыто, превью включается автоматически. Закрой или сверни окно, чтобы освободить камеру."
        case .exposure:
            "Выдержка, диафрагма и ISO находятся под превью. Нажми на значение, чтобы выбрать другое. Для управления подключи USB камеры к LightController — изменения применяются сразу."
        case .focus:
            "Мы открыли панель «Фокус». Здесь режим AF, область фокусировки и ручные шаги «Ближе» и «Дальше». Доступные команды зависят от режима камеры. Попробовать можно прямо сейчас."
        case .light:
            "В панели «Свет» выбери цвет, яркость и эффект. Управление применяется сразу. Здесь же можно сохранить профиль для созвонов. Кнопка «Свет» открывает и закрывает эту панель."
        case .automation:
            "Переключатель «Автоматически» разрешает включать сохранённый свет при захвате камеры, включая превью Canon Rig. Когда захват заканчивается, свет гаснет. Во время тура автоматика приостановлена."
        case .settings:
            "Шестерёнка открывает подключение и настройки. USB и Wi-Fi выбираются автоматически. Здесь можно настроить сеть позже или снова запустить знакомство с приложением."
        }
    }
}
