import AppKit
import CanonRigCore
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private var onClose: () -> Void
    init(model: AppModel, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Знакомство с Light Rig"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(model: model, flow: model.onboarding) { [weak window] height in
            guard let window, height > 0 else { return }
            let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 540, height: ceil(height))).size
            guard abs(window.frame.height - size.height) > 1 else { return }
            var frame = window.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            window.setFrame(frame, display: true)
        })
        window.center()
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func hideForApplication() { window?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { onClose() }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flow: OnboardingFlow
    var onHeightChange: (CGFloat) -> Void
    @State private var manualNetwork = false
    @State private var networkPickerOpen = false
    private let accent = Color.accentColor
    private var sameBoard: Bool { model.client.isConnected && model.client.state.deviceID == flow.deviceID }
    private var usbReady: Bool { sameBoard && model.client.activeConnectionMode == .usb }
    private var validCredentials: Bool {
        !model.routerSSID.isEmpty && model.routerSSID.utf8.count <= 32 &&
        (8...63).contains(model.routerPassword.utf8.count)
    }
    private var networkFailed: Bool {
        if case .failed = model.client.networkSetupStatus { return true }; return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                Image(systemName: "video").font(.system(size: 23, weight: .medium)).foregroundStyle(.secondary)
                Text("Light Rig").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(flow.step == .invitation ? "2 из 2" : "1 из 2")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                switch flow.step {
                case .connection, nil: connection
                case .wifi: wifi
                case .waiting: waiting
                case .invitation, .tour: invitation
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(28)
        .frame(width: 540, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: OnboardingHeight.self, value: geometry.size.height)
        })
        .onPreferenceChange(OnboardingHeight.self) { height in
            DispatchQueue.main.async { onHeightChange(height) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .onChange(of: model.client.state.wifiNetworks) { _, networks in
            if model.routerSSID.isEmpty, let first = networks.first { model.routerSSID = first.ssid }
        }
    }

    private func title(_ text: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.system(size: 22, weight: .semibold))
            Text(detail).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 22) {
            title("Light Rig найден", detail: "Настроим подключение один раз. Потом приложение будет само выбирать USB или Wi-Fi.")
            VStack(alignment: .leading, spacing: 14) {
                Label("Mac → встроенный USB-C Light Rig", systemImage: "laptopcomputer")
                Label("Canon → отдельный USB-разъём", systemImage: "camera")
                Text("Разъём для Canon не подключай к компьютеру: он предназначен для камеры.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            Text("С Wi-Fi плату можно питать от блока. USB остаётся доступен в любой момент.")
                .foregroundStyle(.secondary)
            if !usbReady { disconnected }
            HStack(spacing: 12) {
                Button { model.beginOnboardingWiFi() } label: {
                    Label("Настроить Wi-Fi", systemImage: "wifi")
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!usbReady)
                Button { model.continueOnboardingUSB() } label: {
                    Label("Продолжить по USB", systemImage: "cable.connector")
                }.buttonStyle(.bordered).controlSize(.large).disabled(!usbReady)
            }
        }
    }

    private var wifi: some View {
        VStack(alignment: .leading, spacing: 20) {
            title("Подключение к Wi-Fi", detail: "Выбери домашнюю сеть 2,4 ГГц. Настройки сохранятся на Light Rig — повторно вводить их не придётся.")
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Сеть").fontWeight(.medium)
                    Spacer()
                    if model.client.state.supportsWiFiScan {
                        if model.client.state.wifiScanStatus == "scanning" {
                            ProgressView().controlSize(.mini)
                            Text("Поиск…").foregroundStyle(.secondary)
                        } else {
                            Button { model.client.scanWiFi() } label: {
                                Label("Обновить", systemImage: "arrow.clockwise")
                            }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(!usbReady)
                        }
                    }
                }.font(.system(size: 13))
                if manualNetwork || model.client.state.wifiNetworks.isEmpty {
                    TextField("Название сети", text: $model.routerSSID)
                        .textFieldStyle(.plain).onboardingField()
                } else {
                    Button { networkPickerOpen = true } label: {
                        HStack {
                            Image(systemName: "wifi").foregroundStyle(.secondary)
                            Text(model.routerSSID.isEmpty ? "Выбери сеть" : model.routerSSID)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                        }.onboardingField()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Сеть: \(model.routerSSID)")
                    .popover(isPresented: $networkPickerOpen, arrowEdge: .bottom) {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(model.client.state.wifiNetworks) { network in
                                    Button {
                                        model.routerSSID = network.ssid
                                        networkPickerOpen = false
                                    } label: {
                                        HStack {
                                            Text(network.ssid).lineLimit(1)
                                            Spacer()
                                            if network.ssid == model.routerSSID {
                                                Image(systemName: "checkmark").foregroundStyle(accent)
                                            }
                                        }
                                        .padding(.horizontal, 10).frame(height: 34)
                                        .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }.padding(8)
                        }
                        .frame(width: 440, height: min(CGFloat(model.client.state.wifiNetworks.count) * 36 + 16, 300))
                    }
                }
                if !model.client.state.wifiNetworks.isEmpty {
                    Toggle("Ввести название сети вручную", isOn: $manualNetwork)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Пароль").font(.system(size: 13, weight: .medium))
                RevealablePasswordField(text: $model.routerPassword)
            }
            Label("Не отключай USB до подтверждения подключения.", systemImage: "cable.connector")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if model.client.state.wifiScanStatus == "failed" {
                Text("Не получилось найти сети. Обнови список или введи название вручную.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !usbReady { disconnected }
            HStack(spacing: 12) {
                Button("Назад") { model.routerPassword = ""; flow.backToConnection() }
                    .buttonStyle(.bordered).controlSize(.large).frame(width: 100)
                Button("Подключить к Wi-Fi") { model.connectOnboardingWiFi() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!usbReady || !validCredentials)
            }
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 22) {
            title(networkFailed ? "Пока не подключились" : "Подключаем Light Rig", detail: "После сохранения сети плата перезапустится. Окно продолжит настройку, когда Light Rig подтвердит подключение.")
            if !networkFailed { ProgressView().controlSize(.large) }
            switch model.client.networkSetupStatus {
            case .failed(let message): Text(message).foregroundStyle(.orange)
            case .sending: Text("Передаём настройки по USB…")
            default: Text(sameBoard ? "Ждём подключения к Wi-Fi и получения адреса…" : "Ждём возвращения платы после перезапуска…")
            }
            Text("Не отключай USB. Пароль повторно не отправляется.").font(.callout).foregroundStyle(.secondary)
            if networkFailed {
                Button("Изменить сеть или пароль") { model.beginOnboardingWiFi() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!usbReady)
            }
            Button("Продолжить по USB") { model.continueOnboardingUSB() }
                .buttonStyle(.bordered).controlSize(.large).disabled(!usbReady)
        }
    }

    private var invitation: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(flow.usesWiFi ? "Wi-Fi подключён" : "Продолжаем по USB", systemImage: "checkmark.circle.fill")
                .foregroundStyle(accent)
            title("Показать, как всё работает?", detail: "Короткий интерактивный тур прямо в приложении: превью, настройки камеры, фокус и свет.")
            Label("Подсветим нужные кнопки и откроем панели", systemImage: "cursorarrow.rays")
                .font(.callout)
            Text("Можно попробовать управление, вернуться назад или закончить в любой момент. Тур доступен и позже в настройках.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Пройти тур") { model.enterApplication(withTour: true) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Пропустить") { model.enterApplication(withTour: false) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
    }

    private var disconnected: some View {
        Label("Подключи этот Light Rig к Mac встроенным USB-C.", systemImage: "cable.connector")
            .font(.callout).foregroundStyle(.orange)
    }
}

private struct OnboardingHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    func onboardingField() -> some View {
        self.font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
    }
}

struct RevealablePasswordField: View {
    @Binding var text: String
    @State private var revealed = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if revealed { TextField("Пароль сети", text: $text) }
                else { SecureField("Пароль сети", text: $text) }
            }
            .textFieldStyle(.plain).focused($focused)
            Button {
                revealed.toggle()
                focused = true
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .frame(width: 22, height: 28)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(revealed ? "Скрыть пароль" : "Показать пароль")
            .accessibilityLabel(revealed ? "Скрыть пароль" : "Показать пароль")
        }
        .onboardingField()
        .onDisappear { revealed = false }
    }
}
