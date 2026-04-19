import Foundation
import Darwin
import ETS2FFCore

/// Unix-domain socket server that lets the GUI app change FF settings live.
///
/// Protocol: newline-delimited JSON of `ControlMessage`.
///   - client sends { "kind": "query" }           → server replies with `status`
///   - client sends { "kind": "apply", payload }  → server applies + replies `status`
///
/// The server runs on a DispatchQueue and posts mutations back to the main
/// queue so the daemon's USB/FF calls stay on a single thread.
final class ControlServer {

    /// Callback from the server to the daemon when the app sends new settings.
    /// Called on main queue.
    var onApply: ((FFSettings) -> Void)?

    /// Snapshot provider — the server calls this on-demand (main queue) to
    /// build a fresh `FFStatus` when a client queries.
    var statusProvider: (() -> FFStatus)?

    private let queue = DispatchQueue(label: "ets2ff.ctrl", qos: .userInitiated)
    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: ClientState] = [:]

    private final class ClientState {
        let fd: Int32
        let source: DispatchSourceRead
        var inbuf = Data()
        init(fd: Int32, source: DispatchSourceRead) { self.fd = fd; self.source = source }
    }

    func start(socketPath: String = ControlPaths.socketPath) throws {
        unlink(socketPath)  // stale socket from prior run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw POSIXError(.EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < maxLen else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            memcpy(ptr, pathBytes, pathBytes.count)
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.bind(fd, sp, addrLen)
            }
        }
        if bindRes < 0 {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "bind(\(socketPath)) failed: \(String(cString: strerror(err)))"])
        }

        // World-writable so non-root GUI app can connect to a root-owned socket.
        chmod(socketPath, 0o666)

        if Darwin.listen(fd, 8) < 0 {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }

        serverFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.handleAccept() }
        src.resume()
        acceptSource = src

        // Status printed by main.swift.
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if serverFD >= 0 { Darwin.close(serverFD); serverFD = -1 }
            for (_, c) in clients {
                c.source.cancel()
                Darwin.close(c.fd)
            }
            clients.removeAll()
        }
        unlink(ControlPaths.socketPath)
    }

    // MARK: - Accept / read loop

    private func handleAccept() {
        var peer = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let cfd = Darwin.accept(serverFD, &peer, &len)
        if cfd < 0 { return }

        // Make sure the FD closes on exec and is non-blocking for reads.
        _ = fcntl(cfd, F_SETFD, FD_CLOEXEC)

        let src = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: queue)
        let state = ClientState(fd: cfd, source: src)
        src.setEventHandler { [weak self] in self?.handleClientRead(state) }
        src.setCancelHandler {
            Darwin.close(cfd)
        }
        clients[cfd] = state
        src.resume()
    }

    private func handleClientRead(_ c: ClientState) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBufferPointer {
            Darwin.read(c.fd, $0.baseAddress, $0.count)
        }
        if n <= 0 {
            // peer closed or error
            c.source.cancel()
            clients.removeValue(forKey: c.fd)
            return
        }
        c.inbuf.append(buf, count: n)

        // Process line by line
        while let nlIdx = c.inbuf.firstIndex(of: 0x0A) {
            let line = c.inbuf.subdata(in: c.inbuf.startIndex..<nlIdx)
            c.inbuf.removeSubrange(c.inbuf.startIndex...nlIdx)
            if !line.isEmpty { dispatchLine(line, client: c) }
        }

        // Cap buffer to avoid a pathological client OOM'ing us.
        if c.inbuf.count > 64 * 1024 {
            c.inbuf.removeAll(keepingCapacity: true)
        }
    }

    private func dispatchLine(_ line: Data, client c: ClientState) {
        let msg: ControlMessage
        do {
            msg = try JSONDecoder().decode(ControlMessage.self, from: line)
        } catch {
            print("[Ctrl] decode error: \(error)")
            return
        }

        switch msg {
        case .apply(let s):
            DispatchQueue.main.async { [weak self] in
                self?.onApply?(s)
                self?.sendStatus(to: c)
            }

        case .query:
            DispatchQueue.main.async { [weak self] in
                self?.sendStatus(to: c)
            }

        case .status:
            break  // daemons don't consume status messages
        }
    }

    // Called on main, but we hand off writing to our queue to avoid blocking.
    private func sendStatus(to c: ClientState) {
        let status = statusProvider?() ?? FFStatus()
        let reply = ControlMessage.status(status)
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(0x0A)
        let fd = c.fd
        queue.async {
            _ = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base, raw.count)
            }
        }
    }
}
