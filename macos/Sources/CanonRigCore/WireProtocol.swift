import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct WireEnvelope: Codable, Equatable, Sendable {
    public let v: Int
    public let id: String
    public let type: String
    public let payload: [String: JSONValue]
    public var ok: Bool? = nil
    public var error: String? = nil
    public var rebooting: Bool? = nil

    public init(id: String = UUID().uuidString, type: String,
                payload: [String: JSONValue] = [:]) {
        self.v = 1
        self.id = id
        self.type = type
        self.payload = payload
    }
}

public struct RigState: Equatable, Sendable {
    public struct PresenceClient: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var available: Bool
        public var onCall: Bool?
        public var cameraInCall: Bool?
    }
    public var presenceClients: [PresenceClient] = []
    public var presenceAvailable = false
    public var supportsPresence = false
    public var aggregateCall: Bool?
    public var aggregateCamera: Bool?
    public var haEnabled = false
    public var haConnected = false
    public var haHost = ""
    public var haPort = 1883
    public var haTLS = false
    public var haNeedsCredentials = false
    public var hasPersistentSettings = false
    public var haRequiresAuth = false
    public struct LightProbe: Equatable, Sendable {
        public var armed = false
        public var captured = false
        public var ws2812Like = false
        public var symbols = 0
        public var minimumNs = 0
        public var maximumNs = 0
    }

    public struct WiFiNetwork: Identifiable, Equatable, Sendable {
        public var id: String { ssid }
        public let ssid: String
        public let rssi: Int
    }
    public var deviceID = ""
    public var networkSSID = ""
    public var supportsWiFiScan = false
    public var wifiScanStatus = "idle"
    public var wifiNetworks: [WiFiNetwork] = []
    public var mode = "idle"
    public var wifiConnected = false
    public var ipAddress = ""
    public var cameraConnected = false
    public var cameraUSBConnected = false
    public var cameraPTPInterface = false
    public var cameraVendorID = 0
    public var cameraProductID = 0
    public var cameraStatus = "PTP waiting"
    public var cameraModel = ""
    public var cameraFirmware = ""
    public var cameraAperture = CameraProperty()
    public var cameraShutter = CameraProperty()
    public var cameraISO = CameraProperty()
    public var cameraFocusMode = CameraProperty()
    public var cameraAFMethod = CameraProperty()
    public var cameraMovieServo = CameraProperty()
    public var cameraCanSet = false
    public var cameraCanAF = false
    public var cameraCanCancelAF = false
    public var cameraCanFocusStep = false
    public var cameraCanPrepareFocus = false
    public var cameraCanFocusPoint = false
    public var cameraPreviewAspect: Double?
    public var cameraCommandID = ""
    public var cameraCommandStatus = ""
    public var cameraCommandMessage = ""
    public var lightReady = false
    public var lightBrightness = 60
    public var lightPreset = 0
    public var lightEffect = "solid"
    public var lightProbe = LightProbe()
    public var firmware = "—"
    public var networkMode = "unknown"

    public init() {}

    public init(envelope: WireEnvelope) {
        self.init()
        func boolean(_ value: JSONValue?) -> Bool? { if case .bool(let b) = value { return b }; return nil }
        if case .object(let p) = envelope.payload["presence"] {
            supportsPresence = true
            presenceAvailable = boolean(p["available"]) ?? false
            aggregateCall = boolean(p["onCall"]); aggregateCamera = boolean(p["cameraInCall"])
            if case .array(let clients) = p["clients"] {
                presenceClients = clients.compactMap { value in
                    guard case .object(let c) = value, case .string(let id) = c["id"], case .string(let name) = c["name"] else { return nil }
                    return PresenceClient(id: id, name: name, available: boolean(c["available"]) ?? false,
                                          onCall: boolean(c["onCall"]), cameraInCall: boolean(c["cameraInCall"]))
                }
            }
        }
        if case .string(let value) = envelope.payload["networkSSID"] { networkSSID = value }
        if case .object(let scan) = envelope.payload["wifiScan"] {
            supportsWiFiScan = true
            if case .string(let value) = scan["status"] { wifiScanStatus = value }
            if case .array(let networks) = scan["networks"] {
                var seen = Set<String>()
                wifiNetworks = networks.compactMap { item in
                    guard case .object(let entry) = item, case .string(let ssid) = entry["ssid"],
                          !ssid.isEmpty, seen.insert(ssid).inserted,
                          case .number(let rssi) = entry["rssi"], rssi.isFinite, (-127...0).contains(rssi) else { return nil }
                    return WiFiNetwork(ssid: ssid, rssi: Int(rssi))
                }.sorted { $0.rssi > $1.rssi }
            }
        }
        if case .object(let h) = envelope.payload["homeAssistant"] {
            if case .string(let value) = h["deviceId"] { deviceID = value }
            haEnabled = boolean(h["enabled"]) ?? false; haConnected = boolean(h["connected"]) ?? false
            haTLS = boolean(h["tls"]) ?? false; haNeedsCredentials = boolean(h["needsCredentials"]) ?? false
            hasPersistentSettings = boolean(h["credentialsPersistent"]) ?? false
            haRequiresAuth = boolean(h["requiresAuth"]) ?? false
            if case .string(let host) = h["host"] { haHost = host }
            if case .number(let port) = h["port"], port.isFinite, (1...65535).contains(port), port.rounded() == port { haPort = Int(port) }
        }
        if case .string(let value) = envelope.payload["mode"] { mode = value }
        if case .bool(let value) = envelope.payload["wifiConnected"] { wifiConnected = value }
        if case .string(let value) = envelope.payload["ipAddress"] { ipAddress = value }
        if case .bool(let value) = envelope.payload["cameraConnected"] { cameraConnected = value }
        if case .bool(let value) = envelope.payload["cameraUSBConnected"] { cameraUSBConnected = value }
        if case .bool(let value) = envelope.payload["cameraPTPInterface"] { cameraPTPInterface = value }
        if case .number(let value) = envelope.payload["cameraVendorID"] { cameraVendorID = Int(value) }
        if case .number(let value) = envelope.payload["cameraProductID"] { cameraProductID = Int(value) }
        if case .string(let value) = envelope.payload["cameraStatus"] { cameraStatus = value }
        if case .string(let value) = envelope.payload["cameraModel"] { cameraModel = value }
        if case .string(let value) = envelope.payload["cameraFirmware"] { cameraFirmware = value }
        if cameraConnected, case .object(let exposure) = envelope.payload["cameraExposure"] {
            cameraAperture = CameraProperty(json: exposure["aperture"])
            cameraShutter = CameraProperty(json: exposure["shutter"])
            cameraISO = CameraProperty(json: exposure["iso"])
            cameraFocusMode = CameraProperty(json: exposure["focusMode"])
            cameraAFMethod = CameraProperty(json: exposure["afMethod"])
            cameraMovieServo = CameraProperty(json: exposure["movieServo"])
        }
        if cameraConnected, case .object(let capabilities) = envelope.payload["cameraCapabilities"] {
            if case .bool(let value) = capabilities["set"] { cameraCanSet = value }
            if case .bool(let value) = capabilities["autofocus"] { cameraCanAF = value }
            if case .bool(let value) = capabilities["cancelAF"] { cameraCanCancelAF = value }
            if case .bool(let value) = capabilities["focusStep"] { cameraCanFocusStep = value }
            if case .bool(let value) = capabilities["prepareFocus"] { cameraCanPrepareFocus = value }
            if case .bool(let value) = capabilities["focusPoint"] { cameraCanFocusPoint = value }
        }
        if cameraConnected, case .object(let diagnostics) = envelope.payload["cameraDiagnostics"],
           case .number(let w) = diagnostics["jpegWidth"], case .number(let h) = diagnostics["jpegHeight"],
           w.isFinite, h.isFinite, w > 0, h > 0 { cameraPreviewAspect = w / h }
        if case .object(let command) = envelope.payload["cameraCommand"] {
            if case .string(let value) = command["id"] { cameraCommandID = value }
            if case .string(let value) = command["status"] { cameraCommandStatus = value }
            if case .string(let value) = command["message"] { cameraCommandMessage = value }
        }
        if case .bool(let value) = envelope.payload["lightReady"] { lightReady = value }
        if case .number(let value) = envelope.payload["lightBrightness"] { lightBrightness = Int(value) }
        if case .number(let value) = envelope.payload["lightPreset"] { lightPreset = Int(value) }
        if case .string(let value) = envelope.payload["lightEffect"] { lightEffect = value }
        if case .object(let probe) = envelope.payload["lightProbe"] {
            if case .bool(let value) = probe["armed"] { lightProbe.armed = value }
            if case .bool(let value) = probe["captured"] { lightProbe.captured = value }
            if case .bool(let value) = probe["ws2812Like"] { lightProbe.ws2812Like = value }
            if case .number(let value) = probe["symbols"] { lightProbe.symbols = Int(value) }
            if case .number(let value) = probe["minimumNs"] { lightProbe.minimumNs = Int(value) }
            if case .number(let value) = probe["maximumNs"] { lightProbe.maximumNs = Int(value) }
        }
        if case .string(let value) = envelope.payload["firmware"] { firmware = value }
        if case .string(let value) = envelope.payload["networkMode"] { networkMode = value }
    }
}
