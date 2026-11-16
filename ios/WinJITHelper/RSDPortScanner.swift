// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from Henge (Leviidev/Henge, GPL-2.0-or-later) at 7b55730: ios/HengeJITHelper/RSDPortScanner.swift.
import Foundation
import Darwin

/// Last resort when Bonjour finds no `_remotepairing._tcp` port: list the ports open on `host` in the range
/// iOS picks the RemotePairing port from (49152...65535). The caller tries each with StikJIT, or, through
/// the user's own VPN, with RemotePairing's opening handshake (remotePairingAnswers).
/// shortcut: plain TCP connect scan; a batch ends as soon as all its connects have finished (closed ports
/// refuse at once over LocalDevVPN), so it is quick unless ports stay silent: then up to 250 ms per batch,
/// about 8 s with 512 sockets at a time. Drop it once Bonjour lookup works on every device.
/// `host` is IPv4 or IPv6: through the user's own VPN the device is reached at an address its server
/// routes back to it, where a closed port answers only after a round trip to that server (the caller
/// waits longer per batch there).
enum RSDPortScanner {
    /// Ports that are open but never RemotePairing: lockdownd.
    static let known: Set<UInt16> = [62078]

    /// File descriptors left for the rest of the process (StikJIT, the extension's own) while a batch is open.
    private static let reservedDescriptors = 64

    /// `batch` sockets are connecting at a time, fewer when the descriptor limit is lower (an app
    /// extension's soft limit is often 256); each batch waits up to `waitMs` for its connects to finish.
    static func openPorts(host: String = "10.7.0.1", range: ClosedRange<UInt16> = 49152...65535,
                          batch: Int = 512, waitMs: Int32 = 250) -> [UInt16] {
        guard let family = socketAddress(host: host, port: 0)?.family else { return [] }
        let batch = max(16, min(batch, descriptorBudget(wanted: batch) - reservedDescriptors))

        var open: [UInt16] = []
        let ports = Array(range)
        var next = 0
        while next < ports.count {
            var fds: [pollfd] = []
            var portFor: [Int32: UInt16] = [:]
            while next < ports.count && fds.count < batch {
                let port = ports[next]
                let fd = socket(family, SOCK_STREAM, 0)
                if fd < 0 {
                    // Out of descriptors: this port goes in the next batch, once this one has closed its
                    // sockets. A port is never skipped for want of a socket.
                    if (errno == EMFILE || errno == ENFILE) && !fds.isEmpty { break }
                    next += 1
                    continue
                }
                next += 1
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                if startConnect(fd, host: host, port: port) {
                    fds.append(pollfd(fd: fd, events: Int16(POLLOUT), revents: 0))
                    portFor[fd] = port
                } else {
                    close(fd)
                }
            }
            open += finish(&fds, portFor: portFor, waitMs: waitMs)
        }
        return open
    }

    /// What one TCP connect to `host`:`port` came to.
    enum ConnectOutcome: Equatable, CustomStringConvertible {
        case open
        /// The port is closed: something answered with a reset.
        case refused
        /// Nothing answered within the wait.
        case timedOut
        /// Any other error (errno): no route, network down, ...
        case failed(Int32)
        case invalidAddress

        var description: String {
            switch self {
            case .open: return "open"
            case .refused: return "refused (closed port)"
            case .timedOut: return "no answer (timed out)"
            case .failed(let code): return String(cString: strerror(code))
            case .invalidAddress: return "not an IPv4 or IPv6 address"
            }
        }
    }

    /// One TCP connect, closed again straight away: is RemotePairing's port reachable at `host`?
    static func connect(host: String, port: UInt16, timeoutMs: Int32) -> ConnectOutcome {
        let (fd, outcome) = openConnection(host: host, port: port, timeoutMs: timeoutMs)
        if fd >= 0 { close(fd) }
        return outcome
    }

    /// A non-blocking TCP connection to `host`:`port`: its socket when the outcome is .open (the caller
    /// closes it), otherwise -1.
    private static func openConnection(host: String, port: UInt16, timeoutMs: Int32) -> (fd: Int32, outcome: ConnectOutcome) {
        guard let family = socketAddress(host: host, port: port)?.family else { return (-1, .invalidAddress) }
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return (-1, .failed(errno)) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let outcome = waitForConnect(fd, host: host, port: port, timeoutMs: timeoutMs)
        if outcome != .open { close(fd) }
        return (outcome == .open ? fd : -1, outcome)
    }

    private static func waitForConnect(_ fd: Int32, host: String, port: UInt16, timeoutMs: Int32) -> ConnectOutcome {
        guard startConnect(fd, host: host, port: port) else {
            return errno == ECONNREFUSED ? .refused : .failed(errno)
        }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timedOut }
            let ready = poll(&p, 1, Int32((deadline - now + 999_999) / 1_000_000))
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 { return .failed(errno) }
            if ready == 0 { return .timedOut }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            switch err {
            case 0: return .open
            case ECONNREFUSED: return .refused
            case ETIMEDOUT: return .timedOut
            default: return .failed(err)
            }
        }
    }

    // MARK: Does RemotePairing answer?

    /// What one RemotePairing handshake at `host`:`port` came to (remotePairingAnswers).
    enum ProbeOutcome: Equatable, CustomStringConvertible {
        /// The reply began with RemotePairing's "RPPairing" frame.
        case answered
        /// No TCP connection.
        case cannotConnect(ConnectOutcome)
        /// Connected, then the other end closed or reset the connection before any reply.
        case closedWithoutAnswer(String)
        /// Connected, but nothing came back within the wait.
        case silent
        /// Something replied, but not with a RemotePairing frame: another service.
        case otherService

        var description: String {
            switch self {
            case .answered: return "RemotePairing answered"
            case .cannotConnect(let outcome): return "cannot connect: \(outcome)"
            case .closedWithoutAnswer(let how): return "connected, then the connection was \(how) before any RemotePairing answer"
            case .silent: return "connected, but nothing answered"
            case .otherService: return "connected, but the reply is not RemotePairing's (another service)"
            }
        }
    }

    /// RemotePairing frames each message as "RPPairing", a big-endian 16-bit length and JSON.
    private static let rpPairingMagic = Array("RPPairing".utf8)

    /// The first message StikJIT's idevice sends on RemotePairing's port: the handshake with
    /// attemptPairVerify (idevice remote_pairing attempt_pair_verify, wire protocol 19). The device
    /// answers it before it looks at any pairing, so no pairing key is needed and nothing is paired.
    private static let handshakeFrame: [UInt8] = {
        let json = #"{"message":{"plain":{"_0":{"request":{"_0":{"handshake":{"_0":{"hostOptions":{"attemptPairVerify":true},"wireProtocolVersion":19}}}}}}},"originatedBy":"host","sequenceNumber":0}"#
        let body = Array(json.utf8)
        return rpPairingMagic + [UInt8(body.count >> 8), UInt8(body.count & 0xff)] + body
    }()

    /// Connects to `host`:`port`, sends RemotePairing's opening handshake and reads the start of the
    /// reply: tells "RemotePairing answered" from "the connection was closed without an answer", "no
    /// answer" and "another service", which idevice's own errors do not. Waits up to `connectMs` for
    /// the connection, then up to `answerMs` for the reply.
    static func remotePairingAnswers(host: String, port: UInt16, connectMs: Int32, answerMs: Int32) -> ProbeOutcome {
        let (fd, connected) = openConnection(host: host, port: port, timeoutMs: connectMs)
        guard connected == .open else { return .cannotConnect(connected) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(answerMs) * 1_000_000
        /// Waits for `events` on the socket: false when the deadline passed.
        func ready(_ events: Int32) -> Bool {
            var p = pollfd(fd: fd, events: Int16(events), revents: 0)
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                let rc = poll(&p, 1, Int32((deadline - now + 999_999) / 1_000_000))
                if rc < 0 && errno == EINTR { continue }
                return rc > 0
            }
        }
        func closed(_ code: Int32) -> ProbeOutcome {
            .closedWithoutAnswer(code == ECONNRESET ? "reset" : code == EPIPE ? "closed" : String(cString: strerror(code)))
        }

        var sent = 0
        while sent < handshakeFrame.count {
            guard ready(POLLOUT) else { return .silent }
            let n = handshakeFrame[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return closed(errno)
            }
            sent += n
        }

        var reply: [UInt8] = []
        while reply.count < rpPairingMagic.count {
            guard ready(POLLIN) else { return reply.isEmpty ? .silent : .otherService }
            var buffer = [UInt8](repeating: 0, count: rpPairingMagic.count - reply.count)
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return reply.isEmpty ? closed(errno) : .otherService
            }
            if n == 0 { return reply.isEmpty ? .closedWithoutAnswer("closed") : .otherService }
            reply += buffer[..<n]
            guard reply.elementsEqual(rpPairingMagic.prefix(reply.count)) else { return .otherService }
        }
        return .answered
    }

    /// A non-blocking connect to `host`:`port` is under way (or done) on `fd`.
    private static func startConnect(_ fd: Int32, host: String, port: UInt16) -> Bool {
        guard var address = socketAddress(host: host, port: port) else { return false }
        let rc = withUnsafePointer(to: &address.storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, address.length)
            }
        }
        return rc == 0 || errno == EINPROGRESS
    }

    /// `host` (a numeric IPv4 or IPv6 address) and `port` as a socket address, or nil.
    static func socketAddress(host: String, port: UInt16)
        -> (storage: sockaddr_storage, length: socklen_t, family: Int32)? {
        var storage = sockaddr_storage()
        var v4 = sockaddr_in()
        if inet_pton(AF_INET, host, &v4.sin_addr) == 1 {
            v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            v4.sin_family = sa_family_t(AF_INET)
            v4.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &storage) { target in withUnsafeBytes(of: &v4) { target.copyMemory(from: $0) } }
            return (storage, socklen_t(MemoryLayout<sockaddr_in>.size), AF_INET)
        }
        var v6 = sockaddr_in6()
        if inet_pton(AF_INET6, host, &v6.sin6_addr) == 1 {
            v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            v6.sin6_family = sa_family_t(AF_INET6)
            v6.sin6_port = port.bigEndian
            withUnsafeMutableBytes(of: &storage) { target in withUnsafeBytes(of: &v6) { target.copyMemory(from: $0) } }
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size), AF_INET6)
        }
        return nil
    }

    /// Polls until every connect in the batch has finished or `waitMs` has passed: one poll() returns as
    /// soon as any socket has an event (a refused port resets almost at once), while others are still
    /// connecting. Closes every socket; returns the ports that accepted.
    private static func finish(_ fds: inout [pollfd], portFor: [Int32: UInt16], waitMs: Int32) -> [UInt16] {
        var open: [UInt16] = []
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(waitMs) * 1_000_000
        while !fds.isEmpty {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            let left = Int32(min(UInt64(waitMs), (deadline - now + 999_999) / 1_000_000))
            let ready = poll(&fds, nfds_t(fds.count), left)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            var pending: [pollfd] = []
            for p in fds {
                if p.revents == 0 {
                    pending.append(p)
                    continue
                }
                if p.revents & Int16(POLLOUT) != 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(p.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    if err == 0, let port = portFor[p.fd], !known.contains(port) { open.append(port) }
                }
                close(p.fd)
            }
            fds = pending
        }
        fds.forEach { close($0.fd) }
        fds.removeAll()
        return open
    }

    /// The soft RLIMIT_NOFILE, raised towards `wanted` plus the reserve when the hard limit allows.
    private static func descriptorBudget(wanted: Int) -> Int {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 256 }
        let target = rlim_t(wanted + reservedDescriptors * 2)
        if limit.rlim_cur < target {
            var raised = limit
            raised.rlim_cur = min(target, limit.rlim_max)
            if setrlimit(RLIMIT_NOFILE, &raised) == 0 { limit = raised }
        }
        return Int(min(limit.rlim_cur, rlim_t(Int32.max)))
    }
}
