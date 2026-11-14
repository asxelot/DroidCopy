import Foundation
import Testing
@testable import DroidCopyCore
import DroidCopyTestSupport

/// Installing .apk files with `adb install -r` through the transfer queue.
@Suite @MainActor struct InstallTests {
    private func apk(_ fake: FakeAdb, _ name: String) throws -> Transfer {
        let url = try fake.macDir().appendingPathComponent(name)
        try writeFile(url.path, "PK fake apk")
        return Transfer(direction: .install, serial: "FAKE123", source: url.path, destDir: "", name: name, isDirectory: false, replace: true)
    }

    @Test func installsAndReportsTheInstallersReason() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let good = try apk(fake, "Emulator it's [1.2].apk")
        let bad = try apk(fake, "bad.apk")
        let q = TransferQueue(adb: fake.adb)
        q.checkContents = true // no copy to check: an install isn't affected
        q.add([good, bad])
        await waitIdle(q)
        #expect(good.state == .done)
        #expect(good.total == 11 && good.fraction == 1)
        #expect(FileManager.default.fileExists(atPath: fake.installedDir.appendingPathComponent("Emulator it's [1.2].apk").path))
        #expect(bad.state.failure == "adb: failed to install \(bad.source): Failure [INSTALL_FAILED_INVALID_APK: not an apk]")
        #expect(TransferQueue.failureSummary([good, bad])?.hasPrefix("Couldn’t install “bad.apk”.") == true)
    }

    @Test func cancelsAnInstall() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let slow = try apk(fake, "slow.apk")
        let q = TransferQueue(adb: fake.adb)
        q.add([slow])
        await waitUntil { slow.process != nil }
        q.cancel(slow)
        await waitIdle(q)
        #expect(slow.state == .cancelled)
        let again = slow.retryCopy()
        #expect(again.direction == .install && again.source == slow.source)
    }
}
