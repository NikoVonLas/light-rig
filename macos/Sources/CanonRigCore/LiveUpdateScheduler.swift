import Foundation

/// Sends the latest edit at most once per interval, including during a drag.
@MainActor
public final class LiveUpdateScheduler {
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var pending: (@MainActor () -> Void)?

    public init(interval: Duration = .milliseconds(150)) { self.interval = interval }

    public func schedule(_ action: @escaping @MainActor () -> Void) {
        pending = action
        guard task == nil else { return }
        let interval = interval
        task = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard let self else { return }
            let action = self.pending
            self.pending = nil
            self.task = nil
            action?()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}
