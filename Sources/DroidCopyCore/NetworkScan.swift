import Foundation
import Darwin
import os

/// An adb found listening on this Mac's network.
public struct FoundDevice: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Plain adb (`adb tcpip`, usually port 5555): `adb connect` works right away.
        case adb
        /// Android 11's Wireless debugging. This Mac has to pair with it once before it connects.
        case wirelessDebugging
    }

    public let host: String
    public let port: Int
    public let kind: Kind

    public init(host: String, port: Int, kind: Kind) {
        self.host = host
        self.port = port
        self.kind = kind
    }

    public var address: String { "\(host):\(port)" }
}

/// Finds Android devices on the local network without typing an address.
///
/// adb's own discovery relies on the device announcing itself over mDNS, which many routers and
/// some devices don't pass on. This asks the network directly instead:
/// 1. Knock on port 5555 of every address on the Mac's local networks. A phone answers at once,
///    even with nothing listening there ("connection refused"); addresses with nothing on them,
///    and computers whose firewall drops the knock, stay silent and are skipped.
/// 2. On each phone that answered, try 5555 and the range Android picks Wireless debugging's
///    port from (it changes whenever Wireless debugging is turned on, or the device restarts).
/// 3. Check that each open port speaks adb.
public enum NetworkScan {
    static let log = Logger(subsystem: "local.droidcopy", category: "scan")
    public static let classicPort = 5555
    /// Android's ephemeral ports, where Wireless debugging and its pairing screen listen.
    public static let wirelessPorts = Array(32768...60999)

    public enum PortState: Hashable, Sendable {
        case open
        /// Nothing listening, but something at that address answered.
        case refused
        /// No answer in time.
        case silent
    }

    // MARK: Finding devices

    /// Every adb on the local network. Each one is passed to `found` as soon as it turns up, so a
    /// slow computer elsewhere on the network doesn't hold it back. `progress` goes from 0 to 1.
    /// `also` are hosts to look at even if they don't answer the knock, like the last one used.
    /// `hosts`, `knockPort` and `ports` are for tests.
    @discardableResult
    public static func find(hosts: [String]? = nil, also: [String] = [], knockPort: Int = classicPort,
                            ports: [Int] = [classicPort] + wirelessPorts,
                            found: @escaping @Sendable (FoundDevice) -> Void = { _ in },
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> [FoundDevice] {
        let testing = hosts != nil
        let hosts = hosts ?? localHosts()
        // Who's there: anything that answers a knock, and anything the Mac now knows a device is
        // at (its ARP table). A phone with its screen off often ignores knocks on closed ports
        // but still answers the address lookup the knock sets off. The router is left out.
        let knocks = await connectAll(hosts.map { ($0, knockPort) }, timeout: 2)
        if Task.isCancelled { return [] }
        var live = Set(zip(hosts, knocks).filter { $0.1 != .silent }.map(\.0))
        if !testing { live.formUnion(Set(arpTable()).subtracting(gateways())) }
        var targets = hosts.filter(live.contains)
        for h in also where !targets.contains(h) { targets.append(h) }
        log.info("Knocked on \(hosts.count) addresses, \(knocks.filter { $0 == .refused }.count) refused, \(knocks.filter { $0 == .open }.count) open; looking at \(targets.joined(separator: ", "), privacy: .public)")
        progress(targets.isEmpty ? 1 : 0.05)
        guard !targets.isEmpty else { return [] }

        // Every port of every host in one sweep, taking the hosts in turn. Each open port is
        // checked for adb straight away, so a find shows up without waiting for the rest.
        let all = ports.flatMap { port in targets.map { (host: $0, port: port) } }
        let results = Results()
        let probes = DispatchGroup()
        let total = Double(all.count)
        // A dozing phone takes a second or so to wake when a port it listens on is knocked.
        await offThread {
            sweepAll(all, timeout: 1.5, window: 4096, onOpen: { k in
                let t = all[k]
                probes.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    if let kind = probeSync(t.host, t.port, timeout: 2) {
                        let d = FoundDevice(host: t.host, port: t.port, kind: kind)
                        log.info("Found \(d.address, privacy: .public)")
                        results.add(d)
                        found(d)
                    }
                    probes.leave()
                }
            }, onProgress: { done in progress(0.05 + 0.95 * Double(done) / total) })
            probes.wait()
        }
        return results.all
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [FoundDevice] = []
        func add(_ d: FoundDevice) { lock.lock(); list.append(d); lock.unlock() }
        var all: [FoundDevice] { lock.lock(); defer { lock.unlock() }; return list }
    }

    /// The ports among `ports` that accept a connection at `host`.
    public static func openPorts(_ host: String, _ ports: [Int] = wirelessPorts) async -> [Int] {
        let states = await connectAll(ports.map { (host, $0) }, timeout: 1.0)
        return zip(ports, states).filter { $0.1 == .open }.map(\.0)
    }

    /// What's at `host:port`: adb, Wireless debugging, or nil for something else.
    ///
    /// Sends adb's opening message (CNXN). Plain adb answers CNXN or AUTH; Wireless debugging
    /// answers STLS once paired, and before that drops the connection at once (a reset). Other
    /// servers answer something else, or close politely, or wait for more.
    public static func probe(_ host: String, _ port: Int, timeout: TimeInterval = 2) async -> FoundDevice.Kind? {
        await offThread { probeSync(host, port, timeout: timeout) }
    }

    // MARK: The Mac's networks

    /// Addresses on the Mac's local IPv4 networks (Wi-Fi, Ethernet), not counting its own. A
    /// network bigger than /22 is narrowed to the /24 around the Mac, to keep the knock quick.
    public static func localHosts() -> [String] {
        var out: [String] = []
        var seen = Set<UInt32>()
        let own = Set(localNetworks().map(\.address))
        for net in localNetworks() {
            var mask = net.mask
            if mask.nonzeroBitCount < 22 { mask = 0xFFFF_FF00 }
            let base = net.address & mask
            let count = ~mask
            guard count >= 2 else { continue }
            for n in 1..<count {
                let a = base | n
                if own.contains(a) || !seen.insert(a).inserted { continue }
                out.append(format(a))
            }
        }
        return out
    }

    /// The Mac's IPv4 addresses and netmasks on interfaces that are up, leaving out loopback and
    /// VPN tunnels.
    static func localNetworks() -> [(address: UInt32, mask: UInt32)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [(UInt32, UInt32)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            let flags = Int32(i.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  flags & IFF_POINTOPOINT == 0,
                  let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), let m = i.ifa_netmask else { continue }
            let address = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // Link-local (169.254/16) means no DHCP: nothing to find there.
            if address >> 16 == 0xA9FE { continue }
            out.append((address, mask))
        }
        return out
    }

    /// Addresses the Mac has found a device at recently (`arp -an`).
    static func arpTable() -> [String] {
        Parse.arpAddresses(output("/usr/sbin/arp", ["-an"]))
    }

    /// The router(s) the Mac sends internet traffic through (`route -n get default`).
    static func gateways() -> Set<String> {
        Set(Parse.gateway(output("/sbin/route", ["-n", "get", "default"])).map { [$0] } ?? [])
    }

    private static func output(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func format(_ a: UInt32) -> String {
        "\(a >> 24 & 0xFF).\(a >> 16 & 0xFF).\(a >> 8 & 0xFF).\(a & 0xFF)"
    }

    // MARK: Sockets

    /// Tries a TCP connection to each target, many at once, and closes it again.
    public static func connectAll(_ targets: [(host: String, port: Int)], timeout: TimeInterval,
                                  window: Int = 512) async -> [PortState] {
        await offThread { connectAllSync(targets, timeout: timeout, window: window) }
    }

    /// Runs blocking socket work on a thread of its own, not one Swift's tasks share.
    private static func offThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) }
        }
    }

    /// Keeps up to `window` connections in flight, each with its own deadline. Wi-Fi loses the
    /// odd attempt when this many go out at once, so the ones that got no answer are tried once
    /// more, unless that's most of them (a host that ignores everything isn't worth the wait).
    static func connectAllSync(_ targets: [(host: String, port: Int)], timeout: TimeInterval, window: Int) -> [PortState] {
        var result = [PortState](repeating: .silent, count: targets.count)
        sweep(targets, Array(targets.indices), timeout: timeout, window: window, into: &result)
        let silent = result.indices.filter { result[$0] == .silent }
        if !silent.isEmpty, silent.count <= max(64, targets.count / 10) {
            sweep(targets, silent, timeout: timeout, window: window, into: &result)
        }
        return result
    }

    /// `connectAllSync` for a scan: tells `onOpen` about each open target as it's found, and
    /// `onProgress` how many are done now and then.
    static func sweepAll(_ targets: [(host: String, port: Int)], timeout: TimeInterval, window: Int,
                         onOpen: (Int) -> Void, onProgress: (Int) -> Void) {
        var result = [PortState](repeating: .silent, count: targets.count)
        let start = Date()
        sweep(targets, Array(targets.indices), timeout: timeout, window: window, into: &result,
              onOpen: onOpen, onProgress: onProgress)
        log.info("Swept \(targets.count) ports in \(Int(Date().timeIntervalSince(start)))s: \(result.filter { $0 == .open }.count) open, \(result.filter { $0 == .refused }.count) refused")
    }

    private static func sweep(_ targets: [(host: String, port: Int)], _ which: [Int], timeout: TimeInterval,
                              window: Int, into result: inout [PortState],
                              onOpen: (Int) -> Void = { _ in }, onProgress: (Int) -> Void = { _ in }) {
        let window = max(16, min(window, socketBudget))
        var fds: [pollfd] = []
        var index: [Int] = []
        var deadline: [Date] = []
        var next = 0
        var done = 0
        var lastReport = Date.distantPast
        func finish(_ k: Int, _ state: PortState) {
            result[k] = state
            done += 1
            if state == .open { onOpen(k) }
        }
        while next < which.count || !fds.isEmpty {
            fill: while next < which.count && fds.count < window {
                let k = which[next]
                switch startConnect(targets[k].host, targets[k].port) {
                case .done(let state): finish(k, state)
                case .pending(let fd):
                    fds.append(pollfd(fd: fd, events: Int16(POLLOUT), revents: 0))
                    index.append(k)
                    deadline.append(Date().addingTimeInterval(timeout))
                case .busy:
                    // Out of sockets or local ports for now: wait for some to finish. With
                    // nothing in flight there's nothing to wait for, so give up on this one.
                    if fds.isEmpty { finish(k, .silent) } else { break fill }
                }
                next += 1
            }
            if Date().timeIntervalSince(lastReport) > 0.25 {
                onProgress(done)
                lastReport = Date()
            }
            guard !fds.isEmpty else { continue }
            let wait = max(1, min(50, Int32((deadline.min()!.timeIntervalSinceNow) * 1000)))
            let n = poll(&fds, nfds_t(fds.count), wait)
            if n < 0 && errno != EINTR { break }
            let now = Date()
            var keep = 0
            for j in fds.indices {
                let answered = fds[j].revents != 0
                if answered || deadline[j] <= now {
                    let state = answered ? finishConnect(fds[j].fd) : .silent
                    close(fds[j].fd)
                    finish(index[j], state)
                } else {
                    fds[keep] = fds[j]; fds[keep].revents = 0
                    index[keep] = index[j]; deadline[keep] = deadline[j]
                    keep += 1
                }
            }
            fds.removeLast(fds.count - keep); index.removeLast(index.count - keep); deadline.removeLast(deadline.count - keep)
        }
        for f in fds { close(f.fd) }
        onProgress(done)
    }

    private enum Started { case done(PortState), pending(Int32), busy }

    /// Starts a non-blocking connection. Closes the socket unless it's still pending.
    private static func startConnect(_ host: String, _ port: Int) -> Started {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return .done(.silent) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno == EMFILE || errno == ENFILE || errno == ENOBUFS ? .busy : .done(.silent) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r == 0 { close(fd); return .done(.open) }
        let e = errno
        if e == EINPROGRESS { return .pending(fd) }
        close(fd)
        if e == EADDRNOTAVAIL || e == ENOBUFS { return .busy }
        return .done(e == ECONNREFUSED ? .refused : .silent)
    }

    private static func finishConnect(_ fd: Int32) -> PortState {
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        switch err {
        case 0: return .open
        case ECONNREFUSED, ECONNRESET: return .refused
        default: return .silent
        }
    }

    /// How many connections a scan keeps going at once, across all hosts.
    /// Capped well below the ~16,000 local ports macOS has for outgoing connections, so other
    /// apps' connections don't fail while a scan runs.
    static var socketBudget: Int { max(256, min(4096, raiseFileLimit() * 3 / 4)) }

    /// Lets this process have more sockets open at once (apps start with 256). Returns the limit.
    private static func raiseFileLimit() -> Int {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return 256 }
        let want = min(lim.rlim_max, 8192)
        if lim.rlim_cur < want {
            var raised = lim
            raised.rlim_cur = want
            if setrlimit(RLIMIT_NOFILE, &raised) == 0 { lim = raised }
        }
        return Int(lim.rlim_cur)
    }

    // MARK: adb's opening message

    private static let cnxn: UInt32 = 0x4E58_4E43 // "CNXN"
    private static let auth: UInt32 = 0x4854_5541 // "AUTH"
    private static let stls: UInt32 = 0x534C_5453 // "STLS"

    /// An adb CNXN message: a 24-byte header (little-endian words) and its payload.
    static func hello() -> [UInt8] {
        let payload = Array("host::\0".utf8)
        let words: [UInt32] = [cnxn, 0x0100_0001, 256 * 1024, UInt32(payload.count),
                               payload.reduce(0) { $0 &+ UInt32($1) }, cnxn ^ 0xFFFF_FFFF]
        return words.flatMap { w in (0..<4).map { UInt8(truncatingIfNeeded: w >> ($0 * 8)) } } + payload
    }

    /// Reads a reply to `hello()`: which adb it came from, or nil if it isn't adb.
    static func kind(ofReply bytes: [UInt8]) -> FoundDevice.Kind? {
        guard bytes.count >= 4 else { return nil }
        let command = bytes[0..<4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        switch command {
        case cnxn, auth: return .adb
        case stls: return .wirelessDebugging
        default: return nil
        }
    }

    static func probeSync(_ host: String, _ port: Int, timeout: TimeInterval) -> FoundDevice.Kind? {
        guard case .pending(let fd) = startConnect(host, port) else { return nil }
        defer { close(fd) }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, Int32(timeout * 1000)) == 1, finishConnect(fd) == .open else { return nil }
        let message = hello()
        guard message.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == message.count else {
            // The reset can beat the hello out of the door.
            return errno == ECONNRESET || errno == EPIPE ? (waitsWhenIdle(host, port, for: min(timeout, 1)) ? .wirelessDebugging : nil) : nil
        }
        var reply: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while reply.count < 24 {
            let ms = Int32(deadline.timeIntervalSinceNow * 1000)
            guard ms > 0 else { break }
            var r = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&r, 1, ms)
            if n < 0 && errno == EINTR { continue }
            guard n == 1 else { break }
            var buf = [UInt8](repeating: 0, count: 64)
            let got = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if got > 0 {
                reply += buf[0..<got]
            } else {
                // Wireless debugging drops a connection from a computer it hasn't paired with
                // the moment adb says hello. Some other servers reset on anything they don't
                // expect too, but those also hang up on a connection that says nothing; Wireless
                // debugging waits.
                if got < 0 && errno == ECONNRESET && reply.isEmpty {
                    return waitsWhenIdle(host, port, for: min(timeout, 1)) ? .wirelessDebugging : nil
                }
                break
            }
        }
        return kind(ofReply: reply)
    }

    /// Whether a connection that sends nothing stays open for `seconds`.
    static func waitsWhenIdle(_ host: String, _ port: Int, for seconds: TimeInterval) -> Bool {
        guard case .pending(let fd) = startConnect(host, port) else { return false }
        defer { close(fd) }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, 2000) == 1, finishConnect(fd) == .open else { return false }
        var r = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        // Anything readable (data, a close or a reset) within the time means it didn't wait.
        return poll(&r, 1, Int32(seconds * 1000)) == 0
    }
}
