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

@Suite struct DeviceSideTests {
    @Test func aCommandThatHangsTimesOut() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let started = Date()
        let r = await fake.adb.shell("FAKE123", "sleep 3; echo late", timeout: 0.3)
        #expect(r.timedOut && !r.ok)
        #expect(r.message == AdbError.notRespondingMessage)
        #expect(Date().timeIntervalSince(started) < 2)
        let quick = await fake.adb.shell("FAKE123", "echo hi", timeout: 5)
        #expect(quick.ok && quick.output == "hi\n")
    }

    @Test func listingAnUnresponsiveDeviceThrowsNotResponding() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir()
        fake.adb.quickTimeout = 0.3
        let ls = fake.root.appendingPathComponent("bin/ls")
        try writeFile(ls.path, "#!/bin/sh\nsleep 3\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ls.path)
        await #expect(throws: AdbError.self) { try await fake.adb.list("FAKE123", dir) }
        do { _ = try await fake.adb.list("FAKE123", dir) } catch { #expect(error.localizedDescription == AdbError.notRespondingMessage) }
    }

    @Test func copyOnTheDeviceIsCompleteOrAbsent() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir()
        try FileManager.default.createDirectory(atPath: Parse.join(dir, "src/sub"), withIntermediateDirectories: true)
        try writeFile(Parse.join(dir, "src/sub/" + AdbTests.awkwardName), "data")

        let r = await fake.adb.copy("FAKE123", from: Parse.join(dir, "src"), to: Parse.join(dir, "dst"))
        #expect(r.ok)
        #expect(readFile(Parse.join(dir, "dst/sub/" + AdbTests.awkwardName)) == "data")

        let again = await fake.adb.copy("FAKE123", from: Parse.join(dir, "src"), to: Parse.join(dir, "dst"))
        #expect(!again.ok && again.message.contains("already exists"))

        try writeFile(Parse.join(dir, "src/sub/new.txt"), "n")
        let replaced = await fake.adb.copy("FAKE123", from: Parse.join(dir, "src"), to: Parse.join(dir, "dst"), replace: true)
        #expect(replaced.ok)
        #expect(readFile(Parse.join(dir, "dst/sub/new.txt")) == "n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["dst", "src"], "no hidden leftovers")

        let missing = await fake.adb.copy("FAKE123", from: Parse.join(dir, "nope"), to: Parse.join(dir, "x"))
        #expect(!missing.ok)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["dst", "src"])
    }

    @Test func moveCanReplaceAndCountsItems() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir()
        try writeFile(Parse.join(dir, "a"), "new")
        try writeFile(Parse.join(dir, "b"), "old")
        #expect(!(await fake.adb.move("FAKE123", from: Parse.join(dir, "a"), to: Parse.join(dir, "b"))).ok)
        #expect((await fake.adb.move("FAKE123", from: Parse.join(dir, "a"), to: Parse.join(dir, "b"), replace: true)).ok)
        #expect(readFile(Parse.join(dir, "b")) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["b"])
        #expect(await fake.adb.itemCount("FAKE123", dir) == 1)
    }
}

@Suite struct CaseOnlyRenameTests {
    @Test func renamingOnlyTheCaseWorksOnCaseInsensitiveStorage() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dir = try fake.deviceDir()
        try FileManager.default.createDirectory(atPath: Parse.join(dir, "ROMs"), withIntermediateDirectories: false)
        try writeFile(Parse.join(dir, "Other"), "o")
        let r = await fake.adb.move("FAKE123", from: Parse.join(dir, "ROMs"), to: Parse.join(dir, "Roms"))
        #expect(r.ok, "\(r.message)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["Other", "Roms"])
        let clash = await fake.adb.move("FAKE123", from: Parse.join(dir, "Roms"), to: Parse.join(dir, "other"))
        #expect(!clash.ok, "a different item that differs only in case is still a clash")
    }
}

@Suite struct ServerLaunchTests {
    @Test func startsTheServerWhenNoneIsRunning() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let port: UInt16 = 45_000 + UInt16.random(in: 0..<1000)
        let pidFile = dir.appendingPathComponent("server.pid").path
        // A stand-in adb whose "server" just listens on the port, like adb's does.
        let fake = dir.appendingPathComponent("adb")
        try writeFile(fake.path, """
            #!/bin/sh
            [ "$1" = start-server ] || exit 1
            nohup /usr/bin/perl -MIO::Socket::INET -e '$s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => \(port), Listen => 5, ReuseAddr => 1) or die; while (1) { close($s->accept) }' >/dev/null 2>&1 &
            echo $! > '\(pidFile)'
            """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        defer {
            if let pid = readFile(pidFile).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) { kill(pid, SIGTERM) }
        }

        #expect(!Adb.serverIsRunning(port: port))
        var launches = 0
        let started = await Adb(path: fake.path).startServer(port: port) {
            launches += 1
            return Process.run(fake.path, ["start-server"]) == ""
        }
        #expect(started && launches == 1)
        #expect(Adb.serverIsRunning(port: port))

        // Already running: nothing is launched again.
        #expect(await Adb(path: fake.path).startServer(port: port) { launches += 1; return true })
        #expect(launches == 1)
    }

    @Test func aLaunchThatFailsOrNeverListensIsReported() async {
        let adb = Adb(path: "/nonexistent/adb")
        #expect(!(await adb.startServer(port: 1, wait: 0.2) { false }))
        #expect(!(await adb.startServer(port: 1, wait: 0.2) { true }), "launched, but nothing listens")
    }
}

private extension Process {
    /// Runs a command to completion and returns its output.
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
