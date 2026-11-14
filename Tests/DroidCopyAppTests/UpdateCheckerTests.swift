import Foundation
import Testing
@testable import DroidCopy
import DroidCopyCore

/// The update check: when it asks GitHub, and when it says something.
@Suite @MainActor struct UpdateCheckerTests {
    final class Calls { var fetches = 0; var shown: [UpdateChecker.UpdateResult] = [] }

    func checker(latest: String?, current: String = "1.0.1") -> (UpdateChecker, Calls, UserDefaults) {
        let defaults = UserDefaults(suiteName: "droidcopy-test-\(UUID().uuidString)")!
        let c = UpdateChecker(defaults: defaults, appVersion: current)
        let calls = Calls()
        c.fetch = { _ in
            calls.fetches += 1
            return latest.map { Release.Info(version: $0, page: Release.pageURL) }
        }
        c.present = { calls.shown.append($0) }
        return (c, calls, defaults)
    }

    @Test func announcesANewVersionOnce() async {
        let (c, calls, _) = checker(latest: "1.1")
        let now = Date()
        await c.checkIfDue(now: now)
        #expect(calls.shown == [.available(Release.Info(version: "1.1", page: Release.pageURL), current: "1.0.1")])
        await c.checkIfDue(now: now.addingTimeInterval(60))
        #expect(calls.fetches == 1, "not again within a day")
        await c.checkIfDue(now: now.addingTimeInterval(UpdateChecker.interval + 1))
        #expect(calls.fetches == 2)
        #expect(calls.shown.count == 1, "1.1 was already announced")
    }

    @Test func staysQuietWhenUpToDateOrOffOrOffline() async {
        let (upToDate, calls, _) = checker(latest: "1.0.1")
        await upToDate.checkIfDue()
        #expect(calls.fetches == 1 && calls.shown.isEmpty)

        let (off, offCalls, _) = checker(latest: "2.0")
        off.automatic = false
        await off.checkIfDue()
        #expect(offCalls.fetches == 0 && offCalls.shown.isEmpty)

        let (offline, offlineCalls, defaults) = checker(latest: nil)
        await offline.checkIfDue()
        #expect(offlineCalls.shown.isEmpty)
        #expect(defaults.object(forKey: UpdateChecker.lastCheckKey) == nil, "tries again at the next launch")
    }

    @Test func checkNowAlwaysAnswers() async {
        let (c, calls, _) = checker(latest: "1.0.1")
        await c.checkNow()
        #expect(calls.shown == [.upToDate("1.0.1")])
        let (offline, offlineCalls, _) = checker(latest: nil)
        await offline.checkNow()
        #expect(offlineCalls.shown == [.failed])
        let (newer, newerCalls, _) = checker(latest: "1.2")
        await newer.checkNow()
        await newer.checkIfDue(now: Date().addingTimeInterval(2 * UpdateChecker.interval))
        #expect(newerCalls.shown.count == 1, "announced by Check Now, so not again automatically")
    }

    @Test func automaticIsOnByDefaultAndRemembered() {
        let (c, _, defaults) = checker(latest: nil)
        #expect(c.automatic)
        c.automatic = false
        #expect(UpdateChecker(defaults: defaults, appVersion: "1").automatic == false)
    }
}

@Suite @MainActor struct CheckContentsSettingTests {
    @Test func reachesTheQueueAndIsRemembered() throws {
        let defaults = UserDefaults(suiteName: "droidcopy-test-\(UUID().uuidString)")!
        let model = AppModel(adb: nil, defaults: defaults)
        #expect(!model.checkContents && !model.queue.checkContents)
        model.checkContents = true
        #expect(model.queue.checkContents)
        let again = AppModel(adb: nil, defaults: defaults)
        #expect(again.checkContents && again.queue.checkContents)
    }
}
