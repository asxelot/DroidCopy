import Foundation
import UniformTypeIdentifiers
import Testing
@testable import DroidCopyCore
import DroidCopyTestSupport

@Suite struct ModelsTests {
    private func item(_ name: String, dir: Bool = false) -> FileItem {
        FileItem(name: name, path: "/x/" + name, isDirectory: dir, size: 0, modified: nil)
    }

    @Test func sortsFoldersFirstThenFinderOrder() {
        let items = [item("file10"), item("b", dir: true), item("file2"), item("A", dir: true), item("Zed")]
        #expect(items.sortedForDisplay().map(\.name) == ["A", "b", "file2", "file10", "Zed"])
    }

    @Test func sortDateFallsBackToDistantPast() {
        #expect(item("a").sortDate == .distantPast)
        let d = Date(timeIntervalSince1970: 5)
        #expect(FileItem(name: "a", path: "/a", isDirectory: false, size: 0, modified: d).sortDate == d)
    }

    @Test func deviceDisplayName() {
        #expect(DeviceInfo(serial: "s", state: "device", model: "Retroid_Pocket_5").displayName == "Retroid Pocket 5")
        #expect(DeviceInfo(serial: "s", state: "device", model: nil).displayName == "s")
    }

    @Test func stateIsFinished() {
        #expect(!Transfer.State.waiting.isFinished)
        #expect(!Transfer.State.running.isFinished)
        #expect(Transfer.State.done.isFinished)
        #expect(Transfer.State.failed("x").isFinished)
        #expect(Transfer.State.cancelled.isFinished)
    }

    @MainActor @Test func destPathForBothDirections() {
        let up = Transfer(direction: .toDevice, serial: "s", source: "/Users/me/a b.nsp", destDir: "/storage/X/ROMs",
                          name: "a b.nsp", isDirectory: false, replace: false)
        #expect(up.destPath == "/storage/X/ROMs/a b.nsp")
        let down = Transfer(direction: .toMac, serial: "s", source: "/storage/X/a.txt", destDir: "/Users/me/Downloads/",
                            name: "a.txt", isDirectory: false, replace: false)
        #expect(down.destPath == "/Users/me/Downloads/a.txt")
    }

    @MainActor @Test func fractionIsClampedAndSafeWithoutTotal() {
        let t = Transfer(direction: .toDevice, serial: "s", source: "/a", destDir: "/d", name: "a", isDirectory: false, replace: false)
        #expect(t.fraction == 0)
        t.total = 100
        t.transferred = 25
        #expect(t.fraction == 0.25)
        t.transferred = 150
        #expect(t.fraction == 1)
    }

    @MainActor @Test func retryCopyIsAFreshTransfer() {
        let t = Transfer(direction: .toMac, serial: "s", source: "/a", destDir: "/d", name: "a", isDirectory: true, replace: true)
        t.state = .failed("x")
        t.transferred = 5
        let r = t.retryCopy()
        #expect(r.id != t.id)
        #expect(r.state == .waiting && r.transferred == 0)
        #expect(r.direction == .toMac && r.source == "/a" && r.destDir == "/d" && r.name == "a" && r.isDirectory && r.replace)
    }
}

@Suite struct LocalFSTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("localfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func listSortsAndHidesDotFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFile(dir.appendingPathComponent("b.txt").path, "12345")
        try writeFile(dir.appendingPathComponent(".secret").path, "x")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Zfolder"), withIntermediateDirectories: false)

        let items = try LocalFS.list(dir)
        #expect(items.map(\.name) == ["Zfolder", "b.txt"])
        #expect(items[1].size == 5 && !items[1].isDirectory && items[1].modified != nil)
        #expect(try LocalFS.list(dir, showHidden: true).contains { $0.name == ".secret" })
    }

    @Test func listOfMissingFolderThrows() {
        #expect(throws: (any Error).self) { try LocalFS.list(URL(fileURLWithPath: "/nonexistent-\(UUID())")) }
    }

    @Test func sizeOfFileFolderAndMissingItem() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFile(dir.appendingPathComponent("a").path, "123")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        try writeFile(dir.appendingPathComponent("sub/b").path, "4567")

        #expect(LocalFS.size(dir.appendingPathComponent("a")) == 3)
        #expect(LocalFS.size(dir) == 7)
        #expect(LocalFS.size(dir.appendingPathComponent("missing")) == 0)
    }

    @Test func freeBytesOfTempFolder() throws {
        #expect((LocalFS.freeBytes(FileManager.default.temporaryDirectory) ?? 0) > 0)
    }
}

@Suite struct FmtTests {
    @Test func durationIsAtLeastOneSecond() {
        #expect(Fmt.duration(0) == Fmt.duration(1))
        #expect(!Fmt.duration(3725).isEmpty)
    }

    @Test func speedAddsPerSecond() {
        #expect(Fmt.speed(2048).hasSuffix("/s"))
        #expect(Fmt.speed(2048).hasPrefix(Fmt.bytes(2048)))
    }
}

@Suite struct LocalFSSymlinkTests {
    @Test func sizeFollowsSymlinkToFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("localfs-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFile(dir.appendingPathComponent("real").path, String(repeating: "x", count: 4000))
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("link").path, withDestinationPath: "real")
        #expect(LocalFS.size(dir.appendingPathComponent("link")) == 4000)
    }
}

@Suite struct TableSortTests {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private func file(_ name: String, _ size: Int64, _ age: Double, dir: Bool = false) -> FileItem {
        FileItem(name: name, path: "/x/" + name, isDirectory: dir, size: size, modified: Date(timeIntervalSince1970: 1000 + age))
    }
    private var items: [FileItem] {
        [file("b.txt", 30, 1), file("a10.bin", 10, 3), file("a2.bin", 20, 2), file("Zdir", 0, 9, dir: true), file("adir", 0, 0, dir: true)]
    }

    @Test func nameSortUsesFinderOrderBothWays() {
        #expect(items.sorted(by: .name, ascending: true).map(\.name) == ["adir", "Zdir", "a2.bin", "a10.bin", "b.txt"])
        #expect(items.sorted(by: .name, ascending: false).map(\.name) == ["Zdir", "adir", "b.txt", "a10.bin", "a2.bin"])
    }

    @Test func sizeAndDateSortKeepFoldersFirst() {
        #expect(items.sorted(by: .size, ascending: false).map(\.name) == ["adir", "Zdir", "b.txt", "a2.bin", "a10.bin"])
        #expect(items.sorted(by: .size, ascending: true).map(\.name) == ["adir", "Zdir", "a10.bin", "a2.bin", "b.txt"])
        #expect(items.sorted(by: .modified, ascending: false).map(\.name) == ["Zdir", "adir", "a10.bin", "a2.bin", "b.txt"])
    }

    @Test func kindSortGroupsTypesThenNames() {
        let mixed = [file("z.jpg", 1, 0), file("b.txt", 1, 0), file("a.jpg", 1, 0), file("dir", 0, 0, dir: true)]
        #expect(mixed.sorted(by: .kind, ascending: true).map(\.name) == ["dir", "a.jpg", "z.jpg", "b.txt"])
        #expect(mixed.sorted(by: .kind, ascending: false).map(\.name) == ["dir", "b.txt", "a.jpg", "z.jpg"])
    }

    @Test func kindReadsLikeFinder() {
        let kind = { (name: String, dir: Bool) in FileItem(name: name, path: "/x/" + name, isDirectory: dir, size: 0, modified: nil).kind }
        #expect(kind("ROMs", true) == "Folder")
        #expect(kind("photo.JPG", false) == "JPEG image")
        #expect(kind("autorun.inf", false) == "INF file")
        #expect(kind("README", false) == "Document")
        #expect(kind(".nomedia", false) == "Document")
        #expect(kind("notes.txt", false) == "Text")
    }

    @Test func tiesFallBackToName() {
        let same = [file("b", 5, 1), file("a", 5, 1), file("c", 5, 1)]
        #expect(same.sorted(by: .size, ascending: false).map(\.name) == ["a", "b", "c"])
        #expect(same.sorted(by: .modified, ascending: true).map(\.name) == ["a", "b", "c"])
    }

    @Test func contentTypeForFinder() {
        #expect(file("Saves", 0, 0, dir: true).contentType == .folder)
        #expect(file("photo.jpg", 1, 0).contentType == .jpeg)
        #expect(file("game.nsp", 1, 0).contentType.conforms(to: .data))
        #expect(file("README", 1, 0).contentType == .data)
    }
}
