import SwiftUI
import UniformTypeIdentifiers
import CanonRigCore

struct RigSettingsView: View {
    private enum SettingsTab: String, CaseIterable {
        case network = "Сеть", homeAssistant = "Home Assistant"

        var icon: String {
            switch self {
            case .network: "wifi"
            case .homeAssistant: "house"
            }
        }
    }
    @ObservedObject var model: AppModel
    @State private var section: SettingsTab = .network
    @State private var draftNetworkMode: String?
    private enum NetworkChoice: Hashable { case none, ssid(String), other }
    @State private var draftNetwork: NetworkChoice?
    @State private var manualSSID = ""
    @State private var networkPassword = ""
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

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsTab.allCases, id: \.self, selection: $section) { tab in
                Label(tab.rawValue, systemImage: tab.icon).tag(tab)
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Разделы настроек")
            .frame(width: 170)
            .tourTarget(.settings)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(section.rawValue)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 20).padding(.top, 16)
                Form {
                    switch section {
                    case .network: networkSettings
                    case .homeAssistant: homeAssistantSettings
                    }
                    if section != .network, let error = model.client.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .background(.background)
            .id(section)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.client.state.deviceID) { _, _ in
            draftNetworkMode = nil
            draftNetwork = nil
            manualSSID = ""
            networkPassword = ""
        }
        .onChange(of: model.client.state.networkMode) { _, mode in
            if draftNetworkMode == mode { draftNetworkMode = nil }
        }
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
            networkPassword = ""
        }
    }

    private var networkSettings: some View {
        Group {
            Section("LightController") {
                LabeledContent("Подключение", value: model.client.connectionLabel)
                if model.client.state.wifiConnected {
                    LabeledContent("IP-адрес", value: model.client.state.ipAddress)
                }
            }
            Section {
                Picker("Режим платы", selection: Binding(get: { selectedNetworkMode }, set: { mode in
                    draftNetworkMode = mode == model.client.state.networkMode ? nil : mode
                })) {
                    if selectedNetworkMode == "unknown" { Text("Нет данных").tag("unknown") }
                    Text("Домашняя сеть").tag("router")
                    Text("Точка доступа LightController").tag("ap")
                    Text("Без Wi-Fi").tag("usb")
                }
                .pickerStyle(.menu)
                if selectedNetworkMode == "router" {
                    routerFields
                }
                if selectedNetworkMode == "ap" {
                    if !board.isEmpty && model.client.state.hasPersistentSettings {
                        if showAPPassword { TextField("Пароль точки доступа", text: $apPassword) }
                        else { SecureField("Пароль точки доступа", text: $apPassword) }
                        Toggle("Показать пароль", isOn: $showAPPassword)
                    } else { Text("Пароль точки доступа доступен по USB с новой прошивкой.") }
                }
                Button("Сохранить сеть и перезапустить плату") {
                    let replacingCredentials = selectedNetworkMode == "router" && !networkPassword.isEmpty
                    if model.client.configureNetwork(mode: selectedNetworkMode,
                        ssid: replacingCredentials ? selectedSSID : "",
                        password: replacingCredentials ? networkPassword : "",
                        apPassword: selectedNetworkMode == "ap" ? apPassword : "") {
                        networkPassword = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.client.isConnected || selectedNetworkMode == "unknown" ||
                          (selectedNetworkMode == "router" && !canSaveRouter))
            } header: {
                Text("Сеть контроллера")
            }
            Section("Знакомство с приложением") {
                LabeledContent("Первое подключение") {
                    Button("Быстрая настройка…") { model.restartOnboarding() }
                        .disabled(!model.client.isConnected || model.client.state.deviceID.isEmpty)
                }
                LabeledContent("Управление камерой и светом") {
                    Button("Пройти тур…") { model.restartTour() }
                }
            }
            if case .failed(let message) = model.client.networkSetupStatus {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if let error = model.client.lastError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let notice = model.client.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var savedSSID: String {
        model.client.isConnected ? model.client.state.networkSSID : ""
    }

    private var networkChoice: NetworkChoice {
        draftNetwork ?? (savedSSID.isEmpty ? .none : .ssid(savedSSID))
    }

    private var selectedSSID: String {
        switch networkChoice {
        case .none: ""
        case .ssid(let ssid): ssid
        case .other: manualSSID
        }
    }

    private var usesSavedNetwork: Bool { !savedSSID.isEmpty && selectedSSID == savedSSID }

    private var canSaveRouter: Bool {
        if networkPassword.isEmpty { return usesSavedNetwork }
        return (1...32).contains(selectedSSID.utf8.count) && (8...63).contains(networkPassword.utf8.count)
    }

    @ViewBuilder private var routerFields: some View {
        let networks = model.client.state.wifiNetworks.map(\.ssid)
        Picker("Сеть Wi-Fi", selection: Binding(get: { networkChoice }, set: { choice in
            draftNetwork = choice
            networkPassword = ""
        })) {
            if networkChoice == .none {
                Text(model.client.state.wifiScanStatus == "scanning" ? "Поиск сетей…" : "Выбери сеть")
                    .tag(NetworkChoice.none)
            }
            if !savedSSID.isEmpty && !networks.contains(savedSSID) {
                Text(savedSSID).tag(NetworkChoice.ssid(savedSSID))
            }
            if case .ssid(let ssid) = draftNetwork, ssid != savedSSID && !networks.contains(ssid) {
                Text(ssid).tag(NetworkChoice.ssid(ssid))
            }
            ForEach(networks, id: \.self) { ssid in Text(ssid).tag(NetworkChoice.ssid(ssid)) }
            Divider()
            Text("Другая сеть…").tag(NetworkChoice.other)
        }
        .pickerStyle(.menu)
        .task(id: board) {
            if !board.isEmpty && model.client.state.wifiScanStatus != "scanning" { model.client.scanWiFi() }
        }
        if networkChoice == .other {
            TextField("Название сети", text: $manualSSID)
                .onChange(of: manualSSID) { _, _ in networkPassword = "" }
        }
        SecureField("Пароль сети", text: $networkPassword,
                    prompt: Text(usesSavedNetwork ? "••••••••" : "Введи пароль"))
    }

    private var selectedNetworkMode: String {
        if let draftNetworkMode { return draftNetworkMode }
        let mode = model.client.state.networkMode
        return model.client.isConnected && ["router", "ap", "usb"].contains(mode) ? mode : "unknown"
    }

    private var homeAssistantSettings: some View {
        Group {
            Section("Состояние подключения") {
                Label(model.client.state.haConnected ? "Контроллер подключён" :
                      model.client.state.haNeedsCredentials ? "Нужен пароль MQTT" :
                      model.client.state.haEnabled ? "Ожидание подключения MQTT" : "Ещё не подключён",
                      systemImage: model.client.state.haConnected ? "checkmark.circle.fill" : "house")
                if !model.client.state.wifiConnected {
                    Text("Подключи LightController к Wi-Fi в разделе «Сеть».").font(.caption).foregroundStyle(.secondary)
                }
                if model.client.state.haEnabled {
                    Button("Отключить Home Assistant") {
                        model.client.configureHomeAssistant(enabled: false, host: "", port: 1883, tls: false)
                    }.disabled(board.isEmpty)
                }
            }
            Section("MQTT-брокер") {
                TextField("Адрес", text: $mqttHost, prompt: Text("Имя хоста или IP"))
                Picker("Соединение", selection: Binding(get: { mqttTLS }, set: { tls in
                    if mqttPort == (mqttTLS ? "8883" : "1883") { mqttPort = tls ? "8883" : "1883" }
                    mqttTLS = tls
                })) {
                    Text("С TLS").tag(true)
                    Text("Без TLS").tag(false)
                }
                .pickerStyle(.menu)
                TextField("Порт", text: $mqttPort)
                if mqttTLS {
                    TextField("Имя пользователя (если требуется)", text: $mqttUsername)
                    SecureField(model.client.state.haRequiresAuth && !model.client.state.haNeedsCredentials ?
                                "Новый пароль (по желанию)" : "Пароль MQTT", text: $mqttPassword)
                    LabeledContent("Корневой сертификат") {
                        HStack {
                            Text(mqttCA.isEmpty ? "Встроенные" : "Свой CA").foregroundStyle(.secondary)
                            Button(mqttCA.isEmpty ? "Выбрать…" : "Заменить…") { pickingCertificate = true }
                            if !mqttCA.isEmpty { Button("Убрать") { mqttCA = ""; certificateError = nil } }
                        }
                    }
                    if let certificateError { Text(certificateError).foregroundStyle(.orange) }
                } else {
                    Text("Анонимное подключение по локальной сети.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Сохранить на контроллере") {
                    model.client.configureHomeAssistant(enabled: true, host: mqttHost.trimmingCharacters(in: .whitespacesAndNewlines),
                        port: Int(mqttPort) ?? 0, tls: mqttTLS, username: mqttTLS ? mqttUsername : "",
                        password: mqttTLS ? mqttPassword : "", caPEM: mqttTLS ? mqttCA : "")
                }
                .buttonStyle(.borderedProminent)
                .disabled(board.isEmpty || model.client.usbSettings == nil || mqttHost.isEmpty)
                if board.isEmpty { Text("Для сохранения подключи LightController по USB.") }
                else if !model.client.state.hasPersistentSettings { Text("Для сохранения нужна новая прошивка LightController.") }
                if let notice = model.client.mqttNotice { Text(notice).font(.caption) }
            }
            if !model.client.state.presenceClients.isEmpty {
                Section("Компьютеры") {
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
