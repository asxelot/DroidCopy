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
    let defaultsSuite = "droidcopy-test-\(UUID().uuidString)"
    let defaults: UserDefaults
    /// Files the app opened on the Mac, and notifications it posted.
    var opened: [URL] = []
    var notifications: [(String, String)] = []

    init(push: FakeAdb.CopyMode = .normal, pull: FakeAdb.CopyMode = .normal) throws {
        fake = try FakeAdb(push: push, pull: pull)
        dev = try fake.deviceDir("card")
        mac = try fake.macDir()
        cache = fake.root.appendingPathComponent("cache")
        defaults = UserDefaults(suiteName: defaultsSuite)!
        model = AppModel(adb: fake.adb, pasteboard: pasteboard, clipboardCache: cache,
                         openCache: fake.root.appendingPathComponent("open"), defaults: defaults)
        model.queue.progressDelay = 60
        model.device = DeviceInfo(serial: "FAKE123", state: "device", model: "Fake_Phone")
        model.openOnMac = { [unowned self] in self.opened.append($0) }
        model.notify = { [unowned self] in self.notifications.append(($0, $1)) }
        model.undoManager = undo
    }

    /// Plays the window's undo manager. Without a run loop handing out events, groups are opened by hand.
    let undo: UndoManager = {
        let u = UndoManager()
        u.groupsByEvent = false
        return u
    }()

    /// ⌘Z, then waits for the device to catch up.
    func undoLast() async {
        model.undo()
        await model.undoTask?.value
        await settle()
    }

    func redoLast() async {
        model.redo()
        await model.undoTask?.value
        await settle()
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: Parse.join(dev, path)) }

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
        defaults.removePersistentDomain(forName: defaultsSuite)
        fake.cleanUp()
    }

    /// Makes a folder (and its parents) on the fake device.
    func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: Parse.join(dev, path), withIntermediateDirectories: true)
    }

    /// Replaces a "device" command with a script, like a slow `rm` or a hanging `ls`.
    func stub(_ command: String, _ script: String) throws {
        let url = fake.root.appendingPathComponent("bin/\(command)")
        try writeFile(url.path, "#!/bin/sh\n" + script + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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

    @Test func openingAFilePullsItAndOpensItOnTheMac() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "hello")
        await h.open()
        h.model.openDevice(h.item("a.txt")!)
        await waitUntil { !h.opened.isEmpty }
        #expect(h.model.deviceDir == h.dev, "a file doesn't change the folder")
        #expect(h.opened.count == 1 && h.opened[0].lastPathComponent == "a.txt")
        #expect(readFile(h.opened[0].path) == "hello")
        #expect(h.notifications.isEmpty, "opening a file isn't worth a notification")
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

    @Test func deletingReportsEachItemThenClears() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        for name in ["a.bin", "b.bin", "c.bin"] { try writeFile(Parse.join(h.dev, name), "x") }
        await h.open()
        var seen: [AppModel.DeviceActivity?] = []
        let watch = h.model.$activity.sink { seen.append($0) }
        defer { watch.cancel() }

        await h.model.delete(["a.bin", "b.bin", "c.bin"].compactMap(h.item))
        let shown = seen.compactMap { $0 }
        #expect(shown.map(\.name) == ["a.bin", "b.bin", "c.bin"])
        #expect(shown.map(\.index) == [1, 2, 3] && shown.allSatisfy { $0.count == 3 && $0.verb == "Deleting" })
        #expect(h.model.activity == nil)
        #expect(h.model.deviceItems.isEmpty)
    }

    @Test func wontEjectWhileDeleting() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        // A slow rm on the "device", like a big file on an SD card.
        try h.stub("rm", "sleep 2\nexec /bin/rm \"$@\"")
        try writeFile(Parse.join(h.dev, "big.iso"), "x")
        await h.open()

        let deleting = Task { await h.model.delete([h.item("big.iso")!]) }
        await waitUntil { h.model.activity != nil }
        await h.model.eject()
        #expect(h.model.device != nil && h.model.ejectedSerial == nil)
        #expect(h.model.alertMessage == "Wait for the delete to finish before ejecting.")
        await deleting.value
        #expect(h.model.activity == nil && h.item("big.iso") == nil)
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

    @Test func copiedFilesAreSelectedWhenTheyLand() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "old.txt"), "old")
        for name in ["a.txt", "b.txt"] { try writeFile(h.mac.appendingPathComponent(name).path, name) }
        await h.open()
        h.model.deviceSelection = [Parse.join(h.dev, "old.txt")]

        #expect(h.model.dropOnDevice(["a.txt", "b.txt"].map { h.mac.appendingPathComponent($0) }))
        await waitUntil { h.model.queue.items.count == 2 }
        await h.idle()
        let both: Set = [Parse.join(h.dev, "a.txt"), Parse.join(h.dev, "b.txt")]
        await waitUntil { h.model.deviceSelection == both }
        #expect(h.model.deviceSelection == both, "the new files replace the old selection")
    }

    @Test func failedCopiesAreNotSelected() async throws {
        let h = try Harness(push: .fail)
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "old.txt"), "old")
        try writeFile(h.mac.appendingPathComponent("a.txt").path, "a")
        await h.open()
        h.model.deviceSelection = [Parse.join(h.dev, "old.txt")]

        h.model.copyToDevice([h.mac.appendingPathComponent("a.txt")])
        await waitUntil { h.model.queue.items.count == 1 }
        await h.idle()
        #expect(h.model.deviceSelection == [Parse.join(h.dev, "old.txt")])
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

@Suite @MainActor struct EjectTests {
    private func setDevices(_ h: Harness, _ text: String) throws {
        try text.write(to: h.fake.root.appendingPathComponent("devices.txt"), atomically: true, encoding: .utf8)
    }

    @Test func ejectedDeviceStaysAwayUntilReconnected() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()

        await h.model.eject()
        #expect(h.model.device == nil && h.model.deviceItems.isEmpty)
        #expect(h.model.ejectedSerial == "FAKE123")
        #expect(h.model.alertMessage == nil)

        await h.model.pollDevices()
        #expect(h.model.device == nil, "still plugged in, but ejected")
        #expect(h.model.deviceStatus.contains("safe to unplug"))

        await h.model.reconnect()
        #expect(h.model.device?.serial == "FAKE123")
        #expect(h.model.ejectedSerial == nil)
    }

    @Test func unpluggingAnEjectedDeviceForgetsTheEject() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.model.eject()

        try setDevices(h, "List of devices attached\n")
        await h.model.pollDevices()
        #expect(h.model.ejectedSerial == nil)
        #expect(h.model.deviceStatus.contains("No device connected"))

        try setDevices(h, "List of devices attached\nFAKE123  device product:x model:Fake_Phone\n")
        await h.model.pollDevices()
        #expect(h.model.device?.serial == "FAKE123", "plugging it back in connects it again")
    }

    @Test func wontEjectWhileCopying() async throws {
        let h = try Harness(push: .hang)
        defer { h.cleanUp() }
        try writeFile(h.mac.appendingPathComponent("a.txt").path, "abcdef")
        await h.open()
        h.model.copyToDevice([h.mac.appendingPathComponent("a.txt")])
        await waitUntil { h.model.queue.items.first?.state == .running }

        await h.model.eject()
        #expect(h.model.device != nil && h.model.ejectedSerial == nil)
        #expect(h.model.alertMessage?.contains("Wait for the copies") == true)
        await h.model.queue.cancelAllAndWait()
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
        let actions = FileTableActions(open: { _ in }, copyToMac: { _ in }, copy: { _ in }, rename: { _, _ in },
                                       delete: { _ in }, receive: { _, _ in }, deliver: deliver)
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

    @Test func rowsAlsoCarryTheirShellEscapedPathForTerminal() throws {
        let odd = FileItem(name: "Fire Emblem [US].nsp", path: "/storage/7EF7-7423/ROMs/Fire Emblem [US].nsp",
                           isDirectory: false, size: 2, modified: nil)
        let (c, table) = coordinator([odd])
        let row = try #require(c.tableView(table, pasteboardWriterForRow: 0) as? NSFilePromiseProvider)
        #expect(row.writableTypes(for: .general).contains(.string))
        #expect(row.pasteboardPropertyList(forType: .string) as? String
                == #"/storage/7EF7-7423/ROMs/Fire\ Emblem\ \[US\].nsp "#)
        #expect(row.writableTypes(for: .general).contains(.droidcopyItems), "moves within the device still work")
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
        let actions = FileTableActions(open: { _ in }, copyToMac: { _ in }, copy: { _ in }, rename: { _, _ in },
                                       delete: { _ in }, receive: { _, _ in }, deliver: { _, _, d in d(nil) })
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

    @Test func draggedRowsCarryTheirDevicePaths() throws {
        let (c, table) = coordinator(items)
        let pb = NSPasteboard(name: .init("droidcopy-drag-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let writers = [0, 2].compactMap { c.tableView(table, pasteboardWriterForRow: $0) }
        pb.writeObjects(writers)
        let dragged = FileTable.Coordinator.draggedItems(on: pb)
        #expect(dragged.map(\.path) == ["/s/ROMs", "/s/b.nsp"])
        #expect(dragged.map(\.isDirectory) == [true, false])
        #expect(dragged.map(\.name) == ["ROMs", "b.nsp"])
    }

    @Test func typingANameFindsItsRow() {
        let (c, table) = coordinator(items)
        let name = NSTableColumn(identifier: .init("name"))
        #expect(c.tableView(table, typeSelectStringFor: name, row: 1) == "a.jpg")
        #expect(c.tableView(table, typeSelectStringFor: NSTableColumn(identifier: .init("kind")), row: 1) == nil)
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

@Suite @MainActor struct TransferPanelTests {
    final class Measured { var height: CGFloat = 0 }

    /// The height the panel gets for `count` transfers (one copying, held open; the rest waiting)
    /// at the bottom of a window `window` points tall, laid out as BrowserView lays it out: under
    /// a folder view that takes all the room it can.
    private func panelHeight(_ count: Int, window: CGFloat = 700) async throws -> CGFloat {
        let fake = try FakeAdb(push: .hang)
        defer { fake.cleanUp() }
        let dev = try fake.deviceDir()
        let mac = try fake.macDir()
        let queue = TransferQueue(adb: fake.adb)
        let transfers = try (0..<count).map { i -> Transfer in
            let src = mac.appendingPathComponent("file\(i).bin")
            try writeFile(src.path, "data")
            return Transfer(direction: .toDevice, serial: "FAKE123", source: src.path, destDir: dev,
                            name: "file\(i).bin", isDirectory: false, replace: false)
        }
        queue.add(transfers)
        await waitUntil { transfers[0].state == .running }
        let measured = Measured()
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Color.clear.frame(maxHeight: .infinity)
            TransferList(queue: queue, maxRowsHeight: window * BrowserView.transferShare)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured.height = $0 }
        })
        host.frame = CGRect(x: 0, y: 0, width: 700, height: window)
        // The rows are measured in one pass and the panel sized to them in the next.
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        await queue.cancelAllAndWait()
        return measured.height
    }

    @Test func barsAreThinLikeFinders() {
        let bar = NSHostingController(rootView: ThinBar(fraction: 0.5).frame(width: 200))
        #expect(bar.sizeThatFits(in: CGSize(width: 200, height: 100)).height == ThinBar.height)
    }

    @Test func aCopyingRowIsCompact() async throws {
        let one = try await panelHeight(1)
        #expect(one > 40 && one < 90, "header plus one copying row, not a share of the window: \(one)")
        let tall = try await panelHeight(1, window: 1200)
        #expect(abs(tall - one) < 1, "a taller window doesn't stretch it: \(one) vs \(tall)")
    }

    @Test func growsWithItsRowsUpToACap() async throws {
        let one = try await panelHeight(1)
        let two = try await panelHeight(2)
        let many = try await panelHeight(12)
        let cap = 700 * BrowserView.transferShare
        #expect(two > one + 20, "a second row makes it taller: \(one) → \(two)")
        #expect(many > cap && many < cap + 40, "twelve rows stop at the cap (plus the header) and scroll: \(many)")
        let small = try await panelHeight(12, window: 450)
        #expect(small < many - 50, "a smaller window gives a smaller panel: \(many) vs \(small)")
    }
}

@Suite @MainActor struct NavigationTests {
    @Test func backAndForwardRetraceTheFoldersVisited() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("ROMs/switch")
        await h.open()
        #expect(!h.model.canGoBack && !h.model.canGoForward)

        h.model.openDevice(h.item("ROMs")!)
        await h.settle()
        h.model.openDevice(h.item("switch")!)
        await h.settle()
        #expect(h.model.folderTitle == "switch")

        h.model.goBack()
        await h.settle()
        #expect(h.model.deviceDir == Parse.join(h.dev, "ROMs"))
        #expect(h.model.canGoForward)
        h.model.goBack()
        await h.settle()
        #expect(h.model.deviceDir == h.dev && !h.model.canGoBack)
        #expect(h.model.folderTitle == "SD card")

        h.model.goForward()
        await h.settle()
        #expect(h.model.deviceDir == Parse.join(h.dev, "ROMs"))

        // Going somewhere new drops the forward history, like Finder.
        h.model.deviceUp()
        await h.settle()
        #expect(!h.model.canGoForward)
    }

    @Test func goingUpSelectsTheFolderYouCameFrom() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("ROMs/switch")
        try h.mkdir("Saves")
        await h.open()
        h.model.goDevice(Parse.join(h.dev, "ROMs/switch"))
        await h.settle()
        h.model.deviceUp()
        await h.settle()
        #expect(h.model.deviceSelection == [Parse.join(h.dev, "ROMs/switch")])
    }

    @Test func goToFolderTakesFullAndRelativePaths() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("ROMs/switch")
        await h.open()
        h.model.goToFolder("ROMs/switch/")
        await h.settle()
        #expect(h.model.deviceDir == Parse.join(h.dev, "ROMs/switch"))
        h.model.goToFolder(Parse.join(h.dev, "ROMs"))
        await h.settle()
        #expect(h.model.deviceDir == Parse.join(h.dev, "ROMs"))
        #expect(h.model.deviceItems.map(\.name) == ["switch"])
    }

    @Test func searchNarrowsTheFolderAndTheStatusBarCounts() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        for name in ["Doom.nsp", "doom-update.nsp", "Zelda.nsp"] { try writeFile(Parse.join(h.dev, name), "x") }
        await h.open()
        #expect(h.model.statusText.hasPrefix("3 items, "))
        #expect(h.model.statusText.hasSuffix(" available"))

        h.model.searchText = "DOOM"
        #expect(Set(h.model.visibleItems.map(\.name)) == ["Doom.nsp", "doom-update.nsp"])
        h.model.deviceSelection = [Parse.join(h.dev, "Zelda.nsp"), Parse.join(h.dev, "Doom.nsp")]
        #expect(h.model.selectedItems.map(\.name) == ["Doom.nsp"], "hidden by the search, so not acted on")
        #expect(h.model.statusText.hasPrefix("1 of 2 selected"))

        h.model.searchText = "zzz"
        #expect(h.model.visibleItems.isEmpty)

        h.model.goDevice(h.dev)
        #expect(h.model.searchText.isEmpty, "opening a folder ends the search")
    }

    @Test func hiddenFilesShowWhenAskedAndTheChoiceIsKept() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, ".nomedia"), "")
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        await h.open()
        #expect(h.model.deviceItems.map(\.name) == ["a.txt"])

        h.model.showHidden = true
        await h.settle()
        #expect(h.model.deviceItems.map(\.name) == [".nomedia", "a.txt"])
        #expect(h.defaults.bool(forKey: "showHiddenFiles"))
        let again = AppModel(adb: h.fake.adb, pasteboard: h.pasteboard, clipboardCache: h.cache, defaults: h.defaults)
        #expect(again.showHidden)
    }

    @Test func aDeviceThatStopsAnsweringSaysSoAndCanBeRetried() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        await h.open()
        h.fake.adb.quickTimeout = 0.5
        try h.stub("ls", "sleep 3")   // the listing's first step hangs, like a busy SD card

        let started = Date()
        await h.model.loadDevice()
        #expect(Date().timeIntervalSince(started) < 2.5, "gave up instead of waiting")
        #expect(h.model.deviceError == AdbError.notRespondingMessage)
        #expect(!h.model.deviceLoading)

        try FileManager.default.removeItem(at: h.fake.root.appendingPathComponent("bin/ls"))
        await h.settle()   // Try Again
        #expect(h.model.deviceError == nil)
        #expect(h.item("a.txt") != nil)
    }
}

@Suite @MainActor struct ConnectTests {
    /// A fake /storage with internal storage and one card, so connecting can be tested end to end.
    private func storages(_ h: Harness) throws -> (phone: String, card: String) {
        let root = try h.fake.deviceDir("storage")
        h.fake.adb.storageRoot = root
        let phone = Parse.join(root, "emulated/0"), card = Parse.join(root, "AAAA-1111")
        try FileManager.default.createDirectory(atPath: Parse.join(card, "ROMs/switch"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: phone, withIntermediateDirectories: true)
        return (phone, card)
    }

    @Test func opensTheCardFirstThenRemembersTheLastFolder() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let (phone, card) = try storages(h)
        h.model.device = nil
        await h.model.pollDevices()
        await h.settle()
        #expect(h.model.storages.map(\.path) == [phone, card])
        #expect(h.model.deviceDir == card)
        #expect(h.model.favorites.map(\.name) == ["ROMs"], "the card's ROMs folder starts in the sidebar")

        h.model.goDevice(Parse.join(card, "ROMs/switch"))
        await h.settle()

        // Unplug and plug back in: it opens where you left off, and Back has nothing stale.
        try "List of devices attached\n".write(to: h.fake.root.appendingPathComponent("devices.txt"), atomically: true, encoding: .utf8)
        await h.model.pollDevices()
        #expect(h.model.device == nil)
        try "List of devices attached\nFAKE123  device product:x model:Fake_Phone\n".write(to: h.fake.root.appendingPathComponent("devices.txt"), atomically: true, encoding: .utf8)
        await h.model.pollDevices()
        await h.settle()
        #expect(h.model.deviceDir == Parse.join(card, "ROMs/switch"))
        #expect(h.model.storage?.path == card)
        #expect(!h.model.canGoBack)
    }

    @Test func aRememberedFolderThatIsGoneFallsBackToTheCard() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let (_, card) = try storages(h)
        h.defaults.set(Parse.join(card, "deleted"), forKey: "lastFolder.FAKE123")
        h.model.device = nil
        await h.model.pollDevices()
        await h.settle()
        #expect(h.model.deviceDir == card)
    }

    @Test func goingIntoAnotherStorageSwitchesTheSidebarSelection() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let (phone, card) = try storages(h)
        h.model.device = nil
        await h.model.pollDevices()
        await h.settle()
        #expect(h.model.sidebarSelection == card)
        h.model.goDevice(phone)
        #expect(h.model.storage?.path == phone)
        #expect(h.model.sidebarSelection == phone)
        h.model.goDevice(Parse.join(card, "ROMs"))
        #expect(h.model.storage?.path == card)
        #expect(h.model.sidebarSelection == Parse.join(card, "ROMs"), "a favourite highlights too")
        h.model.goDevice(Parse.join(card, "ROMs/switch"))
        #expect(h.model.sidebarSelection == nil, "only the location itself is highlighted, as in Finder")
    }
}

@Suite @MainActor struct FavoritesTests {
    @Test func foldersCanBePinnedReorderedAndUnpinned() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("ROMs")
        try h.mkdir("Saves")
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        await h.open()

        h.model.addToSidebar([h.item("ROMs")!, h.item("a.txt")!, h.item("Saves")!])
        #expect(h.model.favorites.map(\.name) == ["ROMs", "Saves"], "files aren't pinned")
        h.model.addToSidebar([h.item("ROMs")!])
        #expect(h.model.favorites.count == 2, "no duplicates")

        h.model.moveFavorites(from: [1], to: 0)
        #expect(h.model.favorites.map(\.name) == ["Saves", "ROMs"])
        h.model.removeFromSidebar(h.model.favorites[0])
        #expect(h.model.favorites.map(\.name) == ["ROMs"])

        // Kept per device, across launches.
        h.model.device = nil
        await h.model.pollDevices()
        #expect(h.model.favorites.map(\.name) == ["ROMs"])
    }

    @Test func withNothingSelectedTheOpenFolderIsPinned() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("ROMs/switch")
        await h.open()
        h.model.addToSidebar([])
        #expect(h.model.favorites.isEmpty, "the storage itself is already in the sidebar")
        h.model.goDevice(Parse.join(h.dev, "ROMs/switch"))
        await h.settle()
        h.model.addToSidebar([])
        #expect(h.model.favorites.map(\.path) == [Parse.join(h.dev, "ROMs/switch")])
        #expect(h.model.sidebarSelection == Parse.join(h.dev, "ROMs/switch"))
    }

    @Test func renamingMovingAndDeletingKeepFavoritesRight() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("ROMs/switch")
        try h.mkdir("Games")
        await h.open()
        h.model.goDevice(Parse.join(h.dev, "ROMs"))
        await h.settle()
        h.model.addToSidebar([h.item("switch")!])
        h.model.goDevice(h.dev)
        await h.settle()

        await h.model.rename(h.item("ROMs")!, to: "Roms")
        #expect(h.model.favorites.map(\.path) == [Parse.join(h.dev, "Roms/switch")])

        await h.model.move([h.item("Roms")!], to: Parse.join(h.dev, "Games"))
        #expect(h.model.favorites.map(\.path) == [Parse.join(h.dev, "Games/Roms/switch")])

        await h.model.delete([h.item("Games")!])
        #expect(h.model.favorites.isEmpty)
    }
}

@Suite @MainActor struct DeviceMoveTests {
    @Test func cutThenPasteMovesItemsIntoTheOpenFolder() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("ROMs")
        try writeFile(Parse.join(h.dev, "a.nsp"), "A")
        try writeFile(Parse.join(h.dev, "b.nsp"), "B")
        await h.open()

        h.model.cutItems([h.item("a.nsp")!, h.item("b.nsp")!])
        #expect(h.model.cutPaths.count == 2)
        #expect(h.model.canPaste)
        #expect(h.pasteboard.string(forType: .string) == "\(Parse.join(h.dev, "a.nsp"))\n\(Parse.join(h.dev, "b.nsp"))")

        h.model.openDevice(h.item("ROMs")!)
        await h.settle()
        h.model.paste()
        await waitUntil { h.model.deviceItems.count == 2 && h.model.activity == nil }
        #expect(h.model.deviceItems.map(\.name) == ["a.nsp", "b.nsp"])
        #expect(readFile(Parse.join(h.dev, "ROMs/a.nsp")) == "A")
        #expect(!FileManager.default.fileExists(atPath: Parse.join(h.dev, "a.nsp")))
        #expect(h.model.deviceSelection == Set(["a.nsp", "b.nsp"].map { Parse.join(h.dev, "ROMs/\($0)") }))
        #expect(h.model.cutPaths.isEmpty)
    }

    @Test func copyingSomethingElseForgetsTheCut() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.nsp"), "A")
        await h.open()
        h.model.cutItems([h.item("a.nsp")!])
        h.pasteboard.clearContents()
        h.pasteboard.setString("something else", forType: .string)
        #expect(!h.model.canPaste)
        h.model.paste()
        #expect(h.model.cutPaths.isEmpty)
        #expect(h.item("a.nsp") != nil)
    }

    @Test func clashesAskThenReplaceOrSkip() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("ROMs")
        try writeFile(Parse.join(h.dev, "ROMs/a.nsp"), "old")
        try writeFile(Parse.join(h.dev, "a.nsp"), "new")
        try writeFile(Parse.join(h.dev, "b.nsp"), "B")
        await h.open()

        await h.model.move([h.item("a.nsp")!, h.item("b.nsp")!], to: Parse.join(h.dev, "ROMs"))
        let asked = try #require(h.model.pendingMove)
        #expect(asked.clashes == ["a.nsp"])
        #expect(readFile(Parse.join(h.dev, "ROMs/a.nsp")) == "old", "nothing moved before answering")

        await h.model.resolve(asked, replace: false)
        #expect(readFile(Parse.join(h.dev, "ROMs/a.nsp")) == "old")
        #expect(readFile(Parse.join(h.dev, "ROMs/b.nsp")) == "B")
        #expect(h.item("a.nsp") != nil && h.item("b.nsp") == nil)

        await h.model.move([h.item("a.nsp")!], to: Parse.join(h.dev, "ROMs"))
        await h.model.resolve(try #require(h.model.pendingMove), replace: true)
        #expect(readFile(Parse.join(h.dev, "ROMs/a.nsp")) == "new")
        #expect(h.model.deviceItems.map(\.name) == ["ROMs"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: Parse.join(h.dev, "ROMs"))
        #expect(leftovers.sorted() == ["a.nsp", "b.nsp"], "no hidden leftovers")
    }

    @Test func aFolderCantGoIntoItself() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("ROMs/switch")
        await h.open()
        await h.model.move([h.item("ROMs")!], to: Parse.join(h.dev, "ROMs/switch"))
        #expect(h.model.alertMessage == "“ROMs” can’t be moved into itself.")
        #expect(FileManager.default.fileExists(atPath: Parse.join(h.dev, "ROMs/switch")))
    }

    @Test func optionDragCopiesAndKeepsTheOriginal() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("Backup")
        try h.mkdir("Saves/zelda")
        try writeFile(Parse.join(h.dev, "Saves/zelda/slot1.sav"), "S")
        await h.open()
        await h.model.move([h.item("Saves")!], to: Parse.join(h.dev, "Backup"), copy: true)
        #expect(readFile(Parse.join(h.dev, "Backup/Saves/zelda/slot1.sav")) == "S")
        #expect(readFile(Parse.join(h.dev, "Saves/zelda/slot1.sav")) == "S")
        #expect(try FileManager.default.contentsOfDirectory(atPath: Parse.join(h.dev, "Backup")) == ["Saves"])
    }

    @Test func duplicateNamesCopiesLikeFinderAndSelectsThem() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "game.nsp"), "G")
        try h.mkdir("ROMs")
        await h.open()

        await h.model.duplicate([h.item("game.nsp")!, h.item("ROMs")!])
        #expect(h.model.deviceItems.map(\.name) == ["ROMs", "ROMs copy", "game copy.nsp", "game.nsp"])
        #expect(h.model.deviceSelection == [Parse.join(h.dev, "ROMs copy"), Parse.join(h.dev, "game copy.nsp")])

        await h.model.duplicate([h.item("game.nsp")!])
        await h.model.duplicate([h.item("game copy.nsp")!])
        #expect(h.item("game copy 2.nsp") != nil && h.item("game copy 3.nsp") != nil)
        #expect(readFile(Parse.join(h.dev, "game copy 3.nsp")) == "G")
    }

    @Test func droppingFinderFilesOnAFolderRowCopiesIntoIt() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("ROMs")
        let src = h.mac.appendingPathComponent("x.nsp")
        try writeFile(src.path, "X")
        await h.open()
        #expect(h.model.dropOnDevice([src], into: Parse.join(h.dev, "ROMs")))
        await waitUntil { h.model.queue.items.count == 1 }
        await h.idle()
        #expect(readFile(Parse.join(h.dev, "ROMs/x.nsp")) == "X")
        #expect(h.item("x.nsp") == nil)
    }
}

@Suite @MainActor struct FinderActionTests {
    @Test func newFolderIsUntitledSelectedAndReadyToRename() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        await h.model.newFolder()
        let first = Parse.join(h.dev, "untitled folder")
        #expect(h.item("untitled folder")?.isDirectory == true)
        #expect(h.model.deviceSelection == [first])
        #expect(h.model.renamingPath == first)

        await h.model.newFolder()
        #expect(h.item("untitled folder 2") != nil)
    }

    @Test func renameKeepsTheItemSelected() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        await h.open()
        h.model.deviceSelection = [Parse.join(h.dev, "a.txt")]
        await h.model.rename(h.item("a.txt")!, to: "b.txt")
        #expect(h.model.deviceSelection == [Parse.join(h.dev, "b.txt")])
    }

    @Test func getInfoCountsAndSizesFolders() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("ROMs/switch")
        try writeFile(Parse.join(h.dev, "ROMs/switch/a.nsp"), String(repeating: "x", count: 5000))
        try writeFile(Parse.join(h.dev, "ROMs/b.nsp"), "b")
        try writeFile(Parse.join(h.dev, "c.txt"), "hello")
        await h.open()

        h.model.getInfo([h.item("ROMs")!])
        #expect(h.model.info?.loading == true)
        await waitUntil { h.model.info?.loading == false }
        #expect(h.model.info?.count == 3, "switch, a.nsp and b.nsp, like Finder’s “Contains”")
        #expect((h.model.info?.size ?? 0) >= 5000)

        h.model.getInfo([h.item("c.txt")!])
        await waitUntil { h.model.info?.loading == false }
        #expect(h.model.info?.size == 5 && h.model.info?.count == 1)
    }

    @Test func copyPathPutsDevicePathsOnTheClipboard() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        await h.open()
        h.model.copyPaths([h.item("a.txt")!])
        #expect(h.pasteboard.string(forType: .string) == Parse.join(h.dev, "a.txt"))
        h.model.copyPaths([])
        #expect(h.pasteboard.string(forType: .string) == h.dev)
    }

    @Test func quickLookSkipsFoldersAndRefusesHugeFiles() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.jpg"), "jpg")
        try h.mkdir("ROMs")
        await h.open()
        var shown: [URL] = []
        h.model.preview([h.item("a.jpg")!, h.item("ROMs")!]) { shown = $0 }
        await waitUntil { !shown.isEmpty }
        #expect(shown.map(\.lastPathComponent) == ["a.jpg"])

        let huge = FileItem(name: "big.iso", path: Parse.join(h.dev, "big.iso"), isDirectory: false, size: 7 << 30, modified: nil)
        h.model.preview([huge]) { _ in Issue.record("shouldn't pull a 7 GB file to preview it") }
        #expect(h.model.alertMessage?.contains("too big to preview") == true)
    }

    @Test func finishedCopiesNotifyWhileAway() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let src = h.mac.appendingPathComponent("x.nsp")
        try writeFile(src.path, "X")
        await h.open()
        h.model.copyToDevice([src])
        await waitUntil { h.model.queue.items.count == 1 }
        await h.idle()
        #expect(h.notifications.count == 1)
        #expect(h.notifications.first?.0 == "Copying finished")
        #expect(h.notifications.first?.1 == "“x.nsp” was copied to the device.")
    }

    @Test func batchNotificationSummarisesSuccessesAndFailures() {
        func t(_ name: String, _ dir: Transfer.Direction = .toDevice, label: String? = nil) -> Transfer {
            let t = Transfer(direction: dir, serial: "s", source: "/a/\(name)", destDir: "/b", name: name, isDirectory: false, replace: false)
            t.destLabel = label
            return t
        }
        let both = AppModel.batchNotification(done: [t("a"), t("b")], failed: [t("c")])
        #expect(both?.0 == "Copying finished with problems")
        #expect(both?.1 == "2 items were copied to the device. “c” couldn’t be copied.")
        #expect(AppModel.batchNotification(done: [t("a", .toMac)], failed: [])?.1 == "“a” was copied to the Mac.")
        #expect(AppModel.batchNotification(done: [t("a", .toMac, label: "Quick Look")], failed: []) == nil)
    }
}

@Suite @MainActor struct StandardFavoritesTests {
    @Test func aNewDeviceStartsWithTheUsualFoldersItHas() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let root = try h.fake.deviceDir("storage")
        h.fake.adb.storageRoot = root
        let phone = Parse.join(root, "emulated/0"), card = Parse.join(root, "AAAA-1111")
        for path in ["emulated/0/Download", "emulated/0/DCIM", "emulated/0/Music", "emulated/0/Android", "AAAA-1111/ROMs"] {
            try FileManager.default.createDirectory(atPath: Parse.join(root, path), withIntermediateDirectories: true)
        }
        h.model.device = nil
        await h.model.pollDevices()
        #expect(h.model.favorites.map(\.path) == [Parse.join(card, "ROMs"), Parse.join(phone, "Download"),
                                                  Parse.join(phone, "DCIM"), Parse.join(phone, "Music")])

        // They're ordinary favourites: removing one sticks, and nothing is added back.
        h.model.removeFromSidebar(h.model.favorites[1])
        h.model.device = nil
        await h.model.pollDevices()
        #expect(h.model.favorites.map(\.name) == ["ROMs", "DCIM", "Music"])

        for f in h.model.favorites { h.model.removeFromSidebar(f) }
        h.model.device = nil
        await h.model.pollDevices()
        #expect(h.model.favorites.isEmpty, "an emptied sidebar stays empty")
    }

    // MARK: Undo

    @Test func undoAndRedoARename() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        await h.open()
        #expect(!h.model.canUndo)
        await h.model.rename(h.item("a.txt")!, to: "b.txt")
        #expect(h.undo.undoActionName == "Rename")
        #expect(h.model.canUndo && h.model.undoTitle == "Undo Rename")

        await h.undoLast()
        #expect(h.exists("a.txt") && !h.exists("b.txt"))
        #expect(h.model.deviceSelection == [Parse.join(h.dev, "a.txt")])
        #expect(h.undo.redoActionName == "Rename")
        #expect(h.model.canRedo && h.model.redoTitle == "Redo Rename" && !h.model.canUndo)

        await h.redoLast()
        #expect(h.exists("b.txt") && !h.exists("a.txt"))
        #expect(h.undo.undoActionName == "Rename")
    }

    @Test func undoAMovePutsTheItemsBack() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("Games")
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        try writeFile(Parse.join(h.dev, "b.txt"), "b")
        await h.open()
        await h.model.move([h.item("a.txt")!, h.item("b.txt")!], to: Parse.join(h.dev, "Games"))
        #expect(h.exists("Games/a.txt") && h.exists("Games/b.txt"))
        #expect(h.undo.undoActionName == "Move")

        await h.undoLast()
        #expect(h.exists("a.txt") && h.exists("b.txt") && !h.exists("Games/a.txt"))
        #expect(h.model.deviceSelection == [Parse.join(h.dev, "a.txt"), Parse.join(h.dev, "b.txt")])
    }

    @Test func aMoveThatReplacedSomethingCantBeUndone() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("Games")
        try writeFile(Parse.join(h.dev, "a.txt"), "new")
        try writeFile(Parse.join(h.dev, "Games/a.txt"), "old")
        await h.open()
        await h.model.move([h.item("a.txt")!], to: Parse.join(h.dev, "Games"))
        let pending = try #require(h.model.pendingMove)
        await h.model.resolve(pending, replace: true)
        #expect(readFile(Parse.join(h.dev, "Games/a.txt")) == "new")
        // The old one is gone for good, so there's nothing to put back.
        #expect(!h.undo.canUndo)
    }

    @Test func undoADuplicateRemovesTheCopy() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        await h.open()
        await h.model.duplicate([h.item("a.txt")!])
        #expect(h.exists("a copy.txt"))
        #expect(h.undo.undoActionName == "Duplicate")

        await h.undoLast()
        #expect(!h.exists("a copy.txt") && h.exists("a.txt"))
        await h.redoLast()
        #expect(readFile(Parse.join(h.dev, "a copy.txt")) == "a")
    }

    @Test func undoACopyKeepsTheCopyIfTheOriginalIsGone() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("Games")
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        await h.open()
        await h.model.move([h.item("a.txt")!], to: Parse.join(h.dev, "Games"), copy: true)
        #expect(h.undo.undoActionName == "Copy")
        try FileManager.default.removeItem(atPath: Parse.join(h.dev, "a.txt"))

        await h.undoLast()
        // Removing the copy would lose the only one left.
        #expect(h.exists("Games/a.txt"))
        #expect(h.model.alertMessage?.contains("Couldn’t undo") == true)
    }

    @Test func undoNewFolderOnlyRemovesItWhileEmpty() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        await h.model.newFolder()
        #expect(h.exists("untitled folder"))
        #expect(h.undo.undoActionName == "New Folder")
        await h.undoLast()
        #expect(!h.exists("untitled folder"))

        await h.model.newFolder()
        try writeFile(Parse.join(h.dev, "untitled folder/keep.txt"), "k")
        await h.undoLast()
        #expect(h.exists("untitled folder/keep.txt"))
        #expect(h.model.alertMessage != nil)
    }

    @Test func undoStepsBackThroughNewFolderThenRename() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        await h.model.newFolder()
        await h.model.rename(h.item("untitled folder")!, to: "Saves")
        await h.undoLast()
        #expect(h.exists("untitled folder") && !h.exists("Saves"))
        await h.undoLast()
        #expect(!h.exists("untitled folder"))
        #expect(!h.undo.canUndo)
    }

    @Test func undoACopyKeepsItIfSomethingWasAddedToIt() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("Photos")
        try writeFile(Parse.join(h.dev, "Photos/a.jpg"), "a")
        await h.open()
        await h.model.duplicate([h.item("Photos")!])
        try writeFile(Parse.join(h.dev, "Photos copy/new.jpg"), "only here")

        await h.undoLast()
        #expect(readFile(Parse.join(h.dev, "Photos copy/new.jpg")) == "only here")
        #expect(h.model.alertMessage?.contains("has changed since it was copied") == true)
    }

    @Test func undoACopyKeepsADifferentItemThatTookItsName() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        await h.open()
        await h.model.duplicate([h.item("a.txt")!])
        try writeFile(Parse.join(h.dev, "a copy.txt"), "something else entirely")

        await h.undoLast()
        #expect(readFile(Parse.join(h.dev, "a copy.txt")) == "something else entirely")
    }

    @Test func pressingUndoTwiceQuicklyKeepsTheHistory() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        try writeFile(Parse.join(h.dev, "c.txt"), "c")
        await h.open()
        await h.model.rename(h.item("a.txt")!, to: "b.txt")
        await h.model.rename(h.item("c.txt")!, to: "d.txt")

        h.model.undo()
        h.model.undo()  // while the first is still on the device
        await h.model.undoTask?.value
        await h.settle()
        #expect(h.exists("c.txt") && h.exists("b.txt"))
        #expect(h.model.alertMessage == "Wait for the undo to finish.")
        // The earlier rename can still be undone.
        #expect(h.undo.undoActionName == "Rename")
        await h.undoLast()
        #expect(h.exists("a.txt"))
    }

    @Test func undoWaitsForOtherDeviceWork() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        await h.open()
        await h.model.rename(h.item("a.txt")!, to: "b.txt")
        h.model.activity = AppModel.DeviceActivity(verb: "Deleting", noun: "delete", name: "x", index: 1, count: 1, started: Date())
        h.model.undo()
        #expect(h.model.alertMessage == "Wait for the delete to finish.")
        #expect(h.exists("b.txt") && h.undo.canUndo)
        h.model.activity = nil
        await h.undoLast()
        #expect(h.exists("a.txt"))
    }

    @Test func undoWaitsForCopiesFromTheMac() async throws {
        let h = try Harness(push: .hang)
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "a")
        let big = h.mac.appendingPathComponent("big.bin")
        try writeFile(big.path, "0123456789")
        await h.open()
        await h.model.rename(h.item("a.txt")!, to: "b.txt")
        h.model.copyToDevice([big])
        await waitUntil { h.model.queue.hasActive }
        h.model.undo()
        #expect(h.model.alertMessage == "Wait for the copies to finish.")
        #expect(h.exists("b.txt") && h.undo.canUndo)
        await h.model.queue.cancelAllAndWait()
    }

    @Test func undoNewFolderTakesItOffTheSidebar() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        await h.model.newFolder()
        h.model.addToSidebar([h.item("untitled folder")!])
        #expect(h.model.favorites.count == 1)
        await h.undoLast()
        #expect(!h.exists("untitled folder"))
        #expect(h.model.favorites.isEmpty)
    }

    @Test func undoNewFolderSaysSoWhenItsAlreadyGone() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        await h.model.newFolder()
        try FileManager.default.removeItem(atPath: Parse.join(h.dev, "untitled folder"))
        await h.undoLast()
        #expect(h.model.alertMessage?.contains("is no longer there") == true)
    }

    @Test func oneCopyDragIsOneUndoStep() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try h.mkdir("Games")
        try writeFile(Parse.join(h.dev, "Games/a.txt"), "a")
        try writeFile(Parse.join(h.dev, "b.txt"), "b")
        await h.open()
        let a = FileItem(name: "a.txt", path: Parse.join(h.dev, "Games/a.txt"), isDirectory: false, size: 1, modified: nil)
        await h.model.move([a, h.item("b.txt")!], to: Parse.join(h.dev, "Games"), copy: true)
        #expect(h.exists("Games/a copy.txt") && h.exists("Games/b.txt"))
        #expect(h.undo.undoActionName == "Copy")

        await h.undoLast()
        #expect(!h.exists("Games/a copy.txt") && !h.exists("Games/b.txt"))
        #expect(!h.undo.canUndo)
    }

    @Test func aMoveThatReplacedOneOfSeveralCantBeUndone() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try writeFile(Parse.join(h.dev, "a.txt"), "new")
        try writeFile(Parse.join(h.dev, "b.txt"), "b")
        try h.mkdir("Games")
        try writeFile(Parse.join(h.dev, "Games/a.txt"), "old")
        await h.open()
        await h.model.move([h.item("a.txt")!, h.item("b.txt")!], to: Parse.join(h.dev, "Games"))
        await h.model.resolve(try #require(h.model.pendingMove), replace: true)
        #expect(h.exists("Games/b.txt"))
        // Undoing only b would leave the move half done.
        #expect(!h.undo.canUndo)
    }
}

