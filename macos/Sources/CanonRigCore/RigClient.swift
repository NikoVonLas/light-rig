import Foundation

public enum RigConnectionMode: String, CaseIterable, Sendable {
    case automatic, usb, accessPoint, router
}

public enum NetworkSetupStatus: Equatable {
    case idle, sending, waiting, connected
    case failed(String)
}

@MainActor
public final class RigClient: ObservableObject {
    @Published public private(set) var state = RigState()
    @Published public private(set) var isConnected = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var notice: String?
    @Published public private(set) var usbSettings: [String: JSONValue]?
    @Published public private(set) var mqttNotice: String?
    private var settingsReadID: String?
    private var mqttSaveID: String?
    @Published public private(set) var cameraNotice: String?
    @Published public private(set) var pendingCameraID: String?
    private var cameraSentAt = Date.distantPast
    private var cameraReplies: Task<Void, Never>?
    private var deferredFocusPoint: (point: CGPoint, aspect: Double)?
    public var cameraBusy: Bool {
        pendingCameraID != nil || (isConnected && ["queued", "running"].contains(state.cameraCommandStatus))
    }
    public var connectionMode: RigConnectionMode = .automatic
    @Published public private(set) var activeConnectionMode: RigConnectionMode?
    public var connectionLabel: String {
        guard isConnected else { return "Поиск LightController…" }
        return activeConnectionMode == .usb ? "USB" : "Wi-Fi"
    }
    @Published public private(set) var networkSetupStatus: NetworkSetupStatus = .idle
    private var networkRequest: (id: String, deviceID: String, mode: String, ssid: String, started: Date)?
    private var networkAcknowledged = false
    private var selection = RigConnectionSelection()
    private var endpoint: RigEndpoint?
    public var serialPath = ""
    public static func serialPorts() -> [String] { SerialTransport.ports() }

    public var host: String {
        didSet {
            if Self.isIPv4Address(host) { defaults.set(host, forKey: "rigLastRouterIP") }
        }
    }
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var sendQueue: Task<Void, Never>?
    private var generation = UUID()
    private var lastAttempt = Date.distantPast
    private var serial: (any RigSerialConnection)?
    private let portsProvider: () -> [String]
    private let serialFactory: () -> any RigSerialConnection
    private let now: () -> Date
    private let defaults: UserDefaults
    // A rapid relaunch can leave the board in the same aggregate call across Mac sessions.
    private var restoredCallDevices = Set<String>()
    private var startupPresence: (id: String, device: String, sentAt: Date)?
    private var lastHeartbeat = Date.distantPast
    private var lastReply = Date.distantPast

    public func maintainConnection() {
        if let request = networkRequest, now().timeIntervalSince(request.started) > 90 {
            networkSetupStatus = .failed("Плата не подтвердила подключение. Проверь сеть и пароль или продолжи по USB.")
            networkRequest = nil
        }
        if pendingCameraID != nil && now().timeIntervalSince(cameraSentAt) > 20 {
            deferredFocusPoint = nil
            pendingCameraID = nil
            cameraNotice = "Нет подтверждения команды. Значение на экране — последнее полученное от камеры."
        }
        if connectionMode == .automatic {
            let ports = portsProvider()
            selection.observe(ports: ports)
            if case .usb(let path) = endpoint, !ports.contains(path) {
                connectionFailed("USB отключён")
                lastAttempt = .distantPast
            }
            // Switch only between commands. Never replay a camera command on another transport.
            if activeConnectionMode != .usb, pendingCameraID == nil,
               let usb = selection.preferredUSB(ports: ports, at: now()) {
                connect(to: usb)
                return
            }
        }
        if task == nil && serial == nil {
            if now().timeIntervalSince(lastAttempt) >= 5 { connect() }
        } else {
            if now().timeIntervalSince(lastReply) > (isConnected ? 10 : 5) {
                connectionFailed("Контроллер не отвечает")
            } else if now().timeIntervalSince(lastHeartbeat) >= 2 {
                lastHeartbeat = now()
                send(WireEnvelope(type: "hello", payload: ["client": .string("macos")]))
            }
        }
    }

    public convenience init(host: String? = nil) {
        self.init(host: host, defaults: .standard, ports: { SerialTransport.ports() },
                  serialFactory: { SerialTransport() }, now: { Date() })
    }

    init(host: String?, defaults: UserDefaults, ports: @escaping () -> [String],
         serialFactory: @escaping () -> any RigSerialConnection, now: @escaping () -> Date) {
        self.defaults = defaults
        self.portsProvider = ports
        self.serialFactory = serialFactory
        self.now = now
        self.host = host ?? defaults.string(forKey: "rigLastRouterIP") ?? "canonrig.local"
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) &&
            Int(part).map { (0...255).contains($0) } == true
        }
    }

    private func connectionFailed(_ message: String) {
        if let endpoint { selection.failed(endpoint, at: now()) }
        disconnect()
        lastError = message
    }

    public func connect() {
        let target: RigEndpoint?
        switch connectionMode {
        case .automatic:
            let ports = portsProvider()
            selection.observe(ports: ports)
            target = selection.next(ports: ports, host: host, at: now())
        case .usb:
            let ports = portsProvider()
            target = serialPath.isEmpty ? (ports.count == 1 ? .usb(ports[0]) : nil) : .usb(serialPath)
        case .router: target = .network(host)
        case .accessPoint: target = .network("192.168.4.1")
        }
        guard let target else {
            disconnect()
            lastAttempt = now()
            lastError = connectionMode == .usb ? "LightController не найден по USB" : "Ищу LightController по USB и Wi-Fi"
            return
        }
        connect(to: target)
    }

    private func connect(to target: RigEndpoint) {
        disconnect()
        endpoint = target
        lastAttempt = now()
        lastReply = now()
        lastHeartbeat = now()
        lastError = nil
        notice = nil
        if case .usb(let path) = target {
            activeConnectionMode = .usb
            let transport = serialFactory()
            let current = generation
            transport.onMessage = { [weak self] data in
                guard self?.generation == current else { return }
                self?.accept(data)
            }
            transport.onError = { [weak self] message in
                guard self?.generation == current else { return }
                self?.connectionFailed(message)
            }
            do {
                try transport.open(path)
                serial = transport
                send(WireEnvelope(type: "hello", payload: ["client": .string("macos")]))
            } catch { connectionFailed("USB: \(error.localizedDescription)") }
            return
        }
        guard case .network(let address) = target else { return }
        activeConnectionMode = address == "192.168.4.1" ? .accessPoint : .router
        guard let url = URL(string: "ws://\(address)/ws") else {
            connectionFailed("Некорректный адрес контроллера")
            return
        }
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        isConnected = false // Only a valid rig.state response confirms connection.
        lastError = nil
        let current = generation
        receiveLoop = Task { [weak self] in await self?.receiveMessages(socket, generation: current) }
        send(WireEnvelope(type: "hello", payload: ["client": .string("macos")]))
    }

    public func disconnect() {
        startupPresence = nil
        if presetSaveRequest != nil { profileNotice = "Связь прервана до подтверждения сохранения" }
        presetSaveRequest = nil
        usbSettings = nil
        settingsReadID = nil
        mqttSaveID = nil
        mqttNotice = nil
        deferredFocusPoint = nil
        cameraReplies?.cancel()
        cameraReplies = nil
        if pendingCameraID != nil { cameraNotice = "Связь прервана: результат команды неизвестен" }
        pendingCameraID = nil
        generation = UUID()
        serial?.close()
        serial = nil
        sendQueue?.cancel()
        sendQueue = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        activeConnectionMode = nil
        endpoint = nil
    }

    public func setMode(_ mode: String) {
        send(WireEnvelope(type: "rig.setState", payload: ["mode": .string(mode)]))
    }

    public func readUSBSettings() {
        guard isConnected, activeConnectionMode == .usb, state.hasPersistentSettings else { return }
        let request = WireEnvelope(type: "settings.read")
        settingsReadID = request.id
        send(request)
    }

    public func configureHomeAssistant(enabled: Bool, host: String, port: Int, tls: Bool,
                                       username: String = "", password: String = "", caPEM: String = "") {
        guard isConnected, activeConnectionMode == .usb else { lastError = "Настройка MQTT доступна по USB"; return }
        guard state.hasPersistentSettings else { mqttNotice = "Обнови прошивку LightController для сохранения настроек"; return }
        guard !enabled || (!host.isEmpty && (1...65535).contains(port)) else { mqttNotice = "Укажи адрес и порт MQTT"; return }
        guard !enabled || (caPEM.utf8.count <= 3072 && username.utf8.count <= 64 && password.utf8.count <= 128 &&
            (tls || (username.isEmpty && password.isEmpty && caPEM.isEmpty)) && (!username.isEmpty || password.isEmpty)) else {
            mqttNotice = "Проверь TLS, сертификат и данные для входа"; return
        }
        var payload: [String: JSONValue] = ["enabled": .bool(enabled)]
        if enabled {
            payload["host"] = .string(host)
            payload["port"] = .number(Double(port))
            payload["tls"] = .bool(tls)
            payload["caPEM"] = .string(caPEM)
            payload["username"] = .string(username)
            if !password.isEmpty { payload["password"] = .string(password) }
        }
        let request = WireEnvelope(type: "homeassistant.configure", payload: payload)
        mqttSaveID = request.id
        mqttNotice = "Сохранение…"
        send(request)
    }

    public func sendPresence(_ heartbeat: WireEnvelope) {
        let device = state.deviceID
        if heartbeat.payload["automatic"] != .bool(true) || heartbeat.payload["onCall"] != .bool(true) {
            startupPresence = nil
        } else if isConnected, !device.isEmpty, !restoredCallDevices.contains(device),
                  now().timeIntervalSince(startupPresence?.sentAt ?? .distantPast) > 5 {
            startupPresence = (heartbeat.id, device, now())
        }
        send(heartbeat)
    }

    private func honorManualLight() {
        guard isConnected, !state.deviceID.isEmpty else { return }
        restoredCallDevices.insert(state.deviceID)
        startupPresence = nil
    }

    public func setLight(enabled: Bool, brightness: Int, mode: String = "neutral",
                         red: Int = 255, green: Int = 255, blue: Int = 255,
                         warm: Int = 65, cool: Int = 65,
                         effect: String = "solid", speed: Int = 40) {
        honorManualLight()
        send(WireEnvelope(type: "light.set", payload: [
            "enabled": .bool(enabled), "brightness": .number(Double(brightness)),
            "mode": .string(mode),
            "red": .number(Double(red)), "green": .number(Double(green)),
            "blue": .number(Double(blue)), "warm": .number(Double(warm)),
            "cool": .number(Double(cool)), "effect": .string(effect),
            "speed": .number(Double(speed)),
        ]))
    }

    public func toggleLightPower() {
        guard isConnected, state.lightReady, let enabled = state.lightEnabled else { return }
        honorManualLight()
        if !enabled, let frames = state.lightFrameCount, frames <= 1 {
            // The boot OFF frame has no color to restore yet.
            applyLightPreset(3)
        } else {
            send(WireEnvelope(type: "light.set", payload: ["enabled": .bool(!enabled)]))
        }
        // Legacy firmware can acknowledge before the LED task transmits its frame.
        let connection = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, self.isConnected, self.generation == connection else { return }
            self.send(WireEnvelope(type: "hello"))
        }
    }

    public func applyLightPreset(_ slot: Int) {
        send(WireEnvelope(type: "light.applyPreset", payload: ["slot": .number(Double(slot))]))
    }

    public func startLightCapture() {
        send(WireEnvelope(type: "light.captureStart"))
    }

    @Published public private(set) var profileNotice: String?
    private var presetSaveRequest: WireEnvelope?

    public func saveLightPreset(slot: Int, name: String, enabled: Bool, brightness: Int,
                                mode: String, red: Int, green: Int, blue: Int,
                                warm: Int, cool: Int, effect: String, speed: Int) {
        let request = WireEnvelope(type: "preset.save", payload: [
            "slot": .number(Double(slot)), "name": .string(name), "enabled": .bool(enabled),
            "brightness": .number(Double(brightness)), "mode": .string(mode),
            "red": .number(Double(red)), "green": .number(Double(green)),
            "blue": .number(Double(blue)), "warm": .number(Double(warm)),
            "cool": .number(Double(cool)), "effect": .string(effect),
            "speed": .number(Double(speed)),
        ])
        presetSaveRequest = request
        profileNotice = "Сохранение…"
        send(request)
    }

    public func cameraSet(kind: CameraExposureKind, property: CameraProperty, value: UInt32) {
        guard state.cameraCanSet, property.raw != nil, property.optionsKnown, property.options.contains(value) else {
            cameraNotice = "Камера не предлагает это значение"; return
        }
        sendCamera(WireEnvelope(type: "camera.set", payload: [
            "property": .string(kind.propertyKey), "value": .number(Double(value)),
        ]))
    }

    public func autofocus() {
        guard state.cameraCanAF else { return }
        sendCamera(WireEnvelope(type: "camera.autofocus"))
    }

    public func cancelAutofocus() {
        guard state.cameraCanCancelAF else { return }
        sendCamera(WireEnvelope(type: "camera.autofocusCancel"))
    }

    public func focusStep(far: Bool, step: Int) {
        guard state.cameraCanFocusStep, (1...3).contains(step) else { return }
        sendCamera(WireEnvelope(type: "camera.focusStep", payload: [
            "direction": .string(far ? "far" : "near"), "step": .number(Double(step))
        ]))
    }

    @discardableResult
    public func focusPoint(_ point: CGPoint, videoAspect: Double) -> Bool {
        guard isConnected, state.cameraConnected else { cameraNotice = "Нет связи с камерой"; return false }
        guard !cameraBusy else { cameraNotice = "Canon ещё выполняет команду"; return false }
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y),
              videoAspect.isFinite, videoAspect > 0 else { return false }
        if !state.cameraCanFocusPoint {
            guard state.cameraCanPrepareFocus else { cameraNotice = "Фокус по клику недоступен"; return false }
            deferredFocusPoint = (point, videoAspect)
            sendCamera(WireEnvelope(type: "camera.prepareFocus"))
            cameraNotice = "Читаю координаты AF с камеры…"
            return true
        }
        guard let cameraAspect = state.cameraPreviewAspect, abs(cameraAspect / videoAspect - 1) < 0.02 else {
            cameraNotice = "Форматы HDMI и Live View различаются — точка AF не отправлена"; return false
        }
        sendCamera(WireEnvelope(type: "camera.focusPoint", payload: ["x": .number(point.x), "y": .number(point.y)]))
        return true
    }

    private func sendCamera(_ envelope: WireEnvelope) {
        guard isConnected, state.cameraConnected, !cameraBusy else {
            cameraNotice = "Камера не подключена или ещё выполняет команду"; return
        }
        pendingCameraID = envelope.id
        cameraSentAt = now()
        cameraNotice = "Ожидание ответа Canon…"
        send(envelope)
        cameraReplies?.cancel()
        cameraReplies = Task { [weak self] in
            for _ in 0..<80 {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.pendingCameraID == envelope.id, self.isConnected else { return }
                self.send(WireEnvelope(type: "hello"))
            }
            guard let self, self.pendingCameraID == envelope.id else { return }
            self.deferredFocusPoint = nil
            self.pendingCameraID = nil
            self.cameraNotice = "Нет подтверждения команды; автоматического повтора не было"
        }
    }

    public func send(_ envelope: WireEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        if let serial { serial.send(data); return }
        guard let task, let string = String(data: data, encoding: .utf8) else { return }
        let previous = sendQueue
        let current = generation
        sendQueue = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, self?.generation == current else { return }
            do {
                try await task.send(.string(string))
            } catch {
                guard self?.generation == current else { return }
                self?.connectionFailed(error.localizedDescription)
            }
        }
    }

    public func scanWiFi() {
        guard isConnected, activeConnectionMode == .usb, state.supportsWiFiScan else { return }
        send(WireEnvelope(type: "network.scan"))
    }

    public func cancelNetworkSetup() {
        networkRequest = nil
        networkAcknowledged = false
        networkSetupStatus = .idle
    }

    @discardableResult
    public func configureNetwork(mode: String, ssid: String = "", password: String = "", apPassword: String = "") -> Bool {
        guard isConnected else {
            networkSetupStatus = .failed("Подключи LightController к Mac встроенным USB-C.")
            return false
        }
        guard networkRequest == nil else { return false }
        if mode == "router", (!ssid.isEmpty || !password.isEmpty),
           (ssid.isEmpty || ssid.utf8.count > 32 || !(8...63).contains(password.utf8.count)) {
            networkSetupStatus = .failed("Проверь название сети и пароль: пароль должен содержать 8–63 байта.")
            return false
        }
        var payload: [String: JSONValue] = ["mode": .string(mode)]
        if mode == "ap" && !apPassword.isEmpty {
            guard activeConnectionMode == .usb, state.hasPersistentSettings, (8...63).contains(apPassword.utf8.count) else {
                networkSetupStatus = .failed("Для смены пароля подключи плату с новой прошивкой по USB и введи 8–63 байта.")
                return false
            }
            payload["apPassword"] = .string(apPassword)
        }
        if mode == "router" && (!ssid.isEmpty || !password.isEmpty) {
            payload["ssid"] = .string(ssid)
            payload["password"] = .string(password)
        }
        let envelope = WireEnvelope(type: "network.configure", payload: payload)
        networkRequest = (envelope.id, state.deviceID, mode, ssid, now())
        networkAcknowledged = false
        networkSetupStatus = .sending
        send(envelope)
        return true
    }

    private func acceptNetworkSetup(_ envelope: WireEnvelope) {
        guard let request = networkRequest, state.deviceID == request.deviceID else { return }
        if envelope.id == request.id {
            if envelope.ok == false {
                networkSetupStatus = .failed("Не удалось сохранить сеть: \(envelope.error ?? "ошибка платы")")
                networkRequest = nil
                return
            }
            if envelope.ok == true {
                networkAcknowledged = true
                networkSetupStatus = .waiting
            }
        }
        guard networkAcknowledged, envelope.rebooting != true,
              state.networkMode == request.mode else { return }
        if request.mode == "router" {
            guard state.wifiConnected, Self.isIPv4Address(state.ipAddress),
                  state.networkSSID.isEmpty || request.ssid.isEmpty || state.networkSSID == request.ssid else { return }
        }
        networkSetupStatus = .connected
        networkRequest = nil
    }

    func accept(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data),
              envelope.v == 1, envelope.type == "rig.state" else { return }
        state = RigState(envelope: envelope)
        if let pending = startupPresence, pending.id == envelope.id {
            startupPresence = nil
            if envelope.ok == true, pending.device == state.deviceID, state.lightReady {
                restoredCallDevices.insert(pending.device)
                applyLightPreset(3)
            }
        }
        if activeConnectionMode == .usb, envelope.id == settingsReadID {
            settingsReadID = nil
            if envelope.ok == true, case .object(let values) = envelope.payload["usbSettings"] { usbSettings = values }
        }
        if let request = presetSaveRequest, envelope.id == request.id {
            presetSaveRequest = nil
            if envelope.ok != true {
                profileNotice = "Не удалось сохранить профиль на LightController"
            } else if state.callLight == nil {
                profileNotice = "Профиль отправлен. Эта прошивка не подтверждает сохранённый цвет."
            } else if state.callLight == RigState.CallLight(.object(request.payload)) {
                profileNotice = "Профиль «Созвон» сохранён на LightController"
            } else {
                profileNotice = "LightController вернул другой профиль. Повтори сохранение."
            }
        }
        if envelope.id == mqttSaveID {
            mqttSaveID = nil
            if envelope.ok == true {
                mqttNotice = "Настройки сохранены на LightController"
                readUSBSettings()
            } else { mqttNotice = envelope.error ?? "Не удалось сохранить настройки" }
        }
        acceptNetworkSetup(envelope)
        if state.networkMode == "router" && state.wifiConnected &&
            Self.isIPv4Address(state.ipAddress) {
            host = state.ipAddress
        }
        if let pending = pendingCameraID {
            if envelope.id == pending, envelope.ok == false {
                deferredFocusPoint = nil
                cameraNotice = envelope.error ?? "Команда отклонена"
                pendingCameraID = nil
            } else if state.cameraCommandID == pending && !["queued", "running"].contains(state.cameraCommandStatus) {
                switch state.cameraCommandStatus {
                case "confirmed": cameraNotice = "Изменение подтверждено камерой"
                case "accepted": cameraNotice = "Команда фокуса принята. Резкость проверь по превью."
                case "unconfirmed": cameraNotice = "Команда принята, но значение ещё не подтверждено"
                default: cameraNotice = state.cameraCommandMessage
                }
                pendingCameraID = nil
                if let deferred = deferredFocusPoint {
                    deferredFocusPoint = nil
                    if state.cameraCommandStatus == "confirmed" && state.cameraCanFocusPoint {
                        focusPoint(deferred.point, videoAspect: deferred.aspect)
                    }
                }
            }
        }
        isConnected = true
        lastError = nil
        if let endpoint { selection.succeeded(endpoint) }
        lastReply = now()
        if let error = envelope.error { lastError = error }
        if envelope.rebooting == true {
            notice = "Настройки сохранены. LightController перезапускается; RGB выключится."
            disconnect()
            lastAttempt = now()
        }
    }

    private func receiveMessages(_ socket: URLSessionWebSocketTask, generation current: UUID) async {
        while !Task.isCancelled, generation == current {
            do {
                let message = try await socket.receive()
                guard generation == current else { return }
                let data: Data?
                switch message {
                case .string(let value): data = value.data(using: .utf8)
                case .data(let value): data = value
                @unknown default: data = nil
                }
                if let data { accept(data) }
            } catch {
                if !Task.isCancelled, generation == current {
                    connectionFailed(error.localizedDescription)
                }
                return
            }
        }
    }
}
