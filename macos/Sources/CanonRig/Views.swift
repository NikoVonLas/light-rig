import AppKit
import CanonRigCore
import SwiftUI

struct RigHeaderIcon: View {
    let onCall: Bool

    var body: some View {
        Image(systemName: onCall ? "video.fill" : "video")
            .font(.system(size: 23, weight: .medium))
            .foregroundStyle(onCall ? Color.red : .secondary)
            .accessibilityHidden(true)
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RigHeaderIcon(onCall: model.onCall)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Canon Rig").font(.system(size: 15, weight: .semibold))
                    Text(model.client.isConnected ? "LightController · " + model.client.connectionLabel : "Поиск LightController…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.reconnect() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Переподключить LightController").accessibilityLabel("Переподключить LightController")
            }
            .padding(.horizontal, 18).padding(.top, 15)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Свет на созвоне", systemImage: "lightbulb").font(.headline)
                    Spacer()
                    Toggle("Включать автоматически", isOn: $model.automatic)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .help("Включать подсветку автоматически во время созвона")
                }
                Label(model.onCall ? "На созвоне" : "Свободен", systemImage: model.onCall ? "video.fill" : "video")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background { MenuPanelField() }
            .padding(.horizontal, 10).padding(.vertical, 8)

            VStack(spacing: 10) {
                connectionRow("Камера", icon: "camera",
                              connected: model.client.isConnected && model.client.state.cameraConnected,
                              detail: model.client.isConnected && model.client.state.cameraConnected ? "Подключена" : "Нет связи")
                connectionRow("Home Assistant", icon: "house",
                              connected: model.client.isConnected && model.client.state.haConnected,
                              detail: model.client.isConnected ? (model.client.state.haConnected ? "Подключён" : "Не подключён") : "Нет данных")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background { MenuPanelField() }
            .padding(.horizontal, 10).padding(.bottom, 12)

            HStack {
                Button {
                    dismiss()
                    model.openMainWindow()
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Label("Панель управления…", systemImage: "slider.horizontal.3") }
                Spacer()
                #if CANON_RIG_UPDATES
                Button("Обновления…") { dismiss(); CanonRigApplicationDelegate.updates.checkForUpdates(nil) }
                #endif
                Button("Выйти") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20).padding(.bottom, 14)
        }
        .frame(width: 356)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MenuPanelSurface())
    }

    private func connectionRow(_ title: String, icon: String, connected: Bool, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Image(systemName: connected ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(connected ? Color.green : .secondary)
                .accessibilityHidden(true)
        }
    }
}

struct ControlView: View {
    @State private var focusStep = 1
    @State private var showFocus = false
    @State private var showLight = false
    @ObservedObject var model: AppModel
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        Group {
            switch model.windowTab {
            case .camera: cameraTab
            case .settings: RigSettingsView(model: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var cameraTab: some View {
        preview
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if model.client.cameraBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .padding(7)
                        .background(.black.opacity(0.6), in: Circle())
                        .padding(.top, 16)
                        .accessibilityLabel("Камера выполняет команду")
                        .allowsHitTesting(false)
                }
            }
    }

    private func showTourPanel() {
        showFocus = flow.step == .tour && flow.tourStep == .focus
        showLight = flow.step == .tour && flow.tourStep == .light
        if flow.step == .tour { model.selectTab(flow.tourStep == .settings ? .settings : .camera) }
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
            .padding(16)
        }
        .overlay(alignment: .topLeading) {
            previewPanel(exposure, isVisible: showFocus)
                .tourTarget(.focus)
                .padding(.bottom, 96)
                .padding(.leading, 16).padding(.top, 70)
        }
        .overlay(alignment: .topTrailing) {
            previewPanel(lighting, isVisible: showLight)
                .tourTarget(.light)
                .padding(.bottom, 96)
                .padding(.trailing, 16).padding(.top, 70)
        }
        .overlay(alignment: .topLeading) {
            Button { showFocus.toggle(); showLight = false } label: {
                Label("Фокус", systemImage: "viewfinder").padding(5)
            }
            .buttonStyle(.bordered)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            Button { showLight.toggle(); showFocus = false } label: {
                Label("Свет", systemImage: "lightbulb").padding(5)
            }
            .buttonStyle(.bordered)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(16)
        }
    }

    private func previewPanel<Content: View>(_ content: Content, isVisible: Bool) -> some View {
        let controls = content.padding(12)
        return ViewThatFits(in: .vertical) {
            controls.fixedSize(horizontal: false, vertical: true)
            ScrollView { controls }
        }
            .frame(width: 350)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary, lineWidth: 1)
                    .allowsHitTesting(false)
            }
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
        VStack(alignment: .leading, spacing: 9) {
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
                HStack(alignment: .center, spacing: 18) {
                    LightColorWheel(selection: $model.wheel).padding(6)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(model.lightColor.color)
                                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15)) }
                                .frame(width: 22, height: 18)
                            Text(String(format: "#%02X%02X%02X", model.lightColor.red, model.lightColor.green, model.lightColor.blue))
                                .font(.subheadline.monospaced())
                        }
                        brightnessSlider
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if model.lightColorMode == .temperature || model.usesAnimatedColors {
                brightnessSlider
            }
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
                Button(model.client.state.lightEnabled == true ? "Выключить" : "Включить") {
                    model.toggleLightPower()
                }
                .disabled(!model.client.isConnected || !model.client.state.lightReady || model.client.state.lightEnabled == nil)
                Spacer()
                Button("Сохранить для созвонов") { model.saveLightPreset() }
                    .disabled(!model.client.isConnected)
            }
            if let notice = model.client.profileNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
    }

    private var brightnessSlider: some View {
        valueSlider("Яркость", value: $model.lightBrightness, range: 0...100, suffix: "%")
    }

    private func valueSlider(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text("\(value.wrappedValue)\(suffix)")
                    .font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .controlSize(.large).accessibilityLabel(title)
        }
    }


}
