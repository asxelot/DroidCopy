import Foundation
import Testing
@testable import DroidCopyCore
import DroidCopyTestSupport

/// Checking copies by checksum (the "Check copies by content" setting).
@Suite @MainActor struct ContentCheckTests {
    let serial = "FAKE123"

    private func run(_ fake: FakeAdb, _ t: Transfer, check: Bool) async {
        let q = TransferQueue(adb: fake.adb)
        q.checkContents = check
        q.add([t])
        await waitIdle(q)
    }

    private func folder(in dir: URL) throws -> URL {
        let f = dir.appendingPathComponent("Saves")
        try FileManager.default.createDirectory(at: f.appendingPathComponent("inner deep"), withIntermediateDirectories: true)
        try writeFile(f.appendingPathComponent("a.sav").path, "aaaa")
        try writeFile(f.appendingPathComponent("inner deep/b it's.sav").path, "bbbb")
        try writeFile(f.appendingPathComponent(".hidden").path, "h")
        return f
    }

    @Test func parsesMd5sum() {
        let out = """
            d41d8cd98f00b204e9800998ecf8427e  ./empty
            764efa883dda1e11db47671c4a3bbd9e  ./with  two spaces.txt
            \\0cc175b9c0f1b6a831c399e269772661  ./odd\\nname
            garbage
            """
        #expect(Parse.checksums(out) == [
            "./empty": "d41d8cd98f00b204e9800998ecf8427e",
            "./with  two spaces.txt": "764efa883dda1e11db47671c4a3bbd9e",
            "./odd\\nname": "0cc175b9c0f1b6a831c399e269772661",
        ])
    }

    @Test func macAndDeviceSumsAgree() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let f = try folder(in: try fake.macDir())
        let mac = LocalFS.checksums(f)
        #expect(mac?.count == 3)
        #expect(mac?["./inner deep/b it's.sav"] == "65ba841e01d6db7733e90a5b7f9e6f80") // md5("bbbb")
        // The fake device runs its shell on this Mac, so the same folder reads the same both ways.
        #expect(await fake.adb.checksums(serial, f.path) == mac)
        let file = f.appendingPathComponent("a.sav")
        #expect(LocalFS.checksums(file) == [".": "74b87337454200d4d33f80c4663dc5e5"]) // md5("aaaa")
        #expect(await fake.adb.checksums(serial, file.path) == LocalFS.checksums(file))
        #expect(await fake.adb.checksums(serial, f.path + "-missing") == nil)
    }

    @Test func goodCopiesPass() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let mac = try fake.macDir()
        let f = try folder(in: mac)
        let dev = try fake.deviceDir()
        let up = Transfer(direction: .toDevice, serial: serial, source: f.path, destDir: dev, name: "Saves", isDirectory: true, replace: false)
        await run(fake, up, check: true)
        #expect(up.state == .done)
        #expect(readFile(Parse.join(dev, "Saves/inner deep/b it's.sav")) == "bbbb")

        let back = try fake.macDir("back")
        let down = Transfer(direction: .toMac, serial: serial, source: Parse.join(dev, "Saves/a.sav"), destDir: back.path, name: "a.sav", isDirectory: false, replace: false)
        await run(fake, down, check: true)
        #expect(down.state == .done)
        #expect(readFile(back.appendingPathComponent("a.sav").path) == "aaaa")
    }

    @Test func aChangedByteIsCaughtAndTheCopyRemoved() async throws {
        let fake = try FakeAdb(push: .corrupt, pull: .corrupt)
        defer { fake.cleanUp() }
        let mac = try fake.macDir()
        let file = mac.appendingPathComponent("game.nsp")
        try writeFile(file.path, "0123456789")
        let dev = try fake.deviceDir()

        // Without the check, the size matches and the bad copy is kept.
        let unchecked = Transfer(direction: .toDevice, serial: serial, source: file.path, destDir: dev, name: "game.nsp", isDirectory: false, replace: false)
        await run(fake, unchecked, check: false)
        #expect(unchecked.state == .done)
        #expect(readFile(Parse.join(dev, "game.nsp")) == "X123456789")
        try FileManager.default.removeItem(atPath: Parse.join(dev, "game.nsp"))

        let checked = Transfer(direction: .toDevice, serial: serial, source: file.path, destDir: dev, name: "game.nsp", isDirectory: false, replace: false)
        await run(fake, checked, check: true)
        #expect(checked.state.failure?.contains("checksums differ") == true, "\(checked.state)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dev).isEmpty, "neither the copy nor its hidden name is left")

        let f = try folder(in: mac)
        let folderUp = Transfer(direction: .toDevice, serial: serial, source: f.path, destDir: dev, name: "Saves", isDirectory: true, replace: false)
        await run(fake, folderUp, check: true)
        #expect(folderUp.state.failure?.hasPrefix("1 file isn’t the same") == true, "\(folderUp.state)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dev).isEmpty)

        try writeFile(Parse.join(dev, "game.nsp"), "0123456789")
        let back = try fake.macDir("back")
        let down = Transfer(direction: .toMac, serial: serial, source: Parse.join(dev, "game.nsp"), destDir: back.path, name: "game.nsp", isDirectory: false, replace: false)
        await run(fake, down, check: true)
        #expect(down.state.failure?.contains("checksums differ") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: back.path).isEmpty)
    }

    @Test func aReplacedItemSurvivesAFailedCheck() async throws {
        let fake = try FakeAdb(push: .corrupt)
        defer { fake.cleanUp() }
        let file = try fake.macDir().appendingPathComponent("game.nsp")
        try writeFile(file.path, "new content")
        let dev = try fake.deviceDir()
        try writeFile(Parse.join(dev, "game.nsp"), "old")
        let t = Transfer(direction: .toDevice, serial: serial, source: file.path, destDir: dev, name: "game.nsp", isDirectory: false, replace: true)
        await run(fake, t, check: true)
        #expect(t.state.isFailed)
        #expect(readFile(Parse.join(dev, "game.nsp")) == "old")
    }
}
