import Foundation

enum RigEndpoint: Hashable {
    case usb(String)
    case network(String)
}

/// Tries each reachable route without letting a stale IP or a silent serial
/// adapter prevent discovery. A valid rig.state, not an open socket, is success.
struct RigConnectionSelection {
    private var retryAfter: [RigEndpoint: Date] = [:]
    private var observedPorts: Set<String> = []

    mutating func observe(ports: [String]) {
        let current = Set(ports)
        for path in current.subtracting(observedPorts) {
            retryAfter.removeValue(forKey: .usb(path))
        }
        observedPorts = current
    }

    func preferredUSB(ports: [String], at now: Date) -> RigEndpoint? {
        ports.sorted().map(RigEndpoint.usb).first { available($0, at: now) }
    }

    func next(ports: [String], host: String, at now: Date) -> RigEndpoint? {
        if let usb = preferredUSB(ports: ports, at: now) { return usb }
        let addresses = [host, "lightrig.local", "canonrig.local", "192.168.4.1"]
        return addresses.filter { !$0.isEmpty }.map(RigEndpoint.network)
            .first { available($0, at: now) }
    }

    mutating func failed(_ endpoint: RigEndpoint, at now: Date) {
        // Allow the other routes time to connect before retrying this one.
        retryAfter[endpoint] = now.addingTimeInterval(30)
    }

    mutating func succeeded(_ endpoint: RigEndpoint) {
        retryAfter.removeValue(forKey: endpoint)
    }

    private func available(_ endpoint: RigEndpoint, at now: Date) -> Bool {
        retryAfter[endpoint].map { now >= $0 } ?? true
    }
}
