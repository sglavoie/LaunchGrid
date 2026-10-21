import Foundation
import Testing
@testable import LaunchGridCore

func app(_ name: String, id: String? = nil) -> AppRef {
    AppRef(bundleID: id ?? "com.test.\(name.lowercased())", path: "/Applications/\(name).app", name: name)
}

func titles(_ page: Page) -> [String] { page.items.map(\.title) }

@Suite struct GridOpsTests {
    func grid(_ names: [[String]], rows: Int = 1, columns: Int = 3) -> Grid {
        Grid(rows: rows, columns: columns, pages: names.map { Page(items: $0.map { .app(app($0)) }) })
    }

    @Test func insertSpillsOverflowOntoNewPage() {
        var g = grid([["A", "B", "C"]])
        g.insert([.app(app("X"))], page: 0, at: 0)
        #expect(g.pages.count == 2)
        #expect(titles(g.pages[0]) == ["X", "A", "B"])
        #expect(titles(g.pages[1]) == ["C"])
    }

    @Test func overflowCascadesAcrossPages() {
        var g = grid([["A", "B", "C"], ["D", "E", "F"]])
        g.insert([.app(app("X"))], page: 0, at: 1)
        #expect(g.pages.map(titles) == [["A", "X", "B"], ["C", "D", "E"], ["F"]])
    }

    @Test func moveUsesIndexAfterRemoval() {
        var g = grid([["A", "B", "C"]])
        let a = g.pages[0].items[0].id
        g.move([a], toPage: 0, at: 2)
        #expect(titles(g.pages[0]) == ["B", "C", "A"])
    }

    @Test func moveAcrossPagesAndMultiSelect() {
        var g = grid([["A", "B", "C"], ["D"]])
        let ids = [g.pages[0].items[0].id, g.pages[0].items[2].id]
        g.move(ids, toPage: 1, at: 1)
        #expect(g.pages.map(titles) == [["B"], ["D", "A", "C"]])
    }

    @Test func groupCreatesFolderAtAnchorAndFlattensFolders() {
        var g = grid([["A", "B", "C"]])
        let (a, c) = (g.pages[0].items[0].id, g.pages[0].items[2].id)
        let folderID = g.group([c, a], name: "F", anchor: c)
        #expect(titles(g.pages[0]) == ["B", "F"])
        #expect(g.folder(folderID!)?.apps.map(\.name) == ["A", "C"])

        let b = g.pages[0].items[0].id
        let outer = g.group([b, folderID!], name: "G", anchor: b)
        #expect(g.pages[0].items.count == 1)
        #expect(g.folder(outer!)?.apps.map(\.name) == ["B", "A", "C"])
    }

    @Test func removingLastAppFromFolderDeletesFolder() {
        var g = grid([["A", "B"]])
        let fid = g.group(g.pages[0].items.map(\.id), name: "F")!
        let apps = g.folder(fid)!.apps
        g.move([apps[0].id], toPage: 0, at: 0)
        #expect(g.folder(fid)?.apps.count == 1)
        g.move([apps[1].id], toPage: 0, at: 0)
        #expect(g.folder(fid) == nil)
        #expect(titles(g.pages[0]) == ["B", "A"])
    }

    @Test func addToFolder() {
        var g = grid([["A", "B", "C"]])
        let fid = g.group([g.pages[0].items[0].id], name: "F")!
        g.addToFolder([g.pages[0].items[2].id], folder: fid)
        #expect(g.folder(fid)?.apps.map(\.name) == ["A", "C"])
        #expect(titles(g.pages[0]) == ["F", "B"])
    }

    @Test func removeRemembersKeys() {
        var g = grid([["A", "B"]])
        g.remove([g.pages[0].items[0].id])
        #expect(g.removedBundleIDs == ["com.test.a"])
        #expect(titles(g.pages[0]) == ["B"])
    }

    @Test func resizeReflows() {
        var g = grid([["A", "B", "C"], ["D", "E"]])
        #expect(g.pageCountAfterResize(rows: 1, columns: 2) == 3)
        g.resize(rows: 1, columns: 2)
        #expect(g.pages.map(titles) == [["A", "B"], ["C"], ["D", "E"]])
        g.resize(rows: 2, columns: 3)
        #expect(g.pages.count == 3) // growing never merges pages
    }

    @Test func sortPageWithFolderPlacement() {
        var g = grid([["c", "B", "a"]])
        let fid = g.group([g.pages[0].items[0].id], name: "Z")!
        g.sortPage(0, folders: .first)
        #expect(titles(g.pages[0]) == ["Z", "a", "B"])
        g.sortPage(0, folders: .last)
        #expect(titles(g.pages[0]) == ["a", "B", "Z"])
        g.sortPage(0, folders: .mixed)
        #expect(titles(g.pages[0]) == ["a", "B", "Z"])
        _ = fid
    }

    @Test func sortEverythingReflows() {
        var g = grid([["E", "A"], ["D", "C", "B"], []])
        g.sortEverything()
        #expect(g.pages.map(titles) == [["A", "B", "C"], ["D", "E"]])
    }

    @Test func renameAndResetName() {
        var g = grid([["A"]])
        let id = g.pages[0].items[0].id
        g.rename(id, to: "Alpha")
        #expect(g.item(id)?.title == "Alpha")
        g.rename(id, to: "  ")
        #expect(g.item(id)?.app?.displayName == nil)
    }

    @Test func deletePageMovesItemsToPrevious() {
        var g = grid([["A"], ["B", "C"]])
        g.deletePage(1)
        #expect(g.pages.map(titles) == [["A", "B", "C"]])
    }

    @Test func ungroupInPlace() {
        var g = grid([["A", "B", "C"]])
        let fid = g.group([g.pages[0].items[1].id, g.pages[0].items[2].id], name: "F")!
        g.ungroup(fid)
        #expect(titles(g.pages[0]) == ["A", "B", "C"])
    }

    @Test func appendToFirstFree() {
        var g = grid([["A", "B", "C"], ["D"]])
        g.appendToFirstFree([.app(app("X")), .app(app("Y")), .app(app("Z"))])
        #expect(g.pages.map(titles) == [["A", "B", "C"], ["D", "X", "Y"], ["Z"]])
    }
}

@Suite struct GridStoreTests {
    @Test func jsonRoundTrip() throws {
        var g = Grid(rows: 4, columns: 6, pages: [Page(title: "Work", items: [.app(app("A")), .app(app("B"))])])
        g.group([g.pages[0].items[1].id], name: "Folder")
        g.removedBundleIDs = ["com.gone"]
        let data = try GridStore.encode(g)
        #expect(try GridStore.decode(data) == g)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("grid.json")
        let store = GridStore(url: url)
        try store.save(g)
        #expect(try store.load() == g)
    }

    @Test func rejectsNewerVersion() {
        let data = #"{"version": 99, "rows": 5, "columns": 7, "pages": [], "removedBundleIDs": []}"#.data(using: .utf8)!
        #expect(throws: GridFileError.self) { try GridStore.decode(data) }
    }

    @Test func missingVersionDecodesAsV1AndNormalizes() throws {
        let json = #"{"rows": 1, "columns": 1, "pages": [{"id": "8F0E4C1B-5B0B-4E5E-8D7B-1D2E3F4A5B6C", "items": [{"type": "app", "app": {"id": "1F0E4C1B-5B0B-4E5E-8D7B-1D2E3F4A5B6C", "path": "/Applications/A.app", "name": "A"}}, {"type": "app", "app": {"id": "2F0E4C1B-5B0B-4E5E-8D7B-1D2E3F4A5B6C", "path": "/Applications/B.app", "name": "B"}}]}], "removedBundleIDs": []}"#
        let g = try GridStore.decode(json.data(using: .utf8)!)
        #expect(g.version == 1)
        #expect(g.pages.count == 2) // overflow spilled
    }
}

@Suite struct SearchTests {
    @Test func ranking() {
        let apps = ["Notes", "Keynote", "Notion", "Sonoma Notes", "Final Cut Pro", "GarageBand"].map { app($0) }
        let no = Search.results(in: apps, query: "no").map(\.name)
        #expect(no == ["Notes", "Notion", "Sonoma Notes", "Keynote"])
        #expect(Search.results(in: apps, query: "fcp").map(\.name) == ["Final Cut Pro"])
        #expect(Search.results(in: apps, query: "gb").map(\.name) == ["GarageBand"])
        #expect(Search.results(in: apps, query: "grbd").map(\.name) == ["GarageBand"])
        #expect(Search.results(in: apps, query: "zzz").isEmpty)
    }

    @Test func diacriticInsensitiveAndRenames() {
        var a = app("Café")
        a.displayName = "Coffee"
        #expect(Search.results(in: [a], query: "cafe").count == 1)
        #expect(Search.results(in: [a], query: "coff").count == 1)
    }
}
