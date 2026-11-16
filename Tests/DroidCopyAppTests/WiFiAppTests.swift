import Foundation
import Testing
@testable import DroidCopy
import DroidCopyCore
import DroidCopyTestSupport

/// File ▸ Connect over Wi-Fi….
@Suite @MainActor struct WiFiAppTests {
    @Test func switchesACabledDeviceToWiFi() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        let r = await h.model.switchToWiFi()
        #expect(r.ok, "\(r.message)")
        #expect(r.message == "Connected to 192.168.1.50:5555. You can unplug the cable.")
        #expect(FileManager.default.fileExists(atPath: h.fake.root.appendingPathComponent("tcpip-5555").path))
        #expect(await h.fake.adb.devices().map(\.serial).contains("192.168.1.50:5555"))
        #expect(h.model.lastWiFiAddress == "192.168.1.50:5555")
    }

    @Test func connectsToAnAddress() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        #expect(await h.model.connectWiFi("not an address").message == "Enter an address like 192.168.1.20:5555.")
        let refused = await h.model.connectWiFi("192.168.1.50:4444")
        #expect(!refused.ok && refused.message.contains("refused"))
        let ok = await h.model.connectWiFi("192.168.1.50")
        #expect(ok.ok && ok.message == "Connected to 192.168.1.50:5555.")
        #expect(h.model.lastWiFiAddress == "192.168.1.50:5555")
    }

    @Test func pairs() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        #expect(await h.model.pairWiFi("not an address!", code: "123456").message.hasPrefix("Enter the IP address and port"))
        #expect(await h.model.pairWiFi("192.168.1.50:37099", code: " ").message == "Enter the pairing code shown on the device.")
        #expect(!(await h.model.pairWiFi("192.168.1.50:37099", code: "999999")).ok)
        #expect(await h.model.pairWiFi("192.168.1.50:37099", code: "123456").ok)
    }

    @Test func ejectingAWiFiDeviceDisconnectsIt() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        _ = await h.fake.adb.connect("192.168.1.50:5555")
        h.model.device = DeviceInfo(serial: "192.168.1.50:5555", state: "device", model: "Fake_Phone")
        await h.open()
        await h.model.eject()
        #expect(h.model.device == nil)
        #expect(h.model.ejectedSerial == nil, "nothing to unplug: it's simply gone")
        #expect(h.model.deviceStatus == "Disconnected from “Fake Phone” over Wi-Fi.")
        #expect(await h.fake.adb.devices().map(\.serial) == ["FAKE123"])
    }

    @Test func aCabledDeviceCantSwitchWithoutWiFiOrCable() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.model.device = DeviceInfo(serial: "192.168.1.50:5555", state: "device", model: "Fake_Phone")
        #expect(await h.model.switchToWiFi().message == "Connect the device with a cable first.")
    }

    // MARK: Finding devices on the network

    let retroid = FoundDevice(host: "192.168.1.50", port: 37000, kind: .wirelessDebugging)

    /// A network with the given devices on it, and the pairing screen open on port 37099.
    func network(_ h: Harness, _ devices: [FoundDevice], before: [FoundDevice] = []) {
        h.model.scanNetwork = { _, found, progress in
            for d in devices { found(d) }
            progress(1)
            return devices
        }
        h.model.probeAddress = { host, port in before.first { $0.host == host && $0.port == port }?.kind }
        h.model.scanPorts = { _ in [37000, 41234, 37099] }
    }

    @Test func findsDevicesAndRemembersThem() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let tcpip = FoundDevice(host: "192.168.1.60", port: 5555, kind: .adb)
        network(h, [retroid, tcpip])
        await h.model.findWiFiDevices()
        #expect(h.model.foundDevices == [retroid, tcpip])
        #expect(!h.model.scanning && h.model.scanProgress == 1)
        #expect(h.model.rememberedAddresses == ["192.168.1.60:5555", "192.168.1.50:37000"])
    }

    @Test func checksWhereDevicesWereBeforeFirst() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.defaults.set(["192.168.1.50:37000", "192.168.1.70:40000"], forKey: AppModel.foundAddressesKey)
        let asked = Asked()
        network(h, [], before: [retroid])
        h.model.scanNetwork = { also, _, _ in asked.also = also; return [] }
        await h.model.findWiFiDevices()
        #expect(h.model.foundDevices == [retroid], "still there; the other one's gone")
        #expect(asked.also == ["192.168.1.50", "192.168.1.70"], "and the full search looks at those hosts too")
    }

    final class Asked: @unchecked Sendable { var also: [String] = [] }

    @Test func connectsToAFoundDevice() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let tcpip = FoundDevice(host: "192.168.1.60", port: 5555, kind: .adb)
        let r = await h.model.connectFound(tcpip)
        #expect(r.ok && r.message == "Connected to 192.168.1.60:5555.")
        #expect(h.model.pairTarget == nil)
    }

    @Test func anUnpairedDeviceAsksForTheCodeThenPairsAndConnects() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        network(h, [retroid])
        await h.model.findWiFiDevices()
        let first = await h.model.connectFound(retroid)
        #expect(!first.ok && first.message.hasPrefix("This Mac isn’t paired with 192.168.1.50 yet."))
        #expect(h.model.pairTarget == retroid)
        #expect(!(await h.fake.adb.devices().map(\.serial).contains(retroid.address)), "the failed connection isn't left behind")

        #expect(!(await h.model.pairWiFi("", code: "999999")).ok)
        // No address typed: the pairing port is found (37000 is the device's own, 41234 isn't it).
        let paired = await h.model.pairWiFi("", code: "123456")
        #expect(paired.ok, "\(paired.message)")
        #expect(paired.message == "Paired and connected to 192.168.1.50:37000.")
        #expect(await h.fake.adb.devices().map(\.serial).contains(retroid.address))
        #expect(h.model.lastWiFiAddress == retroid.address)
    }

    @Test func pairingWithoutAnAddressNeedsADevice() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        network(h, [])
        #expect(await h.model.pairWiFi("", code: "123456").message.hasPrefix("Enter the IP address and port"))
        // A typed host without a port is enough: the port is found.
        let r = await h.model.pairWiFi("192.168.1.50", code: "123456")
        #expect(r.ok && r.message.hasPrefix("Paired. Now connect"), "\(r.message)")
        h.model.scanPorts = { _ in [] }
        #expect(await h.model.pairWiFi("192.168.1.50", code: "123456").message.hasPrefix("Couldn’t find the pairing screen on 192.168.1.50."))
    }

    @Test func remembersDeviceNamesByAddress() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        // The cabled fake device is on Wi-Fi at 192.168.1.50.
        h.model.device = nil
        await h.model.pollDevices()
        await waitUntil { h.model.deviceName(at: "192.168.1.50") != nil }
        #expect(h.model.deviceName(at: "192.168.1.50") == "Fake Phone")
        #expect(h.model.deviceName(at: "192.168.1.60") == nil)
        #expect(WiFiSheet.detail(retroid, named: true) == "192.168.1.50 · Wireless debugging, port 37000")
        #expect(WiFiSheet.detail(FoundDevice(host: "192.168.1.60", port: 5555, kind: .adb), named: false) == "adb, port 5555")
    }

    @Test func pairsWithWhicheverDeviceShowsTheCode() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        // Two devices with Wireless debugging; the code is showing on the other one.
        let other = FoundDevice(host: "192.168.1.51", port: 38000, kind: .wirelessDebugging)
        network(h, [retroid, other])
        h.model.scanPorts = { host in host == "192.168.1.51" ? [38000, 37099] : [37000] }
        await h.model.findWiFiDevices()
        _ = await h.model.connectFound(retroid)
        #expect(h.model.pairTarget == retroid)
        let r = await h.model.pairWiFi("", code: "123456")
        #expect(r.ok && r.message == "Paired and connected to 192.168.1.51:38000.", "\(r.message)")
        h.model.scanPorts = { host in host == "192.168.1.51" ? [38000] : [37000] }
        #expect(await h.model.pairWiFi("", code: "123456").message.hasPrefix("Couldn’t find the pairing screen on any device."))
    }
}
