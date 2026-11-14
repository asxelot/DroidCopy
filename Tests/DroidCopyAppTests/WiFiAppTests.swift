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
        #expect(await h.model.pairWiFi("192.168.1.50", code: "123456").message.hasPrefix("Enter the IP address and port"))
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
}
