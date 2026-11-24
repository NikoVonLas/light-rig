import Foundation

public struct CallHysteresis: Sendable {
    public let enterDelay: TimeInterval
    public let exitDelay: TimeInterval
    public private(set) var isOnCall = false
    private var candidateSince: Date?

    public init(enterDelay: TimeInterval = 2, exitDelay: TimeInterval = 30) {
        self.enterDelay = enterDelay
        self.exitDelay = exitDelay
    }

    @discardableResult
    public mutating func update(rawActive: Bool, at now: Date = Date()) -> Bool {
        guard rawActive != isOnCall else {
            candidateSince = nil
            return false
        }
        if candidateSince == nil { candidateSince = now }
        let delay = rawActive ? enterDelay : exitDelay
        if now.timeIntervalSince(candidateSince!) >= delay {
            isOnCall = rawActive
            candidateSince = nil
            return true
        }
        return false
    }
}
