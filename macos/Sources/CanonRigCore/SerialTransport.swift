import Darwin
import Foundation

public struct SerialLineDecoder {
    private var buffer = Data()
    private var overflow = false
    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        var messages: [Data] = []
        for byte in data {
            if byte == 10 {
                if !overflow, buffer.starts(with: Data("@rig ".utf8)) {
                    messages.append(Data(buffer.dropFirst(5)))
                }
                buffer.removeAll(keepingCapacity: true)
                overflow = false
            } else if byte != 13 {
                if buffer.count < 32768 && !overflow { buffer.append(byte) }
                else { overflow = true }
            }
        }
        return messages
    }
}

/// CH340 UART bridge, not native ESP USB (which is reserved for Canon).
/// Nonblocking I/O is polled on the main actor; no DTR/RTS reset toggles.
@MainActor
protocol RigSerialConnection: AnyObject {
    var onMessage: ((Data) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func open(_ path: String) throws
    func close()
    func send(_ data: Data)
}

@MainActor
final class SerialTransport: RigSerialConnection {
    private var descriptor: Int32 = -1
    private var reader: Task<Void, Never>?
    private var decoder = SerialLineDecoder()
    private var pending = Data()
    var onMessage: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    static func ports() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial") }
            .sorted().map { "/dev/" + $0 }
    }

    func open(_ path: String) throws {
        close()
        guard Self.ports().contains(path) else { throw POSIXError(.ENODEV) }
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Prevent another app from opening the port after us. A pre-existing
        // monitor must still be closed by its owner before connecting.
        guard ioctl(fd, TIOCEXCL) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EBUSY)
        }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        cfmakeraw(&options)
        cfsetspeed(&options, speed_t(B115200))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CRTSCTS | HUPCL)
        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        descriptor = fd
        reader = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func close() {
        reader?.cancel()
        reader = nil
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        pending.removeAll()
        decoder = SerialLineDecoder()
    }

    func send(_ data: Data) {
        guard descriptor >= 0 else { return }
        guard data.count <= 8192, pending.count + data.count < 32768 else {
            fail("USB command queue overflow")
            return
        }
        pending.append(data)
        pending.append(10)
        poll()
    }

    private func fail(_ message: String) {
        close()
        onError?(message)
    }

    private func poll() {
        guard descriptor >= 0 else { return }
        if !pending.isEmpty {
            let count = pending.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { pending.removeFirst(count) }
            else if count < 0 && errno != EAGAIN && errno != EINTR {
                fail("USB write: \(String(cString: strerror(errno)))")
                return
            }
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
            for message in decoder.append(Data(bytes.prefix(count))) { onMessage?(message) }
        } else if count < 0 && errno != EAGAIN && errno != EINTR {
            fail("USB read: \(String(cString: strerror(errno)))")
        }
    }
}
