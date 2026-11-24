import CryptoKit
import Foundation

struct FirmwareUpdateError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

struct ControllerImage {
    let bytes: Data
    let version: String

    init?(_ data: Data) {
        guard (289...0x190000).contains(data.count), data[0] == 0xe9, data[12] == 2, data[13] == 0,
              data[32..<36].elementsEqual([0x32, 0x54, 0xcd, 0xab]),
              data[23] == 1, SHA256.hash(data: data.dropLast(32)).elementsEqual(data.suffix(32)),
              String(decoding: data[80..<112].prefix(while: { $0 != 0 }), as: UTF8.self) == "light_rig"
        else { return nil }
        let version = String(decoding: data[48..<80].prefix(while: { $0 != 0 }), as: UTF8.self)
        guard Self.components(version) != nil else { return nil }
        self.version = version
        bytes = data
    }

    private static func components(_ version: String) -> [UInt32]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { UInt32($0) }
        guard parts.count == 3, numbers.count == 3,
              numbers.map(String.init).joined(separator: ".") == version else { return nil }
        return numbers
    }

    func isNewer(than current: String) -> Bool {
        guard let old = Self.components(current), let new = Self.components(version) else { return false }
        return old.lexicographicallyPrecedes(new)
    }

    func supports(_ state: RigState) -> Bool {
        if let target = state.firmwareTarget { return target == "Light-Rig-esp32s2" && state.otaProtocol == 1 }
        return state.isLegacyLightController && state.firmware == "0.1.0"
    }
}

private final class UploadDelegate: NSObject, URLSessionTaskDelegate {
    let progress: @Sendable (Int) -> Void
    init(progress: @escaping @Sendable (Int) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { progress(Int(totalBytesSent * 99 / totalBytesExpectedToSend)) }
    }
}

@MainActor
public final class ControllerFirmware: ObservableObject {
    @Published public private(set) var status = ""
    @Published public private(set) var progress: Int?
    @Published public private(set) var canRetry = false
    private let client: RigClient
    private let image: ControllerImage?
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var legacyUpload: URLSession?
    private var idleSince: Date?
    private var currentBoard = ""
    private var busy = true
    private let now: () -> Date
    private var blockedKey: String { "firmwareAttempt.\(currentBoard)" }

    public convenience init(client: RigClient) {
        let data = Bundle.main.url(forResource: "Light-Rig-esp32s2", withExtension: "bin")
            .flatMap { try? Data(contentsOf: $0) }
        self.init(client: client, image: data.flatMap(ControllerImage.init), defaults: .standard)
    }

    init(client: RigClient, image: ControllerImage?, defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.now = now
        self.client = client
        self.image = image
        self.defaults = defaults
    }

    public func retry() {
        guard canRetry, task == nil, client.isConnected, client.state.deviceID == currentBoard else { return }
        defaults.removeObject(forKey: blockedKey)
        canRetry = false
        idleSince = nil
        status = ""
    }

    public func observe(videoActive: Bool) {
        let state = client.state
        busy = videoActive || state.aggregateCall == true || state.mode == "on_call" || state.mode == "preview"
        if busy { legacyUpload?.invalidateAndCancel() }
        guard task == nil, let image else { return }
        guard client.isConnected, !state.deviceID.isEmpty else { idleSince = nil; return }
        if currentBoard != state.deviceID {
            currentBoard = state.deviceID
            idleSince = nil
            canRetry = false
            status = ""
        }
        guard image.isNewer(than: state.firmware), image.supports(state) else {
            if image.version == state.firmware {
                if defaults.string(forKey: blockedKey) != nil { defaults.removeObject(forKey: blockedKey) }
                canRetry = false
                status = "Прошивка \(state.firmware)"
            }
            return
        }
        if let percent = state.otaProgress {
            status = "Light Rig обновляется · \(percent)%"
            idleSince = nil
            return
        }
        if defaults.string(forKey: blockedKey) == image.version {
            if !canRetry { status = "Обновление не подтверждено. На плате версия \(state.firmware)." }
            canRetry = true
            return
        }
        guard !busy, !client.cameraBusy, client.networkSetupStatus != .sending,
              client.networkSetupStatus != .waiting else {
            idleSince = nil
            status = "Обновление до \(image.version) отложено"
            return
        }
        guard state.otaProtocol == 1 || client.firmwareAddress != nil else {
            status = "Для первого обновления платы \(state.firmware) подключи её к Wi-Fi"
            return
        }
        guard let idleSince else { self.idleSince = now(); return }
        guard now().timeIntervalSince(idleSince) >= 4 else { return }
        let address = client.firmwareAddress
        client.firmwareTransferActive = true
        task = Task { await self.install(image, on: state, address: address) }
    }

    private func install(_ image: ControllerImage, on board: RigState, address: String?) async {
        defer {
            progress = nil
            client.firmwareTransferActive = false
            task = nil
            idleSince = nil
        }
        progress = 0
        status = "Обновление Light Rig до \(image.version)"
        let session = UUID().uuidString
        do {
            if board.otaProtocol == 1 {
                try await client.firmwareCommand(["op": .string("begin"), "session": .string(session),
                    "device": .string(board.deviceID), "from": .string(board.firmware),
                    "target": .string(image.version), "size": .number(Double(image.bytes.count))])
                do {
                    for offset in stride(from: 0, to: image.bytes.count, by: 1536) {
                        try checkConnection(board)
                        let end = min(offset + 1536, image.bytes.count)
                        try await client.firmwareCommand(["op": .string("write"), "session": .string(session),
                            "offset": .number(Double(offset)), "data": .string(image.bytes[offset..<end].base64EncodedString())])
                        progress = end * 99 / image.bytes.count
                    }
                    try checkConnection(board)
                    defaults.set(image.version, forKey: blockedKey)
                    try await client.firmwareCommand(["op": .string("finish"), "session": .string(session)])
                } catch {
                    if client.isConnected, client.state.deviceID == board.deviceID {
                        try? await client.firmwareCommand(["op": .string("abort"), "session": .string(session)])
                    }
                    throw error
                }
            } else if let address {
                try await installLegacy(image, board: board, address: address)
            }
            progress = 100
            status = "Light Rig перезапускается"
            for _ in 0..<55 {
                try await Task.sleep(for: .seconds(1))
                if client.isConnected, client.state.deviceID == board.deviceID, client.state.firmware == image.version {
                    status = "Прошивка \(image.version)"
                    canRetry = false
                    defaults.removeObject(forKey: blockedKey)
                    return
                }
            }
            throw FirmwareUpdateError("Плата не подтвердила новую версию")
        } catch {
            if (busy || error.localizedDescription == "controller busy"), defaults.string(forKey: blockedKey) == nil {
                status = "Ожидание готовности Light Rig"
            } else {
                defaults.set(image.version, forKey: blockedKey)
                status = "Обновление прервано. \(error.localizedDescription)"
                canRetry = true
            }
        }
    }

    private func checkConnection(_ board: RigState) throws {
        guard !busy, client.state.aggregateCall != true, client.state.mode != "on_call",
              client.state.mode != "preview" else { throw FirmwareUpdateError("Камера занята") }
        guard client.isConnected, client.state.deviceID == board.deviceID else { throw URLError(.networkConnectionLost) }
    }

    private func installLegacy(_ image: ControllerImage, board: RigState, address: String) async throws {
        var components = URLComponents()
        components.scheme = "http"
        components.host = address
        guard let base = components.url else { throw URLError(.badURL) }
        let delegate = UploadDelegate { [weak self] value in
            Task { @MainActor in
                if let self, let progress = self.progress, progress < value { self.progress = value }
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        legacyUpload = session
        defer {
            legacyUpload = nil
            session.invalidateAndCancel()
        }
        let (data, health) = try await session.data(from: base.appendingPathComponent("health"))
        guard (health as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
        let peer = RigState(envelope: envelope)
        guard envelope.type == "rig.state", envelope.v == 1, peer.deviceID == board.deviceID,
              peer.firmware == board.firmware, image.supports(peer),
              peer.aggregateCall != true, peer.mode != "on_call", peer.mode != "preview"
        else { throw FirmwareUpdateError("Не подтверждены плата или её готовность к обновлению") }
        try checkConnection(board)
        var request = URLRequest(url: base.appendingPathComponent("api/ota"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        defaults.set(image.version, forKey: blockedKey)
        let (reply, response) = try await session.upload(for: request, from: image.bytes)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: reply) as? [String: Bool],
              json["ok"] == true, json["rebooting"] == true else { throw URLError(.badServerResponse) }
    }
}
