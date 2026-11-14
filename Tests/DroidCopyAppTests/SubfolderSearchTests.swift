import Foundation
import Testing
@testable import DroidCopy
import DroidCopyCore
import DroidCopyTestSupport

/// The search bar's "and Subfolders" scope.
@Suite @MainActor struct SubfolderSearchTests {
    func harness() async throws -> Harness {
        let h = try Harness()
        for d in ["ROMs/switch", "ROMs/snes"] {
            try FileManager.default.createDirectory(atPath: Parse.join(h.dev, d), withIntermediateDirectories: true)
        }
        try writeFile(Parse.join(h.dev, "ROMs/switch/Mario.nsp"), "x")
        try writeFile(Parse.join(h.dev, "ROMs/snes/mario world.sfc"), "x")
        try writeFile(Parse.join(h.dev, "mario notes.txt"), "x")
        await h.open()
        return h
    }

    @Test func thisFolderOnlyFiltersWhatsShown() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        h.model.searchText = "mario"
        #expect(h.model.visibleItems.map(\.name) == ["mario notes.txt"])
        #expect(!h.model.searchingSubfolders)
    }

    @Test func subfoldersAsksTheDevice() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        h.model.searchScope = .subfolders
        h.model.searchText = "mario"
        #expect(h.model.searching)
        await h.model.searchSettled()
        #expect(Set(h.model.visibleItems.map(\.name)) == ["Mario.nsp", "mario world.sfc", "mario notes.txt"])
        #expect(!h.model.searching && !h.model.searchTruncated)
        let mario = h.model.visibleItems.first { $0.name == "Mario.nsp" }!
        #expect(FileTable.location(of: mario, under: h.dev, rootName: "SD card") == "SD card › ROMs › switch")
        #expect(FileTable.location(of: h.model.visibleItems.first { $0.name == "mario notes.txt" }!, under: h.dev, rootName: "SD card") == "SD card")

        // Clearing the search shows the folder again.
        h.model.searchText = ""
        #expect(h.model.searchResults == nil)
        #expect(h.model.visibleItems.map(\.name).contains("ROMs"))
    }

    @Test func resultsStayFreshAfterARename() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        h.model.searchScope = .subfolders
        h.model.searchText = "mario"
        await h.model.searchSettled()
        let mario = h.model.visibleItems.first { $0.name == "Mario.nsp" }!
        h.model.deviceSelection = [mario.path]
        await h.model.rename(mario, to: "Mario Kart.nsp")
        await h.model.searchSettled()
        #expect(h.model.visibleItems.contains { $0.name == "Mario Kart.nsp" })
        #expect(!h.model.visibleItems.contains { $0.name == "Mario.nsp" })
        #expect(h.exists("ROMs/switch/Mario Kart.nsp"))
    }

    @Test func showInEnclosingFolderOpensItSelected() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        h.model.searchScope = .subfolders
        h.model.searchText = "world"
        await h.model.searchSettled()
        let item = try #require(h.model.visibleItems.first)
        h.model.showInEnclosingFolder(item)
        await h.settle()
        #expect(h.model.deviceDir == Parse.join(h.dev, "ROMs/snes"))
        #expect(h.model.searchText.isEmpty)
        #expect(h.model.deviceSelection == [item.path])
    }

    @Test func scopeIsRemembered() async throws {
        let h = try await harness()
        defer { h.cleanUp() }
        h.model.searchScope = .subfolders
        let again = AppModel(adb: nil, defaults: h.defaults)
        #expect(again.searchScope == .subfolders)
    }
}
