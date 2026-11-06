import AppKit
import Foundation
import Testing
@testable import LaunchGrid
@testable import LaunchGridCore

/// The motion and feedback state behind `Polish.swift`: what opening, removing and searching set.
@MainActor @Suite(.tempDir) struct PolishTests {
    @Test func opensRankWhatIsUsedFirstAndPersist() {
        let state = makeState(["Slack", "Safari"])
        state.query = "s"
        #expect(state.allSearchResults.map(\.title) == ["Slack", "Safari"])
        // Recorded as an open: the next search ranks it first among its kind of match.
        state.recordUse(state.grid.pages[0].items[1])
        #expect(state.allSearchResults.map(\.title) == ["Safari", "Slack"])
        // Kept in the settings, so a relaunch ranks the same.
        let again = Preferences(defaults: UserDefaults(suiteName: TempDir.suiteName(for: TempDir.url))!)
        #expect(again.usage.score(state.grid.pages[0].items[1]) > 0.9)
    }

    @Test func runningAnActionRecordsItAndPulsesWhenTheGridStays() async throws {
        let state = makeState(["A"])
        let opener = FakeOpener()
        opener.install(on: state)
        let link = Action(name: "Docs", kind: .openURL(template: "https://example.com/docs"))
        state.apply { $0.pages[0].items.append(.action(link)) }
        state.isShown = true
        state.prefs.hideAfterLaunch = false
        await state.run(link, argument: nil)?.value
        #expect(state.launchPulse.id == link.id && state.launchPulse.count == 1)
        #expect(state.launchingID == nil)
        #expect(state.prefs.usage.score(.action(link)) > 0.9)
        // Hiding to run it, it zooms instead.
        state.prefs.hideAfterLaunch = true
        state.onHideForLaunch = {}
        await state.run(link, argument: nil)?.value
        #expect(state.launchingID == link.id)
        state.didHide()
        #expect(state.launchingID == nil)
    }

    @Test func removingOffersUndoInTheToast() {
        let state = makeState(["A", "B"])
        state.remove([state.grid.pages[0].items[0].id])
        #expect(state.toast == "Removed A — ⌘Z to undo" && state.toastUndoable)
        #expect(ToastLayer.withoutUndoHint(state.toast!) == "Removed A")
        // Other toasts don't.
        state.showToast("Added to Folder")
        #expect(!state.toastUndoable)
        #expect(ToastLayer.withoutUndoHint("Added to Folder") == "Added to Folder")
    }

    @Test func nothingFoundSuggestsActionsThatTakeWhatWasTyped() {
        let state = makeState(["A"])
        let web = Action(name: "Web", kind: .openURL(template: "https://example.com/?q={query}"))
        let fixed = Action(name: "Docs", kind: .openURL(template: "https://example.com/docs"))
        state.apply { $0.pages[0].items += [.action(web), .action(fixed)] }
        state.query = "zzz"
        #expect(state.allSearchResults.isEmpty)
        #expect(state.noResultSuggestions.map(\.name) == ["Web"])
        // Only once nothing matches, and not for a blank query.
        state.query = "a"
        #expect(state.noResultSuggestions.isEmpty)
        state.query = "  "
        #expect(state.noResultSuggestions.isEmpty)
    }

    @Test func turningPastTheLastPageBouncesOnlyWhenShown() async throws {
        let state = makeState(["A"])
        state.flipPage(1)
        #expect(state.bounceCount == 0 && state.currentPage == 0)
        state.isShown = true
        state.flipPage(1)
        #expect(state.currentPage == 0)
        // None with Reduce Motion, which this Mac may have on.
        let expected = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1
        #expect(state.bounceCount == expected)
        // A jump of several pages (End) doesn't bounce.
        state.flipPage(5)
        #expect(state.bounceCount == expected)
    }

    @Test func aRunningAppIsKnownByPathOrByItsOnlyCopy() {
        let state = makeState(["A", "B"])
        let a = state.grid.allApps[0], b = state.grid.allApps[1]
        state.runningApps = ["com.test.A"]
        #expect(state.isRunning(a) && !state.isRunning(b))
        // Two copies share an ID: only the copy running by path counts.
        let beta = AppRef(bundleID: "com.test.A", path: "/Applications/A-beta.app", name: "A-beta")
        state.apply { $0.pages[0].items.append(.app(beta)) }
        #expect(!state.isRunning(a) && !state.isRunning(beta))
        state.runningApps = ["com.test.A", "/Applications/A-beta.app"]
        #expect(!state.isRunning(a) && state.isRunning(beta))
    }

    @Test func theFirstLayoutBuildsInOnce() {
        let state = AppState(prefs: testPreferences(), store: GridStore(url: TempDir.url.appendingPathComponent("grid.json")))
        state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: [])]))
        #expect(state.introPending == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        state.didHide()
        #expect(!state.introPending)
        // Later layouts (a rebuild, an import) don't.
        state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: [])]))
        #expect(!state.introPending)
    }
}
