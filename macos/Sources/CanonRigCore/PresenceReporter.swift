import Foundation

/// Each installation has its own identity; sessions/sequences reject old heartbeats.
public struct PresenceReporter {
    public let clientID: String
    public let name: String
    private let session = UUID().uuidString
    private var sequence: UInt32 = 0
    public init(clientID: String, name: String) {
        self.clientID = clientID
        // Firmware limits UTF-8 bytes, not Swift character count.
        var label = name.filter { !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }
        while label.utf8.count > 48 { label.removeLast() }
        self.name = label.isEmpty ? "Mac" : label
    }
    public static func installationID(defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: "presenceClientID"), UUID(uuidString: saved) != nil { return saved }
        let id = UUID().uuidString
        defaults.set(id, forKey: "presenceClientID")
        return id
    }
    public mutating func envelope(onCall: Bool, cameraInCall: Bool?, automatic: Bool, preview: Bool) -> WireEnvelope {
        sequence += 1
        return WireEnvelope(type: "presence.update", payload: [
            "clientId": .string(clientID), "name": .string(name), "session": .string(session),
            "sequence": .number(Double(sequence)), "onCall": .bool(onCall),
            "cameraInCall": !onCall ? .bool(false) : cameraInCall.map(JSONValue.bool) ?? .null,
            "automatic": .bool(automatic), "preview": .bool(preview)
        ])
    }
}
