// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from Henge (Leviidev/Henge, GPL-2.0-or-later) at 7b55730: ios/HengeJITHelper/RSDPortScanner.swift.
import Foundation
import Darwin

/// Last resort when Bonjour finds no `_remotepairing._tcp` port: list the ports open on `host` in the range
/// iOS picks the RemotePairing port from (49152...65535). The caller tries each with StikJIT.
/// shortcut: plain TCP connect scan; a batch ends as soon as all its connects have finished (closed ports
/// refuse at once over LocalDevVPN), so it is quick unless ports stay silent: then up to 250 ms per batch,
/// about 8 s with 512 sockets at a time. Drop it once Bonjour lookup works on every device.
enum RSDPortScanner {
    /// Ports that are open but never RemotePairing: lockdownd.
    static let known: Set<UInt16> = [62078]

    /// File descriptors left for the rest of the process (StikJIT, the extension's own) while a batch is open.
    private static let reservedDescriptors = 64

    /// `batch` sockets are connecting at a time, fewer when the descriptor limit is lower (an app
    /// extension's soft limit is often 256); each batch waits up to `waitMs` for its connects to finish.
    static func openPorts(host: String = "10.7.0.1", range: ClosedRange<UInt16> = 49152...65535,
                          batch: Int = 512, waitMs: Int32 = 250) -> [UInt16] {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return [] }
        let batch = max(16, min(batch, descriptorBudget(wanted: batch) - reservedDescriptors))

        var open: [UInt16] = []
        let ports = Array(range)
        var next = 0
        while next < ports.count {
            var fds: [pollfd] = []
            var portFor: [Int32: UInt16] = [:]
            while next < ports.count && fds.count < batch {
                let port = ports[next]
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                if fd < 0 {
                    // Out of descriptors: this port goes in the next batch, once this one has closed its
                    // sockets. A port is never skipped for want of a socket.
                    if (errno == EMFILE || errno == ENFILE) && !fds.isEmpty { break }
                    next += 1
                    continue
                }
                next += 1
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var a = addr
                a.sin_port = port.bigEndian
                let rc = withUnsafePointer(to: &a) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if rc == 0 || errno == EINPROGRESS {
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
