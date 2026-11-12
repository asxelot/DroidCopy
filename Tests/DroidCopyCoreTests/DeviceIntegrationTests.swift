import Foundation
import Testing
@testable import DroidCopyCore
import DroidCopyTestSupport

/// Real adb push/pull against a connected device.
/// Run with: DROIDCOPY_DEVICE=<serial> swift test --filter DeviceIntegrationTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DROIDCOPY_DEVICE"] != nil), .serialized)
@MainActor
struct DeviceIntegrationTests {
    let serial = ProcessInfo.processInfo.environment["DROIDCOPY_DEVICE"] ?? ""
    let remoteDir = "/storage/emulated/0/Download/droidcopy-test"
    let adb = Adb.locate()!

    private func freshRemoteDir() async {
        _ = await adb.delete(serial, remoteDir)
        _ = await adb.makeDirectory(serial, remoteDir)
    }

    private func localTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("droidcopy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Random bytes, so adb's compression can't make the copy instant.
    private func makeRandomFile(_ url: URL, megabytes: Int) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/dd")
        p.arguments = ["if=/dev/urandom", "of=\(url.path)", "bs=1m", "count=\(megabytes)"]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }

    private func waitIdle(_ q: TransferQueue, seconds: Int = 120) async {
        for _ in 0..<(seconds * 10) where q.hasActive {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @Test func pushRefuseOverwritePullAndFolder() async throws {
        await freshRemoteDir()
        let tmp = try localTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A file with characters that need shell quoting.
        let name = "it's [a] $file (1).bin"
        let src = tmp.appendingPathComponent(name)
        let payload = Data((0..<3_000_000).map { _ in UInt8.random(in: 0...255) })
        try payload.write(to: src)

        let q = TransferQueue(adb: adb)
        q.add([Transfer(direction: .toDevice, serial: serial, source: src.path, destDir: remoteDir, name: name, isDirectory: false, replace: false)])
        await waitIdle(q)
        #expect(q.items.first?.state == .done)
        #expect(await adb.size(serial, Parse.join(remoteDir, name)) == Int64(payload.count))

        // Without "replace", an existing item must be left alone.
        let other = tmp.appendingPathComponent("other.bin")
        try Data([1, 2, 3]).write(to: other)
        q.add([Transfer(direction: .toDevice, serial: serial, source: other.path, destDir: remoteDir, name: name, isDirectory: false, replace: false)])
        await waitIdle(q)
        guard case .failed = q.items.first?.state else {
            Issue.record("expected failure, got \(String(describing: q.items.first?.state))")
            return
        }
        #expect(await adb.size(serial, Parse.join(remoteDir, name)) == Int64(payload.count))

        // Pull it back and compare bytes.
        let outDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        q.add([Transfer(direction: .toMac, serial: serial, source: Parse.join(remoteDir, name), destDir: outDir.path, name: name, isDirectory: false, replace: false)])
        await waitIdle(q)
        #expect(q.items.first?.state == .done)
        #expect(try Data(contentsOf: outDir.appendingPathComponent(name)) == payload)

        // Folder push, and the listing sees it.
        let folder = tmp.appendingPathComponent("My Folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("sub/a.txt"))
        q.add([Transfer(direction: .toDevice, serial: serial, source: folder.path, destDir: remoteDir, name: "My Folder", isDirectory: true, replace: false)])
        await waitIdle(q)
        #expect(q.items.first?.state == .done)
        #expect(await adb.size(serial, Parse.join(remoteDir, "My Folder/sub/a.txt")) == 5)
        let listing = try await adb.list(serial, remoteDir)
        #expect(Set(listing.map(\.name)) == [name, "My Folder"])
        #expect(listing.first?.isDirectory == true)

        _ = await adb.delete(serial, remoteDir)
    }

    @Test func cancelDeletesThePartialCopy() async throws {
        await freshRemoteDir()
        let tmp = try localTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("big.bin")
        try makeRandomFile(src, megabytes: 400)

        let q = TransferQueue(adb: adb)
        let t = Transfer(direction: .toDevice, serial: serial, source: src.path, destDir: remoteDir, name: "big.bin", isDirectory: false, replace: false)
        q.add([t])
        for _ in 0..<100 where t.transferred == 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(t.transferred > 0, "progress should be reported while copying")
        #expect(t.bytesPerSecond > 0)
        q.cancel(t)
        await waitIdle(q)
        #expect(t.state == .cancelled)
        #expect(await adb.exists(serial, t.destPath) == false)

        _ = await adb.delete(serial, remoteDir)
    }
}
