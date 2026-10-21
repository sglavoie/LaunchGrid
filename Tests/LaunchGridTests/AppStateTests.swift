import Foundation
import Testing
@testable import LaunchGrid
@testable import LaunchGridCore

/// A fresh temporary folder for each test, removed when the test ends. Suites using
/// `makeState` or `TempDir.current` carry the `.tempDir` trait.
struct TempDir: TestTrait, SuiteTrait, TestScoping {
    @TaskLocal static var current: URL?

    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> TempDir? {
        testCase == nil ? nil : self
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await TempDir.$current.withValue(dir) { try await function() }
    }

    /// The current test's folder; a test without the trait would leave its folder behind.
    static var url: URL {
        guard let current else { preconditionFailure("add the .tempDir trait to this suite") }
        return current
    }
}

extension Trait where Self == TempDir {
    static var tempDir: TempDir { TempDir() }
}

@MainActor
func makeState(_ names: [String] = []) -> AppState {
    let dir = TempDir.url
    let state = AppState(prefs: Preferences(), store: GridStore(url: dir.appendingPathComponent("grid.json")))
    let apps = names.map { GridItem.app(AppRef(bundleID: "com.test.\($0)", path: "/Applications/\($0).app", name: $0)) }
    state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: apps)]))
    return state
}

func installed(_ name: String) -> InstalledApp {
    InstalledApp(bundleID: "com.test.\(name)", path: "/Applications/\(name).app", name: name)
}

@MainActor @Suite(.tempDir) struct UndoTests {
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
}

@MainActor @Suite(.tempDir) struct CatalogTests {
    @Test func launchGridLeavesItsOwnGridAndCatalog() {
        let state = makeState(["A", "LaunchGrid"])
        state.ownBundleID = "com.test.LaunchGrid"
        state.catalogScanned(["A", "B", "LaunchGrid"].map(installed))
        #expect(state.installed.map(\.name) == ["A", "B"])
        #expect(!state.grid.allApps.map(\.name).contains("LaunchGrid"))
    }
}

@MainActor @Suite(.tempDir) struct DragTests {
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
        return AppState(prefs: Preferences(), store: GridStore(url: url))
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

    @Test func clearingTheSelectionForgetsTheAnchor() {
        let state = makeState(["A", "B", "C", "D"])
        let id = ids(state)
        state.toggleSelection(id["A"]!)
        state.selection.removeAll()
        state.extendSelection(to: id["C"]!)
        #expect(selected(state) == ["C"])
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
        try await Task.sleep(for: .milliseconds(300))
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
    @Test func ignoresChangesDeepInsideBundles() {
        #expect(FolderWatcher.isRelevant("/Applications/"))
        #expect(FolderWatcher.isRelevant("/Applications/Utilities/"))
        #expect(FolderWatcher.isRelevant("/Applications/Foo.app/"))
        #expect(FolderWatcher.isRelevant("/Applications/Foo.app/Contents/"))
        #expect(!FolderWatcher.isRelevant("/Applications/Foo.app/Contents/Resources/"))
        #expect(!FolderWatcher.isRelevant("/Applications/Foo.app/Contents/Frameworks/X.framework/Versions/A/"))
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

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: plist.path)
        #expect(icons.dropStale([app.path]) == [app.path])
        #expect(icons.cached(app.path) == nil)
    }
}

@MainActor @Suite(.tempDir) struct ChooseAppsTests {
    @Test func firstRunChoiceIsRememberedByTheBuild() {
        let dir = TempDir.url
        let state = AppState(prefs: Preferences(), store: GridStore(url: dir.appendingPathComponent("grid.json")))
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
