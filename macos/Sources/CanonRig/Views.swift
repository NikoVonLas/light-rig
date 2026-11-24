import AppKit
import CanonRigCore
import SwiftUI

struct StatusDot: View {
    let active: Bool
    var color: Color = .green
    var body: some View {
        Circle().fill(active ? color : Color.secondary.opacity(0.25)).frame(width: 9, height: 9)
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    private let signalGreen = Color(red: 0.39, green: 0.80, blue: 0.31)
    private let portBlue = Color(red: 0.32, green: 0.66, blue: 0.98)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 340)
        .background(.ultraThinMaterial)
        .tint(signalGreen)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "video")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(signalGreen)
                .frame(width: 36, height: 30)
                .background(signalGreen.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Canon Rig")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(model.client.isConnected ? signalGreen : .orange).frame(width: 6, height: 6)
                    Text(model.client.isConnected ? "LightController подключён" : "Поиск LightController")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: model.onCall ? "video.fill" : "checkmark.circle")
                    .foregroundStyle(model.onCall ? .red : signalGreen)
                Text(model.onCall ? "На созвоне" : "Свободен")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                Text(model.client.isConnected ? model.client.connectionLabel : "Нет связи")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(portBlue)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(portBlue.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Подключения")
                connectionRow("Камера", icon: "camera", detail: model.client.isConnected && model.client.state.cameraConnected
                    ? "Подключена" : "Нет связи", connected: model.client.isConnected && model.client.state.cameraConnected,
                    accent: signalGreen)
                connectionRow("Home Assistant", icon: "house", detail: model.client.isConnected && model.client.state.haConnected
                    ? "Подключён" : model.client.isConnected ? "Не подключён" : "Нет данных",
                    connected: model.client.isConnected && model.client.state.haConnected, accent: portBlue)
            }
            Toggle(isOn: $model.automatic) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Свет на созвоне").font(.system(size: 12))
                    Text("Включать автоматически")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { model.reconnect() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Переподключить LightController").accessibilityLabel("Переподключить LightController")
            Button {
                model.openMainWindow()
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: { Image(systemName: "gearshape") }
            .buttonStyle(.plain)
            .help("Открыть панель управления").accessibilityLabel("Открыть панель управления")
            Spacer()
            #if CANON_RIG_UPDATES
            Button("Обновления…") {
                CanonRigApplicationDelegate.updates.checkForUpdates(nil)
            }
            .buttonStyle(.plain)
            #endif
            Button("Выйти") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.8).foregroundStyle(.secondary)
    }

    private func connectionRow(_ title: String, icon: String, detail: String, connected: Bool, accent: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).frame(width: 16)
            Text(title).font(.system(size: 11, weight: .medium, design: .rounded))
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            Circle().fill(connected ? accent : Color.secondary.opacity(0.25)).frame(width: 6, height: 6)
        }
        .foregroundStyle(connected ? accent : .primary)
        .padding(.horizontal, 10).frame(height: 34)
        .background(connected ? accent.opacity(0.13) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(connected ? accent.opacity(0.32) : Color.primary.opacity(0.06), lineWidth: 1))
    }
}

struct ControlView: View {
    @State private var focusStep = 1
    @State private var showSettings = false
    @State private var showFocus = false
    @State private var showLight = false
    @ObservedObject var model: AppModel
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "video")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.39, green: 0.80, blue: 0.31))
                    .frame(width: 36, height: 30)
                    .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                Text("Canon Rig").font(.system(.headline, design: .rounded, weight: .semibold))
                StatusDot(active: model.client.isConnected && model.client.state.cameraConnected,
                          color: model.onCall ? .red : .green)
                Text(model.onCall ? "На созвоне" : model.client.state.cameraConnected && model.client.isConnected ? "Готов" : "Нет связи с камерой")
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Автоматически", isOn: $model.automatic).toggleStyle(.switch).controlSize(.small)
                    .tourTarget(.automation)
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .help("Подключение и настройки").accessibilityLabel("Настройки")
                    .tourTarget(.settings)
                    .popover(isPresented: $showSettings, arrowEdge: .top) {
                        RigSettingsView(model: model)
                    }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(.ultraThinMaterial)
            preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(model.client.cameraNotice ?? "Параметры применяются сразу. Свет для звонков — в панели «Свет».")
                    .lineLimit(2)
                Spacer()
                if model.client.cameraBusy { ProgressView().controlSize(.small) }
            }
            .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Color(red: 0.39, green: 0.80, blue: 0.31))
        .overlayPreferenceValue(TourAnchors.self) { anchors in
            if flow.step == .tour {
                InteractiveTour(flow: flow, anchors: anchors)
            }
        }
        .onChange(of: flow.tourStep) { _, _ in showTourPanel() }
        .onChange(of: flow.step) { _, _ in showTourPanel() }
        .onAppear {
            if !model.client.isConnected { model.client.connect() }
            showTourPanel()
        }
    }

    private func showTourPanel() {
        showFocus = flow.step == .tour && flow.tourStep == .focus
        showLight = flow.step == .tour && flow.tourStep == .light
        showSettings = false
    }

    private var preview: some View {
        ZStack {
            Color.black
            CameraPreview(controller: model.preview) { point, aspect in
                model.client.focusPoint(point, videoAspect: aspect)
            }
        }
        .tourTarget(.preview)
        .overlay(alignment: .bottomLeading) {
            HStack(alignment: .bottom, spacing: 8) {
                exposureChip("Выдержка", kind: .shutter, property: model.client.state.cameraShutter)
                exposureChip("Диафрагма", kind: .aperture, property: model.client.state.cameraAperture)
                exposureChip("ISO", kind: .iso, property: model.client.state.cameraISO)
                Spacer(minLength: 0)
            }
            .padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .tourTarget(.exposure)
            .padding(16).environment(\.colorScheme, .dark)
        }
        .overlay(alignment: .topLeading) {
            previewPanel(exposure, isVisible: showFocus)
                .tourTarget(.focus)
                .padding(.leading, 16).padding(.top, 70)
        }
        .overlay(alignment: .topTrailing) {
            previewPanel(lighting, isVisible: showLight)
                .tourTarget(.light)
                .padding(.trailing, 16).padding(.top, 70)
        }
        .overlay(alignment: .topLeading) {
            Button { showFocus.toggle(); showLight = false } label: {
                Label("Фокус", systemImage: "viewfinder").padding(8)
            }
            .buttonStyle(.bordered).tint(.black.opacity(0.7))
            .padding(16).environment(\.colorScheme, .dark)
        }
        .overlay(alignment: .topTrailing) {
            Button { showLight.toggle(); showFocus = false } label: {
                Label("Свет", systemImage: "lightbulb").padding(8)
            }
            .buttonStyle(.bordered).tint(.black.opacity(0.7))
            .padding(16).environment(\.colorScheme, .dark)
        }
    }

    private func previewPanel<Content: View>(_ content: Content, isVisible: Bool) -> some View {
        ScrollView { content.padding(14) }
            .frame(width: 350, height: 300)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .environment(\.colorScheme, .dark)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .transaction { $0.animation = nil }
    }

    private func exposureChip(_ title: String, kind: CameraExposureKind, property: CameraProperty) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(Array(Set(property.options)).sorted(), id: \.self) { value in
                    Button(kind.label(value)) { model.client.cameraSet(kind: kind, property: property, value: value) }
                }
            } label: {
                Text(kind.label(model.client.isConnected ? property.raw : nil))
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    .frame(minWidth: 90, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .disabled(!model.client.isConnected || !model.client.state.cameraCanSet || model.client.cameraBusy || !property.optionsKnown || property.options.isEmpty)
        }.padding(.horizontal, 8)
    }

    private var exposure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.client.state.cameraModel.isEmpty ? "Canon · PTP" : model.client.state.cameraModel)
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                exposureRow("Режим фокуса", kind: .focusMode, property: model.client.state.cameraFocusMode)
                exposureRow("Область AF", kind: .afMethod, property: model.client.state.cameraAFMethod)
                exposureRow("Servo AF (видео)", kind: .movieServo, property: model.client.state.cameraMovieServo)
            }
            HStack {
                Button("Навести AF") { model.client.autofocus() }
                    .disabled(!model.client.state.cameraCanAF)
                Button("Отменить AF") { model.client.cancelAutofocus() }
                    .disabled(!model.client.state.cameraCanCancelAF)
            }
            .disabled(!model.client.isConnected || model.client.cameraBusy)
            HStack {
                Button("Ближе") { model.client.focusStep(far: false, step: focusStep) }
                Picker("Шаг", selection: $focusStep) {
                    Text("Малый").tag(1)
                    Text("Средний").tag(2)
                    Text("Большой").tag(3)
                }
                Button("Дальше") { model.client.focusStep(far: true, step: focusStep) }
            }
            .disabled(!model.client.isConnected || model.client.cameraBusy || !model.client.state.cameraCanFocusStep)
            Text("Для ручной подстройки отключи Servo AF (видео), иначе камера может перефокусироваться.")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.client.cameraNotice ?? "Выбор применяется сразу. Значения обновляются по ответу камеры.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private func exposureRow(_ title: String, kind: CameraExposureKind, property: CameraProperty) -> some View {
        GridRow {
            Text(title)
            if model.client.isConnected && model.client.state.cameraCanSet && property.optionsKnown && !property.options.isEmpty {
                Picker(title, selection: Binding<UInt32?>(get: { property.raw }, set: { value in
                    if let value, value != property.raw {
                        model.client.cameraSet(kind: kind, property: property, value: value)
                    }
                })) {
                    if property.raw == nil { Text("—").tag(nil as UInt32?) }
                    if let current = property.raw, !property.options.contains(current) {
                        Text(kind.label(current)).tag(Optional(current))
                    }
                    ForEach(Array(Set(property.options)).sorted(), id: \.self) { value in
                        Text(kind.label(value)).tag(Optional(value))
                    }
                }
                .labelsHidden()
                .disabled(model.client.cameraBusy || property.raw == nil)
            } else {
                Text(kind.label(model.client.isConnected ? property.raw : nil)).monospacedDigit()
                    .help("Камера не предоставила доступные варианты изменения в текущем режиме")
            }
        }
    }

    private var lighting: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Цвет света", selection: $model.lightColorMode) {
                Text("RGB").tag(LightColorMode.rgb)
                Text("Температура").tag(LightColorMode.temperature)
            }
            .pickerStyle(.segmented).labelsHidden()

            if model.lightColorMode == .temperature {
                HStack {
                    Text("Температура белого")
                    Spacer()
                    Text("\(model.lightKelvin, format: .number.grouping(.never)) K").monospacedDigit()
                }
                Slider(value: Binding(get: { Double(model.lightKelvin) },
                                      set: { model.lightKelvin = Int($0.rounded()) }),
                       in: Double(LightRGB.kelvinRange.lowerBound)...Double(LightRGB.kelvinRange.upperBound), step: 100) {
                    Text("Температура белого")
                }
                .labelsHidden().tint(model.lightColor.color)
                HStack {
                    Text("Теплее")
                    Spacer()
                    Text("Холоднее")
                }.font(.caption).foregroundStyle(.secondary)
            } else if !model.usesAnimatedColors {
                HStack(spacing: 22) {
                    LightColorWheel(selection: $model.wheel).padding(6)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 6).fill(model.lightColor.color)
                            .frame(width: 38, height: 20)
                        Text(String(format: "#%02X%02X%02X", model.lightColor.red, model.lightColor.green, model.lightColor.blue))
                            .font(.caption.monospaced())
                    }
                }
            }

            valueSlider("Яркость", value: $model.lightBrightness, range: 0...100, suffix: "%")
            Picker("Эффект", selection: $model.lightEffect) {
                Text("Статичный").tag("solid")
                Text("Дыхание").tag("breathe")
                if model.lightColorMode == .rgb {
                    Text("Радуга").tag("rainbow")
                    Text("Смена цветов").tag("color_cycle")
                }
            }
            if model.lightEffect != "solid" {
                valueSlider("Скорость", value: $model.lightSpeed, range: 0...100)
            }
            HStack {
                Button("Выключить") { model.applyLight(enabled: false) }
                Spacer()
                Button("Сохранить для созвонов") { model.saveLightPreset() }
                    .disabled(!model.client.isConnected)
            }
            if let notice = model.profileNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
    }

    private func valueSlider(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String = "") -> some View {
        HStack {
            Text(title).frame(width: 66, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            Text("\(value.wrappedValue)\(suffix)").monospacedDigit().frame(width: 40)
        }
    }


}
