import Foundation
import Network

/// Uses the interface that advertised the controller, including while a VPN is active.
@MainActor
final class LocalWebSocket {
    var onMessage: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    private let connection: NWConnection
    private var cancelled = false

    init(url: URL, interface: NWInterface?) {
        let parameters = NWParameters.tcp
        if let interface { parameters.requiredInterface = interface }
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 8 * 1024 * 1024
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.cancelled else { return }
                switch state {
                case .ready: self.receive()
                case .failed(let error), .waiting(let error): self.fail(error.localizedDescription)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    func send(_ data: Data) {
        guard !cancelled else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "wire", metadata: [metadata])
        connection.send(content: data, contentContext: context, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                if let error { self?.fail(error.localizedDescription) }
            }
        })
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.cancelled else { return }
                if let error { self.fail(error.localizedDescription); return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close || (data == nil && metadata == nil) {
                    self.fail("Контроллер закрыл соединение")
                    return
                }
                if let data, metadata?.opcode == .text || metadata?.opcode == .binary { self.onMessage?(data) }
                if !self.cancelled { self.receive() }
            }
        }
    }

    private func fail(_ message: String) {
        guard !cancelled else { return }
        cancel()
        onError?(message)
    }

    isolated deinit { cancel() }

    func cancel() {
        cancelled = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
