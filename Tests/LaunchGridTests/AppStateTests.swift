import Carbon.HIToolbox
import Foundation
import os
import Testing
@testable import LaunchGrid
@testable import LaunchGridCore

/// A fresh temporary folder and settings domain for each test, removed when the test ends.
/// Suites using `makeState`, `testPreferences` or `TempDir.current` carry the `.tempDir` trait.
struct TempDir: TestTrait, SuiteTrait, TestScoping {
    @TaskLocal static var current: URL?

    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> TempDir? {
        testCase == nil ? nil : self
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults().removePersistentDomain(forName: TempDir.suiteName(for: dir))
        }
        try await TempDir.$current.withValue(dir) { try await function() }
    }

    /// The current test's folder; a test without the trait would leave its folder behind.
    static var url: URL {
        guard let current else { preconditionFailure("add the .tempDir trait to this suite") }
        return current
    }

    static func suiteName(for dir: URL) -> String {
        "com.sglavoie.launchgrid.tests.\(dir.lastPathComponent)"
    }
}

extension Trait where Self == TempDir {
    static var tempDir: TempDir { TempDir() }
}

/// Settings in the current test's own domain, never the app's.
@MainActor
func testPreferences() -> Preferences {
    Preferences(defaults: UserDefaults(suiteName: TempDir.suiteName(for: TempDir.url))!)
}

@MainActor
func makeState(_ names: [String] = []) -> AppState {
    let dir = TempDir.url
    let state = AppState(prefs: testPreferences(), store: GridStore(url: dir.appendingPathComponent("grid.json")))
    let apps = names.map { GridItem.app(AppRef(bundleID: "com.test.\($0)", path: "/Applications/\($0).app", name: $0)) }
    state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: apps)]))
    return state
}

func installed(_ name: String) -> InstalledApp {
    InstalledApp(bundleID: "com.test.\(name)", path: "/Applications/\(name).app", name: name)
}

@MainActor @Suite(.tempDir) struct UndoTests {
    @Test func undoingFolderRemovalRestoresItsTemporarilyMissingApps() {
        let state = makeState()
        state.prefs.autoAddApps = false
        let a = installed("A"), b = installed("B")
        var ref = a.makeRef()
        ref.displayName = "My App"
        let folder = Folder(name: "Work", apps: [ref, b.makeRef()])
        state.replaceGrid(Grid(pages: [Page(items: [.folder(folder)])]))
        state.catalogScanned([b])
        state.remove([folder.id])
        #expect(state.grid.isExcluded(a))
        #expect(state.grid.recentlyPruned.isEmpty)

        state.undo()
        state.catalogScanned([a, b])
        #expect(state.grid.folder(folder.id)?.apps.map(\.title) == ["My App", "B"])
        #expect(state.grid.folder(folder.id)?.apps.first?.id == ref.id)
        #expect(!state.grid.isExcluded(a))
    }

    @Test(arguments: [false, true])
    func pruneMemoryInHistoryKeepsItsBookmark(inRedo: Bool) {
        let state = makeState(["A"])
        let returning = AppRef(bundleID: "com.test.returning", path: "/Users/x/Apps/Returning.app")
        let expired = AppRef(bundleID: "com.test.expired", path: "/Users/x/Apps/Expired.app")
        var remembered = state.grid
        remembered.recentlyPruned = [
            PrunedApp(app: returning, prunedAt: Date(), pageID: remembered.pages[0].id, index: 0),
            PrunedApp(app: expired, prunedAt: Date().addingTimeInterval(-Reconciler.restoreWindow - 60),
                      pageID: remembered.pages[0].id, index: 0),
        ]
        state.replaceGrid(remembered)
        if inRedo {
            state.undo()
        } else {
            state.apply { $0.recentlyPruned = [] }
        }
        #expect(state.grid.recentlyPruned.isEmpty)
        #expect(state.appPathsInUse.contains(returning.path), "history can restore its slot and needs sandbox access")
        #expect(!state.appPathsInUse.contains(expired.path), "expired slots no longer need access")
    }

    @Test func rememberingAMovedAppIsNotAnUndoStep() throws {
        let state = makeState(["A", "B"])
        let a = try #require(state.grid.allApps.first)
        state.apply { $0.rename(a.id, to: "Renamed") }
        state.undo()
        #expect(state.canUndo == false)
        #expect(state.canRedo)

        state.rememberPath("/Users/x/Applications/A.app", of: a.id)
        #expect(state.grid.allApps.first?.path == "/Users/x/Applications/A.app")
        #expect(state.canUndo == false)
        #expect(state.canRedo, "redo history survives")
    }

    @Test func undoDoesNotBringBackUninstalledApps() throws {
        let state = makeState(["A", "B"])
        let a = try #require(state.grid.allApps.first)
        state.apply { $0.rename(a.id, to: "Renamed") }
        state.catalogScanned([installed("A")]) // B was uninstalled since.
        #expect(state.grid.allApps.map(\.name) == ["A"])

        state.undo()
        #expect(state.grid.allApps.map(\.title) == ["A"])
        state.redo()
        #expect(state.grid.allApps.map(\.title) == ["Renamed"])
    }

    @Test(arguments: [false, true], [false, true])
    func scansKeepRenamedAppsInTheirSlotWhenUndoingAndRedoing(autoAdd: Bool, prunedFirst: Bool) throws {
        let state = makeState(["A", "B"])
        state.prefs.autoAddApps = autoAdd
        state.catalogScanned([installed("A"), installed("B")])
        let a = try #require(state.grid.allApps.first)
        state.apply { $0.rename(a.id, to: "Custom") }
        if prunedFirst { state.catalogScanned([installed("B")]) }
        let renamed = InstalledApp(bundleID: a.bundleID, path: "/Applications/New A.app", name: "New A")
        state.catalogScanned([renamed, installed("B")])
        // By the next scan, the new path is no longer a newly discovered copy.
        state.catalogScanned([renamed, installed("B")])

        state.undo()
        #expect(state.grid.allApps.map(\.path) == [renamed.path, installed("B").path])
        #expect(state.grid.allApps.first?.id == a.id)
        #expect(state.grid.allApps.first?.title == renamed.name)
        state.redo()
        #expect(state.grid.allApps.map(\.path) == [renamed.path, installed("B").path])
        #expect(state.grid.allApps.first?.id == a.id)
        #expect(state.grid.allApps.first?.title == "Custom")
    }

    @Test func scanDetectedMovesKeepRedoExclusionsForAppCopies() throws {
        let state = makeState()
        let original = installed("Xcode")
        let beta = InstalledApp(bundleID: original.bundleID, path: "/Applications/Xcode-beta.app", name: "Xcode-beta")
        state.catalogScanned([original, beta])
        let tile = try #require(state.grid.allApps.first { $0.path == beta.path })
        state.remove([tile.id])
        state.undo()

        let moved = InstalledApp(bundleID: beta.bundleID, path: "/Applications/Dev/Xcode-beta.app", name: beta.name)
        state.catalogScanned([original, moved])
        state.redo()

        #expect(state.grid.allApps.map(\.path) == [original.path])
        #expect(state.grid.removedBundleIDs == [moved.path])
    }
}

@MainActor @Suite(.tempDir) struct CatalogTests {
    @Test func launchGridLeavesItsOwnGridAndCatalog() {
        let state = makeState(["A", "LaunchGrid"])
        state.ownBundleID = "com.test.LaunchGrid"
        state.catalogScanned(["A", "B", "LaunchGrid"].map(installed))
        #expect(state.installed.map(\.name) == ["A", "B"])
        #expect(!state.grid.allApps.map(\.name).contains("LaunchGrid"))
    }

    @Test func aBuildAskedForBeforeTheFirstScanWaitsForIt() {
        // As closing the welcome window before the apps are found does.
        let state = AppState(prefs: testPreferences(), store: GridStore(url: TempDir.url.appendingPathComponent("grid.json")))
        #expect(!state.hasScanned)
        state.buildWhenScanned(style: .alphabetical)
        #expect(!state.hasGridFile, "no empty layout")
        state.catalogScanned(["B", "A"].map(installed))
        #expect(state.hasScanned && state.hasGridFile)
        #expect(state.grid.allApps.map(\.name) == ["A", "B"])
        state.catalogScanned(["B", "A", "C"].map(installed))
        #expect(state.grid.allApps.map(\.name) == ["A", "B", "C"], "built once, then reconciled as usual")
    }

    @Test func aWaitingBuildGivesWayToALayoutChosenMeanwhile() {
        let state = AppState(prefs: testPreferences(), store: GridStore(url: TempDir.url.appendingPathComponent("grid.json")))
        state.buildWhenScanned(style: .alphabetical)
        let chosen = Grid(rows: 5, columns: 7, pages: [Page(items: [.app(AppRef(bundleID: "com.test.B", path: "/Applications/B.app", name: "B"))])])
        state.replaceGrid(chosen) // an import or a grid file
        state.catalogScanned(["B", "A"].map(installed))
        #expect(state.grid.pages[0].items.first?.title == "B")
        #expect(state.grid.allApps.map(\.name) == ["B", "A"], "the chosen layout still receives the completed scan")
    }
}

@Suite struct GridHitTests {
    @Test func anUnmeasuredGridHasNoDropTarget() {
        let layout = GridLayout(size: .zero, rows: 5, columns: 7)
        #expect(layout.cellIndex(at: .zero) == nil)
    }

    @Test func aCollapsedGridHasNoDropTarget() {
        for size in [CGSize(width: 0, height: 500), CGSize(width: 700, height: 0)] {
            let layout = GridLayout(size: size, rows: 5, columns: 7)
            #expect(layout.cellIndex(at: .zero) == nil)
        }
    }

    @Test func pointsBeyondTheSidesStillReachTheEdgeCells() {
        let layout = GridLayout(size: CGSize(width: 700, height: 500), rows: 5, columns: 7)
        #expect(layout.cellIndex(at: CGPoint(x: -100, y: 150)) == 7)
        #expect(layout.cellIndex(at: CGPoint(x: 800, y: 150)) == 13)
        #expect(layout.cellIndex(at: CGPoint(x: 50, y: -100)) == nil)
    }
}

@MainActor @Suite(.tempDir) struct DragTests {
    @Test func aNewGestureAfterAMissingEndLeavesTheTemporaryPage() {
        let state = makeState(["A", "B"])
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let start = state.iconCenter(0, inFolder: false)
        state.dragChanged(start: start, location: CGPoint(x: 695, y: start.y))
        state.drag.edgeSince = .distantPast
        state.drag.timer?.fire()
        #expect(state.showsVirtualPage)

        // SwiftUI never delivered the first gesture's end. A new background swipe
        // must begin on a real page, even if this swipe is too short to turn it.
        let next = CGPoint(x: 350, y: 250)
        state.dragChanged(start: next, location: next)
        state.dragEnded(start: next, location: next, predicted: next)

        #expect(state.currentPage == 0)
        #expect(state.currentItems.map(\.title) == ["A", "B"])
        #expect(!state.drag.active)
    }

    @Test func aNewGestureAfterAMissingEndAppliesTheDeferredScan() {
        let state = makeState(["A"])
        state.catalogScanned([installed("A")])
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let start = state.iconCenter(0, inFolder: false)
        state.dragChanged(start: start, location: start)
        state.catalogScanned(["A", "B"].map(installed))
        #expect(state.grid.allApps.map(\.name) == ["A"])

        let next = CGPoint(x: 350, y: 250)
        state.dragChanged(start: next, location: next)
        #expect(state.grid.allApps.map(\.name) == ["A", "B"], "apply the scan before hit-testing the new gesture")
        state.dragEnded(start: next, location: next, predicted: next)
    }

    @Test func leavingTheGridCancelsAPendingReorderAndEdgeFlip() {
        let state = makeState(["A", "B", "C"])
        let before = state.grid
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let start = state.iconCenter(0, inFolder: false)
        state.dragChanged(start: start, location: CGPoint(x: 320, y: start.y))
        #expect(state.drag.pendingGap == 2)

        let outside = CGPoint(x: 695, y: -100)
        state.dragChanged(start: start, location: outside)
        state.drag.pendingGapSince = .distantPast
        state.drag.edgeSince = .distantPast
        state.drag.timer?.fire()
        #expect(state.drag.gap == 0, "the pointer left before the reorder dwell completed")
        #expect(state.currentPage == 0, "holding above the grid must not turn pages")
        state.dragEnded(start: start, location: outside, predicted: outside)
        #expect(state.grid == before)
    }

    @Test(arguments: [false, true])
    func losingTheGridMeasurementDuringADragKeepsEveryApp(inFolder: Bool) {
        let state = makeState(["A", "B", "C"])
        if inFolder {
            let ids = state.grid.allApps.map(\.id)
            var folderID: UUID?
            state.apply { folderID = $0.group(ids, name: "F") }
            if let folderID { state.openFolder(folderID) }
        }
        let before = state.grid
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        state.drag.folderGridFrame = CGRect(x: 0, y: 0, width: 700, height: 100)
        state.drag.folderPanelFrame = CGRect(x: 0, y: 0, width: 700, height: 150)
        let start = state.iconCenter(0, inFolder: inFolder)
        state.dragChanged(start: start, location: CGPoint(x: 320, y: start.y))
        #expect(state.drag.active)
        #expect(state.drag.pendingGap == 2)
        state.drag.pagerFrame = .zero
        state.drag.folderGridFrame = .zero
        state.dragEnded(start: start, location: .zero, predicted: .zero)
        #expect(state.grid == before)
        #expect(!state.drag.active)
    }

    @Test(arguments: [(-200.0, -200.0, 2), (200.0, 200.0, 0),
                      (-20.0, -400.0, 2), (20.0, 400.0, 0), (20.0, 30.0, 1)])
    func swipingUsesDistanceOrAShortFlick(dx: Double, flick: Double, page: Int) {
        let state = makeState()
        state.replaceGrid(Grid(pages: [Page(), Page(), Page()]))
        state.currentPage = 1
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let start = CGPoint(x: 350, y: 250)
        let release = CGPoint(x: start.x + dx, y: start.y)
        state.dragChanged(start: start, location: release)
        state.dragEnded(start: start, location: release, predicted: CGPoint(x: start.x + flick, y: start.y))
        #expect(state.currentPage == page)
        #expect(state.swipeOffset == 0)
    }

    @Test(arguments: [-1.0, 1.0])
    func reversingAFlickDoesNotTurnThePageTwice(direction: Double) {
        let state = makeState()
        state.replaceGrid(Grid(pages: [Page(), Page(), Page()]))
        state.currentPage = 1
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let start = CGPoint(x: 350, y: 250)
        let release = CGPoint(x: start.x + direction * 200, y: start.y)
        // Enough distance to turn a page, but the last motion predicts a flick back.
        let predicted = CGPoint(x: start.x - direction * 400, y: start.y)
        state.dragChanged(start: start, location: release)
        state.dragEnded(start: start, location: release, predicted: predicted)
        #expect(state.currentPage == (direction > 0 ? 0 : 2))
        #expect(state.swipeOffset == 0)
    }

    @Test func draggingAcrossFolderPagesKeepsKeyboardFocusVisible() {
        let state = makeState()
        let refs = (1...30).map { installed("App\($0)").makeRef() }
        let folder = Folder(name: "F", apps: refs)
        state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: [.folder(folder)])]))
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        state.drag.folderGridFrame = CGRect(x: 0, y: 0, width: 700, height: 400)
        state.drag.folderPanelFrame = CGRect(x: 0, y: 0, width: 700, height: 440)
        state.openFolder(folder.id)
        state.focusIndex = 1
        let start = state.iconCenter(0, inFolder: true)
        let edge = CGPoint(x: 695, y: start.y)
        state.dragChanged(start: start, location: edge)
        state.drag.edgeSince = .distantPast
        state.drag.timer?.fire()

        #expect(state.folderPage == 1)
        #expect(state.focusIndex == 29, "Return must act on the folder page now shown")
        state.dragEnded(start: start, location: edge, predicted: edge)
        #expect(state.folderPage == 1)
        // Dropping App1 after App30 shifts App30 back a slot; focus stays on App30.
        #expect(state.focusIndex == 28)
        #expect(state.openFolder?.apps[safe: state.focusIndex ?? -1]?.id == refs[29].id)
    }

    @Test(arguments: [false, true])
    func releasingOverAnAppMergesOnlyAfterDwelling(dwelled: Bool) {
        let state = makeState(["A", "B", "C"])
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let start = state.iconCenter(0, inFolder: false)
        let release = state.iconCenter(1, inFolder: false)
        let target = state.grid.pages[0].items[1].id
        state.dragChanged(start: start, location: release)
        #expect(state.drag.candidate == target)
        if dwelled { state.drag.mergeTarget = target }

        state.dragEnded(start: start, location: release, predicted: release)
        let folders = state.grid.pages[0].items.compactMap(\.folder)
        #expect(folders.count == (dwelled ? 1 : 0))
        #expect(Set(state.grid.allApps.map(\.name)) == ["A", "B", "C"])
    }

    @Test func aDropUsesTheReleasePosition() {
        let state = makeState(["A", "B", "C"])
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let start = state.iconCenter(0, inFolder: false)
        state.dragChanged(start: start, location: start)
        #expect(state.drag.active)

        // The release can arrive beyond the last movement event, in the gap after C.
        let release = CGPoint(x: 320, y: start.y)
        state.dragEnded(start: start, location: release, predicted: release)
        #expect(state.grid.allApps.map(\.name) == ["B", "C", "A"])
    }

    @Test func releasingAwayFromAMergeTargetDoesNotMakeAFolder() {
        let state = makeState(["A", "B", "C"])
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let start = state.iconCenter(0, inFolder: false)
        let target = state.grid.pages[0].items[1].id
        state.dragChanged(start: start, location: state.iconCenter(1, inFolder: false))
        // The dwell timer has armed the merge before the final motion/release.
        state.drag.mergeTarget = target
        let release = CGPoint(x: 320, y: start.y)
        state.dragEnded(start: start, location: release, predicted: release)
        #expect(state.grid.pages[0].items.compactMap(\.folder).isEmpty)
        #expect(state.grid.allApps.map(\.name) == ["B", "C", "A"])
    }

    @Test func escapeEndsTheDragForTheRestOfTheGesture() {
        let state = makeState(["A", "B", "C"])
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500) // 100 × 100 cells
        let start = CGPoint(x: 50, y: 50)
        state.dragChanged(start: start, location: CGPoint(x: 120, y: 60))
        #expect(state.drag.active)

        state.drag.cancel() // Esc
        state.dragChanged(start: start, location: CGPoint(x: 160, y: 60))
        #expect(!state.drag.active, "the same gesture must not pick the item up again")
        state.dragEnded(start: start, location: CGPoint(x: 260, y: 60), predicted: CGPoint(x: 260, y: 60))
        #expect(state.grid.allApps.map(\.name) == ["A", "B", "C"])

        // The next gesture works normally.
        state.dragChanged(start: start, location: CGPoint(x: 120, y: 60))
        #expect(state.drag.active)
        state.drag.reset()
    }
}

@MainActor @Suite(.tempDir) struct LoadProblemTests {
    func load(_ contents: String) throws -> AppState {
        let dir = TempDir.url
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("grid.json")
        try Data(contents.utf8).write(to: url)
        return AppState(prefs: testPreferences(), store: GridStore(url: url))
    }

    @Test func newerFormatIsKeptAndExplained() throws {
        let state = try load(#"{"version": 99, "pages": []}"#)
        let problem = try #require(state.loadProblem)
        #expect(problem.backup.lastPathComponent.hasPrefix("grid.newer-"))
        #expect(FileManager.default.fileExists(atPath: problem.backup.path))
        #expect(!state.hasGridFile)
    }

    @Test func corruptFileIsSetAside() throws {
        let state = try load("not json")
        #expect(state.loadProblem?.backup.lastPathComponent.hasPrefix("grid.corrupt-") == true)
    }

    @Test(arguments: [
        #"{"version": 1, "pages": null}"#,
        #"{"version": 1, "pages": [{"items": null}]}"#,
        #"{"version": 1, "pages": [{"items": [{"type": "folder", "folder": {"apps": null}}]}]}"#,
    ])
    func nullLayoutListsRestoreTheBackupInsteadOfStartingAnEmptyLayout(contents: String) throws {
        let first = makeState(["A"])
        #expect(first.saveNow())
        let a = try #require(first.grid.allApps.first)
        first.apply { $0.rename(a.id, to: "Renamed") }
        #expect(first.saveNow())
        try Data(contents.utf8).write(to: first.store.url)

        let recovered = AppState(prefs: testPreferences(), store: first.store)
        #expect(recovered.grid.allApps.map(\.title) == ["A"])
        #expect(recovered.hasGridFile)
        #expect(recovered.recoveryNotice != nil)
        #expect(recovered.saveNow())
        #expect(try recovered.store.load().allApps.map(\.title) == ["A"])
    }

    @Test func aPartlyReadableLayoutIsCopiedAsideAndExplained() throws {
        let original = #"{"version": 1, "rows": 2, "columns": 2, "pages": [{"items": [{"type": "app", "app": {"path": "/Applications/A.app", "name": "A"}}, {"type": "app", "app": {"name": "No path"}}, {"type": "app", "app": {"name": "Nor this"}}]}], "removedBundleIDs": []}"#
        let state = try load(original)
        #expect(state.grid.allApps.map(\.title) == ["A"])
        #expect(state.loadProblem == nil)
        let notice = try #require(state.recoveryNotice)
        #expect(notice.message.hasPrefix("2 entries"))
        #expect(notice.file.lastPathComponent.hasPrefix("grid.partial-"))
        #expect(try String(contentsOf: notice.file, encoding: .utf8) == original, "the file as it was")
    }

    @Test func aPartlyReadableLayoutThatCantBeCopiedIsExplainedAtLaunchAndKept() throws {
        let original = #"{"version": 1, "rows": 2, "columns": 2, "pages": [{"items": [{"type": "app", "app": {"path": "/Applications/A.app", "name": "A"}}, {"type": "app", "app": {"name": "No path"}}, {"type": "app", "app": {"name": "Nor this"}}]}], "removedBundleIDs": []}"#
        let dir = TempDir.url
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("grid.json")
        try Data(original.utf8).write(to: url)
        // No copy can be made beside it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let state = AppState(prefs: testPreferences(), store: GridStore(url: url))
        #expect(state.grid.allApps.map(\.title) == ["A"])
        #expect(state.hasGridFile, "so the welcome window, which tells of load problems, stays shut")
        let notice = try #require(state.recoveryNotice, "told at launch instead")
        #expect(notice.message.hasPrefix("2 entries"))
        #expect(notice.file == url)
        #expect(!state.saveNow(reportingFailure: false), "recovery blocked saves even before an edit")
        #expect(state.lastSaveError?.localizedDescription == notice.message)
        let a = try #require(state.grid.allApps.first)
        state.apply { $0.rename(a.id, to: "Renamed") }
        #expect(!state.saveNow(reportingFailure: false))
        #expect(state.lastSaveError?.localizedDescription == notice.message, "a save says why, not that the file couldn't be read")
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test func aPartlyReadableLayoutIsWrittenBackSoTheNextLaunchDoesNotAskAgain() throws {
        let original = #"{"version": 1, "rows": 2, "columns": 2, "pages": [{"items": [{"type": "app", "app": {"path": "/Applications/A.app", "name": "A"}}, {"type": "app", "app": {"name": "No path"}}]}], "removedBundleIDs": []}"#
        let first = try load(original)
        #expect(first.recoveryNotice != nil)
        first.saveNow() // as the save `init` schedules does, unchanged since
        #expect(try GridStore.decodeCountingSkipped(Data(contentsOf: first.store.url)).skipped == 0)
        let next = AppState(prefs: testPreferences(), store: first.store)
        #expect(next.recoveryNotice == nil)
        #expect(next.loadProblem == nil)
        #expect(next.grid.allApps.map(\.title) == ["A"])
    }

    @Test func aJSONObjectWithoutPagesIsNotAnEmptyLayout() throws {
        // As a damaged file or another app's JSON: set aside, never read as an empty grid.
        let state = try load("{}")
        #expect(state.loadProblem?.backup.lastPathComponent.hasPrefix("grid.corrupt-") == true)
        #expect(throws: GridFileError.self) { try GridStore.decode(Data(#"{"rows": 5}"#.utf8)) }
        #expect(try GridStore.decode(Data(#"{"pages": []}"#.utf8)).allApps.isEmpty, "exclusions only")
    }

    @Test func savesKeepThePreviousOneToRestoreFromWhenTheLastIsUnreadable() throws {
        let first = makeState(["A"])
        first.saveNow()
        let a = try #require(first.grid.allApps.first)
        first.apply { $0.rename(a.id, to: "Renamed") }
        first.saveNow()
        #expect(try first.store.loadBackup().allApps.map(\.title) == ["A"], "the save before last")

        try Data().write(to: first.store.url) // as a power cut right after writing can leave it
        let state = AppState(prefs: testPreferences(), store: first.store)
        #expect(state.grid.allApps.map(\.title) == ["A"])
        #expect(state.hasGridFile)
        #expect(state.loadProblem == nil)
        let notice = try #require(state.recoveryNotice)
        #expect(notice.file.lastPathComponent.hasPrefix("grid.corrupt-"))
        #expect(FileManager.default.fileExists(atPath: notice.file.path))
    }

    @Test func aSymlinkedLayoutIsRecoveredBesideTheFileItPointsAt() throws {
        // As a dotfiles repository can hold it: the layout lives elsewhere, linked from here.
        let real = TempDir.url.appendingPathComponent("dotfiles/grid.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        let link = TempDir.url.appendingPathComponent("grid.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let first = makeState(["A"])
        first.saveNow()
        let a = try #require(first.grid.allApps.first)
        first.apply { $0.rename(a.id, to: "Renamed") }
        first.saveNow()
        try Data().write(to: real)

        let state = AppState(prefs: testPreferences(), store: first.store)
        #expect(state.grid.allApps.map(\.title) == ["A"], "restored from the backup beside the real file")
        let notice = try #require(state.recoveryNotice)
        #expect(notice.file.deletingLastPathComponent().lastPathComponent == "dotfiles")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path, "the link stays")
        state.saveNow()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try GridStore(url: real).load().allApps.map(\.title) == ["A"])
    }

    @Test func aLayoutRestoredFromTheBackupIsWrittenBackWithoutWaitingForAChange() async throws {
        let first = makeState(["A"])
        first.saveNow()
        let a = try #require(first.grid.allApps.first)
        first.apply { $0.rename(a.id, to: "Renamed") }
        first.saveNow()
        try Data().write(to: first.store.url)

        let state = AppState(prefs: testPreferences(), store: first.store)
        #expect(state.recoveryNotice != nil)
        #expect(!state.store.exists, "the unreadable file was set aside")
        // Not a fixed wait: other tests running alongside keep the main actor busy.
        for _ in 0..<50 where !state.store.exists { try await Task.sleep(for: .milliseconds(100)) }
        #expect(try state.store.load().allApps.map(\.title) == ["A"])
    }

    @Test func theBackupIsRefreshedAtTheFirstSaveOfARunNotAtEveryOne() throws {
        let state = makeState(["A"])
        state.saveNow()
        let a = try #require(state.grid.allApps.first)
        state.apply { $0.rename(a.id, to: "B") }
        state.saveNow()
        state.apply { $0.rename(a.id, to: "C") }
        state.saveNow()
        #expect(try state.store.loadBackup().allApps.map(\.title) == ["A"], "kept: refreshed less often")
        let next = AppState(prefs: testPreferences(), store: state.store)
        next.apply { $0.rename(a.id, to: "D") }
        next.saveNow()
        #expect(try next.store.loadBackup().allApps.map(\.title) == ["C"], "a new run refreshes it at once")
    }

    @Test func theBackupIsRefreshedAgainOnceTheIntervalHasPassed() throws {
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 0))
        let writer = LayoutWriter(store: GridStore(url: TempDir.url.appendingPathComponent("grid.json"))) {
            clock.withLock { $0 }
        }
        func save(_ name: String) throws {
            if let error = writer.save(Grid(pages: [Page(items: [.app(AppRef(bundleID: nil, path: "/Applications/\(name).app", name: name))])])) {
                throw error
            }
        }
        func backup() throws -> [String] { try writer.store.loadBackup().allApps.map(\.title) }
        try save("A")
        try save("B") // the first save to refresh it: A
        try save("C")
        clock.withLock { $0 += LayoutWriter.backupInterval - 1 }
        try save("D")
        #expect(try backup() == ["A"], "kept until the interval has passed")
        clock.withLock { $0 += 1 }
        try save("E")
        #expect(try backup() == ["D"], "then refreshed with the save before")
        try save("F")
        #expect(try backup() == ["D"])
    }
}

@MainActor @Suite(.tempDir) struct SelectionTests {
    func ids(_ state: AppState) -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: state.grid.allApps.map { ($0.name, $0.id) })
    }

    func selected(_ state: AppState) -> [String] {
        state.grid.allApps.filter { state.selection.contains($0.id) }.map(\.name)
    }

    @Test func shiftClickRangeStartsAtTheLastClickAndCanShrink() {
        let state = makeState(["A", "B", "C", "D", "E", "F"])
        let id = ids(state)
        state.toggleSelection(id["E"]!)
        state.extendSelection(to: id["B"]!)
        #expect(selected(state) == ["B", "C", "D", "E"])
        state.extendSelection(to: id["D"]!)
        #expect(selected(state) == ["D", "E"], "the next shift-click replaces the previous range")
    }

    @Test func shiftClickKeepsItemsSelectedOtherwise() {
        let state = makeState(["A", "B", "C", "D", "E", "F"])
        let id = ids(state)
        state.toggleSelection(id["A"]!)
        state.toggleSelection(id["E"]!)
        state.extendSelection(to: id["C"]!)
        #expect(selected(state) == ["A", "C", "D", "E"])
        state.extendSelection(to: id["F"]!)
        #expect(selected(state) == ["A", "E", "F"])
    }

    @Test func shiftClickOnAnotherPageEstablishesANewAnchor() {
        let state = makeState(["A", "B", "C", "D", "E", "F"])
        let id = ids(state)
        state.apply { g in
            let items = g.pages[0].items
            g.pages = [Page(items: Array(items.prefix(2))), Page(items: Array(items.dropFirst(2)))]
        }
        state.toggleSelection(id["A"]!)
        state.goToPage(1)
        state.extendSelection(to: id["C"]!)
        state.extendSelection(to: id["E"]!)
        #expect(selected(state) == ["A", "C", "D", "E"])
        state.extendSelection(to: id["D"]!)
        #expect(selected(state) == ["A", "C", "D"], "the range shrinks towards C, its new anchor")
    }

    @Test func shiftClickOnAnotherPageKeepsThePreviousPagesRange() {
        let state = makeState(["A", "B", "C", "D", "E", "F"])
        let id = ids(state)
        state.apply { g in
            let items = g.pages[0].items
            g.pages = [Page(items: Array(items.prefix(2))), Page(items: Array(items.dropFirst(2)))]
        }
        state.toggleSelection(id["A"]!)
        state.extendSelection(to: id["B"]!)
        state.goToPage(1)
        state.extendSelection(to: id["C"]!)
        state.extendSelection(to: id["E"]!)
        #expect(selected(state) == ["A", "B", "C", "D", "E"])
        state.extendSelection(to: id["D"]!)
        #expect(selected(state) == ["A", "B", "C", "D"], "only the current page's range shrinks")
    }

    @Test func closingAFolderDropsTheAppsSelectedInsideIt() {
        let state = makeState(["A", "B", "C", "D"])
        let id = ids(state)
        state.apply { _ = $0.group([id["A"]!, id["B"]!], name: "F") }
        let folder = try! #require(state.grid.pages[0].items.first { $0.folder != nil })
        state.toggleSelection(id["D"]!)
        state.openFolder(folder.id)
        state.toggleSelection(id["A"]!)
        state.closeFolder(restoringFocus: true)
        #expect(selected(state) == ["D"], "out of sight, ⌫ or Group would act on it unseen")
    }

    @Test func aSelectionOnOtherPagesIsCounted() {
        let state = makeState(["A", "B", "C"])
        state.apply { $0.pages = [Page(items: Array($0.pages[0].items.prefix(2))), Page(items: Array($0.pages[0].items.suffix(1)))] }
        let id = ids(state)
        state.toggleSelection(id["A"]!)
        state.toggleSelection(id["B"]!)
        #expect(state.selectionOutOfView == 0)
        state.goToPage(1)
        #expect(state.selectionOutOfView == 2)
        state.toggleSelection(id["C"]!)
        #expect(state.selectionOutOfView == 2)
    }

    @Test func aSelectionOnOtherFolderPagesIsCounted() {
        let state = makeState()
        let refs = (1...5).map { installed("App\($0)").makeRef() }
        let folder = Folder(name: "F", apps: refs)
        state.replaceGrid(Grid(rows: 3, columns: 2, pages: [Page(items: [.folder(folder)])]))
        state.openFolder(folder.id) // Four apps on the first folder page.
        state.toggleSelection(refs[0].id)
        #expect(state.selectionOutOfView == 0)

        state.flipPage(1)
        #expect(state.selectionOutOfView == 1, "Remove must count selections hidden on another folder page")
        state.toggleSelection(refs[4].id)
        #expect(state.selectionOutOfView == 1)
        state.flipPage(-1)
        #expect(state.selectionOutOfView == 1)
    }

    @Test func removingOneItemNamesIt() {
        let state = makeState(["Safari", "Mail"])
        state.remove([ids(state)["Mail"]!])
        #expect(state.toast == "Removed Mail — ⌘Z to undo")
    }

    @Test func clearingTheSelectionForgetsTheAnchor() {
        let state = makeState(["A", "B", "C", "D"])
        let id = ids(state)
        state.toggleSelection(id["A"]!)
        state.selection.removeAll()
        state.extendSelection(to: id["C"]!)
        #expect(selected(state) == ["C"])
    }

    @Test func selectedAppsAreListedOnce() {
        let state = makeState(["A", "B", "C"])
        let id = ids(state)
        state.toggleSelection(id["A"]!)
        state.toggleSelection(id["C"]!)
        #expect(state.orderedSelection == [id["A"]!, id["C"]!])
        #expect(state.targets(for: id["A"]!).count == 2, "the drag badge counts these")
    }

    @Test func movingToAFullPageKeepsTheItemsOnIt() {
        let state = makeState((1...36).map { "App\($0)" })
        state.apply { $0.normalize() } // 35 on the first page, one on the next
        let last = state.grid.pages[1].items[0].id
        state.moveToPage([last], page: 0)
        #expect(state.grid.pages[0].items.last?.id == last)
        #expect(state.grid.pages[1].items.map(\.title) == ["App35"], "the item it displaced")
    }

    @Test func pageTargetsFollowThePageNotItsPlace() {
        let state = makeState(["A", "B", "C"])
        state.apply { g in
            g.pages = g.allApps.map { Page(items: [.app($0)]) }
        }
        state.beginPageTitleEdit(2)
        let menuPage = state.grid.pages[2].id
        let a = state.grid.pages[0].items[0].id
        state.apply { $0.pages.remove(at: 1) } // as a rescan can, with the edit and a menu open
        state.commitTextEdit("Late")
        #expect(state.grid.pages.map(\.title) == [nil, "Late"], "the page it was opened for")

        state.apply { $0.pages.remove(at: 1) }
        state.moveToPage([a], pageID: menuPage)
        #expect(state.grid.pages.map { $0.items.map(\.title) } == [["A"]], "that page is gone: nothing moves")
        state.moveToPage([a], pageID: nil)
        #expect(state.grid.pages.map { $0.items.map(\.title) } == [["A"]], "onto a new page, emptying the old")
    }

    @Test func groupingNeedsTwoItems() {
        let state = makeState(["A", "B"])
        state.toggleSelection(ids(state)["A"]!)
        state.groupSelection()
        #expect(state.grid.pages[0].items.allSatisfy { $0.folder == nil })
    }

    @Test func groupingWithTheKeyboardMakesTheFolderOnThePageShown() {
        let state = makeState(["A", "B", "C", "D"])
        state.apply { $0.pages = [Page(items: Array($0.pages[0].items.prefix(2))), Page(items: Array($0.pages[0].items.suffix(2)))] }
        let id = ids(state)
        state.toggleSelection(id["A"]!)
        state.goToPage(1)
        state.toggleSelection(id["C"]!)
        state.toggleSelection(id["D"]!)
        state.groupSelection()
        #expect(state.grid.pages[1].items.first?.folder?.apps.map(\.name) == ["A", "C", "D"])
        #expect(state.currentPage == 1 && state.openFolderID == state.grid.pages[1].items.first?.id)
    }

    @Test func groupingTheLastItemOfAnotherPageRemovesThatPage() {
        let state = makeState(["A", "B", "C"])
        state.apply { $0.pages = [Page(items: Array($0.pages[0].items.prefix(1))), Page(items: Array($0.pages[0].items.suffix(2)))] }
        let id = ids(state)
        state.toggleSelection(id["A"]!)
        state.goToPage(1)
        state.toggleSelection(id["B"]!)
        state.groupSelection()
        #expect(state.grid.pages.count == 1, "no blank page where A was")
        #expect(state.grid.pages[0].items.map(\.title).contains("C"))
        #expect(state.currentPage == 0 && state.openFolderID == state.grid.pages[0].items.first { $0.folder != nil }?.id)
    }

    @Test func removingAFolderSaysHowManyAppsLeave() {
        let state = makeState(["A", "B", "C"])
        let id = ids(state)
        state.toggleSelection(id["A"]!)
        state.toggleSelection(id["B"]!)
        state.groupSelection()
        let folder = state.grid.pages[0].items.first { $0.folder != nil }!.id
        state.remove([folder])
        #expect(state.toast == "Removed 2 apps — ⌘Z to undo")
    }

    @Test func emptyingThePageShownGoesBackAPageAsDeletingItDoes() {
        let state = makeState()
        let pages = [["A", "B"], ["C", "D"], ["E", "F"]].map { Page(items: $0.map { .app(installed($0).makeRef()) }) }
        state.replaceGrid(Grid(rows: 5, columns: 7, pages: pages))
        state.currentPage = 1
        state.focusIndex = 1
        state.remove(state.currentItems.map(\.id))
        #expect(state.currentPage == 0)
        #expect(state.currentItems.map(\.title) == ["A", "B"])
        #expect(state.focusIndex == 1, "on the last item of the page shown now")
    }

    @Test func appsSelectedInsideASelectedFolderAreCountedOnce() {
        let state = makeState(["A", "B", "C"])
        let id = ids(state)
        state.toggleSelection(id["A"]!)
        state.toggleSelection(id["B"]!)
        state.groupSelection()
        let folder = state.grid.pages[0].items.first { $0.folder != nil }!.id
        state.remove([folder, id["A"]!, id["B"]!, id["C"]!])
        #expect(state.toast == "Removed 3 apps — ⌘Z to undo")
    }
}

@MainActor @Suite(.tempDir) struct PageActionTests {
    @Test func movingTheLastAppOutOfAFolderToItsOwnPageCanBeUndone() {
        let state = makeState()
        let x = installed("X").makeRef()
        let layout = Grid(rows: 1, columns: 3, pages: [Page(items: [
            .folder(Folder(name: "F", apps: [x])),
            .app(installed("A").makeRef()), .app(installed("B").makeRef()),
        ])])
        state.replaceGrid(layout)
        let original = state.grid

        state.moveToPage([x.id], page: 0)
        #expect(state.grid.pages.map { $0.items.map(\.title) } == [["A", "B", "X"]])
        state.undo()
        #expect(state.grid == original)
        state.redo()
        #expect(state.grid.pages.map { $0.items.map(\.title) } == [["A", "B", "X"]])
    }

    @Test func pageActionsClearTheSearchFirst() {
        // Over search results the ⋯ menu would otherwise sort a page nobody can see.
        let state = makeState(["C", "B", "A"])
        state.query = "a"
        state.sortCurrentPage()
        #expect(state.query.isEmpty)
        #expect(state.grid.pages[0].items.map(\.title) == ["A", "B", "C"])
    }

    @Test func aNewPageFromTheMenuClosesTheFolderOverIt() {
        let state = makeState(["A", "B", "C"])
        let a = state.grid.allApps[0].id, b = state.grid.allApps[1].id
        state.toggleSelection(a)
        state.toggleSelection(b)
        state.groupSelection()
        #expect(state.openFolderID != nil)
        state.newPage()
        #expect(state.openFolderID == nil && state.currentPage == 1)
    }

    @Test func sortingEverythingAlwaysSaysHowToUndo() {
        let state = makeState(["C", "B", "A"])
        state.sortEverything()
        #expect(state.toast == "Sorted everything — ⌘Z to undo")
        state.apply { $0.setPageTitle(0, "Work") }
        state.sortEverything()
        #expect(state.toast == "Sorted; page titles were cleared — ⌘Z to undo")
    }

    @Test func aCancelledDragLeavesFocusOnThePageShown() {
        let state = makeState(["A", "B", "C", "D", "E"])
        state.apply { $0.pages = [Page(items: Array($0.pages[0].items.prefix(4))), Page(items: Array($0.pages[0].items.suffix(1)))] }
        state.focusIndex = 3
        state.currentPage = 1 // as an edge flip leaves it
        state.cancelDrag()
        #expect(state.focusIndex == 0)
    }
}

@MainActor @Suite(.tempDir) struct ToastTests {
    @Test func aToastWhileHiddenWaitsForTheNextShow() async throws {
        let state = makeState(["A"])
        state.toastDuration = .milliseconds(100)
        state.showToast("Loaded layout")
        try await Task.sleep(for: .milliseconds(300))
        #expect(state.toast == "Loaded layout", "nobody has seen it yet")
        state.didShow()
        #expect(state.toast == "Loaded layout")
        // Waits longer on a busy machine (other tests share the main actor) rather than fail.
        for _ in 0..<30 where state.toast != nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(state.toast == nil, "dismissed once seen")
    }
}

@MainActor @Suite(.tempDir) struct SearchCountTests {
    @Test func searchResultsShowOnePageButCountEveryMatch() {
        let names = (1...50).map { "App \($0)" }
        let state = makeState([])
        state.replaceGrid(Grid(rows: 2, columns: 3, pages: [Page(items: names.map {
            .app(AppRef(bundleID: "com.test.\($0)", path: "/Applications/\($0).app", name: $0))
        })]))
        state.query = "app"
        #expect(state.searchResults.count == 6)
        #expect(state.allSearchResults.count == 50)
    }
}

@Suite struct WatcherTests {
    @Test(arguments: ["app", "APP", "App"])
    func bundleFilteringMatchesTheScannersExtensionRules(ext: String) {
        let app = "/Applications/Foo.\(ext)"
        #expect(FolderWatcher.isRelevant(app, roots: ["/Applications"]))
        #expect(FolderWatcher.isRelevant(app + "/Contents", roots: ["/Applications"]))
        #expect(!FolderWatcher.isRelevant(app + "/Contents/Resources", roots: ["/Applications"]))
        #expect(!FolderWatcher.isRelevant(app + "/Contents/Resources"))
        // Nested bundles are still scanned; their Contents updates must not be rejected
        // as plain folders beyond the depth limit.
        let nested = "/Applications/Tools/Foo.\(ext)"
        #expect(FolderWatcher.isRelevant(nested + "/Contents", roots: ["/Applications"]))
        #expect(!FolderWatcher.isRelevant(nested + "/Contents/Resources", roots: ["/Applications"]))
        // A scan root explicitly inside a bundle still gets its own changes.
        #expect(FolderWatcher.isRelevant(app + "/Contents/Applications", roots: [app + "/Contents/Applications"]))
    }

    @Test func ignoresChangesDeepInsideBundles() {
        #expect(FolderWatcher.isRelevant("/Applications/"))
        #expect(FolderWatcher.isRelevant("/Applications/Utilities/"))
        #expect(FolderWatcher.isRelevant("/Applications/Foo.app/"))
        #expect(FolderWatcher.isRelevant("/Applications/Foo.app/Contents/"))
        #expect(!FolderWatcher.isRelevant("/Applications/Foo.app/Contents/Resources/"))
        #expect(!FolderWatcher.isRelevant("/Applications/Foo.app/Contents/Frameworks/X.framework/Versions/A/"))
        let roots = ["/Users/me/Downloads", "/Applications"]
        #expect(FolderWatcher.isRelevant("/Users/me/Downloads/", roots: roots))
        #expect(FolderWatcher.isRelevant("/Users/me/Downloads/Tools/Old/", roots: roots), "the deepest folder the scan lists")
        #expect(!FolderWatcher.isRelevant("/Users/me/Downloads/a/b/c/", roots: roots), "deeper than the scan reads")
        #expect(!FolderWatcher.isRelevant("/Users/me/Downloads/project/.git/objects/", roots: roots))
        #expect(FolderWatcher.isRelevant("/Users/me/Downloads/Tools/Foo.app/", roots: roots))
        #expect(!FolderWatcher.isRelevant("/Users/me/Downloads/a/b/c/Foo.app/", roots: roots), "not scanned there")
        #expect(FolderWatcher.isRelevant("/private/elsewhere/x/y/z/", roots: roots), "outside the roots: rescan to be safe")
        let xcode = ["/Applications/Xcode.app/Contents/Applications"]
        #expect(FolderWatcher.isRelevant("/Applications/Xcode.app/Contents/Applications/", roots: xcode))
        #expect(FolderWatcher.isRelevant("/Applications/Xcode.app/Contents/Applications/Instruments.app/Contents/", roots: xcode))
        #expect(!FolderWatcher.isRelevant("/Applications/Xcode.app/Contents/Applications/Instruments.app/Contents/Resources/", roots: xcode))
    }

    @MainActor @Test func aFolderCreatedAfterWatchingStartsIsNoticed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let later = dir.appendingPathComponent("Applications").path
        var changes = 0
        let watcher = FolderWatcher(paths: [later], latency: 0.1) { changes += 1 }
        #expect(watcher.paths == [later])
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.createDirectory(atPath: later, withIntermediateDirectories: false)
        for _ in 0..<30 where changes == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(changes > 0, "creating ~/Applications, say, is noticed without waiting for the periodic rescan")
        _ = watcher
    }
}

@Suite struct IconTests {
    @Test func iconsOfAppsUpdatedInPlaceAreDropped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("Foo.app")
        let plist = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<plist><dict/></plist>".utf8).write(to: plist)
        defer { try? FileManager.default.removeItem(at: dir) }

        let icons = IconProvider()
        _ = await icons.icon(app.path)
        #expect(icons.cached(app.path) != nil)
        #expect(icons.dropStale([app.path]).isEmpty, "unchanged")

        try Data("<plist><dict><key>CFBundleVersion</key><string>2</string></dict></plist>".utf8).write(to: plist)
        #expect(icons.dropStale([app.path]) == [app.path])
        #expect(icons.cached(app.path) == nil)
    }
}

@MainActor @Suite(.tempDir) struct ChooseAppsTests {
    @Test func firstRunChoiceIsRememberedByTheBuild() {
        let dir = TempDir.url
        let state = AppState(prefs: testPreferences(), store: GridStore(url: dir.appendingPathComponent("grid.json")))
        state.catalogScanned(["A", "B", "C"].map(installed))
        #expect(state.includedPaths.count == 3)

        state.chooseApps(include: [], exclude: [installed("B")])
        #expect(!state.hasGridFile, "choosing alone doesn't create a layout")
        #expect(state.grid.allApps.isEmpty)
        #expect(state.includedPaths == ["/Applications/A.app", "/Applications/C.app"])

        state.build(style: .alphabetical)
        #expect(state.grid.allApps.map(\.name) == ["A", "C"])
        state.build(style: .byCategory)
        #expect(state.grid.allApps.map(\.name) == ["A", "C"], "rebuilds keep the exclusions")
        #expect(state.grid.removedBundleIDs == ["com.test.B"])
    }

    @Test func resizingBeforeTheFirstLayoutIsNotUndoneAfterIt() {
        let dir = TempDir.url
        let state = AppState(prefs: testPreferences(), store: GridStore(url: dir.appendingPathComponent("grid.json")))
        state.catalogScanned(["A", "B"].map(installed))
        state.resize(rows: 4, columns: 6)
        #expect(!state.canUndo)

        state.build(style: .alphabetical)
        #expect(state.grid.rows == 4 && state.grid.columns == 6)
        #expect(!state.canUndo, "nothing to go back to before the first layout")
        state.undo()
        #expect(state.grid.allApps.map(\.name) == ["A", "B"])
    }

    @Test func addingAppsBeforeTheFirstLayoutOnlyIncludesThem() {
        let dir = TempDir.url
        let state = AppState(prefs: testPreferences(), store: GridStore(url: dir.appendingPathComponent("grid.json")))
        state.catalogScanned(["A", "B", "C"].map(installed))
        state.chooseApps(include: [], exclude: [installed("B"), installed("C")])

        state.addApps([installed("B")])
        #expect(state.grid.allApps.isEmpty, "one app alone isn't the layout")
        #expect(!state.hasGridFile)
        _ = state.saveNow()
        #expect(!state.hasGridFile, "nor once saved")
        state.build(style: .alphabetical)
        #expect(state.grid.allApps.map(\.name) == ["A", "B"])
    }

    @Test func theExcludedCountIsOfInstalledAppsOffTheGrid() {
        let state = makeState(["A"])
        state.catalogScanned(["A", "B", "C"].map(installed))
        state.chooseApps(include: [], exclude: [installed("B")])
        var g = state.grid
        // An exclusion outliving its app, and a path entry beside its bundle ID, aren't apps to count.
        g.removedBundleIDs.formUnion(["com.test.Deleted", "/Applications/B.app"])
        state.apply { $0 = g }
        #expect(state.excludedApps.map(\.name) == ["B"])
    }

    @Test func changingTheChoiceLaterIsOneUndoStep() {
        let state = makeState(["A", "B"])
        state.catalogScanned(["A", "B", "C"].map(installed))
        #expect(state.grid.allApps.map(\.name) == ["A", "B", "C"])

        state.chooseApps(include: [], exclude: [installed("A"), installed("C")])
        #expect(state.grid.allApps.map(\.name) == ["B"])
        #expect(state.includedPaths == ["/Applications/B.app"])
        state.catalogScanned(["A", "B", "C"].map(installed))
        #expect(state.grid.allApps.map(\.name) == ["B"], "scans don't bring them back")

        state.chooseApps(include: [installed("C")], exclude: [])
        #expect(state.grid.allApps.map(\.name) == ["B", "C"])
        state.undo()
        #expect(state.grid.allApps.map(\.name) == ["B"])
    }

    @Test func aDeletedAppDoesNotBecomeTheCopyBesideIt() {
        let xcode = InstalledApp(bundleID: "com.test.xcode", path: "/Applications/LGTestXcode.app", name: "LGTestXcode")
        let beta = InstalledApp(bundleID: "com.test.xcode", path: "/Applications/LGTestXcode-beta.app", name: "LGTestXcode-beta")
        let state = makeState(["A"])
        state.prefs.autoAddApps = false
        state.catalogScanned([installed("A"), xcode])
        state.apply { $0.appendAtEnd([.app(xcode.makeRef())]) }
        state.catalogScanned([installed("A"), xcode, beta])
        state.catalogScanned([installed("A"), beta]) // Xcode deleted
        #expect(state.grid.allApps.map(\.name) == ["A"])
        #expect(state.missingApps == [beta])
    }

    @Test func copiesSharingABundleIDAreChosenSeparately() {
        let xcode = InstalledApp(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", name: "Xcode")
        let beta = InstalledApp(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode-beta.app", name: "Xcode-beta")
        let state = makeState(["A"])
        state.catalogScanned([installed("A"), xcode, beta])
        #expect(state.selectableApps.count == 3, "one row per copy")
        #expect(state.grid.allApps.map(\.name) == ["A", "Xcode", "Xcode-beta"])

        state.chooseApps(include: [], exclude: [beta])
        #expect(state.grid.allApps.map(\.name) == ["A", "Xcode"])
        #expect(state.grid.removedBundleIDs == [beta.path])
        state.catalogScanned([installed("A"), xcode, beta])
        #expect(state.grid.allApps.map(\.name) == ["A", "Xcode"], "scans keep only the beta out")

        state.chooseApps(include: [beta], exclude: [])
        #expect(state.grid.allApps.map(\.name) == ["A", "Xcode", "Xcode-beta"])
        #expect(state.grid.removedBundleIDs.isEmpty)
    }

    @Test func includingOneCopyOfAnExcludedBundleIDKeepsTheOtherOut() {
        let xcode = InstalledApp(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", name: "Xcode")
        let beta = InstalledApp(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode-beta.app", name: "Xcode-beta")
        let state = makeState(["A"])
        // A layout from before per-copy exclusions excluded the bundle ID, so both copies.
        var g = state.grid
        g.removedBundleIDs = ["com.apple.dt.Xcode"]
        state.replaceGrid(g)
        state.catalogScanned([installed("A"), xcode, beta])
        #expect(state.grid.allApps.map(\.name) == ["A"])
        state.chooseApps(include: [xcode], exclude: [])
        #expect(state.grid.allApps.map(\.name) == ["A", "Xcode"])
        #expect(state.grid.removedBundleIDs == [beta.path])
    }
}

@Suite struct LaunchFallbackTests {
    let xcode = AppRef(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", name: "Xcode")
    let beta = AppRef(bundleID: "com.apple.dt.Xcode", path: "/Volumes/Ext/Xcode-beta.app", name: "Xcode-beta")

    func grid(_ apps: AppRef...) -> Grid {
        Grid(rows: 5, columns: 7, pages: [Page(items: apps.map(GridItem.app))])
    }

    @Test func aMovedAppIsFollowed() {
        let moved = AppRef(bundleID: "com.test.A", path: "/Applications/A.app", name: "A")
        #expect(AppState.followsLaunch(to: "/Users/x/Applications/A.app", of: moved, in: grid(moved, xcode),
                                       isReachable: { _ in true }, pathExists: { _ in false }))
    }

    @Test func aTileDoesNotTakeOverAnotherTilesCopy() {
        #expect(!AppState.followsLaunch(to: xcode.path, of: beta, in: grid(xcode, beta),
                                        isReachable: { _ in true }, pathExists: { _ in false }),
                "Xcode-beta's tile opened Xcode: it must not become a second Xcode")
    }

    @Test func anUnreachableOrStillPresentAppIsNotRewritten() {
        #expect(!AppState.followsLaunch(to: xcode.path, of: beta, in: grid(beta),
                                        isReachable: { !$0.hasPrefix("/Volumes/Ext/") }, pathExists: { _ in false }))
        #expect(!AppState.followsLaunch(to: xcode.path, of: beta, in: grid(beta),
                                        isReachable: { _ in true }, pathExists: { _ in true }))
    }

    @Test func onlyPathsOnAnUnmountedVolumeAreUnmounted() {
        let name = "LaunchGridTest-\(UUID().uuidString)"
        #expect(Volume.unmountedVolume(for: "/Volumes/\(name)/Xcode-beta.app") == name)
        #expect(Volume.unmountedVolume(for: "/Applications/Xcode.app") == nil)
        #expect(Volume.unmountedVolume(for: "/Volumes") == nil)
    }

    @MainActor @Test func onlyOneCopyHoldsTheInstanceLock() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lg-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(AppDelegate.acquireInstanceLock(in: folder))
        #expect(!AppDelegate.acquireInstanceLock(in: folder), "a second copy starting meanwhile hands over")
    }

    @Test func theMountedVolumesComeFromTheSystem() throws {
        let names = try #require(Volume.mountedNames())
        #expect(names == Set(try FileManager.default.contentsOfDirectory(atPath: "/Volumes")))
        let startup = try #require(try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName)
        #expect(names.contains(startup), "the startup disk, linked to / from there")
    }
}

@Suite struct LayoutExclusionTests {
    @Test(arguments: [false, true])
    func loadingOneCopyKeepsOtherCopiesExcluded(exclusionInFile: Bool) {
        let stable = InstalledApp(bundleID: "com.test.editor", path: "/Applications/Editor.app", name: "Editor")
        let beta = InstalledApp(bundleID: stable.bundleID, path: "/Applications/Editor-beta.app", name: "Editor Beta")
        let file = Grid(pages: [Page(items: [.app(stable.makeRef())])],
                        removedBundleIDs: exclusionInFile ? [stable.key] : [])
        var merged = AppState.keepingExclusions(exclusionInFile ? [] : [stable.key], in: file, installed: [stable, beta])
        #expect(!merged.isExcluded(stable))
        #expect(merged.isExcluded(beta))
        _ = Reconciler.reconcile(&merged, installed: [stable, beta], autoAdd: true)
        #expect(merged.allApps.map(\.path) == [stable.path])

        // A layout explicitly containing both copies includes both, regardless of their order.
        var both = file
        both.pages[0].items.insert(.app(beta.makeRef()), at: 0)
        let included = AppState.keepingExclusions([stable.key], in: both, installed: [stable, beta])
        #expect(included.removedBundleIDs.isEmpty)
    }

    @Test func loadingALayoutKeepsCurrentExclusionsUnlessItHasThoseApps() {
        let a = AppRef(bundleID: "com.test.A", path: "/Applications/A.app", name: "A")
        let c = AppRef(bundleID: "com.test.C", path: "/Applications/C.app", name: "C")
        var file = Grid(rows: 5, columns: 7, pages: [Page(items: [.app(a), .app(c)])])
        file.removedBundleIDs = ["com.test.D"]
        let current: Set<String> = ["com.test.B", "/Applications/Xcode-beta.app", "com.test.C"]
        let merged = AppState.keepingExclusions(current, in: file)
        #expect(merged.removedBundleIDs == ["com.test.B", "/Applications/Xcode-beta.app", "com.test.D"])
        #expect(merged.allApps.map(\.name) == ["A", "C"])
    }
}

@Suite struct IconStaleTests {
    @Test func theGenericIconOfAMissingAppIsReplacedOnceItAppears() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("Foo.app")
        defer { try? FileManager.default.removeItem(at: dir) }

        let icons = IconProvider()
        _ = await icons.icon(app.path)
        #expect(icons.cached(app.path) != nil)
        #expect(icons.dropStale([app.path]).isEmpty, "still missing")

        let plist = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<plist><dict/></plist>".utf8).write(to: plist)
        #expect(icons.dropStale([app.path]) == [app.path])
        await icons.renderAll([app.path])
        #expect(icons.cached(app.path) != nil)
    }
}

@MainActor @Suite(.tempDir) struct RescanTests {
    @MainActor final class Log {
        var entries: [String] = []
    }

    @Test(.timeLimit(.minutes(1))) func completionsQueuedDuringAScanRunAfterTheScanThatServesThem() async throws {
        let state = makeState()
        let scans = OSAllocatedUnfairLock(initialState: 0)
        state.scanner = { _ in
            let n = scans.withLock { $0 += 1; return $0 }
            Thread.sleep(forTimeInterval: 0.1)
            return AppScanner.ScanResult(apps: n == 1 ? [installed("A")] : [installed("A"), installed("B")])
        }
        let log = Log()
        state.rescan { log.entries.append("first saw \(state.installed.count)") }
        state.rescan { log.entries.append("second saw \(state.installed.count)") }
        state.rescan { log.entries.append("third saw \(state.installed.count)") }
        // Other suites share the main actor. Wait for completion, with the test's time
        // limit bounding a genuine hang, instead of charging their work to a short deadline.
        while log.entries.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(log.entries == ["first saw 1", "second saw 2", "third saw 2"])
        #expect(scans.withLock { $0 } == 2, "requests during a scan share one more")
    }
}

@MainActor @Suite(.tempDir) struct HungScanTests {
    @Test(.timeLimit(.minutes(1))) func whatWaitsForAScanThatHangsGoesAheadAndTheScanStillCounts() async throws {
        let state = makeState()
        state.scanTimeout = .milliseconds(200)
        let scans = OSAllocatedUnfairLock(initialState: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() } // cancellation must also release the background worker
        state.scanner = { _ in
            let n = scans.withLock { $0 += 1; return $0 }
            // The first hangs, as a read of a volume that stopped answering does, until released.
            if n == 1 { release.wait() }
            return AppScanner.ScanResult(apps: n == 1 ? [installed("A")] : [installed("A"), installed("B")])
        }
        let log = RescanTests.Log()
        state.rescan { log.entries.append("launch saw \(state.installed.count)") }
        state.rescan { log.entries.append("queued saw \(state.installed.count)") }
        state.rescan()
        while log.entries.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(log.entries == ["launch saw 0", "queued saw 0"], "they went ahead without it")
        // The watchdog can run before a busy background queue even starts the scan.
        while scans.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(scans.withLock { $0 } == 1, "no second scan stuck behind the same read")
        state.rescan { log.entries.append("later saw \(state.installed.count)") }
        #expect(log.entries.last == "later saw 0", "one asked for now doesn't wait either")

        // It ends after all: taken in, its waiters not run twice, and the queued scan follows.
        release.signal()
        while state.installed.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(state.installed.map(\.name) == ["A", "B"])
        #expect(scans.withLock { $0 } == 2)
        #expect(log.entries.count == 3)
    }
}

@MainActor @Suite(.tempDir) struct ReplaceGridTests {
    @Test(arguments: [false, true])
    func replacingALayoutClearsFocusFromTheFolderItCloses(unchanged: Bool) {
        let state = makeState()
        let folder = Folder(name: "Work", apps: ["A", "B", "C"].map { installed($0).makeRef() })
        let layout = Grid(pages: [Page(items: [.folder(folder)])])
        state.replaceGrid(layout)
        state.openFolder(folder.id)
        state.focusIndex = 2

        var replacement = layout
        if !unchanged { replacement.pages[0].title = "Imported" }
        state.replaceGrid(replacement)

        #expect(state.openFolderID == nil)
        #expect(state.focusIndex == nil, "a closed folder's app index is not a top-level item index")
    }

    @Test func restartingWithOnlyPrunedAppsRestoresTheExistingLayout() throws {
        let state = makeState(["A"])
        state.prefs.autoAddApps = false
        let a = try #require(state.grid.allApps.first)
        state.apply { $0.rename(a.id, to: "My App") }
        let pageID = state.grid.pages[0].id
        state.catalogScanned([installed("B")])
        #expect(state.grid.allApps.isEmpty)
        #expect(state.grid.recentlyPruned.count == 1)
        #expect(state.saveNow())

        let reopened = AppState(prefs: state.prefs, store: state.store)
        #expect(reopened.hasGridFile, "a temporarily empty layout is not a first launch")
        reopened.catalogScanned([installed("A"), installed("B")])
        #expect(reopened.grid.allApps.map(\.id) == [a.id])
        #expect(reopened.grid.allApps.map(\.title) == ["My App"])
        #expect(reopened.grid.pages[0].id == pageID)
    }

    @Test func replacingAnEmptyGridDropsItsRedoHistory() {
        let state = makeState()
        state.newPage()
        state.undo()
        #expect(state.canRedo)
        state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: [.app(installed("A").makeRef())])]))
        #expect(!state.canRedo)
        state.redo()
        #expect(state.grid.allApps.map(\.name) == ["A"], "redo must not bring back the empty grid")
    }
}

@MainActor @Suite(.tempDir) struct FocusContinuityTests {
    @Test func aRescanKeepsFocusOnTheSameApp() throws {
        let state = makeState(["A", "B", "C"])
        state.prefs.autoAddApps = false
        state.focusIndex = 1
        let focused = state.grid.allApps[1].id
        state.catalogScanned([installed("B"), installed("C")],
                             outside: AppState.OutsideRead(checked: [installed("A").path]),
                             disk: DiskState(mountedVolumes: []))
        #expect(state.currentItems.map(\.title) == ["B", "C"])
        let index = try #require(state.focusIndex)
        #expect(state.currentItems[index].id == focused)
    }

    @Test func sortingAndUndoKeepFocusOnTheSameApp() throws {
        let state = makeState(["C", "A", "B"])
        let focused = state.grid.allApps[0].id
        state.focusIndex = 0
        state.sortCurrentPage()
        #expect(state.currentItems[try #require(state.focusIndex)].id == focused)
        state.undo()
        #expect(state.currentItems[try #require(state.focusIndex)].id == focused)
        state.redo()
        #expect(state.currentItems[try #require(state.focusIndex)].id == focused)
    }

    @Test func removingAnEarlierSearchResultKeepsTheFocusedResult() throws {
        let state = makeState(["App A", "App B", "App C"])
        let focused = state.grid.allApps[1].id
        state.query = "App"
        state.focusIndex = 1
        state.remove([state.grid.allApps[0].id])
        #expect(state.searchResults[try #require(state.focusIndex)].id == focused)
    }

    @Test func removingAnEarlierFolderAppKeepsFocusVisibleAcrossPages() throws {
        let state = makeState()
        let refs = (1...30).map { installed("App\($0)").makeRef() }
        let folder = Folder(name: "F", apps: refs)
        state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: [.folder(folder)])]))
        state.openFolder(folder.id)
        state.folderPage = 1
        state.focusIndex = 28
        state.remove([refs[0].id])
        #expect(state.openFolder?.apps[try #require(state.focusIndex)].id == refs[28].id)
        #expect(state.folderPage == 0, "the focused app moved to the previous folder page")
    }

    @Test func removingTheFocusedAppFocusesItsSuccessor() throws {
        let state = makeState(["A", "B", "C"])
        state.focusIndex = 1
        state.remove([state.grid.allApps[1].id])
        #expect(state.currentItems[try #require(state.focusIndex)].title == "C")
    }
}

@MainActor @Suite(.tempDir) struct FolderPageTests {
    @Test func anOpenFolderFollowsItsPageWhenAnInsertionSpillsIt() throws {
        let state = makeState()
        let folder = Folder(name: "F", apps: [installed("A").makeRef()])
        state.replaceGrid(Grid(rows: 1, columns: 2, pages: [
            Page(items: [.app(installed("B").makeRef()), .folder(folder)]),
            Page(items: [.app(installed("C").makeRef())]),
        ]))
        state.openFolder(folder.id)
        // Restoring a temporarily missing app can insert ahead of the open folder.
        state.apply { $0.insert([.app(installed("Returning").makeRef())], page: 0, at: 0) }
        let location = try #require(state.grid.locate(folder.id))
        #expect(location.page == 1)
        #expect(state.currentPage == location.page, "the folder stays over the page containing its icon")
        state.closeFolder(restoringFocus: true)
        let focus = try #require(state.focusIndex)
        #expect(state.currentItems[safe: focus]?.id == folder.id)
    }

    @Test(arguments: [2, 5])
    func resizingKeepsTheFocusedFolderAppVisible(rows: Int) {
        let state = makeState()
        let refs = (1...20).map { installed("App\($0)").makeRef() }
        let folder = Folder(name: "F", apps: refs)
        state.replaceGrid(Grid(rows: 3, columns: 2, pages: [Page(items: [.folder(folder)])]))
        state.openFolder(folder.id)
        state.folderPage = 1
        state.focusIndex = 5

        state.resize(rows: rows, columns: 2)
        #expect(state.focusIndex == 5)
        #expect(state.folderPage == 5 / FolderLayout.perPage(state.grid))
        state.undo()
        #expect(state.folderPage == 1)
        state.redo()
        #expect(state.folderPage == 5 / FolderLayout.perPage(state.grid))
    }

    @Test func removingTheLastPagesOnlyAppMovesBackAPage() {
        let state = makeState()
        let refs = (1...29).map { installed("App\($0)").makeRef() }
        let folder = Folder(name: "F", apps: refs)
        state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: [.folder(folder)])])) // 28 per folder page
        state.openFolder(folder.id)
        state.folderPage = 1
        state.focusIndex = 28
        state.remove([refs[28].id])
        #expect(state.openFolderID == folder.id)
        #expect(state.folderPage == 0)
        #expect(state.focusIndex == 27)
    }

    @Test func turningAFolderPageKeepsFocusOnTheShownPage() {
        let state = makeState()
        let refs = (1...30).map { installed("App\($0)").makeRef() }
        let folder = Folder(name: "F", apps: refs)
        state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: [.folder(folder)])])) // 28 per folder page
        state.openFolder(folder.id)
        state.focusIndex = 1
        state.flipPage(1)
        #expect(state.folderPage == 1)
        #expect(state.focusIndex == 29, "the same slot on page 2")
        state.focusIndex = 28
        state.flipPage(-1)
        #expect(state.focusIndex == 0)
        state.focusIndex = 5
        state.flipPage(1)
        #expect(state.focusIndex == 29, "clamped to the last app when the slot is empty")
    }
}

@MainActor @Suite(.tempDir) struct SaveTests {
    func savedTitles(_ state: AppState) throws -> [String] {
        try GridStore.decode(Data(contentsOf: state.store.url)).allApps.map(\.title)
    }

    @Test func changesAreSavedShortlyAfterAndFlushedOnQuit() async throws {
        let state = makeState(["A"])
        state.saveNow()
        let a = try #require(state.grid.allApps.first)
        state.apply { $0.rename(a.id, to: "Renamed") }
        #expect(try savedTitles(state) == ["A"], "saves are debounced")
        // Half a second after the change; waits longer on a busy machine rather than fail.
        for _ in 0..<30 where try savedTitles(state) != ["Renamed"] { try await Task.sleep(for: .milliseconds(100)) }
        #expect(try savedTitles(state) == ["Renamed"])

        state.apply { $0.rename(a.id, to: "Again") }
        state.saveNow(reportingFailure: false) // what quitting does
        #expect(try savedTitles(state) == ["Again"])
    }

    @Test func aDelayedSaveIsRecordedAndItsFailureReported() async throws {
        let state = makeState(["A"])
        state.saveNow()
        var errors = 0
        state.onError = { _, _ in errors += 1 }
        let a = try #require(state.grid.allApps.first)
        let folder = state.store.url.deletingLastPathComponent().path
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        state.apply { $0.rename(a.id, to: "Renamed") }
        state.saveInBackground() // as the delayed save after a change does: no completion
        for _ in 0..<50 where errors == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(errors == 1)
        #expect(state.lastSaveError != nil)
    }

    @Test func aFailedSaveCoveredByALaterOneOfTheSameGridIsNotReported() async throws {
        let state = makeState(["A"])
        state.saveNow()
        var errors = 0
        state.onError = { _, _ in errors += 1 }
        let a = try #require(state.grid.allApps.first)
        state.apply { $0.rename(a.id, to: "Renamed") }
        let folder = state.store.url.deletingLastPathComponent().path
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        // As hiding does while the delayed save is under way: the same grid queued twice, the
        // first write failing and the second one working.
        var results: [Bool] = []
        state.saveInBackground { results.append($0) }
        state.writer.queue.async { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        state.saveInBackground { results.append($0) }
        for _ in 0..<50 where results.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(results == [true, true])
        #expect(errors == 0)
        #expect(state.lastSaveError == nil)
        #expect(try savedTitles(state) == ["Renamed"])
    }

    @Test func backgroundSavesLandInOrderWithOnesMadeAtOnce() async throws {
        let state = makeState(["A"])
        state.saveNow()
        let a = try #require(state.grid.allApps.first)
        state.apply { $0.rename(a.id, to: "One") }
        let first = await withCheckedContinuation { done in state.saveInBackground { done.resume(returning: $0) } }
        #expect(first)
        #expect(try savedTitles(state) == ["One"])

        state.apply { $0.rename(a.id, to: "Two") }
        var finished: Bool?
        state.saveInBackground { finished = $0 }
        state.apply { $0.rename(a.id, to: "Three") }
        #expect(state.saveNow(reportingFailure: false), "quitting waits for the one under way")
        #expect(try savedTitles(state) == ["Three"])
        for _ in 0..<50 where finished == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(finished == true)
        #expect(try savedTitles(state) == ["Three"], "the older save didn't land after it")
        #expect(state.saveNow(), "nothing left to write")
    }

    @Test func anUnchangedGridIsNotSavedAgain() throws {
        let state = makeState(["A"])
        state.saveNow()
        let a = try #require(state.grid.allApps.first)
        state.apply { $0.rename(a.id, to: "Renamed") }
        state.saveNow()
        state.saveNow() // as each hide and quitting do
        #expect(try savedTitles(state) == ["Renamed"])
        #expect(try state.store.loadBackup().allApps.map(\.title) == ["A"], "still the save before it")

        let reopened = AppState(prefs: testPreferences(), store: state.store)
        reopened.saveNow()
        #expect(try reopened.store.loadBackup().allApps.map(\.title) == ["A"], "nothing changed since loading")
    }

    @Test func exclusionsChosenBeforeTheFirstLayoutAreKept() {
        let url = TempDir.url.appendingPathComponent("grid.json")
        let state = AppState(prefs: testPreferences(), store: GridStore(url: url))
        state.catalogScanned(["A", "B"].map(installed))
        state.chooseApps(include: [], exclude: [installed("B")])
        state.saveNow()

        let reopened = AppState(prefs: testPreferences(), store: GridStore(url: url))
        #expect(!reopened.hasGridFile, "the welcome window still has to make the layout")
        #expect(reopened.grid.removedBundleIDs == ["com.test.B"])
    }

    @Test func anUnreadableLayoutThatCannotBeMovedAsideIsNotSavedOver() throws {
        let dir = TempDir.url
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("grid.json")
        try Data("not json".utf8).write(to: url)
        // Take every backup name the next seconds could use, so the move fails.
        let now = Int(Date().timeIntervalSince1970)
        for t in (now - 2)...(now + 30) {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("grid.corrupt-\(t).json"),
                                                    withIntermediateDirectories: true)
        }
        let state = AppState(prefs: testPreferences(), store: GridStore(url: url))
        #expect(state.loadProblem?.backup == url)

        state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: [.app(installed("A").makeRef())])]))
        #expect(!state.saveNow(reportingFailure: false), "not saved, so quitting asks first")
        #expect(state.lastSaveError != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")

        try FileManager.default.removeItem(at: url) // the user moved it away
        state.saveNow()
        #expect(try savedTitles(state) == ["A"])
    }
}

@MainActor @Suite(.tempDir) struct UnlistedFolderTests {
    @Test(arguments: [false, true], [false, true])
    func unreadableDirectoriesProtectTilesThroughEveryAlias(aliasFirst: Bool, nested: Bool) throws {
        let fm = FileManager.default
        let root = TempDir.url.appendingPathComponent("Real")
        let locked = nested ? root.appendingPathComponent("Locked") : root
        let alias = TempDir.url.appendingPathComponent("Alias")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: root)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let roots = aliasFirst ? [alias, root] : [root, alias]
        let result = AppScanner.scanReporting(roots: roots)
        let parents = [locked, nested ? alias.appendingPathComponent("Locked") : alias]
        let refs = parents.enumerated().map { i, parent in
            AppRef(bundleID: "com.test.locked\(i)", path: parent.appendingPathComponent("App\(i).app").path)
        }
        for ref in refs {
            #expect(!AppState.isReachable(ref.path, unreachableFolders: result.unlisted))
        }
        // A successful scan elsewhere must not turn the inaccessible apps into removals.
        var grid = Grid(pages: [Page(items: refs.map(GridItem.app))])
        _ = Reconciler.reconcile(&grid, installed: [installed("Other")], autoAdd: false,
                                isReachable: { AppState.isReachable($0, unreachableFolders: result.unlisted) },
                                pathExists: { _ in false })
        #expect(grid.allApps == refs)
        #expect(grid.recentlyPruned.isEmpty)
    }

    @Test func theScannerReportsFoldersItCouldNotList() throws {
        let root = TempDir.url.appendingPathComponent("Apps")
        let locked = root.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let missing = TempDir.url.appendingPathComponent("Missing")

        let result = AppScanner.scanReporting(roots: [root, missing])
        #expect(result.apps.isEmpty)
        // Folders found in a listing are named as the listing names them (/private/var, here).
        #expect(Set(result.unlisted.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
            == Set([locked.resolvingSymlinksInPath().path, missing.resolvingSymlinksInPath().path]))
    }

    @Test func aTileNotReadYetIsKeptUntilABackgroundReadFindsItGone() async throws {
        let state = makeState(["A"])
        state.catalogScanned([installed("A")])
        var g = state.grid
        g.pages[0].items.append(.app(AppRef(bundleID: "com.test.B", path: "/Users/x/Gone/B.app", name: "B")))
        state.replaceGrid(g) // as an undo or a load brings back a tile from outside the scan folders
        #expect(state.grid.allApps.map(\.name) == ["A", "B"], "not read yet: no disk access on the main thread")
        for _ in 0..<50 where state.grid.allApps.count > 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(state.grid.allApps.map(\.name) == ["A"], "read off the main thread, found gone")
    }

    @Test func appsUnderAFolderTheScanCouldNotListAreKept() {
        let state = makeState(["A"])
        var g = state.grid
        g.pages[0].items.append(.app(AppRef(bundleID: "com.test.B", path: "/Volumes/NAS/Apps/B.app", name: "B")))
        g.pages[0].items.append(.app(AppRef(bundleID: "com.test.C", path: "/Users/x/Denied/C.app", name: "C")))
        state.replaceGrid(g)

        state.catalogScanned([installed("A")], unlisted: ["/Users/x/Denied"])
        #expect(state.grid.allApps.map(\.name) == ["A", "B", "C"], "B's volume isn't mounted; C's folder couldn't be listed")
        state.catalogScanned([installed("A")])
        #expect(state.grid.allApps.map(\.name) == ["A", "B"], "once listed, C's absence counts")
    }
}

@MainActor @Suite(.tempDir) struct OutsideAppTests {
    @Test func loadingAnOlderSpellingOfAKnownAppKeepsItsTile() async throws {
        let state = makeState()
        state.prefs.autoAddApps = false
        let scanned = installed("Zoom.us")
        let old = "/Applications/zoom.us.app"
        let ref = AppRef(bundleID: scanned.bundleID, path: old, name: "zoom.us", displayName: "Meetings")
        // The app is already known before loading the older layout.
        state.catalogScanned([scanned])
        state.catalogScanned([scanned])
        state.outsideReader = { paths in
            AppState.OutsideRead(checked: Set(paths), existing: [old])
        }
        state.replaceGrid(Grid(pages: [Page(items: [.app(ref)])]))
        while !state.outsideReading.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(state.grid.allApps.map(\.id) == [ref.id])
        #expect(state.grid.allApps.map(\.path) == [scanned.path])
        #expect(state.grid.allApps.first?.displayName == "Meetings")
        #expect(state.grid.recentlyPruned.isEmpty)
    }

    @Test func aScanChecksAnExcludedAppsOlderSpelling() throws {
        let path = try makeBundle("Zoom.us")
        let old = (path as NSString).deletingLastPathComponent + "/zoom.us.app"
        // Use a real alternate path on either filesystem format.
        if !FileManager.default.fileExists(atPath: old) {
            try FileManager.default.createSymbolicLink(atPath: old, withDestinationPath: path)
        }
        let scanned = InstalledApp(bundleID: "com.test.Zoom.us", path: path, name: "Zoom.us")
        let state = makeState()
        state.prefs.autoAddApps = false
        state.catalogScanned([scanned])
        state.apply { $0.removedBundleIDs.insert(old) }
        state.catalogScanned([scanned])

        #expect(state.grid.removedBundleIDs == [path])
        #expect(state.grid.allApps.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func olderOutsideReadsDoNotReplaceNewerScanResults(deleted: Bool, coveredByScan: Bool) async throws {
        let state = makeState(["A"])
        state.prefs.autoAddApps = false
        state.catalogScanned([installed("A")])
        let outside = InstalledApp(bundleID: "com.test.Outside", path: "/Elsewhere/Outside.app", name: "Outside")
        let updated = InstalledApp(bundleID: outside.bundleID, path: outside.path, name: "Updated")
        let latest = AppState.OutsideRead(apps: deleted ? [:] : [outside.path: updated], checked: [outside.path],
                                        existing: deleted ? [] : [outside.path])
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        state.outsideReader = { paths in
            let first = reads.withLock { $0 += 1; return $0 == 1 }
            if !first { return latest }
            release.wait()
            return AppState.OutsideRead(apps: [outside.path: outside], checked: Set(paths), existing: [outside.path])
        }
        var grid = state.grid
        grid.pages[0].items.append(.app(outside.makeRef()))
        state.replaceGrid(grid)
        while reads.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }

        // A newer scan supersedes this read. It may have started before the tile was added,
        // in which case it doesn't cover the outside app and a fresh read is needed.
        state.catalogScanned([installed("A")], outside: coveredByScan ? latest : AppState.OutsideRead())
        release.signal()
        while !state.outsideReading.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(state.grid.allApps.map(\.name) == (deleted ? ["A"] : ["A", "Updated"]))
        #expect(state.grid.recentlyPruned.map(\.app.path) == (deleted ? [outside.path] : []))
        #expect(reads.withLock { $0 } == (coveredByScan ? 1 : 2))
    }

    @Test func missingAppsUsesTheCachedExistenceOfAnOutsideCopy() {
        let state = makeState()
        state.prefs.autoAddApps = false
        let original = InstalledApp(bundleID: "com.test.A", path: "/Elsewhere/A.app", name: "A")
        let copy = installed("A")
        state.replaceGrid(Grid(pages: [Page(items: [.app(original.makeRef())])]))
        state.catalogScanned([copy], outside: AppState.OutsideRead(
            apps: [original.path: original], checked: [original.path], existing: [original.path]))

        #expect(state.grid.allApps.map(\.path) == [original.path])
        #expect(state.missingApps == [copy], "an existing outside copy does not claim the scanned copy")
    }

    /// A minimal app bundle in the test's folder, outside every scan folder.
    func makeBundle(_ name: String) throws -> String {
        let app = TempDir.url.appendingPathComponent("Elsewhere/\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "com.test.\(name)", "CFBundleName": name]
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        return app.path
    }

    @Test func anAppRenamedInOtherCapitalsIsNotReadAsAnotherAppOutsideTheScan() throws {
        // The tile's old spelling still opens the app on a disk that ignores case, so reading it
        // as an app from elsewhere would keep the tile there and add the new spelling beside it.
        let path = try makeBundle("Zoom.us")
        let old = (path as NSString).deletingLastPathComponent + "/zoom.us.app"
        let state = makeState()
        state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: [.app(AppRef(bundleID: "com.test.Zoom.us", path: old, name: "zoom.us"))])]))
        state.catalogScanned([InstalledApp(bundleID: "com.test.Zoom.us", path: path, name: "Zoom.us")])
        #expect(state.grid.allApps.map(\.path) == [path])
    }

    @Test func rebuildingKeepsAppsAddedFromOutsideTheScanFolders() throws {
        let path = try makeBundle("Outside")
        let state = makeState(["A"])
        state.catalogScanned(["A", "B"].map(installed))
        state.addApps([InstalledApp(bundleID: "com.test.Outside", path: path, name: "Outside")])
        #expect(state.grid.allApps.map(\.name) == ["A", "B", "Outside"])

        state.build(style: .alphabetical)
        #expect(state.grid.allApps.map(\.name) == ["A", "B", "Outside"])
        #expect(state.selectableApps.map(\.path).contains(path), "still offered in Choose Apps")
    }
}

@MainActor @Suite(.tempDir) struct WelcomeExclusionTests {
    @Test(arguments: [false, true])
    func removingEveryAppDoesNotRestartSetup(legacy: Bool) throws {
        let state = makeState(["A"])
        if legacy {
            var old = state.grid
            old.hasCreatedLayout = false
            try state.store.save(old)
        }
        let editing = legacy ? AppState(prefs: testPreferences(), store: state.store) : state
        editing.remove(editing.grid.allApps.map(\.id))
        #expect(editing.saveNow())

        let reopened = AppState(prefs: testPreferences(), store: state.store)
        #expect(reopened.hasGridFile, "an intentionally empty layout has already completed setup")
        #expect(reopened.grid.allApps.isEmpty)
        reopened.catalogScanned([installed("A"), installed("B")])
        #expect(reopened.grid.allApps.map(\.name) == ["B"], "new apps still reconcile into the existing layout")
    }

    @Test func anExplicitlyEmptyLayoutSurvivesRelaunch() {
        let state = makeState()
        state.apply { $0.setPageTitle(0, "Work") }
        #expect(state.saveNow())

        let reopened = AppState(prefs: testPreferences(), store: state.store)
        #expect(reopened.hasGridFile)
        #expect(reopened.grid.pages.first?.title == "Work")
    }

    @Test func savedWelcomeChoicesStillNeedSetup() {
        let state = AppState(prefs: testPreferences(), store: GridStore(url: TempDir.url.appendingPathComponent("grid.json")))
        state.chooseApps(include: [], exclude: [installed("A")])
        #expect(state.saveNow())

        let reopened = AppState(prefs: testPreferences(), store: state.store)
        #expect(!reopened.hasGridFile)
        #expect(reopened.grid.isExcluded(installed("A")))
    }

    @Test func includingTheLastExcludedAppAgainIsSaved() {
        let url = TempDir.url.appendingPathComponent("grid.json")
        let state = AppState(prefs: testPreferences(), store: GridStore(url: url))
        state.catalogScanned(["A", "B"].map(installed))
        state.chooseApps(include: [], exclude: [installed("B")])
        state.saveNow()
        state.chooseApps(include: [installed("B")], exclude: [])
        state.saveNow()

        let reopened = AppState(prefs: testPreferences(), store: GridStore(url: url))
        #expect(reopened.grid.removedBundleIDs.isEmpty)
    }
}

/// The sandbox's bookmarks, played out of the sandbox: a bookmark is the path it was made
/// for, and resolves to wherever `moves` says that item is now.
@MainActor final class FakeSandbox {
    var moves: [String: String] = [:]
    var gone: Set<String> = []
    private(set) var closed: [String] = []
    /// Bookmarks resolved and started, by the path each was made for.
    private(set) var opened: [String] = []

    func install() {
        let defaults = UserDefaults(suiteName: TempDir.suiteName(for: TempDir.url))!
        FileAccess.backend = FileAccess.Backend(
            isActive: { true },
            defaults: { defaults },
            bookmark: { Data($0.path.utf8) },
            open: { [self] data in
                let path = String(decoding: data, as: UTF8.self)
                opened.append(path)
                let now = moves[path] ?? path
                guard !gone.contains(now) else { return nil }
                return (URL(fileURLWithPath: now), now != path)
            },
            close: { [self] in closed.append($0.path) }
        )
    }

    var saved: [String: Data] {
        FileAccess.backend.defaults().dictionary(forKey: "bookmarks") as? [String: Data] ?? [:]
    }
}

// Serialized: `FileAccess` is one for the whole process.
@MainActor @Suite(.tempDir, .serialized) struct SandboxFileAccessTests {
    let sandbox = FakeSandbox()

    @Test func anAppPickedByPathIsUsedThroughItsBookmark() {
        // Browse hands over a URL made from a path, whose own access can't be started.
        sandbox.install()
        defer { FileAccess.reset() }
        #expect(FileAccess.remember(URL(fileURLWithPath: "/Users/x/Downloads/A.app")))
        #expect(FileAccess.isGranted("/Users/x/Downloads/A.app"))
        #expect(sandbox.opened == ["/Users/x/Downloads/A.app"], "access through the bookmark, not the plain URL")
        #expect(sandbox.saved.keys.sorted() == ["/Users/x/Downloads/A.app"])
    }

    @Test func anItemMovedSinceItWasPickedIsFollowed() {
        sandbox.install()
        defer { FileAccess.reset() }
        let prefs = testPreferences()
        prefs.extraFolders = ["/Users/x/Tools"]
        FileAccess.remember(URL(fileURLWithPath: "/Users/x/Tools"))
        FileAccess.reset()
        sandbox.install() // a later launch
        sandbox.moves["/Users/x/Tools"] = "/Users/x/Utilities"
        #expect(FileAccess.restore(prefs: prefs) == ["/Users/x/Tools": "/Users/x/Utilities"])
        #expect(FileAccess.isGranted("/Users/x/Utilities") && !FileAccess.isGranted("/Users/x/Tools"))
        #expect(sandbox.saved.keys.sorted() == ["/Users/x/Utilities"], "filed under its new path")
        #expect(prefs.extraFolders == ["/Users/x/Utilities"])
    }

    @Test func anItemInTheTrashIsNotFollowed() {
        sandbox.install()
        defer { FileAccess.reset() }
        let prefs = testPreferences()
        prefs.customImagePath = "/Users/x/bg.jpg"
        FileAccess.remember(URL(fileURLWithPath: "/Users/x/bg.jpg"))
        FileAccess.reset()
        sandbox.install()
        sandbox.moves["/Users/x/bg.jpg"] = "/Users/x/.Trash/bg.jpg"
        #expect(FileAccess.restore(prefs: prefs).isEmpty)
        #expect(prefs.customImagePath == "/Users/x/bg.jpg")
        #expect(sandbox.saved.keys.sorted() == ["/Users/x/bg.jpg"])
    }

    @Test(arguments: [false, true])
    func bookmarksMovingIntoEachOthersOldPathsKeepTheirAccess(swapping: Bool) {
        sandbox.install()
        defer { FileAccess.reset() }
        let prefs = testPreferences()
        let a = "/Users/x/A.app", b = "/Users/x/B.app", c = "/Users/x/C.app"
        for path in [a, b] { FileAccess.remember(URL(fileURLWithPath: path)) }
        FileAccess.reset()
        sandbox.install() // Both apps moved while LaunchGrid was closed.
        let moves = [a: b, b: swapping ? a : c]
        sandbox.moves = moves

        #expect(FileAccess.restore(prefs: prefs) == moves)
        #expect(Set(sandbox.saved.keys) == Set(moves.values))
        for path in moves.values { #expect(FileAccess.isGranted(path)) }

        // The refreshed bookmarks must also work on the next launch.
        FileAccess.reset()
        sandbox.moves = [:]
        sandbox.install()
        #expect(FileAccess.restore(prefs: prefs).isEmpty)
        for path in moves.values { #expect(FileAccess.isGranted(path)) }
    }

    @Test func settingsFollowEachBookmarkMoveOnlyOnce() {
        sandbox.install()
        defer { FileAccess.reset() }
        let prefs = testPreferences()
        let a = "/Users/x/Tools", b = "/Users/x/Utilities"
        prefs.extraFolders = [a, b]
        for path in [a, b] { FileAccess.remember(URL(fileURLWithPath: path)) }
        FileAccess.reset()
        sandbox.install()
        sandbox.moves = [a: b, b: a]

        #expect(FileAccess.restore(prefs: prefs) == sandbox.moves)
        #expect(prefs.extraFolders == [b, a], "each folder follows its own bookmark once")
    }

    @Test func anItemPickedAgainAtItsNewPlaceKeepsOneBookmark() {
        sandbox.install()
        defer { FileAccess.reset() }
        let prefs = testPreferences()
        FileAccess.remember(URL(fileURLWithPath: "/Users/x/A.app"))
        FileAccess.remember(URL(fileURLWithPath: "/Users/x/Apps/A.app"))
        FileAccess.reset()
        sandbox.install()
        sandbox.moves["/Users/x/A.app"] = "/Users/x/Apps/A.app"
        let closedBefore = sandbox.closed.count
        #expect(FileAccess.restore(prefs: prefs) == ["/Users/x/A.app": "/Users/x/Apps/A.app"])
        #expect(sandbox.saved.keys.sorted() == ["/Users/x/Apps/A.app"])
        #expect(sandbox.closed.dropFirst(closedBefore) == ["/Users/x/Apps/A.app"], "one access for it, not two")
        #expect(FileAccess.isGranted("/Users/x/Apps/A.app"))
    }

    @Test func anAppMovedWhileInUseIsFollowed() {
        sandbox.install()
        defer { FileAccess.reset() }
        let prefs = testPreferences()
        FileAccess.remember(URL(fileURLWithPath: "/Users/x/Downloads/A.app"))
        sandbox.moves["/Users/x/Downloads/A.app"] = "/Users/x/Apps/A.app"
        #expect(FileAccess.followVanished(["/Users/x/Downloads/A.app", "/Applications/B.app"], prefs: prefs)
            == ["/Users/x/Downloads/A.app": "/Users/x/Apps/A.app"])
        #expect(FileAccess.isGranted("/Users/x/Apps/A.app"))
        #expect(sandbox.saved.keys.sorted() == ["/Users/x/Apps/A.app"])
    }

    @Test func anAppMovedWhileInUseIsFollowedThroughABookmarkAScanResolved() throws {
        sandbox.install()
        defer { FileAccess.reset() }
        let prefs = testPreferences()
        FileAccess.remember(URL(fileURLWithPath: "/Users/x/Downloads/A.app"))
        FileAccess.remember(URL(fileURLWithPath: "/Users/x/Downloads/C.app"))
        // As a scan resolves them off the main thread: A moved; C, resolved too, is still there.
        let reopened = ["/Users/x/Downloads/A.app": FileAccess.Opened(url: URL(fileURLWithPath: "/Users/x/Apps/A.app"), stale: true),
                        "/Users/x/Downloads/C.app": FileAccess.Opened(url: URL(fileURLWithPath: "/Users/x/Downloads/C.app"), stale: false)]
        let opened = sandbox.opened.count
        #expect(FileAccess.followVanished(["/Users/x/Downloads/A.app"], prefs: prefs, reopened: reopened)
            == ["/Users/x/Downloads/A.app": "/Users/x/Apps/A.app"])
        #expect(sandbox.opened.count == opened, "nothing resolved again on the main thread")
        #expect(FileAccess.isGranted("/Users/x/Apps/A.app"))
        #expect(FileAccess.isGranted("/Users/x/Downloads/C.app"), "its own access kept")
        #expect(sandbox.closed.filter { $0 == "/Users/x/Downloads/C.app" }.count == 1, "the second access to it ended")
        #expect(sandbox.saved.keys.sorted() == ["/Users/x/Apps/A.app", "/Users/x/Downloads/C.app"])
    }

    @Test func aStaleBookmarkIsRemadeAndAnUnreachableOneKept() {
        sandbox.install()
        defer { FileAccess.reset() }
        let prefs = testPreferences()
        FileAccess.remember(URL(fileURLWithPath: "/Volumes/Ext/Apps"))
        FileAccess.reset()
        sandbox.install()
        sandbox.gone = ["/Volumes/Ext/Apps"] // unmounted
        #expect(FileAccess.restore(prefs: prefs).isEmpty)
        #expect(!FileAccess.isGranted("/Volumes/Ext/Apps"))
        #expect(sandbox.saved.keys.sorted() == ["/Volumes/Ext/Apps"], "kept for when it mounts")
        sandbox.gone = []
        FileAccess.restore(prefs: prefs)
        #expect(FileAccess.isGranted("/Volumes/Ext/Apps"))
    }

    @Test func aFolderOnADriveThatComesBackUnderAnotherNameIsFollowed() {
        sandbox.install()
        defer { FileAccess.reset() }
        let prefs = testPreferences()
        prefs.extraFolders = ["/Volumes/Ext/Apps"]
        FileAccess.remember(URL(fileURLWithPath: "/Volumes/Ext/Apps"))
        #expect(FileAccess.isGranted("/Volumes/Ext/Apps"))
        // Unplugged: the access lapsed with the volume.
        FileAccess.releaseUnmounted(mounted: ["Macintosh HD"])
        #expect(!FileAccess.isGranted("/Volumes/Ext/Apps"))
        #expect(sandbox.closed == ["/Volumes/Ext/Apps"])
        // Plugged back in, mounted as "Ext 1" since a stale "Ext" was still there.
        sandbox.moves["/Volumes/Ext/Apps"] = "/Volumes/Ext 1/Apps"
        #expect(FileAccess.restore(prefs: prefs) == ["/Volumes/Ext/Apps": "/Volumes/Ext 1/Apps"])
        #expect(FileAccess.isGranted("/Volumes/Ext 1/Apps"))
        #expect(prefs.extraFolders == ["/Volumes/Ext 1/Apps"])
    }

    @Test func accessOnMountedVolumesIsKept() {
        sandbox.install()
        defer { FileAccess.reset() }
        FileAccess.remember(URL(fileURLWithPath: "/Volumes/Ext/Apps"))
        FileAccess.remember(URL(fileURLWithPath: "/Users/x/Tools"))
        FileAccess.releaseUnmounted(mounted: ["Ext"])
        #expect(FileAccess.isGranted("/Volumes/Ext/Apps") && FileAccess.isGranted("/Users/x/Tools"))
    }

    @Test func appsNoLongerOnTheGridLoseTheirBookmarksAndAccess() {
        sandbox.install()
        defer { FileAccess.reset() }
        for path in ["/Users/x/A.app", "/Users/x/B.app", "/Users/x/Tools"] { FileAccess.remember(URL(fileURLWithPath: path)) }
        FileAccess.forgetApps(notIn: ["/Users/x/A.app"])
        #expect(sandbox.saved.keys.sorted() == ["/Users/x/A.app", "/Users/x/Tools"])
        #expect(sandbox.closed == ["/Users/x/B.app"])
    }
}

@MainActor @Suite(.tempDir) struct FileAccessTests {
    @Test func aMovedItemsSettingsFollowIt() {
        let prefs = testPreferences()
        prefs.extraFolders = ["/Volumes/A/Apps", "/Users/x/Tools"]
        prefs.customImagePath = "/Users/x/Pictures/bg.jpg"
        FileAccess.migrate(prefs, from: "/Users/x/Tools", to: "/Users/x/Utilities")
        FileAccess.migrate(prefs, from: "/Users/x/Pictures/bg.jpg", to: "/Users/x/Pictures/Old/bg.jpg")
        #expect(prefs.extraFolders == ["/Volumes/A/Apps", "/Users/x/Utilities"])
        #expect(prefs.customImagePath == "/Users/x/Pictures/Old/bg.jpg")

        FileAccess.migrate(prefs, from: "/Volumes/A/Apps", to: "/Users/x/Utilities")
        #expect(prefs.extraFolders == ["/Users/x/Utilities"], "no folder twice")
    }

    @Test func onlyAppsNoLongerInUseLoseTheirBookmarks() {
        let bookmarked = ["/Users/x/Tools", "/Users/x/bg.jpg", "/Users/x/A.app", "/Users/x/B.app"]
        #expect(FileAccess.unusedApps(among: bookmarked, inUse: ["/Users/x/A.app"]) == ["/Users/x/B.app"])
    }

    @Test func appsInTheUndoHistoryAreStillInUse() throws {
        let state = makeState(["A", "B"])
        let b = try #require(state.grid.allApps.last)
        state.remove([b.id])
        #expect(state.appPathsInUse.contains(b.path), "⌘Z can bring it back")
    }

    @Test func movedAppsAreFollowedWithoutAnUndoStep() {
        let state = makeState(["A", "B"])
        state.followMovedApps(["/Applications/B.app": "/Users/x/Apps/B.app"])
        #expect(state.grid.allApps.map(\.path) == ["/Applications/A.app", "/Users/x/Apps/B.app"])
        #expect(!state.canUndo)
    }

    @Test func appsMovedDuringADragAreFollowedAtTheDrop() {
        let state = makeState(["A", "B", "C"])
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500) // 100 × 100 cells
        let start = CGPoint(x: 50, y: 50)
        state.dragChanged(start: start, location: CGPoint(x: 120, y: 60))
        #expect(state.drag.active)
        let before = state.grid
        state.followMovedApps(["/Applications/B.app": "/Users/x/Apps/B.app"])
        #expect(state.grid == before, "not under the drag")

        state.cancelDrag(reopeningFolder: false)
        #expect(state.grid.allApps.map(\.path).contains("/Users/x/Apps/B.app"))
        #expect(!state.canUndo)
    }

    @Test func undoAndRedoDoNotBringBackAPlaceAMovedAppLeft() throws {
        let state = makeState(["A", "B"])
        let b = try #require(state.grid.allApps.last)
        state.apply { $0.rename(b.id, to: "Bee") }
        state.apply { $0.move([b.id], toPage: 0, at: 0) }
        state.undo()
        state.followMovedApps(["/Applications/B.app": "/Users/x/Apps/B.app"])
        state.undo()
        #expect(state.grid.allApps.map(\.path) == ["/Applications/A.app", "/Users/x/Apps/B.app"])
        state.redo()
        state.redo()
        #expect(state.grid.allApps.map(\.path) == ["/Users/x/Apps/B.app", "/Applications/A.app"])

        state.rememberPath("/Volumes/Ext/B.app", of: b.id) // as a launch finding it elsewhere does
        state.undo()
        #expect(state.grid.allApps.last?.path == "/Volumes/Ext/B.app")
        #expect(!state.appPathsInUse.contains("/Users/x/Apps/B.app"), "its old bookmark can go")
    }

    @Test func redoingRemovalAfterACopyMovesKeepsItExcluded() throws {
        let state = makeState()
        let original = installed("Xcode")
        let beta = InstalledApp(bundleID: original.bundleID, path: "/Applications/Xcode-beta.app", name: "Xcode-beta")
        state.catalogScanned([original, beta])
        let tile = try #require(state.grid.allApps.first { $0.path == beta.path })
        state.remove([tile.id])
        state.undo()

        let moved = InstalledApp(bundleID: beta.bundleID, path: "/Applications/Dev/Xcode-beta.app", name: beta.name)
        state.followMovedApps([beta.path: moved.path])
        state.catalogScanned([original, moved])
        state.redo()

        #expect(state.grid.allApps.map(\.path) == [original.path], "auto-add must not undo the removal")
        #expect(state.grid.removedBundleIDs == [moved.path])
    }

    @Test func movingAScanFolderKeepsRemovedCopiesExcludedThroughUndoAndRedo() throws {
        let state = makeState()
        let original = installed("Xcode")
        let root = "/Users/x/Tools", destination = "/Users/x/Utilities"
        let beta = InstalledApp(bundleID: original.bundleID, path: root + "/Xcode-beta.app", name: "Xcode-beta")
        state.catalogScanned([original, beta])
        let tile = try #require(state.grid.allApps.first { $0.path == beta.path })
        state.remove([tile.id])

        state.followMovedApps([root: destination])
        let moved = InstalledApp(bundleID: beta.bundleID, path: destination + "/Xcode-beta.app", name: beta.name)
        state.catalogScanned([original, moved])
        #expect(state.grid.allApps.map(\.path) == [original.path])
        #expect(state.grid.removedBundleIDs == [moved.path])

        state.undo()
        #expect(state.grid.item(tile.id)?.app?.path == moved.path)
        state.redo()
        #expect(state.grid.allApps.map(\.path) == [original.path])
        #expect(state.grid.removedBundleIDs == [moved.path])
    }
}

@Suite struct LauncherTests {
    @Test func copiesInTheTrashAreNotFallbacks() throws {
        #expect(Launcher.isInTrash("/Users/x/.Trash/Xcode.app"))
        #expect(Launcher.isInTrash("/Volumes/Ext/.Trashes/501/Xcode.app"))
        #expect(!Launcher.isInTrash("/Applications/Xcode.app"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let trash = dir.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let app = trash.appendingPathComponent("Xcode.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let alias = dir.appendingPathComponent("Xcode.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        #expect(Launcher.isInTrash(alias.path), "a symlink must not hide a Trash copy")
    }

    @Test func cancellingIsNotAnError() {
        #expect(Launcher.isUserCancel(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        let wrapped = NSError(domain: "com.apple.launchservices", code: 1,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: Int(userCanceledErr))])
        #expect(Launcher.isUserCancel(wrapped))
        #expect(!Launcher.isUserCancel(Launcher.NotFound()))
    }
}

@Suite struct ShortcutConflictTests {
    let cmd = UInt32(cmdKey), opt = UInt32(optionKey), shift = UInt32(shiftKey), ctrl = UInt32(controlKey)

    @Test func keypadKeysAreNamedApartFromTheMainKeys() {
        #expect(KeyCombo.keyName(kVK_ANSI_Keypad1) == "Keypad 1")
        #expect(KeyCombo.keyName(kVK_ANSI_KeypadEnter) == "Keypad ⌤")
        #expect(KeyCombo.describe(keyCode: UInt32(kVK_ANSI_Keypad5), modifiers: opt) == "⌥Keypad 5")
        #expect(KeyCombo.keyName(kVK_F5) == "F5")
    }

    @Test func commonEditingCommandsAreFlagged() {
        #expect(KeyCombo.conflict(keyCode: UInt32(kVK_ANSI_C), modifiers: cmd) == "Copy (in most apps)")
        #expect(KeyCombo.conflict(keyCode: UInt32(kVK_ANSI_V), modifiers: cmd) != nil)
        #expect(KeyCombo.conflict(keyCode: UInt32(kVK_ANSI_C), modifiers: cmd | ctrl) == nil)
    }

    @Test func optionWithAPrintableKeyBlocksTyping() {
        #expect(KeyCombo.conflict(keyCode: UInt32(kVK_ANSI_E), modifiers: opt) != nil)
        #expect(KeyCombo.conflict(keyCode: UInt32(kVK_ANSI_2), modifiers: opt | shift) != nil)
        #expect(KeyCombo.conflict(keyCode: UInt32(kVK_Space), modifiers: opt) == nil, "the default shortcut")
        #expect(KeyCombo.conflict(keyCode: UInt32(kVK_ANSI_E), modifiers: opt | ctrl) == nil)
    }
}

@MainActor @Suite(.tempDir) struct HotkeyTests {
    @Test func aRefusedRecordedShortcutGoesBackToThePreviousOne() {
        let state = makeState()
        let prefs = state.prefs
        let previous = (keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
        prefs.hotkeyKeyCode = UInt32(kVK_ANSI_K)
        prefs.hotkeyModifiers = UInt32(cmdKey)
        var tried: [UInt32] = []
        let ok = AppDelegate.registerHotkey(prefs: prefs, state: state, fallback: previous,
                                            register: { code, _ in tried.append(code); return code != UInt32(kVK_ANSI_K) },
                                            activeCombo: nil)
        #expect(!ok)
        #expect(tried == [UInt32(kVK_ANSI_K), previous.keyCode])
        #expect(prefs.hotkeyKeyCode == previous.keyCode && prefs.hotkeyModifiers == previous.modifiers, "the saved one works")
        #expect(state.hotkeyProblem?.contains("kept") == true)
    }

    @Test func withoutAFallbackTheRefusedShortcutStaysAndIsExplained() {
        let state = makeState()
        let prefs = state.prefs
        let code = prefs.hotkeyKeyCode
        let ok = AppDelegate.registerHotkey(prefs: prefs, state: state, fallback: nil,
                                            register: { _, _ in false }, activeCombo: nil)
        #expect(!ok)
        #expect(prefs.hotkeyKeyCode == code)
        #expect(state.hotkeyProblem?.contains("won't open LaunchGrid") == true)
    }

    @Test func anAcceptedShortcutClearsTheProblem() {
        let state = makeState()
        state.hotkeyProblem = "old"
        #expect(AppDelegate.registerHotkey(prefs: state.prefs, state: state, fallback: nil,
                                           register: { _, _ in true }, activeCombo: nil))
        #expect(state.hotkeyProblem == nil)
    }
}

@Suite struct ScratchMarkerTests {
    @Test func aMarkerBelongsToTheProcessStartItRecords() {
        let start = 1_800_000_000.123456
        let marker = AppDelegate.scratchMarkerContents(startedAt: start)
        #expect(AppDelegate.isScratchMarker(marker, startedAt: start))
        #expect(!AppDelegate.isScratchMarker(marker, startedAt: start + 60), "a reused pid's later process")
        #expect(AppDelegate.isScratchMarker("", startedAt: start), "a run that couldn't tell its start")
        #expect(AppDelegate.isScratchMarker(marker, startedAt: nil))
    }

    @Test func theKernelGivesThisProcessAStableStartTime() throws {
        let start = try #require(AppDelegate.processStart(getpid()))
        #expect(abs(start - Date().timeIntervalSince1970) < 24 * 3600)
        #expect(AppDelegate.processStart(getpid()) == start)
    }
}

@MainActor @Suite struct BackgroundTests {
    @Test func aSolidColourIsOpaqueWithReduceTransparency() {
        #expect(BackgroundView.solidOpacity(0.5, reduceTransparency: true) == 1)
        #expect(BackgroundView.solidOpacity(0, reduceTransparency: false) == 1)
        #expect(abs(BackgroundView.solidOpacity(0.5, reduceTransparency: false) - 0.6) < 1e-9)
        #expect(BackgroundView.solidOpacity(0.9, reduceTransparency: false) >= 0.15)
    }
}

@Suite struct BlurScaleTests {
    /// Points per working pixel, for a picture blurred by `radius` on a display `points` wide.
    func workingPixel(radius: Double, points: CGFloat, pixelScale: CGFloat, source: CGSize) -> CGFloat {
        let target = ImageBlurCache.Target(radius: radius, size: CGSize(width: points, height: points * 9 / 16), pixelScale: pixelScale)
        return ImageBlurCache.fill(source: source, target) / ImageBlurCache.workingScale(source: source, target)
    }

    @Test func aLightBlurOnALargeDisplayIsWorkedFineEnough() {
        // A 6K wallpaper on a 5K display.
        let six = CGSize(width: 6144, height: 3456)
        #expect(workingPixel(radius: 1, points: 2560, pixelScale: 2, source: six) <= 0.5 + 1e-9)
        #expect(workingPixel(radius: 3, points: 2560, pixelScale: 2, source: six) <= 1.5 + 1e-9)
        // A heavy blur still works at the reduced size.
        #expect(abs(ImageBlurCache.workingScale(source: six, .init(radius: 30, size: CGSize(width: 2560, height: 1440), pixelScale: 2)) - 1600.0 / 6144) < 1e-9)
    }

    @Test func noBlurIsNeverFinerThanTheScreen() {
        let target = ImageBlurCache.Target(radius: 0, size: CGSize(width: 1512, height: 982), pixelScale: 2)
        #expect(ImageBlurCache.workingScale(source: CGSize(width: 6144, height: 3456), target) <= 1)
        #expect(abs(ImageBlurCache.workingScale(source: CGSize(width: 6144, height: 3456), target) - 982.0 / 3456 * 2) < 1e-9, "filled by its height")
    }
}

@Suite(.tempDir) struct BlurCacheIdentityTests {
    @Test func aPictureCopiedOverInPlaceIsANewPicture() throws {
        try FileManager.default.createDirectory(at: TempDir.url, withIntermediateDirectories: true)
        let url = TempDir.url.appendingPathComponent("bg.jpg")
        try Data(repeating: 1, count: 200_000).write(to: url)
        let first = ImageBlurCache.identity(of: url)
        #expect(ImageBlurCache.identity(of: url) == first, "the same file reads the same")

        // Written into the same file, as `cp` does: the same inode and the same size.
        func overwrite(at offset: UInt64) throws {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data([2]))
            try handle.close()
        }
        try overwrite(at: 199_999)
        let second = ImageBlurCache.identity(of: url)
        #expect(second != first, "a change at the end")
        try overwrite(at: 0)
        #expect(ImageBlurCache.identity(of: url) != second, "a change at the start")
    }
}

@MainActor @Suite(.tempDir) struct DragDeferralTests {
    @Test func aDeferredRefreshDoesNotMakeAnExistingCopyLookNew() throws {
        let state = makeState(["A", "B"])
        state.prefs.autoAddApps = false
        let a = try #require(state.grid.allApps.first)
        let copy = InstalledApp(bundleID: a.bundleID, path: "/Applications/Other A.app", name: "Other A")
        state.catalogScanned([installed("A"), installed("B"), copy])

        state.drag.active = true
        state.reconcile() // e.g. a background read finishes before the next scan
        state.catalogScanned([installed("B"), copy])
        state.cancelDrag()

        #expect(state.grid.allApps.map(\.name) == ["B"], "the missing app must not become its existing copy")
    }

    @Test(arguments: [false, true])
    func repeatedScansDuringADragPreserveARenamedAppsTile(autoAdd: Bool) throws {
        let state = makeState(["A", "B"])
        state.prefs.autoAddApps = autoAdd
        state.catalogScanned([installed("A"), installed("B")])
        let a = try #require(state.grid.allApps.first)
        state.apply { $0.rename(a.id, to: "Custom") }
        let renamed = InstalledApp(bundleID: a.bundleID, path: "/Applications/New A.app", name: "New A")

        state.drag.active = true
        state.catalogScanned([renamed, installed("B")])
        state.catalogScanned([renamed, installed("B")])
        #expect(state.grid.allApps.first?.path == a.path)
        state.cancelDrag()

        #expect(state.grid.allApps.map(\.path) == [renamed.path, installed("B").path])
        #expect(state.grid.allApps.first?.id == a.id)
        #expect(state.grid.allApps.first?.title == "Custom")
        state.undo()
        #expect(state.grid.allApps.first?.id == a.id)
        #expect(state.grid.allApps.first?.path == renamed.path)
    }

    @Test func consecutiveMovesDuringADragReachTheFinalPath() throws {
        let state = makeState(["A", "B"])
        let a = try #require(state.grid.allApps.first)
        state.apply { $0.rename(a.id, to: "Custom") }
        state.drag.active = true
        state.followMovedApps([a.path: "/Applications/Middle.app"])
        state.followMovedApps(["/Applications/Middle.app": "/Applications/Final.app"])
        #expect(state.grid.allApps.first?.path == a.path)
        state.cancelDrag()

        #expect(state.grid.allApps.first?.path == "/Applications/Final.app")
        state.undo()
        #expect(state.grid.allApps.first?.path == "/Applications/Final.app")
        state.redo()
        #expect(state.grid.allApps.first?.path == "/Applications/Final.app")
    }

    @Test func swappingPathsDuringADragUpdatesHistoryOnlyOnce() throws {
        let state = makeState(["A", "B"])
        let a = try #require(state.grid.allApps.first)
        let b = try #require(state.grid.allApps.last)
        state.apply { $0.rename(a.id, to: "Custom") }
        state.drag.active = true
        state.followMovedApps([a.path: b.path, b.path: a.path])
        state.cancelDrag()

        #expect(state.grid.allApps.map(\.path) == [b.path, a.path])
        state.undo()
        #expect(state.grid.allApps.map(\.path) == [b.path, a.path])
        state.redo()
        #expect(state.grid.allApps.map(\.path) == [b.path, a.path])
    }

    @Test func aScanDuringADragWaitsForTheDrop() {
        let state = makeState(["A"])
        state.catalogScanned([installed("A")])
        state.drag.active = true
        state.catalogScanned(["A", "B"].map(installed))
        #expect(state.grid.allApps.map(\.name) == ["A"], "the drag's slots stay as they are")
        state.cancelDrag()
        #expect(state.grid.allApps.map(\.name) == ["A", "B"])
    }

    @Test func escapeDuringADragOutOfAFolderReopensIt() throws {
        let state = makeState(["A", "B", "C"])
        let ids = state.grid.pages[0].items.map(\.id)
        state.apply { _ = $0.group(Array(ids.prefix(2)), name: "F") }
        let folder = try #require(state.grid.pages[0].items.compactMap(\.folder).first)
        state.openFolder(folder.id)
        state.drag.active = true
        state.drag.source = .folder(folder.id)
        state.closeFolder() // as dragging out of it does
        state.cancelDrag()
        #expect(state.openFolderID == folder.id)

        state.drag.active = true
        state.drag.source = .folder(folder.id)
        state.closeFolder()
        state.didHide()
        #expect(state.openFolderID == nil, "hiding closes it")
    }

    @Test func aSearchEndedAnotherWayForgetsTheFolderItStartedIn() throws {
        let state = makeState(["A", "B", "C"])
        let ids = state.grid.pages[0].items.map(\.id)
        state.apply { _ = $0.group(Array(ids.prefix(2)), name: "F") }
        let folder = try #require(state.grid.pages[0].items.compactMap(\.folder).first)
        state.openFolder(folder.id)
        state.folderBeforeSearch = (folder.id, 0) // as typing does
        state.openFolderID = nil
        state.query = "c"
        state.didHide()
        state.endSearch()
        #expect(state.openFolderID == nil, "a later ⌘F or Esc doesn't reopen it")

        state.openFolder(folder.id)
        state.folderBeforeSearch = (folder.id, 0)
        state.openFolderID = nil
        state.query = "c"
        state.endSearch()
        #expect(state.openFolderID == folder.id, "ending the search itself still goes back")
    }

    @Test func swipingPastTheFirstOrLastPageGivesWayLittle() {
        let state = makeState(["A"])
        state.apply { _ = $0.addPage() }
        #expect(state.swipeOffset(for: -300, width: 1000) == -300, "towards the next page")
        let pastFirst = state.swipeOffset(for: 300, width: 1000)
        #expect(pastFirst > 0 && pastFirst < 200)
        #expect(state.swipeOffset(for: 3000, width: 1000) < 200, "never past a fifth of the page")
        #expect(state.swipeOffset(for: 900, width: 1000) > pastFirst, "further still gives a little more")
        state.goToPage(1)
        #expect(state.swipeOffset(for: 300, width: 1000) == 300)
        #expect(state.swipeOffset(for: -300, width: 1000) == -pastFirst)
        #expect(state.swipeOffset(for: 900, width: 1000) == 600, "at most 0.6 of a page")
    }
}

@MainActor @Suite(.tempDir) struct RevealTests {
    @Test func aSearchResultInEditModeIsShownWhereItIs() throws {
        let state = makeState((1...40).map { "App\($0)" })
        state.apply { $0.normalize() } // 35 on the first page, 5 on the next
        let ids = state.grid.pages[0].items.map(\.id)
        state.apply { _ = $0.group([ids[3], ids[4]], name: "F") }
        state.editing = true

        state.query = "App38"
        state.activateResult(try #require(state.searchResults.first))
        #expect(state.query.isEmpty && state.editing)
        #expect(state.currentPage == 1 && state.openFolderID == nil)
        #expect(state.currentItems[state.focusIndex ?? -1].title == "App38")

        state.query = "App5"
        state.activateResult(try #require(state.searchResults.first { $0.title == "App5" }))
        let folder = try #require(state.openFolder)
        #expect(state.currentPage == 0 && folder.name == "F")
        #expect(folder.apps[state.focusIndex ?? -1].title == "App5")
    }
}

@MainActor @Suite(.tempDir) struct PageShownTests {
    /// One page per app.
    func onePagePerApp(_ names: [String]) -> AppState {
        let state = makeState(names)
        state.apply { g in g.pages = g.allApps.map { Page(items: [.app($0)]) } }
        return state
    }

    @Test func thePageShownStaysWhenAnEarlierOneGoes() {
        let state = onePagePerApp(["X", "F", "Y"])
        state.goToPage(1)
        state.apply { $0.pages.remove(at: 0) } // as a rescan can
        #expect(state.currentItems.map(\.title) == ["F"])
    }

    @Test func endingASearchReopensTheFolderOnItsPage() throws {
        let state = onePagePerApp(["X", "A", "B", "Y"])
        state.apply { g in
            g.pages[1].items += g.pages[2].items
            g.pages.remove(at: 2)
            _ = g.group(g.pages[1].items.map(\.id), name: "F")
        }
        let folder = try #require(state.grid.pages[1].items.first?.folder)
        state.goToPage(1)
        state.openFolder(folder.id)
        state.folderBeforeSearch = (folder.id, 0) // as typing does
        state.openFolderID = nil
        state.query = "y"
        state.apply { $0.pages.remove(at: 0) }
        state.currentPage = 1 // wherever the view was left
        state.endSearch()
        #expect(state.openFolderID == folder.id)
        #expect(state.currentItems.first?.id == folder.id, "over its own page")
    }

    @Test func undoingAPageDeletionShowsThePage() {
        let state = onePagePerApp(["A", "B", "C"])
        state.goToPage(1)
        state.deleteCurrentPage()
        #expect(state.currentPage == 0)
        state.undo()
        #expect(state.currentItems.map(\.title) == ["B"])
        state.redo()
        #expect(state.grid.pages.count == 2)
    }

    @Test func undoingAMoveThatEmptiedAPageShowsThatPage() throws {
        let state = onePagePerApp(["A", "B", "C"])
        let c = try #require(state.grid.pages[2].items.first?.id)
        state.moveToPage([c], page: 0)
        #expect(state.grid.pages.count == 2)
        state.undo()
        #expect(state.currentItems.map(\.title) == ["C"])
    }

    @Test func undoingAChangeOnThePageShownStaysThere() throws {
        let state = onePagePerApp(["A", "B", "C"])
        state.goToPage(2)
        let c = try #require(state.currentItems.first?.id)
        state.apply { $0.rename(c, to: "Renamed") }
        state.undo()
        #expect(state.currentPage == 2)
    }

    @Test func movingNothingLeftToANewPageAddsNoPage() {
        let state = makeState(["A"])
        let undoable = state.canUndo
        state.moveToPage([UUID()], pageID: nil)
        #expect(state.grid.pages.count == 1)
        #expect(state.canUndo == undoable)
    }
}

@MainActor @Suite struct WindowFrameTests {
    @Test func aSavedFrameFollowsItsDisplayWhenTheDisplaysAreRearranged() {
        let right = NSRect(x: 1512, y: 0, width: 2560, height: 1440)
        let saved = OverlayController.savedFrame(NSRect(x: 1612, y: 100, width: 1000, height: 700), on: right)
        // Now to the left of the main display.
        let left = NSRect(x: -2560, y: 0, width: 2560, height: 1440)
        #expect(OverlayController.frame(saved: saved, on: left) == NSRect(x: -2460, y: 100, width: 1000, height: 700))
    }

    @Test func aFrameSavedInGlobalCoordinatesStillLoads() {
        let display = NSRect(x: 1512, y: 0, width: 2560, height: 1440)
        #expect(OverlayController.frame(saved: "{{1612, 100}, {1000, 700}}", on: display) == NSRect(x: 1612, y: 100, width: 1000, height: 700))
    }
}
