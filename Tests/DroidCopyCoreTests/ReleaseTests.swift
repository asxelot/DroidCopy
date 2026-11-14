import Foundation
import Testing
@testable import DroidCopyCore

@Suite struct ReleaseTests {
    @Test func comparesVersions() {
        #expect(Release.isNewer("1.0.1", than: "1.0"))
        #expect(Release.isNewer("v1.1", than: "1.0.1"))
        #expect(Release.isNewer("1.0.10", than: "1.0.9"))
        #expect(Release.isNewer("2", than: "1.9.9"))
        #expect(!Release.isNewer("1.0", than: "1.0.0"))
        #expect(!Release.isNewer("1.0.1", than: "1.0.1"))
        #expect(!Release.isNewer("1.0.1", than: "1.1"))
        #expect(Release.numbers("v1.2.3-beta") == [1, 2, 3])
        #expect(Release.numbers("nightly").isEmpty)
    }

    @Test func readsGitHubsLatestRelease() {
        let json = #"{"tag_name":"v1.1","html_url":"https://github.com/asxelot/DroidCopy/releases/tag/v1.1","draft":false,"prerelease":false,"assets":[]}"#
        #expect(Release.parse(Data(json.utf8)) == Release.Info(version: "1.1", page: URL(string: "https://github.com/asxelot/DroidCopy/releases/tag/v1.1")!))
        #expect(Release.parse(Data(#"{"tag_name":"v2.0","prerelease":true}"#.utf8)) == nil)
        #expect(Release.parse(Data(#"{"message":"Not Found"}"#.utf8)) == nil)
        #expect(Release.parse(Data("not json".utf8)) == nil)
        #expect(Release.parse(Data(#"{"tag_name":"v1.2"}"#.utf8))?.page == Release.pageURL)
    }
}
