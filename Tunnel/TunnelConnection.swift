import Foundation
import NetworkExtension
import Darwin

// A provider's ordinary sockets bypass its tunnel. Apple's through-tunnel TCP
// API selects the virtual route explicitly. The socket pair adapts its stream
// to the existing Rust protocol client; it is never a network listener/relay.
final class TunnelConnection {
    let id = UUID()
    private let connection: NWTCPConnection
    private let descriptor: Int32
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var observation: NSKeyValueObservation?
    private let finished: (UUID) -> Void

    init(connection: NWTCPConnection, descriptor: Int32, finished: @escaping (UUID) -> Void) {
        self.connection = connection
        self.descriptor = descriptor
        self.finished = finished
    }
    func activate() {
        // Register with the provider before an initial KVO callback can finish
        // the connection; otherwise a cancelled bridge can be retained forever.
        observation = connection.observe(\.state, options: [.initial,.new]) { [weak self] connection, _ in
            guard let self else { return }
            if connection.state == .connected { self.start() }
            else if connection.state == .cancelled || connection.state == .disconnected { self.cancel() }
        }
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+8) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let pending = !self.started && !self.stopped; self.lock.unlock()
            if pending { self.cancel() }
        }
    }
    private func start() {
        lock.lock()
        guard !started && !stopped else { lock.unlock(); return }
        started = true
        lock.unlock()
        readNetwork()
        DispatchQueue.global(qos: .utility).async { [self] in
            var buffer = [UInt8](repeating: 0, count: 32768)
            while !isStopped {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count <= 0 { break }
                let completed = DispatchSemaphore(value: 0)
                var failed = false
                connection.write(Data(buffer.prefix(count))) { error in failed = error != nil; completed.signal() }
                if completed.wait(timeout: .now()+8) == .timedOut || failed { break }
            }
            cancel()
        }
    }
    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }; return stopped
    }
    private func readNetwork() {
        guard !isStopped else { return }
        connection.readMinimumLength(1, maximumLength: 32768) { [weak self] data, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty else { self.cancel(); return }
            DispatchQueue.global(qos: .utility).async {
                var written = 0
                data.withUnsafeBytes { bytes in
                    while written < data.count && !self.isStopped {
                        let count = Darwin.write(self.descriptor, bytes.baseAddress!.advanced(by: written), data.count-written)
                        if count <= 0 { break }
                        written += count
                    }
                }
                if written == data.count { self.readNetwork() } else { self.cancel() }
            }
        }
    }
    func cancel() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        connection.cancel()
        Darwin.shutdown(descriptor, SHUT_RDWR)
        finished(id)
    }
    deinit { observation?.invalidate(); Darwin.close(descriptor) }
}

private weak var currentHistoryProvider: PacketTunnelProvider?
func registerHistoryProvider(_ provider: PacketTunnelProvider) { currentHistoryProvider = provider }

func historyTunnelConnect(_ host: UnsafePointer<CChar>?, _ port: UInt16) -> Int32 {
    guard let host, let provider = currentHistoryProvider else { return -1 }
    return provider.openTunnelConnection(host: String(cString: host), port: port)
}
