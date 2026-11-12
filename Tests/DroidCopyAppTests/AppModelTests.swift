import AppKit
import Combine
import SwiftUI
import Testing
@testable import DroidCopy
import DroidCopyCore
import DroidCopyTestSupport

/// An AppModel wired to a fake adb, a private clipboard and a temporary cache, so nothing here
/// touches a real device, the real clipboard or ~/Library/Caches.
@MainActor
final class Harness {
    let fake: FakeAdb
    let model: AppModel
    let dev: String
    let mac: URL
    let pasteboard = NSPasteboard(name: .init("droidcopy-test-\(UUID().uuidString)"))
    let cache: URL

    init(push: FakeAdb.CopyMode = .normal, pull: FakeAdb.CopyMode = .normal) throws {
        fake = try FakeAdb(push: push, pull: pull)
        dev = try fake.deviceDir("card")
        mac = try fake.macDir()
        cache = fake.root.appendingPathComponent("cache")
        model = AppModel(adb: fake.adb, pasteboard: pasteboard, clipboardCache: cache)
        model.queue.progressDelay = 60
        model.device = DeviceInfo(serial: "FAKE123", state: "device", model: "Fake_Phone")
    }

    /// Opens the fake card and waits for its listing.
    func open() async {
        model.selectStorage(StorageRoot(name: "SD card", path: dev))
        await settle()
    }

    /// Waits until every load in flight has finished (opening a folder starts one of its own).
    func settle() async {
        await model.loadDevice()
        await waitUntil { !self.model.deviceLoading }
    }

    func item(_ name: String) -> FileItem? { model.deviceItems.first { $0.name == name } }

    func idle() async {
        await waitIdle(model.queue)
        try? await Task.sleep(nanoseconds: 100_000_000) // let onFinished's listing refresh land
        await settle()
    }

    func cleanUp() {
        pasteboard.releaseGlobally()
        fake.cleanUp()
    }
}

@Suite @MainActor struct BrowsingTests {
    @Test func listsFoldersFirstAndNavigates() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try FileManager.default.createDirectory(atPath: Parse.join(h.dev, "ROMs/switch"), withIntermediateDirectories: true)
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        await h.open()

        #expect(h.model.deviceItems.map(\.name) == ["ROMs", "a.txt"])
        #expect(!h.model.deviceLoading)
        #expect(h.model.deviceFree != nil)
        #expect(!h.model.deviceCanGoUp)

        h.model.openDevice(h.item("ROMs")!)
        await h.settle()
        #expect(h.model.deviceDir == Parse.join(h.dev, "ROMs"))
        #expect(h.model.deviceItems.map(\.name) == ["switch"])
        #expect(h.model.deviceCrumbs.map(\.title) == ["SD card", "ROMs"])
        #expect(h.model.deviceCanGoUp)

        h.model.deviceUp()
        await h.settle()
        #expect(h.model.deviceDir == h.dev)
        #expect(h.model.deviceCrumbs.map(\.title) == ["SD card"])
    }

    @Test func openingAFileDoesNothing() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        await h.open()
        h.model.openDevice(h.item("a.txt")!)
        #expect(h.model.deviceDir == h.dev)
    }

    @Test func missingFolderShowsAnError() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        h.model.goDevice(Parse.join(h.dev, "gone"))
        await h.settle()
        #expect(h.model.deviceError == "Folder not found on the device")
        #expect(h.model.deviceItems.isEmpty)
        #expect(!h.model.deviceLoading)
    }

    @Test func newFolderRenameAndDelete() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "taken.txt"), "t")
        await h.open()

        await h.model.makeFolder("Saves")
        #expect(h.item("Saves")?.isDirectory == true)

        await h.model.rename(h.item("Saves")!, to: "Saves 2")
        #expect(h.item("Saves 2") != nil && h.item("Saves") == nil)

        await h.model.rename(h.item("Saves 2")!, to: "taken.txt")
        #expect(h.model.alertMessage == "Couldn’t rename: An item with that name already exists")
        h.model.alertMessage = nil

        await h.model.delete([h.item("Saves 2")!, h.item("taken.txt")!])
        #expect(h.model.deviceItems.isEmpty)
    }

    @Test func rejectsInvalidNames() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        for bad in ["", "a/b", ".", ".."] {
            await h.model.makeFolder(bad)
            #expect(h.model.alertMessage == "“\(bad)” isn’t a valid name.")
            h.model.alertMessage = nil
        }
        #expect(h.model.deviceItems.isEmpty)
    }
}

@Suite @MainActor struct CopyToDeviceTests {
    @Test func ignoresDropsWithoutFiles() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        #expect(!h.model.dropOnDevice([]))
        #expect(!h.model.dropOnDevice([URL(string: "https://example.com/a.txt")!]))
    }

    @Test func dropCopiesIntoTheOpenFolderAndRefreshes() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let src = h.mac.appendingPathComponent("game [USA].nsp")
        try writeFile(src.path, "GAME")
        await h.open()

        #expect(h.model.dropOnDevice([src]))
        await waitUntil { h.model.queue.items.count == 1 }
        await h.idle()
        #expect(readFile(Parse.join(h.dev, "game [USA].nsp")) == "GAME")
        #expect(h.item("game [USA].nsp") != nil)
        #expect(h.model.pending == nil && h.model.alertMessage == nil)
    }

    @Test func nameClashesAskFirstIncludingHiddenFiles() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, ".nomedia"), "old hidden")
        try writeFile(Parse.join(h.dev, "a.txt"), "old a")
        for (name, body) in [(".nomedia", "new hidden"), ("a.txt", "new a"), ("b.txt", "new b")] {
            try writeFile(h.mac.appendingPathComponent(name).path, body)
        }
        await h.open()
        #expect(h.item(".nomedia") == nil, "the listing hides it, but the clash check must still see it")

        h.model.copyToDevice([".nomedia", "a.txt", "b.txt"].map { h.mac.appendingPathComponent($0) })
        await waitUntil { h.model.pending != nil }
        let batch = try #require(h.model.pending)
        #expect(Set(batch.conflicts.map(\.name)) == [".nomedia", "a.txt"])
        #expect(h.model.queue.items.isEmpty, "nothing is copied until the person decides")

        h.model.enqueue(batch, replace: false)
        await h.idle()
        #expect(readFile(Parse.join(h.dev, "a.txt")) == "old a")
        #expect(readFile(Parse.join(h.dev, ".nomedia")) == "old hidden")
        #expect(readFile(Parse.join(h.dev, "b.txt")) == "new b")

        h.model.enqueue(batch, replace: true)
        await h.idle()
        #expect(readFile(Parse.join(h.dev, "a.txt")) == "new a")
        #expect(readFile(Parse.join(h.dev, ".nomedia")) == "new hidden")
    }

    @Test func withoutADeviceSaysSo() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.model.device = nil
        h.model.copyToDevice([h.mac.appendingPathComponent("x")])
        #expect(h.model.alertMessage == "Connect a device first.")
    }
}

@Suite @MainActor struct FailureAlertTests {
    @Test func oneFailureNamesTheFile() async throws {
        let h = try Harness(push: .fail)
        defer { h.cleanUp() }
        let src = h.mac.appendingPathComponent("a.bin")
        try writeFile(src.path, "0123456789")
        await h.open()

        _ = h.model.dropOnDevice([src])
        await waitUntil { h.model.alertMessage != nil }
        #expect(h.model.alertMessage == "Couldn’t copy “a.bin”.\n\nadb: error: failed to copy: Broken pipe")
        #expect(h.model.queue.failedCount == 1)
    }

    @Test func severalFailuresMakeOneAlert() async throws {
        let h = try Harness(push: .fail)
        defer { h.cleanUp() }
        let srcs = try ["a.bin", "b.bin", "c.bin"].map { name -> URL in
            let u = h.mac.appendingPathComponent(name)
            try writeFile(u.path, "data")
            return u
        }
        await h.open()

        var alerts: [String] = []
        let watch = h.model.$alertMessage.compactMap { $0 }.sink { alerts.append($0) }
        defer { watch.cancel() }
        _ = h.model.dropOnDevice(srcs)
        await waitUntil { !alerts.isEmpty }
        await waitIdle(h.model.queue)
        #expect(alerts.count == 1)
        #expect(alerts[0].hasPrefix("3 items couldn’t be copied."))
        #expect(h.model.queue.failedCount == 3)
    }
}

@Suite @MainActor struct CopyToMacTests {
    @Test func finderDropPullsToTheExactPlace() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "photo.jpg"), "JPEG")
        await h.open()

        let target = h.mac.appendingPathComponent("photo.jpg")
        var result: Result<Void, Error>?
        h.model.deliver(h.item("photo.jpg")!, to: target) { error in result = error.map { .failure($0) } ?? .success(()) }
        await waitUntil { result != nil }
        #expect((try? result?.get()) != nil)
        #expect(readFile(target.path) == "JPEG")
    }

    @Test func finderDropOfAFolder() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try FileManager.default.createDirectory(atPath: Parse.join(h.dev, "Saves"), withIntermediateDirectories: true)
        try writeFile(Parse.join(h.dev, "Saves/one.sav"), "1")
        await h.open()

        var finished = false
        h.model.deliver(h.item("Saves")!, to: h.mac.appendingPathComponent("Saves")) { _ in finished = true }
        await waitUntil { finished }
        #expect(readFile(h.mac.appendingPathComponent("Saves/one.sav").path) == "1")
    }

    @Test func finderDropReportsFailures() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let ghost = FileItem(name: "ghost.txt", path: Parse.join(h.dev, "ghost.txt"), isDirectory: false, size: 1, modified: nil)
        var error: Error?
        var called = false
        h.model.deliver(ghost, to: h.mac.appendingPathComponent("ghost.txt")) { error = $0; called = true }
        await waitUntil { called }
        #expect((error as? AdbError)?.message == "Couldn’t find “ghost.txt” on the device")

        h.model.device = nil
        called = false
        h.model.deliver(ghost, to: h.mac.appendingPathComponent("ghost.txt")) { error = $0; called = true }
        #expect(called)
        #expect((error as? AdbError)?.message == "The device isn’t connected.")
    }
}

@Suite @MainActor struct ClipboardTests {
    private func clipboardURLs(_ pb: NSPasteboard) -> [URL] {
        pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    @Test func copyPullsThenPutsFilesOnTheClipboard() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "AAA")
        try FileManager.default.createDirectory(atPath: Parse.join(h.dev, "Saves"), withIntermediateDirectories: true)
        try writeFile(Parse.join(h.dev, "Saves/s.sav"), "S")
        await h.open()
        h.pasteboard.clearContents()
        h.pasteboard.setString("something older", forType: .string)

        h.model.copyToClipboard([h.item("a.txt")!, h.item("Saves")!])
        #expect(h.pasteboard.string(forType: .string) == nil, "the old contents go at once, so they can't be pasted by mistake")
        #expect(h.model.queue.items.allSatisfy { $0.destLabel == "Clipboard" })

        await waitUntil { clipboardURLs(h.pasteboard).count == 2 }
        let urls = clipboardURLs(h.pasteboard)
        #expect(urls.map(\.lastPathComponent) == ["a.txt", "Saves"])
        #expect(urls.allSatisfy { $0.path.hasPrefix(h.cache.path) })
        #expect(readFile(urls[0].path) == "AAA")
        #expect(readFile(urls[1].appendingPathComponent("s.sav").path) == "S")
    }

    @Test func aNewCopyReplacesTheOldOneAndCleansUp() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "A")
        try writeFile(Parse.join(h.dev, "b.txt"), "B")
        await h.open()

        h.model.copyToClipboard([h.item("a.txt")!])
        await waitUntil { clipboardURLs(h.pasteboard).count == 1 }
        let first = clipboardURLs(h.pasteboard)[0].deletingLastPathComponent()

        h.model.copyToClipboard([h.item("b.txt")!])
        await waitUntil { clipboardURLs(h.pasteboard).first?.lastPathComponent == "b.txt" }
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.cache.path).count == 1)
    }

    @Test func staleCopiesFromEarlierRunsAreRemoved() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let stale = h.cache.appendingPathComponent("OLD")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try writeFile(stale.appendingPathComponent("x").path, "x")
        h.model.removeStaleClipboardCopies()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func nothingFitsOnTheClipboardWhenEveryPullFails() async throws {
        let h = try Harness(pull: .fail)
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "A")
        await h.open()
        h.model.copyToClipboard([h.item("a.txt")!])
        await waitIdle(h.model.queue)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(clipboardURLs(h.pasteboard).isEmpty)
        #expect(h.model.alertMessage?.hasPrefix("Couldn’t copy “a.txt”.") == true)
    }
}

@Suite @MainActor struct FileTableCoordinatorTests {
    private func coordinator(_ items: [FileItem], deliver: @escaping (FileItem, URL, @escaping (Error?) -> Void) -> Void = { _, _, done in done(nil) })
        -> (FileTable.Coordinator, NSTableView) {
        let actions = FileTableActions(open: { _ in }, copyToMac: { _ in }, copy: { _ in }, rename: { _ in },
                                       delete: { _ in }, receive: { _ in }, deliver: deliver)
        let c = FileTable.Coordinator(FileTable(items: items, selection: .constant([]), actions: actions))
        let table = NSTableView()
        c.table = table
        c.update()
        return (c, table)
    }

    private let items = [
        FileItem(name: "b.nsp", path: "/s/b.nsp", isDirectory: false, size: 2, modified: nil),
        FileItem(name: "ROMs", path: "/s/ROMs", isDirectory: true, size: 0, modified: nil),
        FileItem(name: "a.jpg", path: "/s/a.jpg", isDirectory: false, size: 1, modified: nil),
    ]

    @Test func rowsAreFoldersFirstThenNames() {
        let (c, table) = coordinator(items)
        #expect(c.rows.map(\.name) == ["ROMs", "a.jpg", "b.nsp"])
        #expect(c.numberOfRows(in: table) == 3)
    }

    @Test func rowsDragOutAsFilePromises() throws {
        let (c, table) = coordinator(items)
        let folder = try #require(c.tableView(table, pasteboardWriterForRow: 0) as? NSFilePromiseProvider)
        #expect(folder.fileType == "public.folder")
        #expect(c.filePromiseProvider(folder, fileNameForType: folder.fileType) == "ROMs")
        let photo = try #require(c.tableView(table, pasteboardWriterForRow: 1) as? NSFilePromiseProvider)
        #expect(photo.fileType == "public.jpeg")
        #expect(c.tableView(table, pasteboardWriterForRow: 9) == nil)
    }

    @Test func fulfillingAPromiseAsksTheAppToDeliver() async throws {
        var asked: (FileItem, URL)?
        let (c, table) = coordinator(items) { item, url, done in asked = (item, url); done(nil) }
        let promise = try #require(c.tableView(table, pasteboardWriterForRow: 2) as? NSFilePromiseProvider)
        let target = URL(fileURLWithPath: "/tmp/dest/b.nsp")
        var finished = false
        c.filePromiseProvider(promise, writePromiseTo: target) { error in finished = error == nil }
        await waitUntil { finished }
        #expect(asked?.0.path == "/s/b.nsp")
        #expect(asked?.1 == target)
    }

    @Test func selectionFollowsTheBinding() {
        var selection: Set<String> = ["/s/a.jpg"]
        let actions = FileTableActions(open: { _ in }, copyToMac: { _ in }, copy: { _ in }, rename: { _ in },
                                       delete: { _ in }, receive: { _ in }, deliver: { _, _, d in d(nil) })
        let binding = Binding(get: { selection }, set: { selection = $0 })
        let c = FileTable.Coordinator(FileTable(items: items, selection: binding, actions: actions))
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.allowsMultipleSelection = true
        table.dataSource = c
        table.delegate = c
        c.table = table
        c.update()
        #expect(c.selectedItems.map(\.name) == ["a.jpg"])

        table.selectRowIndexes([0, 2], byExtendingSelection: false)
        #expect(selection == ["/s/ROMs", "/s/b.nsp"])
    }
}

@Suite @MainActor struct OverlappingLoadTests {
    @Test func aSlowerOlderLoadNeverOverwritesANewerOne() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        // Start a load, change the folder's contents, then load again while the first may still run.
        let older = Task { await h.model.loadDevice() }
        try writeFile(Parse.join(h.dev, "new.txt"), "n")
        await h.model.loadDevice()
        await older.value
        #expect(h.item("new.txt") != nil)
        #expect(!h.model.deviceLoading)
    }
}
