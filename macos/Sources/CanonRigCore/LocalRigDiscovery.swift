import Foundation
import Network
import dnssd
import Darwin

/// Browses each physical interface class and resolves services on their advertising interface.
@MainActor
final class LocalRigDiscovery {
    private let serviceType: String
    private var browsers: [NWBrowser] = []
    private var monitors: [NWPathMonitor] = []
    private var paths: [Int: [NWInterface]] = [:]
    private var results: [Int: Set<NWBrowser.Result>] = [:]
    private var resolvers: [String: ServiceResolver] = [:]
    private var resolved: [String: RigEndpoint] = [:]
    private var interfaces: [String: NWInterface] = [:]
    var routes: [RigEndpoint] { resolved.keys.sorted().compactMap { resolved[$0] } }

    init(serviceType: String = "_canonrig._tcp") { self.serviceType = serviceType }

    func interface(named name: String) -> NWInterface? { interfaces[name] }

    func routes(for host: String) -> [RigEndpoint] {
        let fallback = host.isEmpty ? [] : interfaces.keys.sorted().map {
            RigEndpoint.local(host: host, port: 80, interface: $0)
        }
        var seen = Set<RigEndpoint>()
        return (routes + fallback).filter { seen.insert($0).inserted }
    }

    func start() {
        guard browsers.isEmpty else { return }
        for (index, type) in [NWInterface.InterfaceType.wifi, .wiredEthernet].enumerated() {
            let monitor = NWPathMonitor(requiredInterfaceType: type)
            monitor.pathUpdateHandler = { [weak self] path in
                MainActor.assumeIsolated {
                    self?.paths[index] = path.status == .satisfied ? path.availableInterfaces.filter { $0.type == type } : []
                    self?.refresh()
                }
            }
            monitors.append(monitor)
            monitor.start(queue: .main)
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = type
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] found, _ in
                MainActor.assumeIsolated {
                    self?.results[index] = found
                    self?.refresh()
                }
            }
            browsers.append(browser)
            browser.start(queue: .main)
        }
    }

    private func refresh() {
        var present = Set<String>()
        interfaces.removeAll()
        for interface in paths.values.flatMap({ $0 }) { interfaces[interface.name] = interface }
        for result in results.values.flatMap({ $0 }) {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            for interface in result.interfaces where interface.type == .wifi || interface.type == .wiredEthernet {
                interfaces[interface.name] = interface
                let key = "\(name)|\(type)|\(domain)|\(interface.index)"
                present.insert(key)
                guard resolvers[key] == nil else { continue }
                let resolver = ServiceResolver(name: name, type: type, domain: domain, interface: interface)
                resolver.onResolve = { [weak self] host, port in
                    self?.resolved[key] = .local(host: host, port: port, interface: interface.name)
                }
                resolvers[key] = resolver
                resolver.start()
            }
        }
        for key in Array(resolvers.keys) where !present.contains(key) {
            resolvers.removeValue(forKey: key)?.stop()
            resolved.removeValue(forKey: key)
        }
    }

    func stop() {
        for browser in browsers {
            browser.browseResultsChangedHandler = nil
            browser.cancel()
        }
        browsers.removeAll()
        for monitor in monitors { monitor.pathUpdateHandler = nil; monitor.cancel() }
        monitors.removeAll()
        paths.removeAll()
        for resolver in resolvers.values { resolver.stop() }
        resolvers.removeAll()
        resolved.removeAll()
        results.removeAll()
        interfaces.removeAll()
    }

    isolated deinit { stop() }
}

@MainActor
private final class ServiceResolver {
    var onResolve: ((String, UInt16) -> Void)?
    private let name: String
    private let type: String
    private let domain: String
    private let interface: NWInterface
    private var reference: DNSServiceRef?
    private var addressReference: DNSServiceRef?
    private var port: UInt16 = 0

    init(name: String, type: String, domain: String, interface: NWInterface) {
        self.name = name; self.type = type; self.domain = domain; self.interface = interface
    }

    func start() {
        let error = DNSServiceResolve(&reference, 0, UInt32(interface.index), name, type, domain, { _, _, _, error, _, host, port, _, _, context in
            guard error == kDNSServiceErr_NoError, let host, let context else { return }
            MainActor.assumeIsolated {
                let resolver = Unmanaged<ServiceResolver>.fromOpaque(context).takeUnretainedValue()
                resolver.resolveAddress(String(cString: host), port: UInt16(bigEndian: port))
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let reference else { stop(); return }
        if DNSServiceSetDispatchQueue(reference, .main) != kDNSServiceErr_NoError { stop() }
    }

    private func resolveAddress(_ host: String, port: UInt16) {
        if let addressReference { DNSServiceRefDeallocate(addressReference) }
        addressReference = nil
        self.port = port
        // The controller firmware serves IPv4. Resolve on the same interface as its SRV record.
        let error = DNSServiceGetAddrInfo(&addressReference, 0, UInt32(interface.index),
                                         DNSServiceProtocol(kDNSServiceProtocol_IPv4), host, { _, flags, _, error, _, address, _, context in
            guard error == kDNSServiceErr_NoError, flags & UInt32(kDNSServiceFlagsAdd) != 0,
                  let address, let context else { return }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return }
            let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            MainActor.assumeIsolated {
                let resolver = Unmanaged<ServiceResolver>.fromOpaque(context).takeUnretainedValue()
                resolver.onResolve?(host, resolver.port)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let addressReference else { return }
        if DNSServiceSetDispatchQueue(addressReference, .main) != kDNSServiceErr_NoError {
            DNSServiceRefDeallocate(addressReference)
            self.addressReference = nil
        }
    }

    func stop() {
        if let addressReference { DNSServiceRefDeallocate(addressReference) }
        addressReference = nil
        if let reference { DNSServiceRefDeallocate(reference) }
        reference = nil
    }

    isolated deinit { stop() }
}
