import AppKit
import Foundation
import Testing
@testable import LaunchGrid
@testable import LaunchGridCore

/// The motion and feedback state behind `Polish.swift`: what opening, removing and searching set.
@MainActor @Suite(.tempDir) struct PolishTests {
    @Test func tintingTheGlassIsOnByDefault() {
        #expect(makeState(["A"]).prefs.tintFromBackground)
    }

    @Test func reduceMotionIsOffByDefaultAndStopsTheAnimations() {
        let state = makeState(["A"])
        defer { state.prefs.reduceMotion = false }
        #expect(!state.prefs.reduceMotion)
        state.prefs.reduceMotion = true
        #expect(Motion.snappy && Motion.reduced)
        #expect(AppState.pageAnimation == nil && AppState.dragMotion(.default) == nil)
        #expect(Motion.fade(0.2) == 0)
        // Kept in the settings.
        let again = Preferences(defaults: UserDefaults(suiteName: TempDir.suiteName(for: TempDir.url))!)
        #expect(again.reduceMotion)
    }

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

@Suite struct GridFitTests {
    @Test func suggestedSizesSuitCommonDisplays() {
        // Page areas: the screen less the bar above the pages, the dots below and the margins.
        #expect(GridLayout.suggestedSize(forPageArea: CGSize(width: 1344, height: 732)) == (5, 7), "13-inch MacBook Air, as Launchpad")
        #expect(GridLayout.suggestedSize(forPageArea: CGSize(width: 1416, height: 814)) == (5, 7), "14-inch MacBook Pro")
        #expect(GridLayout.suggestedSize(forPageArea: CGSize(width: 1824, height: 912)) == (5, 8), "1080p")
        #expect(GridLayout.suggestedSize(forPageArea: CGSize(width: 2464, height: 1272)) == (6, 9), "Studio Display")
        #expect(GridLayout.suggestedSize(forPageArea: CGSize(width: 3344, height: 1270)) == (6, 12), "ultrawide")
        #expect(GridLayout.suggestedSize(forPageArea: CGSize(width: 984, height: 1752)) == (7, 4), "portrait")
        #expect(GridLayout.suggestedSize(forPageArea: CGSize(width: 700, height: 400)) == (3, 4), "small window")
        #expect(GridLayout.suggestedSize(forPageArea: .zero) == (5, 7), "not measured yet")
    }

    @Test func aSuggestedSizeKeepsCellsNearlyAsTallAsWide() {
        for width in stride(from: 600.0, through: 4000, by: 137) {
            for height in stride(from: 300.0, through: 2000, by: 91) {
                let (rows, columns) = GridLayout.suggestedSize(forPageArea: CGSize(width: width, height: height))
                let aspect = (width / Double(columns)) / (height / Double(rows))
                #expect((4...12).contains(columns) && (3...7).contains(rows))
                if columns > 4 && columns < 12 { #expect(aspect > 1.0 && aspect < 1.7, "\(width)×\(height): \(rows)×\(columns)") }
            }
        }
    }
}

