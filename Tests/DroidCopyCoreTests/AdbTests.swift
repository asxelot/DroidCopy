import Foundation
import Testing
@testable import DroidCopyCore
import DroidCopyTestSupport

/// `Adb` commands end to end against `FakeAdb`, including names that need shell quoting.
@Suite struct AdbTests {
    static let awkwardName = "it's a [test] $HOME `x` \"q\".txt"

    @Test func runReportsMissingExecutable() async {
        let r = await Adb(path: "/nonexistent/adb").run(["devices"])
        #expect(r.status == -1)
        #expect(!r.ok)
    }

    @Test func devicesParsesOutput() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let devices = await fake.adb.devices()
        #expect(devices == [DeviceInfo(serial: "FAKE123", state: "device", model: "Fake_Phone")])
    }

    @Test func listShowsFilesAndFoldersWithAwkwardNames() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir("dir with 'quotes'")
        try writeFile(Parse.join(dir, Self.awkwardName), "hello")
        try writeFile(Parse.join(dir, ".hidden"), "x")
        try FileManager.default.createDirectory(atPath: Parse.join(dir, "Sub"), withIntermediateDirectories: false)

        let items = try await fake.adb.list("FAKE123", dir)
        #expect(items.map(\.name) == ["Sub", Self.awkwardName])
        #expect(items[0].isDirectory)
        #expect(!items[1].isDirectory)
        #expect(items[1].size == 5)
        #expect(items[1].path == Parse.join(dir, Self.awkwardName))
        #expect(items[1].modified != nil)

        let all = try await fake.adb.list("FAKE123", dir, showHidden: true)
        #expect(all.contains { $0.name == ".hidden" })
    }

    @Test func listOfEmptyFolderIsEmpty() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let items = try await fake.adb.list("FAKE123", try fake.deviceDir())
        #expect(items.isEmpty)
    }

    @Test func listOfMissingFolderThrowsReadableError() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        await #expect {
            _ = try await fake.adb.list("FAKE123", fake.root.appendingPathComponent("nope").path)
        } throws: { error in
            (error as? AdbError)?.message == "Folder not found on the device"
        }
    }

    @Test func sizeExistsAndFreeBytes() async throws {
        let fake = try FakeAdb(freeKB: 1234)
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir()
        let file = Parse.join(dir, Self.awkwardName)
        try writeFile(file, "12345678")

        #expect(await fake.adb.size("FAKE123", file) == 8)
        #expect(await fake.adb.size("FAKE123", dir) ?? 0 > 0)
        #expect(await fake.adb.size("FAKE123", Parse.join(dir, "missing")) == nil)
        #expect(await fake.adb.exists("FAKE123", file))
        #expect(!(await fake.adb.exists("FAKE123", Parse.join(dir, "missing"))))
        #expect(await fake.adb.freeBytes("FAKE123", dir) == 1234 * 1024)
    }

    @Test func makeDirectoryMoveAndDelete() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir()
        let folder = Parse.join(dir, "New $folder")

        #expect(await fake.adb.makeDirectory("FAKE123", folder).ok)
        #expect(!(await fake.adb.makeDirectory("FAKE123", folder).ok), "mkdir on an existing folder fails")

        let renamed = Parse.join(dir, Self.awkwardName)
        #expect(await fake.adb.move("FAKE123", from: folder, to: renamed).ok)
        #expect(await fake.adb.exists("FAKE123", renamed))
        #expect(!(await fake.adb.exists("FAKE123", folder)))

        #expect(await fake.adb.delete("FAKE123", renamed).ok)
        #expect(!(await fake.adb.exists("FAKE123", renamed)))
    }

    @Test func moveRefusesToOverwrite() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir()
        try writeFile(Parse.join(dir, "a"), "A")
        try writeFile(Parse.join(dir, "b"), "B")

        let r = await fake.adb.move("FAKE123", from: Parse.join(dir, "a"), to: Parse.join(dir, "b"))
        #expect(!r.ok)
        #expect(r.message == "An item with that name already exists")
        #expect(readFile(Parse.join(dir, "a")) == "A")
        #expect(readFile(Parse.join(dir, "b")) == "B")
    }

    @Test func existingNamesFindsHiddenAndAwkwardNames() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir()
        try writeFile(Parse.join(dir, ".nomedia"), "")
        try writeFile(Parse.join(dir, Self.awkwardName), "x")
        try FileManager.default.createDirectory(atPath: Parse.join(dir, "Folder"), withIntermediateDirectories: false)

        let found = await fake.adb.existingNames("FAKE123", in: dir, [".nomedia", Self.awkwardName, "Folder", "missing", "-n"])
        #expect(found == [".nomedia", Self.awkwardName, "Folder"])
        #expect(await fake.adb.existingNames("FAKE123", in: dir, []).isEmpty)
        #expect(await fake.adb.existingNames("FAKE123", in: Parse.join(dir, "nope"), ["Folder"]).isEmpty)
    }

    @Test func listOfUnreadableFolderSaysSo() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir("locked")
        try writeFile(Parse.join(dir, "secret"), "x")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }

        await #expect {
            _ = try await fake.adb.list("FAKE123", dir)
        } throws: { error in
            (error as? AdbError)?.message == "The device doesn’t allow reading this folder"
        }
    }

    @Test func swapInReplacesAndCleansUp() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir()
        let (staging, dest, aside) = (Parse.join(dir, ".dc~a b"), Parse.join(dir, "a b"), Parse.join(dir, ".dc-old~a b"))
        try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: false)
        try writeFile(Parse.join(dest, "old"), "o")
        try writeFile(staging, "new")

        #expect(await fake.adb.swapIn("FAKE123", staging, as: dest, aside: aside).ok)
        #expect(readFile(dest) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["a b"])
    }

    @Test func swapInPutsTheOriginalBackWhenTheNewCopyIsMissing() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir()
        let dest = Parse.join(dir, "a")
        try writeFile(dest, "original")

        let r = await fake.adb.swapIn("FAKE123", Parse.join(dir, ".dc~a"), as: dest, aside: Parse.join(dir, ".dc-old~a"))
        #expect(!r.ok)
        #expect(readFile(dest) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["a"])
    }

    @Test func sizeFollowsSymlinks() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir()
        try writeFile(Parse.join(dir, "real"), String(repeating: "x", count: 3000))
        try FileManager.default.createSymbolicLink(atPath: Parse.join(dir, "link"), withDestinationPath: "real")
        #expect(await fake.adb.size("FAKE123", Parse.join(dir, "link")) == 3000)
    }
}

@Suite struct RunResultTests {
    @Test func messagePrefersErrorLines() {
        let r = RunResult(output: "progress 10%\nprogress 20%\n", error: "adb: error: failed to copy\nsomething else\n", status: 1)
        #expect(r.message == "adb: error: failed to copy")
    }

    @Test func messageFallsBackToLastLine() {
        let r = RunResult(output: "first\nlast line\n", error: "", status: 1)
        #expect(r.message == "last line")
    }

    @Test func messageWhenNothingWasPrinted() {
        let r = RunResult(output: "", error: "  \n", status: 7)
        #expect(r.message == "adb exited with status 7")
        #expect(!r.ok)
        #expect(RunResult(output: "", error: "", status: 0).ok)
    }
}

@Suite struct AdbLocateTests {
    @Test func environmentOverrideWins() {
        #expect(Adb.locate(environment: ["DROIDCOPY_ADB": "/bin/ls"])?.path == "/bin/ls")
        #expect(Adb.locate(environment: ["DROIDCOPY_ADB": "/nonexistent/adb"]) == nil)
    }
}
