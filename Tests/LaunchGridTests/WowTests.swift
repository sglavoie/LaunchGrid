import AppKit
import Foundation
import Testing
@testable import LaunchGrid
@testable import LaunchGridCore

/// The first-impression pass: a grid that keeps its icons together, the last page's shelf,
/// the sort's wave, firsts, sounds and the item ready to open as the grid shows.
@MainActor @Suite(.tempDir) struct WowTests {
    @Test func aWideGridStandsCentredWithItsCellsNoWiderThanTheAspect() {
        // A 16:9 page area with 7 columns of 5 rows: cells would be 1.8 times as wide as tall.
        let layout = GridLayout(size: CGSize(width: 1800, height: 700), rows: 5, columns: 7, maxCellAspect: GridLayout.pageCellAspect)
        #expect(abs(layout.cell.width - 140 * GridLayout.pageCellAspect) < 0.001)
        #expect(layout.inset > 0)
        // Centred: as much margin each side.
        let first = layout.center(0), last = layout.center(6)
        #expect(abs((first.x - layout.cell.width / 2) - (1800 - last.x - layout.cell.width / 2)) < 0.001)
        // Hit-testing agrees with where cells are drawn, margins included.
        #expect(layout.cellIndex(at: layout.center(10)) == 10)
        #expect(layout.cellIndex(at: CGPoint(x: 2, y: 10)) == 0)
        #expect(layout.cellIndex(at: CGPoint(x: 1798, y: 10)) == 6)
        // A folder's grid (no aspect) fills its width as before.
        let folder = GridLayout(size: CGSize(width: 1800, height: 700), rows: 5, columns: 7)
        #expect(folder.inset == 0)
        #expect(abs(folder.cell.width - 1800.0 / 7) < 0.001)
    }

    @Test func iconsAreLargerInTheirCells() {
        let layout = GridLayout(size: CGSize(width: 1400, height: 800), rows: 5, columns: 7, maxCellAspect: GridLayout.pageCellAspect)
        #expect(layout.iconSize(scale: 1) >= layout.cell.height * 0.69)
    }

    @Test func usageKnowsWhatWasOpenedLast() {
        var usage = Usage()
        let a = GridItem.app(AppRef(bundleID: "a", path: "/A.app", name: "A"))
        let b = GridItem.app(AppRef(bundleID: "b", path: "/B.app", name: "B"))
        usage.record(a, at: Date(timeIntervalSinceReferenceDate: 100))
        usage.record(b, at: Date(timeIntervalSinceReferenceDate: 200))
        usage.record(a, at: Date(timeIntervalSinceReferenceDate: 50))
        #expect(usage.recent() == ["app:b", "app:a"])
        #expect(usage.recent(limit: 1) == ["app:b"])
    }

    @Test func recentsFollowTheSuggestionsSetting() {
        let state = makeState(["Mail", "Music"])
        let mail = state.grid.allApps.first { $0.name == "Mail" }!
        state.recordUse(.app(mail))
        state.refreshSuggestions()
        #expect(state.recents.map(\.title) == ["Mail"])
        state.prefs.showSuggestions = false
        state.refreshSuggestions()
        #expect(state.recents.isEmpty)
    }

    @Test func theGridShowsWithTheFocusOnTheAppOpenedAtThisTimeOfDay() {
        let state = makeState(["Mail", "Music", "Notes"])
        let music = state.grid.allApps.first { $0.name == "Music" }!
        state.didShow()
        #expect(state.focusIndex == nil, "nothing stands out yet")
        state.didHide()
        for _ in 0..<4 { state.recordUse(.app(music)) }
        state.didShow()
        #expect(state.focusIndex == 1)
        #expect(state.predictedID == music.id)
        state.didHide()
        // Not over a search or an open folder, nor with suggestions turned off.
        state.query = "no"
        state.didShow()
        #expect(state.focusIndex == 0, "the search's own focus")
        state.didHide()
        state.prefs.showSuggestions = false
        state.didShow()
        #expect(state.focusIndex == nil)
        #expect(state.predictedID == nil)
    }

    @Test func aSortWithTheGridHiddenHappensAtOnce() {
        let state = makeState(["C", "A", "B"])
        state.sortEverything()
        #expect(state.grid.pages[0].items.map(\.title) == ["A", "B", "C"])
        #expect(state.sortWave == 0, "no wave while hidden")
    }

    @Test func buildingByColourWithoutColoursComesOutByName() {
        let apps = ["Zed", "Alpha", "Mid"].map { InstalledApp(bundleID: "t.\($0)", path: "/\($0).app", name: $0) }
        let grid = GridBuilder.build(from: apps, style: .byColour, rows: 5, columns: 7)
        #expect(grid.pages.flatMap(\.items).map(\.title) == ["Alpha", "Mid", "Zed"])
        // With colours, red first.
        let hues = ["Zed": 0.02, "Alpha": 0.6, "Mid": 0.3]
        let coloured = GridBuilder.build(from: apps, style: .byColour, rows: 5, columns: 7, hue: { hues[$0.title] })
        #expect(coloured.pages.flatMap(\.items).map(\.title) == ["Zed", "Mid", "Alpha"])
    }

    @Test func aFirstIsMarkedOnce() {
        let state = makeState(["A", "B"])
        #expect(state.celebrate(.folder))
        #expect(state.celebrating == .folder)
        #expect(state.toastSparkles)
        #expect(!state.celebrate(.folder))
        // Kept in the settings.
        let again = Preferences(defaults: UserDefaults(suiteName: TempDir.suiteName(for: TempDir.url))!)
        #expect(again.firstsSeen.contains("folder"))
    }

    @Test func anEarlierLayoutsFirstsAreTakenAsHad() {
        // A layout with a folder, from before firsts were marked: no flourish for a folder.
        let prefs = testPreferences()
        let url = TempDir.url.appendingPathComponent("grid.json")
        var grid = Grid(rows: 5, columns: 7, pages: [Page(items: ["A", "B", "C"].map { (name: String) -> GridItem in .app(AppRef(bundleID: "t.\(name)", path: "/\(name).app", name: name)) })])
        grid.hasCreatedLayout = true
        let ids = grid.pages[0].items.prefix(2).map(\.id)
        _ = grid.group(ids, name: "F", anchor: ids[0])
        _ = try? GridStore(url: url).save(grid)
        let state = AppState(prefs: prefs, store: GridStore(url: url))
        #expect(state.prefs.firstsSeen.contains("folder"))
        #expect(!state.celebrate(.folder))
        #expect(state.celebrate(.answer))
    }

    @Test func soundsAreShortAndQuiet() {
        for effect in Sounds.Effect.allCases {
            let samples = Sounds.samples(effect)
            #expect(!samples.isEmpty)
            #expect(samples.count < 44_100 / 2, "under half a second")
            #expect(samples.allSatisfy { abs($0) <= 0.4 })
        }
        // Off by default.
        #expect(!testPreferences().playSounds)
    }

    @Test func aDragLeansIntoItsMoveAndStraightens() {
        let drag = DragController()
        drag.active = true
        drag.location = CGPoint(x: 0, y: 0)
        // Simulated quick moves to the right.
        for i in 1...6 {
            Thread.sleep(forTimeInterval: 0.01)
            drag.location = CGPoint(x: Double(i) * 30, y: 0)
        }
        #expect(drag.tilt > 1)
        #expect(drag.tilt <= DragController.maxTilt)
        Thread.sleep(forTimeInterval: 0.1)
        drag.settleTilt()
        #expect(drag.tilt == 0)
        drag.reset()
        #expect(drag.tilt == 0)
    }
}
