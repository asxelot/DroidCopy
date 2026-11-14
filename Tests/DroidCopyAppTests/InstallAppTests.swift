import AppKit
import Testing
@testable import DroidCopy
import DroidCopyCore
import DroidCopyTestSupport

/// Dropping .apk files on the window asks whether to install or copy them.
@Suite @MainActor struct InstallAppTests {
    func files(_ h: Harness, _ names: [String]) throws -> [URL] {
        try names.map {
            let u = h.mac.appendingPathComponent($0)
            try writeFile(u.path, "data")
            return u
        }
    }

    @Test func droppingAnAPKAsks() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        let urls = try files(h, ["Game.apk", "notes.txt"])
        #expect(h.model.dropOnDevice(urls))
        #expect(h.model.pendingAPKs?.apks == [urls[0]])
        #expect(h.model.queue.items.isEmpty, "nothing happens until the person answers")

        h.model.installPending()
        #expect(h.model.pendingAPKs == nil)
        await waitUntil { h.model.queue.items.count == 2 }
        await h.idle()
        #expect(FileManager.default.fileExists(atPath: h.fake.installedDir.appendingPathComponent("Game.apk").path))
        #expect(h.item("notes.txt") != nil, "the other file is copied")
        #expect(h.item("Game.apk") == nil, "the app is installed, not copied")
        #expect(h.model.queue.items.map(\.direction).contains(.install))
    }

    @Test func copyToFolderKeepsTheFile() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        let urls = try files(h, ["Game.apk"])
        _ = h.model.dropOnDevice(urls)
        h.model.copyPending()
        await waitUntil { !h.model.queue.items.isEmpty }
        await h.idle()
        #expect(h.item("Game.apk") != nil)
        #expect(!FileManager.default.fileExists(atPath: h.fake.installedDir.path))
    }

    @Test func otherDropsDontAsk() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.open()
        _ = h.model.dropOnDevice(try files(h, ["a.txt"]))
        #expect(h.model.pendingAPKs == nil)
        await waitUntil { !h.model.queue.items.isEmpty }
        await h.idle()
        #expect(h.item("a.txt") != nil)
    }

    @Test func notificationsSayInstalled() {
        func t(_ name: String, _ d: Transfer.Direction = .install) -> Transfer {
            Transfer(direction: d, serial: "S", source: "/x/\(name)", destDir: "", name: name, isDirectory: false, replace: true)
        }
        #expect(AppModel.batchNotification(done: [t("a.apk")], failed: [])! == ("Installing finished", "“a.apk” was installed."))
        #expect(AppModel.batchNotification(done: [t("a.apk"), t("b.apk")], failed: [t("c.apk")])! ==
                ("Installing finished with problems", "2 apps were installed. “c.apk” couldn’t be installed."))
        #expect(AppModel.batchNotification(done: [t("a.apk"), t("b.txt", .toDevice)], failed: [])?.1 == "2 items were copied to the device.")
    }
}
