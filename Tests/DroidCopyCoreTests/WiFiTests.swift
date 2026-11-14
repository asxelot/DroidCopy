import Foundation
import Testing
@testable import DroidCopyCore
import DroidCopyTestSupport

@Suite struct WiFiTests {
    @Test func parsesTheWiFiAddress() {
        let out = """
            10: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 3000
                inet 192.168.178.44/24 brd 192.168.178.255 scope global wlan0
                   valid_lft forever preferred_lft forever
            """
        #expect(Parse.wifiAddress(out) == "192.168.178.44")
        #expect(Parse.wifiAddress("Device \"wlan0\" does not exist.") == nil)
        #expect(Parse.wifiAddress("") == nil)
    }

    @Test func normalisesAddresses() {
        #expect(Parse.adbAddress("192.168.1.20") == "192.168.1.20:5555")
        #expect(Parse.adbAddress(" 192.168.1.20:37099 ") == "192.168.1.20:37099")
        #expect(Parse.adbAddress("retroid.local") == "retroid.local:5555")
        #expect(Parse.adbAddress("192.168.1.20:port") == nil)
        #expect(Parse.adbAddress("192.168.1.20:70000") == nil)
        #expect(Parse.adbAddress("") == nil)
        #expect(Parse.adbAddress("a b") == nil)
    }

    @Test func knowsWiFiDevices() {
        #expect(DeviceInfo(serial: "192.168.1.20:5555", state: "device", model: nil).isNetwork)
        #expect(DeviceInfo(serial: "adb-8b100894-AbCd._adb-tls-connect._tcp", state: "device", model: nil).isNetwork)
        #expect(!DeviceInfo(serial: "8b100894", state: "device", model: nil).isNetwork)
    }

    @Test func connectsPairsAndDisconnects() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let refused = await fake.adb.connect("192.168.1.50:1234")
        #expect(!refused.ok && refused.message.contains("Connection refused"), "adb exits 0 here, but it failed")
        let c = await fake.adb.connect("192.168.1.50:5555")
        #expect(c.ok && c.message == "connected to 192.168.1.50:5555")
        #expect(await fake.adb.devices().map(\.serial).contains("192.168.1.50:5555"))
        #expect(await fake.adb.connect("192.168.1.50:5555").ok, "already connected is fine")
        await fake.adb.disconnect("192.168.1.50:5555")
        #expect(await fake.adb.devices().map(\.serial) == ["FAKE123"])

        #expect(await fake.adb.pair("192.168.1.50:37099", code: "123456").ok)
        let wrong = await fake.adb.pair("192.168.1.50:37099", code: "000000")
        #expect(!wrong.ok && wrong.message.contains("Wrong password"))
        #expect(await fake.adb.wifiAddress("FAKE123") == "192.168.1.50")
    }
}
