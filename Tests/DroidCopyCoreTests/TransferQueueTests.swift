import Combine
import Foundation
import Testing
@testable import DroidCopyCore
import DroidCopyTestSupport

/// `TransferQueue` against `FakeAdb`: copying both ways, conflicts, free space, failures and cancelling.
@Suite @MainActor struct TransferQueueTests {
    let serial = "FAKE123"

    private func upload(_ source: URL, to dir: String, replace: Bool = false) -> Transfer {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir)
        return Transfer(direction: .toDevice, serial: serial, source: source.path, destDir: dir,
                        name: source.lastPathComponent, isDirectory: isDir.boolValue, replace: replace)
    }

    private func download(_ path: String, to dir: URL, isDirectory: Bool = false, replace: Bool = false) -> Transfer {
        Transfer(direction: .toMac, serial: serial, source: path, destDir: dir.path,
                 name: (path as NSString).lastPathComponent, isDirectory: isDirectory, replace: replace)
    }

    private func run(_ fake: FakeAdb, _ transfers: [Transfer]) async -> (TransferQueue, [Transfer]) {
        let q = TransferQueue(adb: fake.adb)
        var finished: [Transfer] = []
        q.onFinished = { finished.append($0) }
        q.add(transfers)
        await waitIdle(q)
        await waitUntil { finished.count == transfers.count }
        return (q, finished)
    }

    @Test func copiesFileToDevice() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let src = try fake.macDir().appendingPathComponent("game [USA] it's.nsp")
        try writeFile(src.path, "0123456789")
        let dev = try fake.deviceDir()

        let t = upload(src, to: dev)
        let (q, finished) = await run(fake, [t])
        #expect(t.state == .done)
        #expect(t.total == 10 && t.transferred == 10 && t.fraction == 1)
        #expect(readFile(Parse.join(dev, src.lastPathComponent)) == "0123456789")
        #expect(finished.map(\.id) == [t.id])
        #expect(q.activeCount == 0)
        #expect(t.finishedAt != nil && t.process == nil)
    }

    @Test func copiesFolderToDevice() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let folder = try fake.macDir().appendingPathComponent("Saves")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try writeFile(folder.appendingPathComponent("inner/a.sav").path, "abc")
        let dev = try fake.deviceDir()

        let t = upload(folder, to: dev)
        _ = await run(fake, [t])
        #expect(t.state == .done)
        #expect(readFile(Parse.join(dev, "Saves/inner/a.sav")) == "abc")
    }

    @Test func copiesFileToMac() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dev = try fake.deviceDir()
        try writeFile(Parse.join(dev, "photo.jpg"), "JPEGDATA")
        let mac = try fake.macDir()

        let t = download(Parse.join(dev, "photo.jpg"), to: mac)
        _ = await run(fake, [t])
        #expect(t.state == .done)
        #expect(readFile(mac.appendingPathComponent("photo.jpg").path) == "JPEGDATA")
    }

    @Test func runsTransfersInOrder() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let mac = try fake.macDir()
        let dev = try fake.deviceDir()
        let transfers = try (1...3).map { i -> Transfer in
            let src = mac.appendingPathComponent("f\(i)")
            try writeFile(src.path, String(repeating: "x", count: i))
            return upload(src, to: dev)
        }
        let (_, finished) = await run(fake, transfers)
        #expect(finished.map(\.id) == transfers.map(\.id))
        #expect(transfers.allSatisfy { $0.state == .done })
    }

    @Test func keepsExistingItemUnlessReplaceWasChosen() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let src = try fake.macDir().appendingPathComponent("a.txt")
        try writeFile(src.path, "new")
        let dev = try fake.deviceDir()
        try writeFile(Parse.join(dev, "a.txt"), "old")

        let keep = upload(src, to: dev)
        _ = await run(fake, [keep])
        #expect(keep.state == .failed("“a.txt” already exists there"))
        #expect(readFile(Parse.join(dev, "a.txt")) == "old")

        let replace = upload(src, to: dev, replace: true)
        _ = await run(fake, [replace])
        #expect(replace.state == .done)
        #expect(readFile(Parse.join(dev, "a.txt")) == "new")
    }

    @Test func replacesExistingItemOnMac() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dev = try fake.deviceDir()
        try writeFile(Parse.join(dev, "a.txt"), "device")
        let mac = try fake.macDir()
        try writeFile(mac.appendingPathComponent("a.txt").path, "mac")

        let keep = download(Parse.join(dev, "a.txt"), to: mac)
        _ = await run(fake, [keep])
        #expect(keep.state == .failed("“a.txt” already exists there"))

        let replace = download(Parse.join(dev, "a.txt"), to: mac, replace: true)
        _ = await run(fake, [replace])
        #expect(replace.state == .done)
        #expect(readFile(mac.appendingPathComponent("a.txt").path) == "device")
    }

    @Test func refusesWhenDeviceIsFull() async throws {
        let fake = try FakeAdb(freeKB: 1)
        defer { fake.cleanUp() }
        let src = try fake.macDir().appendingPathComponent("big.bin")
        try writeFile(src.path, String(repeating: "x", count: 4096))
        let dev = try fake.deviceDir()

        let t = upload(src, to: dev)
        _ = await run(fake, [t])
        guard case .failed(let message) = t.state else { Issue.record("expected failure, got \(t.state)"); return }
        #expect(message.hasPrefix("Not enough space on the device"))
        #expect(!FileManager.default.fileExists(atPath: Parse.join(dev, "big.bin")))
    }

    @Test func spaceOfReplacedItemCountsAsFree() async throws {
        // 4 KB free plus a 4 KB file being replaced is enough for a 6 KB file.
        let fake = try FakeAdb(freeKB: 4)
        defer { fake.cleanUp() }
        let src = try fake.macDir().appendingPathComponent("save.bin")
        try writeFile(src.path, String(repeating: "n", count: 6 * 1024))
        let dev = try fake.deviceDir()
        try writeFile(Parse.join(dev, "save.bin"), String(repeating: "o", count: 4 * 1024))

        let t = upload(src, to: dev, replace: true)
        _ = await run(fake, [t])
        #expect(t.state == .done)
    }

    @Test func missingDeviceFileFailsClearly() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let t = download(Parse.join(try fake.deviceDir(), "gone.txt"), to: try fake.macDir())
        _ = await run(fake, [t])
        #expect(t.state == .failed("Couldn’t find “gone.txt” on the device"))
    }

    @Test func adbErrorFailsAndRemovesPartialCopy() async throws {
        let fake = try FakeAdb(push: .fail)
        defer { fake.cleanUp() }
        let src = try fake.macDir().appendingPathComponent("a.bin")
        try writeFile(src.path, "0123456789")
        let dev = try fake.deviceDir()

        let t = upload(src, to: dev)
        _ = await run(fake, [t])
        #expect(t.state == .failed("adb: error: failed to copy: Broken pipe"))
        #expect(!FileManager.default.fileExists(atPath: Parse.join(dev, "a.bin")))
    }

    @Test func sizeMismatchFailsAndRemovesCopy() async throws {
        let fake = try FakeAdb(pull: .truncate)
        defer { fake.cleanUp() }
        let dev = try fake.deviceDir()
        try writeFile(Parse.join(dev, "a.bin"), "0123456789")
        let mac = try fake.macDir()

        let t = download(Parse.join(dev, "a.bin"), to: mac)
        _ = await run(fake, [t])
        #expect(t.state == .failed("Size check failed: expected 10 bytes, got 3. The copy was removed."))
        #expect(!FileManager.default.fileExists(atPath: mac.appendingPathComponent("a.bin").path))
    }

    @Test func cancellingRunningTransferStopsAdbAndRemovesPartialCopy() async throws {
        let fake = try FakeAdb(push: .hang)
        defer { fake.cleanUp() }
        let mac = try fake.macDir()
        let dev = try fake.deviceDir()
        let first = mac.appendingPathComponent("first.bin")
        let second = mac.appendingPathComponent("second.bin")
        try writeFile(first.path, "0123456789")
        try writeFile(second.path, "abc")

        let q = TransferQueue(adb: fake.adb)
        let running = upload(first, to: dev)
        let waiting = upload(second, to: dev)
        q.add([running, waiting])
        await waitUntil { running.process != nil && FileManager.default.fileExists(atPath: running.stagingPath) }
        #expect(running.state == .running)
        #expect(q.activeCount == 2)

        q.cancel(waiting)
        #expect(waiting.state == .cancelled)
        q.cancel(running)
        await waitIdle(q)
        #expect(running.state == .cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dev).isEmpty, "no partial or hidden leftovers")
    }

    @Test func cancelAllAndWaitLeavesNothingBehind() async throws {
        let fake = try FakeAdb(pull: .hang)
        defer { fake.cleanUp() }
        let dev = try fake.deviceDir()
        try writeFile(Parse.join(dev, "a.bin"), "0123456789")
        let mac = try fake.macDir()

        let q = TransferQueue(adb: fake.adb)
        let t = download(Parse.join(dev, "a.bin"), to: mac)
        q.add([t])
        await waitUntil { t.process != nil }
        await q.cancelAllAndWait()
        #expect(t.state == .cancelled)
        #expect(!q.hasActive)
        #expect(!FileManager.default.fileExists(atPath: mac.appendingPathComponent("a.bin").path))
    }

    @Test func failuresStayListedAndRetryReplacesThemInPlace() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let mac = try fake.macDir()
        let dev = try fake.deviceDir()
        let src = mac.appendingPathComponent("a.txt")
        try writeFile(src.path, "new")
        try writeFile(Parse.join(dev, "a.txt"), "old")

        let q = TransferQueue(adb: fake.adb)
        let failed = upload(src, to: dev)
        q.add([failed])
        await waitIdle(q)
        #expect(failed.state.isFailed)
        #expect(q.failedCount == 1 && q.activeCount == 0)

        // A new batch drops finished items but keeps the failure.
        let other = mac.appendingPathComponent("b.txt")
        try writeFile(other.path, "b")
        let ok = upload(other, to: dev)
        q.add([ok])
        await waitIdle(q)
        #expect(q.items.map(\.id) == [failed.id, ok.id])

        try FileManager.default.removeItem(atPath: Parse.join(dev, "a.txt"))
        q.retry(failed)
        #expect(q.items[0].id != failed.id, "the retry takes the failed item's place")
        await waitIdle(q)
        #expect(q.items.count == 2)
        #expect(q.items[0].state == .done)
        #expect(q.failedCount == 0)
        #expect(readFile(Parse.join(dev, "a.txt")) == "new")

        q.clearFinished()
        #expect(q.items.isEmpty)
    }

    @Test func cancelBeforeItsTurnStartsNeverCopies() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let src = try fake.macDir().appendingPathComponent("a.txt")
        try writeFile(src.path, "abc")
        let dev = try fake.deviceDir()

        let q = TransferQueue(adb: fake.adb)
        let t = upload(src, to: dev)
        q.add([t])     // schedules the copy...
        q.cancel(t)    // ...and cancels it before the scheduled task runs.
        await waitIdle(q)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(t.state == .cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dev).isEmpty)
    }

    @Test func failedReplaceKeepsTheOriginalOnDevice() async throws {
        let fake = try FakeAdb(push: .fail)
        defer { fake.cleanUp() }
        let src = try fake.macDir().appendingPathComponent("game.nsp")
        try writeFile(src.path, "new version")
        let dev = try fake.deviceDir()
        try writeFile(Parse.join(dev, "game.nsp"), "old version")

        let t = upload(src, to: dev, replace: true)
        _ = await run(fake, [t])
        #expect(t.state.isFailed)
        #expect(readFile(Parse.join(dev, "game.nsp")) == "old version")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dev) == ["game.nsp"])
    }

    @Test func failedReplaceKeepsTheOriginalOnMac() async throws {
        let fake = try FakeAdb(pull: .truncate)
        defer { fake.cleanUp() }
        let dev = try fake.deviceDir()
        try writeFile(Parse.join(dev, "a.txt"), "device version")
        let mac = try fake.macDir()
        try writeFile(mac.appendingPathComponent("a.txt").path, "mac version")

        let t = download(Parse.join(dev, "a.txt"), to: mac, replace: true)
        _ = await run(fake, [t])
        #expect(t.state.isFailed)
        #expect(readFile(mac.appendingPathComponent("a.txt").path) == "mac version")
        #expect(try FileManager.default.contentsOfDirectory(atPath: mac.path) == ["a.txt"])
    }

    @Test func cancelledReplaceKeepsTheOriginal() async throws {
        let fake = try FakeAdb(push: .hang)
        defer { fake.cleanUp() }
        let src = try fake.macDir().appendingPathComponent("a.bin")
        try writeFile(src.path, "0123456789")
        let dev = try fake.deviceDir()
        try writeFile(Parse.join(dev, "a.bin"), "original")

        let q = TransferQueue(adb: fake.adb)
        let t = upload(src, to: dev, replace: true)
        q.add([t])
        await waitUntil { t.process != nil }
        q.cancel(t)
        await waitIdle(q)
        #expect(t.state == .cancelled)
        #expect(readFile(Parse.join(dev, "a.bin")) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dev) == ["a.bin"])
    }

    @Test func replacesFolderOnMacWithoutLeftovers() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dev = try fake.deviceDir()
        try FileManager.default.createDirectory(atPath: Parse.join(dev, "Saves"), withIntermediateDirectories: false)
        try writeFile(Parse.join(dev, "Saves/new.sav"), "n")
        let mac = try fake.macDir()
        let old = mac.appendingPathComponent("Saves")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        try writeFile(old.appendingPathComponent("old.sav").path, "o")

        let t = download(Parse.join(dev, "Saves"), to: mac, isDirectory: true, replace: true)
        _ = await run(fake, [t])
        #expect(t.state == .done)
        #expect(try FileManager.default.contentsOfDirectory(atPath: old.path) == ["new.sav"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: mac.path) == ["Saves"])
    }

    @Test func copiesThroughSymlinksBothWays() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let mac = try fake.macDir()
        let dev = try fake.deviceDir()
        let payload = String(repeating: "z", count: 5000)

        try writeFile(mac.appendingPathComponent("real.bin").path, payload)
        let macLink = mac.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(atPath: macLink.path, withDestinationPath: "real.bin")
        let up = upload(macLink, to: dev)

        try writeFile(Parse.join(dev, "target.bin"), payload)
        try FileManager.default.createSymbolicLink(atPath: Parse.join(dev, "devlink.bin"), withDestinationPath: "target.bin")
        let down = download(Parse.join(dev, "devlink.bin"), to: mac)

        _ = await run(fake, [up, down])
        #expect(up.state == .done)
        #expect(down.state == .done)
        #expect(readFile(Parse.join(dev, "link.bin")) == payload)
        #expect(readFile(mac.appendingPathComponent("devlink.bin").path) == payload)
    }

    @Test func failureSummary() {
        func failed(_ name: String, _ message: String) -> Transfer {
            let t = Transfer(direction: .toDevice, serial: serial, source: "/" + name, destDir: "/d", name: name, isDirectory: false, replace: false)
            t.state = .failed(message)
            return t
        }
        let done = Transfer(direction: .toDevice, serial: serial, source: "/ok", destDir: "/d", name: "ok", isDirectory: false, replace: false)
        done.state = .done

        #expect(TransferQueue.failureSummary([done]) == nil)
        #expect(TransferQueue.failureSummary([done, failed("a", "boom")]) == "Couldn’t copy “a”.\n\nboom")

        let many = TransferQueue.failureSummary((1...7).map { failed("f\($0)", "no space") })!
        #expect(many.hasPrefix("7 items couldn’t be copied."))
        #expect(many.contains("“f5”: no space"))
        #expect(!many.contains("“f6”"))
        #expect(many.contains("…and 2 more"))
    }
}

@Suite @MainActor struct TransferCompletionTests {
    @Test func onCompleteFiresOnceForEveryOutcome() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dev = try fake.deviceDir()
        try writeFile(Parse.join(dev, "a.txt"), "abc")
        let mac = try fake.macDir()

        func make(_ source: String) -> Transfer {
            Transfer(direction: .toMac, serial: "FAKE123", source: source, destDir: mac.path,
                     name: (source as NSString).lastPathComponent, isDirectory: false, replace: false)
        }
        let ok = make(Parse.join(dev, "a.txt"))
        let missing = make(Parse.join(dev, "missing.txt"))
        let cancelled = make(Parse.join(dev, "a.txt"))
        var calls: [UUID: Int] = [:]
        for t in [ok, missing, cancelled] { t.onComplete = { calls[$0.id, default: 0] += 1 } }

        let q = TransferQueue(adb: fake.adb)
        q.add([ok, missing, cancelled])
        q.cancel(cancelled)
        await waitIdle(q)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(ok.state == .done && missing.state.isFailed && cancelled.state == .cancelled)
        #expect(calls == [ok.id: 1, missing.id: 1, cancelled.id: 1])
    }
}

@Suite @MainActor struct ProgressVisibilityTests {
    @Test func quickCopiesNeverShowProgress() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let src = try fake.macDir().appendingPathComponent("small.txt")
        try writeFile(src.path, "abc")
        let dev = try fake.deviceDir()

        let q = TransferQueue(adb: fake.adb)
        q.progressDelay = 1.5
        var seen: [Bool] = []
        let watch = q.$showsProgress.sink { seen.append($0) }
        defer { watch.cancel() }
        q.add([Transfer(direction: .toDevice, serial: "FAKE123", source: src.path, destDir: dev,
                        name: "small.txt", isDirectory: false, replace: false)])
        await waitIdle(q)
        try? await Task.sleep(nanoseconds: 1_800_000_000) // past the delay: the reveal must not fire late
        #expect(!seen.contains(true))
    }

    @Test func longCopiesShowProgressAfterTheDelayUntilDone() async throws {
        let fake = try FakeAdb(push: .hang)
        defer { fake.cleanUp() }
        let src = try fake.macDir().appendingPathComponent("big.bin")
        try writeFile(src.path, "0123456789")
        let dev = try fake.deviceDir()

        let q = TransferQueue(adb: fake.adb)
        q.progressDelay = 0.4
        let t = Transfer(direction: .toDevice, serial: "FAKE123", source: src.path, destDir: dev,
                         name: "big.bin", isDirectory: false, replace: false)
        q.add([t])
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(!q.showsProgress, "not before the delay")
        await waitUntil { q.showsProgress }
        #expect(q.showsProgress)

        q.cancel(t)
        await waitIdle(q)
        #expect(!q.showsProgress, "hidden again once nothing is copying")
    }
}

@Suite @MainActor struct BatchProgressTests {
    @Test func countsTheBatchAddedSinceTheQueueWasIdle() async throws {
        let fake = try FakeAdb()
        defer { fake.cleanUp() }
        let dev = try fake.deviceDir()
        let mac = try fake.macDir()
        let q = TransferQueue(adb: fake.adb)
        func upload(_ name: String) throws -> Transfer {
            let src = mac.appendingPathComponent(name)
            try writeFile(src.path, "data")
            return Transfer(direction: .toDevice, serial: "FAKE123", source: src.path, destDir: dev,
                            name: name, isDirectory: false, replace: false)
        }
        #expect(q.batchProgress.count == 0)
        q.add([try upload("a"), try upload("b"), try upload("c")])
        #expect(q.batchProgress.count == 3)
        await waitIdle(q)
        #expect(q.batchProgress.finished == 3 && q.batchProgress.fraction == 1)

        // A later batch starts counting afresh; a cancelled item drops out of it.
        let d = try upload("d"), e = try upload("e")
        q.add([d, e])
        q.cancel(e)
        await waitIdle(q)
        #expect(q.batchProgress.count == 1 && q.batchProgress.finished == 1)
    }
}
