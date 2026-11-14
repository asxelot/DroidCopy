import Foundation
import Testing
@testable import DroidCopyCore
import DroidCopyTestSupport

/// Searching a folder and everything inside it with `find` on the device.
@Suite struct SearchTests {
    @Test func patternTakesWildcardsLiterally() {
        #expect(Parse.containsPattern("mario") == "*mario*")
        #expect(Parse.containsPattern("a*b?[c]\\d") == "*a\\*b\\?\\[c\\]\\\\d*")
    }

    func tree() throws -> (FakeAdb, String) {
        let fake = try FakeAdb()
        let dev = try fake.deviceDir()
        for d in ["ROMs/switch/Mario Mods", "ROMs/snes", ".hidden/Mario", "ROMs/.cache"] {
            try FileManager.default.createDirectory(atPath: Parse.join(dev, d), withIntermediateDirectories: true)
        }
        for f in ["ROMs/switch/Super Mario Odyssey [v1].nsp", "ROMs/snes/super mario world.sfc", "ROMs/snes/Zelda.sfc",
                  ".hidden/Mario/x.txt", "ROMs/.cache/mario.tmp", "ROMs/.mario-hidden", "Mario*Star?.txt", "MarioXStarY.txt"] {
            try writeFile(Parse.join(dev, f), "x")
        }
        return (fake, dev)
    }

    @Test func findsMatchesAtAnyDepthIgnoringCase() async throws {
        let (fake, dev) = try tree()
        defer { fake.cleanUp() }
        let r = try await fake.adb.search("FAKE123", in: dev, for: "MARIO")
        #expect(Set(r.items.map { String($0.path.dropFirst(dev.count + 1)) }) == [
            "ROMs/switch/Mario Mods", "ROMs/switch/Super Mario Odyssey [v1].nsp", "ROMs/snes/super mario world.sfc",
            "Mario*Star?.txt", "MarioXStarY.txt",
        ], "nothing hidden, and nothing inside hidden folders")
        #expect(!r.truncated)
        #expect(r.items.first { $0.name == "Mario Mods" }?.isDirectory == true)
        #expect(r.items.first { $0.name.hasSuffix(".nsp") }?.size == 1)
    }

    @Test func showsHiddenWhenAsked() async throws {
        let (fake, dev) = try tree()
        defer { fake.cleanUp() }
        let r = try await fake.adb.search("FAKE123", in: dev, for: "mario", showHidden: true)
        #expect(r.items.contains { $0.name == ".mario-hidden" })
        #expect(r.items.contains { $0.path.hasSuffix(".hidden/Mario") })
        #expect(r.items.contains { $0.name == "mario.tmp" })
    }

    @Test func wildcardsAndBracketsAreLiteral() async throws {
        let (fake, dev) = try tree()
        defer { fake.cleanUp() }
        #expect(try await fake.adb.search("FAKE123", in: dev, for: "Mario*Star?").items.map(\.name) == ["Mario*Star?.txt"])
        #expect(try await fake.adb.search("FAKE123", in: dev, for: "[v1]").items.map(\.name) == ["Super Mario Odyssey [v1].nsp"])
    }

    @Test func stopsAtTheLimit() async throws {
        let (fake, dev) = try tree()
        defer { fake.cleanUp() }
        let r = try await fake.adb.search("FAKE123", in: dev, for: "mario", limit: 2)
        #expect(r.items.count == 2 && r.truncated)
        await #expect(throws: AdbError.self) { try await fake.adb.search("FAKE123", in: dev + "/nope", for: "x") }
    }
}
