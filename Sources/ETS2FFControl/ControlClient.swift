import Foundation
import Darwin
import ETS2FFCore

/// Connects to the daemon's Unix socket and handles send/receive.
/// Runs on its own background thread; posts FFStatus updates back on main.
final class ControlClient: ObservableObject {

    @Published var connected: Bool = false
    @Published var latestStatus: FFStatus?
    @Published var lastError: String?

    private let path = ControlPaths.socketPath
    private var fd: Int32 = -1
    private var readThread: Thread?
    private var stopping = false

    private let writeQueue = DispatchQueue(label: "ets2ff.ctrlclient.write")

    func start() {
        reconnectLoop()
    }

    func stop() {
        stopping = true
        closeFD()
    }

    func apply(_ settings: FFSettings) {
        send(.apply(settings))
    }

    func query() {
        send(.query)
    }

    // MARK: - Reconnect loop

    private func reconnectLoop() {
        let t = Thread { [weak self] in
            while let self, !self.stopping {
                if self.fd < 0 { self.tryConnect() }
                if self.fd >= 0 {
                    self.readLoopOnce()
                    // readLoopOnce returns only on disconnect
                    self.closeFD()
                    DispatchQueue.main.async { self.connected = false }
                }
                Thread.sleep(forTimeInterval: 1.5)
            }
        }
        t.name = "ControlClient-read"
        readThread = t
        t.start()
    }

    private func tryConnect() {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(s); return
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { p in
            memcpy(p, pathBytes, pathBytes.count)
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(s, sp, len)
            }
        }
        if r < 0 {
            Darwin.close(s); return
        }
        fd = s
        DispatchQueue.main.async {
            self.connected = true
            self.lastError = nil
        }
        // Ask for initial status
        send(.query)
    }

    private func readLoopOnce() {
        var inbuf = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !stopping {
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            inbuf.append(buf, count: n)
            while let nl = inbuf.firstIndex(of: 0x0A) {
                let line = inbuf.subdata(in: inbuf.startIndex..<nl)
                inbuf.removeSubrange(inbuf.startIndex...nl)
                if line.isEmpty { continue }
                if let msg = try? JSONDecoder().decode(ControlMessage.self, from: line),
                   case .status(let st) = msg {
                    DispatchQueue.main.async { self.latestStatus = st }
                }
            }
        }
    }

    private func send(_ msg: ControlMessage) {
        let fdSnapshot = fd
        guard fdSnapshot >= 0 else { return }
        guard var data = try? JSONEncoder().encode(msg) else { return }
        data.append(0x0A)
        writeQueue.async {
            _ = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fdSnapshot, base, raw.count)
            }
        }
    }

    private func closeFD() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}
