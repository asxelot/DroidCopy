import Foundation
import Darwin

/// A TCP server on 127.0.0.1 that answers a connection the way an adb, Wireless debugging or some
/// other server would, for testing `NetworkScan`.
public final class FakeListener: @unchecked Sendable {
    public enum Mode: Sendable {
        /// Plain adb: answers hello with AUTH.
        case adb
        /// Wireless debugging after pairing: answers STLS.
        case wirelessDebugging
        /// Wireless debugging before pairing: drops the connection (a reset) when it gets hello.
        case unpaired
        /// A web server: answers something else.
        case http
        /// Accepts and says nothing.
        case silent
        /// Hangs up on a connection that says nothing, and resets one that says anything.
        case touchy
    }

    public let port: Int
    private let fd: Int32

    public init(_ mode: Mode) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = Int(UInt16(bigEndian: addr.sin_port))
        let listener = fd
        Thread.detachNewThread {
            while true {
                let c = accept(listener, nil, nil)
                if c < 0 { return }
                Thread.detachNewThread { Self.serve(c, mode) }
            }
        }
    }

    private static func serve(_ c: Int32, _ mode: Mode) {
        if case .touchy = mode {
            var p = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 200) == 0 { close(c); return }
        }
        var buf = [UInt8](repeating: 0, count: 256)
        let got = buf.withUnsafeMutableBytes { read(c, $0.baseAddress, $0.count) }
        guard got > 0 else { close(c); return }
        func reply(_ command: String) {
            var bytes = Array(command.utf8) + [UInt8](repeating: 0, count: 20)
            _ = bytes.withUnsafeMutableBytes { write(c, $0.baseAddress, $0.count) }
        }
        switch mode {
        case .adb: reply("AUTH")
        case .wirelessDebugging: reply("STLS")
        case .http: reply("HTTP/1.1 400 Bad Request\r\n\r\n")
        case .unpaired, .touchy:
            // Closing with a zero linger time sends a reset instead of a polite close.
            var l = linger(l_onoff: 1, l_linger: 0)
            setsockopt(c, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
        case .silent:
            Thread.sleep(forTimeInterval: 5)
        }
        close(c)
    }

    public func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}
