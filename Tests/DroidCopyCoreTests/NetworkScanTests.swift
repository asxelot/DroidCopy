import Foundation
import Testing
@testable import DroidCopyCore
import DroidCopyTestSupport

/// Finding devices on the network without typing an address.
@Suite struct NetworkScanTests {
    @Test func tellsAdbFromOtherServers() async throws {
        let adb = try FakeListener(.adb), wireless = try FakeListener(.wirelessDebugging)
        let unpaired = try FakeListener(.unpaired), http = try FakeListener(.http), silent = try FakeListener(.silent)
        let touchy = try FakeListener(.touchy)
        defer { [adb, wireless, unpaired, http, silent, touchy].forEach { $0.stop() } }
        #expect(await NetworkScan.probe("127.0.0.1", adb.port) == .adb)
        #expect(await NetworkScan.probe("127.0.0.1", wireless.port) == .wirelessDebugging)
        #expect(await NetworkScan.probe("127.0.0.1", unpaired.port) == .wirelessDebugging, "drops the connection until paired")
        #expect(await NetworkScan.probe("127.0.0.1", http.port) == nil)
        #expect(await NetworkScan.probe("127.0.0.1", touchy.port) == nil, "resets on hello, but hangs up when idle too")
        #expect(await NetworkScan.probe("127.0.0.1", silent.port, timeout: 0.5) == nil)
    }

    @Test func findsOpenPorts() async throws {
        let a = try FakeListener(.silent), b = try FakeListener(.silent)
        defer { a.stop(); b.stop() }
        let closed = try FakeListener(.silent)
        let closedPort = closed.port
        closed.stop()
        #expect(await NetworkScan.openPorts("127.0.0.1", [a.port, closedPort, b.port]) == [a.port, b.port])
        let states = await NetworkScan.connectAll([("127.0.0.1", a.port), ("127.0.0.1", closedPort), ("not an address", 1)], timeout: 1)
        #expect(states == [.open, .refused, .silent])
    }

    @Test func findsDevicesOnHostsThatAnswer() async throws {
        let adb = try FakeListener(.adb), unpaired = try FakeListener(.unpaired), http = try FakeListener(.http)
        defer { [adb, unpaired, http].forEach { $0.stop() } }
        let ports = [adb.port, unpaired.port, http.port]
        let found = await NetworkScan.find(hosts: ["127.0.0.1"], knockPort: http.port, ports: ports)
        #expect(Set(found) == [FoundDevice(host: "127.0.0.1", port: adb.port, kind: .adb),
                               FoundDevice(host: "127.0.0.1", port: unpaired.port, kind: .wirelessDebugging)])
        // 192.0.2.0/24 is reserved for documentation: nothing there answers the knock.
        #expect(await NetworkScan.find(hosts: ["192.0.2.1"], ports: ports).isEmpty)
        // …but a host named in `also` is looked at anyway, and each find is reported at once.
        let reported = Reported()
        let viaAlso = await NetworkScan.find(hosts: ["192.0.2.1"], also: ["127.0.0.1"], ports: ports,
                                             found: { reported.add($0) })
        #expect(Set(viaAlso) == Set(found))
        #expect(Set(reported.all) == Set(found))
    }

    final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [FoundDevice] = []
        func add(_ d: FoundDevice) { lock.lock(); list.append(d); lock.unlock() }
        var all: [FoundDevice] { lock.lock(); defer { lock.unlock() }; return list }
    }

    @Test func helloIsAnAdbConnectMessage() {
        let h = NetworkScan.hello()
        #expect(h.count == 24 + 7)
        #expect(Array(h[0..<4]) == Array("CNXN".utf8))
        #expect(Array(h[24...]) == Array("host::\0".utf8))
        #expect(NetworkScan.kind(ofReply: Array("CNXN".utf8)) == .adb)
        #expect(NetworkScan.kind(ofReply: Array("STLS".utf8)) == .wirelessDebugging)
        #expect(NetworkScan.kind(ofReply: Array("HTTP".utf8)) == nil)
        #expect(NetworkScan.kind(ofReply: []) == nil)
    }

    @Test func readsTheArpTable() {
        let out = """
            ? (192.168.0.1) at 98:25:4a:8d:4a:37 on en0 ifscope [ethernet]
            ? (192.168.0.106) at (incomplete) on en0 ifscope [ethernet]
            ? (192.168.0.125) at f2:6b:28:7a:74:7a on en0 ifscope [ethernet]
            """
        #expect(Parse.arpAddresses(out) == ["192.168.0.1", "192.168.0.125"])
        #expect(Parse.arpAddresses("") == [])
        #expect(Parse.gateway("   route to: default\ndestination: default\n    gateway: 192.168.0.1\n  interface: en0") == "192.168.0.1")
        #expect(Parse.gateway("route: writing to routing socket: not in table") == nil)
    }

    @Test func listsTheLocalNetwork() {
        let hosts = NetworkScan.localHosts()
        #expect(hosts.count <= 1022 * max(1, NetworkScan.localNetworks().count))
        #expect(!hosts.contains { $0.hasPrefix("127.") })
        let own = Set(NetworkScan.localNetworks().map { NetworkScan.format($0.address) })
        #expect(own.isDisjoint(with: hosts))
    }

    /// Scans the real network. Runs only when asked: `DROIDCOPY_SCAN=1 swift test --filter realNetwork`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DROIDCOPY_SCAN"] != nil))
    func realNetwork() async {
        let start = Date()
        let found = await NetworkScan.find(found: { d in print("found after \(Int(Date().timeIntervalSince(start)))s: \(d.address) \(d.kind)") })
        print("Found in \(Int(Date().timeIntervalSince(start)))s:", found.map { "\($0.address) \($0.kind)" })
    }
}
