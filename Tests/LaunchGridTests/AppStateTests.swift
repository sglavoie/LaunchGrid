import Foundation
import Testing
@testable import LaunchGrid
@testable import LaunchGridCore

@MainActor
func makeState(_ names: [String] = []) -> AppState {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-\(UUID().uuidString)")
    let state = AppState(prefs: Preferences(), store: GridStore(url: dir.appendingPathComponent("grid.json")))
    let apps = names.map { GridItem.app(AppRef(bundleID: "com.test.\($0)", path: "/Applications/\($0).app", name: $0)) }
    state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: apps)]))
    return state
}

func installed(_ name: String) -> InstalledApp {
    InstalledApp(bundleID: "com.test.\(name)", path: "/Applications/\(name).app", name: name)
}

@MainActor @Suite struct UndoTests {
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

@MainActor @Suite struct DragTests {
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

@MainActor @Suite struct LoadProblemTests {
    func load(_ contents: String) throws -> AppState {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-\(UUID().uuidString)")
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
