import Foundation
import Testing
@testable import CanonRigCore

@Test func discoveredLocalRoutePrecedesStaleIPAndKeepsUSBPriority() {
    var selection = RigConnectionSelection()
    let now = Date(timeIntervalSince1970: 100)
    let wifi = RigEndpoint.local(host: "new-board.local", port: 8080, interface: "en0")
    #expect(selection.next(ports: [], host: "192.0.2.20", local: [wifi], at: now) == wifi)
    #expect(selection.next(ports: ["usb"], host: "192.0.2.20", local: [wifi], at: now) == .usb("usb"))
    selection.failed(wifi, at: now)
    let ethernet = RigEndpoint.local(host: "new-board.local", port: 8080, interface: "en5")
    #expect(selection.next(ports: [], host: "192.0.2.20", local: [wifi, ethernet], at: now) == ethernet)
    #expect(selection.next(ports: [], host: "192.0.2.20", local: [], at: now) == .network("192.0.2.20"))
}

import Network

@MainActor private final class ReceivedMessage { var data = Data() }

@Test @MainActor func localWebSocketExchangesMessagesAndReportsClosure() async throws {
    let options = NWProtocolWebSocket.Options()
    options.autoReplyPing = true
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
    let listener = try NWListener(using: parameters, on: .any)
    var server: NWConnection?
    let received = ReceivedMessage()
    listener.newConnectionHandler = { connection in
        MainActor.assumeIsolated {
            server = connection
            connection.start(queue: .main)
            connection.receiveMessage { data, _, _, _ in
                MainActor.assumeIsolated {
                    received.data = data ?? Data()
                    let pong = NWConnection.ContentContext(identifier: "pong", metadata: [NWProtocolWebSocket.Metadata(opcode: .pong)])
                    connection.send(content: nil, contentContext: pong, completion: .idempotent)
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                    let context = NWConnection.ContentContext(identifier: "state", metadata: [metadata])
                    connection.send(content: Data("reply".utf8), contentContext: context, completion: .idempotent)
                }
            }
        }
    }
    listener.start(queue: .main)
    defer { server?.cancel(); listener.cancel() }
    for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
    let port = try #require(listener.port)
    #expect(port.rawValue > 0)
    let transport = LocalWebSocket(url: URL(string: "ws://127.0.0.1:\(port.rawValue)/ws")!, interface: nil)
    var reply: Data?
    var failed = false
    var failureReason = ""
    transport.onMessage = { reply = $0 }
    transport.onError = { failed = true; failureReason = $0 }
    transport.start()
    defer { transport.cancel() }
    transport.send(Data("hello".utf8))
    for _ in 0..<100 where reply == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(received.data == Data("hello".utf8))
    #expect(reply == Data("reply".utf8), "Transport error: \(failureReason)")
    server?.cancel()
    for _ in 0..<100 where !failed { try await Task.sleep(for: .milliseconds(20)) }
    #expect(failed)
}

@Test @MainActor func bonjourFindsAdvertisedPortAndRemovesDepartedService() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let name = "LightRig-test-\(UUID().uuidString)"
    listener.service = NWListener.Service(name: name, type: "_lrigtest._tcp")
    listener.newConnectionHandler = { $0.cancel() }
    listener.start(queue: .main)
    let discovery = LocalRigDiscovery(serviceType: "_lrigtest._tcp")
    discovery.start()
    defer { listener.cancel(); discovery.stop() }
    for _ in 0..<250 where discovery.routes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    let port = try #require(listener.port)
    let route = try #require(discovery.routes.first)
    guard case .local(let host, let foundPort, let interface) = route else {
        Issue.record("Bonjour must return a local interface route"); return
    }
    #expect(!host.isEmpty)
    #expect(foundPort == port.rawValue)
    #expect(discovery.interface(named: interface) != nil)
    listener.cancel()
    for _ in 0..<250 where !discovery.routes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(discovery.routes.isEmpty)
}

@MainActor private final class LocalRigServer {
    let listener: NWListener
    var connection: NWConnection?
    var hello = false
    init() throws {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.service = NWListener.Service(name: "Rig-\(UUID().uuidString)", type: "_lrige2e._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.connection = connection
                connection.start(queue: .main)
                connection.receiveMessage { [weak self] data, _, _, _ in
                    MainActor.assumeIsolated {
                        self?.hello = data.flatMap { try? JSONDecoder().decode(WireEnvelope.self, from: $0) }?.type == "hello"
                    }
                }
            }
        }
        listener.start(queue: .main)
    }
    func reply(_ type: String) throws {
        let data = try JSONEncoder().encode(WireEnvelope(type: type, payload: ["ipAddress": .string("192.0.2.42"), "wifiConnected": .bool(true), "networkMode": .string("router")]))
        let context = NWConnection.ContentContext(identifier: "state", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection?.send(content: data, contentContext: context, completion: .idempotent)
    }
    func stop() { connection?.cancel(); listener.cancel() }
}

@Test @MainActor func clientUsesDiscoveredInterfaceAndRequiresStateOverLoopback() async throws {
    let server = try LocalRigServer()
    let discovery = LocalRigDiscovery(serviceType: "_lrige2e._tcp")
    let suite = "local-rig-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    var time = Date()
    let client = RigClient(host: "192.0.2.1", defaults: defaults, ports: { [] },
                           serialFactory: { SerialTransport() }, now: { time }, discovery: discovery,
                           localSocketFactory: { url, interface in
        #expect(discovery.routes.contains(.local(host: url.host!, port: UInt16(url.port!), interface: interface.name)))
        #expect(url.path == "/ws")
        // A same-host server uses loopback; it cannot exercise a remote peer's physical route.
        let loopback = URL(string: "ws://127.0.0.1:\(url.port!)/ws")!
        return LocalWebSocket(url: loopback, interface: nil)
    })
    defer { client.disconnect(); discovery.stop(); server.stop(); defaults.removePersistentDomain(forName: suite) }
    discovery.start()
    for _ in 0..<250 where discovery.routes.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!discovery.routes.isEmpty)
    client.connect()
    for _ in 0..<250 where !server.hello { try await Task.sleep(for: .milliseconds(20)) }
    #expect(server.hello, "Routes: \(discovery.routes)")
    #expect(!client.isConnected)
    try server.reply("unknown")
    try await Task.sleep(for: .milliseconds(50))
    #expect(!client.isConnected)
    try server.reply("rig.state")
    for _ in 0..<100 where !client.isConnected { try await Task.sleep(for: .milliseconds(20)) }
    #expect(client.isConnected, "Connection error: \(client.lastError ?? "none")")
    #expect(defaults.string(forKey: "rigLastRouterIP") == "192.0.2.42")
    server.connection?.cancel()
    for _ in 0..<100 where client.isConnected { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!client.isConnected)
    server.hello = false
    time = time.addingTimeInterval(31)
    client.maintainConnection()
    for _ in 0..<100 where !server.hello { try await Task.sleep(for: .milliseconds(20)) }
    #expect(server.hello)
    #expect(!client.isConnected)
    try server.reply("rig.state")
    for _ in 0..<100 where !client.isConnected { try await Task.sleep(for: .milliseconds(20)) }
    #expect(client.isConnected)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHT_RIG_NETWORK_SMOKE"] == "1"))
@MainActor func physicalControllerRespondsThroughAdvertisingInterface() async throws {
    let discovery = LocalRigDiscovery()
    discovery.start()
    defer { discovery.stop() }
    let fallbackHost = ProcessInfo.processInfo.environment["LIGHT_RIG_NETWORK_HOST"] ?? ""
    for _ in 0..<500 where discovery.routes(for: fallbackHost).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    let route = try #require(discovery.routes(for: fallbackHost).first)
    guard case .local(let host, let port, let name) = route else { Issue.record("Missing local route"); return }
    let interface = try #require(discovery.interface(named: name))
    let socket = LocalWebSocket(url: URL(string: "ws://\(host):\(port)/ws")!, interface: interface)
    var stateReceived = false
    var failure = "none"
    socket.onMessage = { data in
        stateReceived = (try? JSONDecoder().decode(WireEnvelope.self, from: data))?.type == "rig.state"
    }
    socket.onError = { failure = $0 }
    socket.start()
    defer { socket.cancel() }
    socket.send(try JSONEncoder().encode(WireEnvelope(type: "hello")))
    for _ in 0..<500 where !stateReceived { try await Task.sleep(for: .milliseconds(20)) }
    #expect(stateReceived, "Route \(route); error: \(failure)")
}

@Test @MainActor func savedAddressUsesPhysicalInterfaceWithoutBonjour() async throws {
    let discovery = LocalRigDiscovery(serviceType: "_lrigabsent._tcp")
    discovery.start()
    defer { discovery.stop() }
    for _ in 0..<250 where discovery.routes(for: "192.0.2.20").isEmpty {
        try await Task.sleep(for: .milliseconds(20))
    }
    let route = try #require(discovery.routes(for: "192.0.2.20").first)
    guard case .local(let host, let port, let name) = route else { Issue.record("Missing local route"); return }
    #expect(host == "192.0.2.20" && port == 80)
    let interface = try #require(discovery.interface(named: name))
    #expect(interface.type == .wifi || interface.type == .wiredEthernet)
    discovery.stop()
    #expect(discovery.routes(for: "192.0.2.20").isEmpty)
}
