import Foundation

/// Emits state on transitions AND on reconnection/re-enabling automation.
public struct CallAutomation: Sendable {
    private var hysteresis = CallHysteresis()
    private var lastSent: Bool?
    public private(set) var isOnCall = false

    public init() {}

    public mutating func update(rawActive: Bool, automatic: Bool,
                                connected: Bool, at now: Date = Date()) -> Bool? {
        hysteresis.update(rawActive: rawActive, at: now)
        isOnCall = hysteresis.isOnCall
        guard automatic, connected else {
            lastSent = nil
            return nil
        }
        guard lastSent != isOnCall else { return nil }
        lastSent = isOnCall
        return isOnCall
    }
}
