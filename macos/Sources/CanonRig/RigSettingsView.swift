import SwiftUI
import UniformTypeIdentifiers
import CanonRigCore

struct RigSettingsView: View {
    private enum Section: String, CaseIterable { case network = "Сеть", homeAssistant = "Home Assistant", calls = "Созвоны" }
    @ObservedObject var model: AppModel
    @State private var section: Section = .network
    @State private var mqttHost = ""
    @State private var mqttPort = "8883"
    @State private var mqttTLS = true
    @State private var mqttUsername = ""
    @State private var mqttPassword = ""
    @State private var mqttCA = ""
    @State private var apPassword = ""
    @State private var showAPPassword = false
    @State private var pickingCertificate = false
    @State private var certificateError: String?
    private var board: String {
        model.client.isConnected && model.client.activeConnectionMode == .usb ? model.client.state.deviceID : ""
    }

    private let signalGreen = Color(red: 0.39, green: 0.80, blue: 0.31)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("НАСТРОЙКИ")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(model.client.isConnected ? signalGreen : .orange)
                    .frame(width: 6, height: 6)
                Text(model.client.isConnected ? "LightController подключён" : "Нет связи")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()
            Picker("Раздел настроек", selection: $section) {
                ForEach(Section.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch section {
                    case .network: networkSettings
                    case .homeAssistant: homeAssistantSettings
                    case .calls: detectorStatus
                    }
                    if section != .network, let error = model.client.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .frame(width: 390, height: 500)
        .background(.ultraThinMaterial)
        .tint(signalGreen)
        .font(.system(size: 12))
        .controlSize(.small)
        .toggleStyle(.switch)
        .groupBoxStyle(SettingsGroupStyle())
        .task(id: board) {
            mqttPassword = ""; apPassword = ""; mqttUsername = ""; mqttCA = ""; showAPPassword = false
            certificateError = nil
            loadBroker()
            model.client.readUSBSettings()
        }
        .onReceive(model.client.$usbSettings) { values in
            guard let values, !board.isEmpty else { return }
            if case .string(let user) = values["username"] { mqttUsername = user }
            if case .string(let ca) = values["caPEM"] { mqttCA = ca }
            if case .string(let pass) = values["apPassword"] { apPassword = pass }
            loadBroker()
        }
        .fileImporter(isPresented: $pickingCertificate, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: 3073) ?? Data()
                guard data.count <= 3072, let pem = String(data: data, encoding: .utf8),
                      pem.hasPrefix("-----BEGIN CERTIFICATE-----"), !pem.contains("PRIVATE KEY") else {
                    certificateError = "Выбери корневой сертификат PEM до 3072 байт"; return
                }
                mqttCA = pem; certificateError = nil
            } catch { certificateError = error.localizedDescription }
        }
        .onDisappear {
            mqttPassword = ""
            model.routerPassword = ""
        }
    }

    private var networkSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Связь с платой").font(.headline)
                Label(model.client.isConnected ? "LightController подключён к этому Mac" : "LightController не найден",
                      systemImage: model.client.isConnected ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.client.isConnected ? .green : .orange)
                Text("Подключение выбирается автоматически: USB при подключённом кабеле, иначе Wi-Fi. Сеть платы нужно настроить один раз по USB.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Button("Пройти интерактивный тур") { model.restartTour() }
            Button("Пройти быструю настройку") { model.restartOnboarding() }
                .disabled(!model.client.isConnected || model.client.state.deviceID.isEmpty)
            GroupBox("Домашняя сеть") {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Текущий режим: \(model.client.state.networkMode == "router" ? "домашняя сеть" : model.client.state.networkMode == "ap" ? "точка доступа LightController" : model.client.state.networkMode == "usb" ? "только USB" : "неизвестен")")
                    if model.client.state.wifiConnected {
                        Label("Wi-Fi подключён · \(model.client.state.ipAddress)", systemImage: "wifi")
                            .foregroundStyle(.green)
                    }
                    Picker("Режим платы", selection: $model.deviceNetworkMode) {
                        Text("Домашняя сеть").tag("router")
                        Text("Точка доступа LightController").tag("ap")
                        Text("Без Wi-Fi").tag("usb")
                    }
                    .pickerStyle(.segmented)
                    if model.deviceNetworkMode == "router" {
                        TextField("Название сети (SSID)", text: $model.routerSSID)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Пароль сети", text: $model.routerPassword)
                            .textFieldStyle(.roundedBorder)
                        Text("Введи один раз при подключении по USB. Сеть 2,4 ГГц; пароль сохраняется на LightController, а на Mac очищается после отправки.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.deviceNetworkMode == "ap" {
                        if !board.isEmpty && model.client.state.hasPersistentSettings {
                            if showAPPassword { TextField("Пароль точки доступа", text: $apPassword) }
                            else { SecureField("Пароль точки доступа", text: $apPassword) }
                            Toggle("Показать пароль", isOn: $showAPPassword)
                        } else { Text("Пароль точки доступа доступен по USB с новой прошивкой.") }
                    }
                    Button("Сохранить сеть и перезапустить плату") {
                        if model.deviceNetworkMode == "ap" {
                            model.client.configureNetwork(mode: "ap", apPassword: apPassword)
                        } else { model.configureDeviceNetwork() }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.client.isConnected ||
                                  (model.deviceNetworkMode == "router" &&
                                   (model.routerSSID.isEmpty || model.routerSSID.utf8.count > 32 ||
                                    model.routerPassword.utf8.count < 8 || model.routerPassword.utf8.count > 63)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox("Подключение этого Mac") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.client.connectionLabel,
                          systemImage: model.client.activeConnectionMode == .usb ? "cable.connector" : "wifi")
                    Text("USB и Wi-Fi переключаются автоматически. Для связи по сети Mac и LightController должны быть доступны друг другу.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Повторить поиск") { model.reconnect() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .failed(let message) = model.client.networkSetupStatus {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if let error = model.client.lastError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let notice = model.client.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var detectorStatus: some View {
        GroupBox("Автодетект созвона") {
            VStack(alignment: .leading, spacing: 7) {
                Toggle("Включать свет при захвате видео", isOn: $model.automatic)
                Text("Используется один профиль «Созвон». Настрой свет в панели поверх кадра и сохрани его для звонков.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Микрофон: \(model.capture.microphoneApps.joined(separator: ", ").nilIfEmpty ?? "не используется приложением созвона")")
                Text("Камеры: \(model.capture.activeCameras.joined(separator: ", ").nilIfEmpty ?? "не используются")")
                Text("Вход: 2 с · выход: 3 с. Потеря связи с Mac: 8 с.")
                Text("Превью Canon Rig тоже включает свет.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var homeAssistantSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Home Assistant").font(.headline)
                Label(model.client.state.haConnected ? "LightController подключён к Home Assistant" :
                      model.client.state.haNeedsCredentials ? "Нужен пароль MQTT после перезапуска" :
                      model.client.state.haEnabled ? "Ожидание подключения MQTT" : "Ещё не подключён",
                      systemImage: model.client.state.haConnected ? "checkmark.circle.fill" : "house")
                    .foregroundStyle(model.client.state.haConnected ? .green : .primary)
                if !model.client.state.wifiConnected {
                    Text("Сначала подключи LightController к домашней сети в разделе «Сеть».")
                        .foregroundStyle(.orange)
                }
            }
            GroupBox("Доступ к Home Assistant") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Адрес MQTT-брокера", text: $mqttHost)
                    TextField("Порт", text: $mqttPort)
                    Toggle("TLS", isOn: $mqttTLS)
                    TextField("Имя пользователя (если требуется)", text: $mqttUsername)
                    SecureField(model.client.state.haRequiresAuth && !model.client.state.haNeedsCredentials ?
                                "Новый пароль (по желанию)" : "Пароль MQTT", text: $mqttPassword)
                    if mqttTLS {
                        HStack {
                            Button(mqttCA.isEmpty ? "Выбрать сертификат CA…" : "Заменить сертификат CA…") { pickingCertificate = true }
                            if !mqttCA.isEmpty { Button("Убрать") { mqttCA = ""; certificateError = nil } }
                        }
                        Text(mqttCA.isEmpty ? "Проверка по системным корневым сертификатам." : "Выбран пользовательский корневой сертификат.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let certificateError { Text(certificateError).foregroundStyle(.orange) }
                    }
                    Button("Сохранить на контроллере") {
                        model.client.configureHomeAssistant(enabled: true, host: mqttHost.trimmingCharacters(in: .whitespacesAndNewlines),
                            port: Int(mqttPort) ?? 0, tls: mqttTLS, username: mqttUsername,
                            password: mqttPassword, caPEM: mqttTLS ? mqttCA : "")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(board.isEmpty || model.client.usbSettings == nil || mqttHost.isEmpty)
                    if board.isEmpty { Text("Для сохранения подключи LightController по USB.") }
                    else if !model.client.state.hasPersistentSettings { Text("Для сохранения нужна новая прошивка LightController.") }
                    if let notice = model.client.mqttNotice { Text(notice).font(.caption) }
                }.textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if model.client.state.haEnabled {
                Button("Отключить Home Assistant") {
                    model.client.configureHomeAssistant(enabled: false, host: "", port: 1883, tls: false)
                }
                .disabled(!model.client.isConnected || model.client.activeConnectionMode != .usb)
            }
            if !model.client.state.presenceClients.isEmpty {
                Divider()
                Text("Компьютеры").font(.headline)
                ForEach(model.client.state.presenceClients) { client in
                    HStack {
                        Text(client.name).lineLimit(1)
                        Spacer()
                        Text(!client.available ? "Нет данных" : client.onCall == true ? "На звонке" : "Свободен")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: model.client.mqttNotice) { _, notice in
            if notice == "Настройки сохранены на LightController" { mqttPassword = "" }
        }
    }

    private func loadBroker() {
        let state = model.client.state
        mqttHost = state.haHost
        mqttPort = state.haHost.isEmpty ? "8883" : String(state.haPort)
        mqttTLS = state.haHost.isEmpty || state.haTLS
    }
}

private struct SettingsGroupStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.system(size: 11, weight: .semibold, design: .rounded))
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
