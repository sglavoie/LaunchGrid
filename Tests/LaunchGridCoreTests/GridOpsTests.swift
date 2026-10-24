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

    @Test func movingAFoldersLastAppOutOfAFullPageSpillsNothing() {
        let x = app("X")
        var g = Grid(rows: 1, columns: 4, pages: [
            Page(items: [.app(app("A")), .folder(Folder(name: "F", apps: [x])), .app(app("B")), .app(app("C"))]),
            Page(items: [.app(app("D"))]),
        ])
        g.move([x.id], toPage: 0, at: 0)
        #expect(g.pages.map(titles) == [["X", "A", "B", "C"], ["D"]])
    }

    @Test func moveAcrossPagesAndMultiSelect() {
        var g = grid([["A", "B", "C"], ["D"]])
        let ids = [g.pages[0].items[0].id, g.pages[0].items[2].id]
        g.move(ids, toPage: 1, at: 1)
        #expect(g.pages.map(titles) == [["B"], ["D", "A", "C"]])
    }

    @Test func itemsMovedOntoTheEndOfAFullPageStayOnIt() {
        var g = grid([["A", "B", "C"], ["D", "E"]])
        let (d, e) = (g.pages[1].items[0].id, g.pages[1].items[1].id)
        g.move([d], toPage: 0, at: 3)
        #expect(g.pages.map(titles) == [["A", "B", "D"], ["C", "E"]], "C is displaced, not D")
        g.removingEmptiedPages { $0.move([d, e], toPage: 0, at: 3) }
        #expect(g.pages.map(titles) == [["A", "D", "E"], ["B", "C"]])
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

    @Test func groupWithAnchorInsideAFolder() {
        var g = grid([["A", "B", "C", "D"]], columns: 4)
        let fid = g.group([g.pages[0].items[0].id, g.pages[0].items[1].id], name: "F")!
        let b = g.folder(fid)!.apps[1].id
        let d = g.pages[0].items[2].id
        let new = g.group([d, b], name: "G", anchor: b)
        #expect(titles(g.pages[0]) == ["G", "F", "C"], "the new folder takes the anchor's folder slot")
        #expect(g.folder(fid)?.apps.map(\.name) == ["A"])
        #expect(g.folder(new!)?.apps.map(\.name) == ["B", "D"])
    }

    @Test func groupWithChosenItemsBeforeTheAnchor() {
        var g = grid([["A", "B", "C", "D"]], columns: 4)
        let ids = g.pages[0].items.map(\.id)
        let fid = g.group([ids[0], ids[1], ids[3]], name: "F", anchor: ids[3])
        #expect(titles(g.pages[0]) == ["C", "F"])
        #expect(g.folder(fid!)?.apps.map(\.name) == ["A", "B", "D"])
    }

    @Test func reorderWithinAFolder() {
        var g = grid([["A", "B", "C"]])
        let fid = g.group(g.pages[0].items.map(\.id), name: "F")!
        let a = g.folder(fid)!.apps[0].id
        g.addToFolder([a], folder: fid, at: 2)
        #expect(g.folder(fid)?.apps.map(\.name) == ["B", "C", "A"])
        g.addToFolder([a], folder: fid, at: 0)
        #expect(g.folder(fid)?.apps.map(\.name) == ["A", "B", "C"])
    }

    @Test func addToFolderWithAnAppIDLeavesTheContainingFolderAlone() {
        var g = grid([["A", "B", "C"]])
        let fid = g.group([g.pages[0].items[0].id, g.pages[0].items[1].id], name: "F")!
        let a = g.folder(fid)!.apps[0].id
        g.addToFolder([g.pages[0].items[1].id], folder: a)
        #expect(g.folder(fid)?.apps.map(\.name) == ["A", "B"])
        #expect(titles(g.pages[0]) == ["F", "C"])
    }

    @Test func insertPastTheLastPageAddsOnlyOnePage() {
        var g = grid([["A"]])
        g.insert([.app(app("X"))], page: 3, at: 0)
        #expect(g.pages.map(titles) == [["A"], ["X"]])
        let b = g.pages[0].items[0].id
        g.move([b], toPage: 5, at: 0)
        #expect(g.pages.map(titles) == [[], ["X"], ["A"]])
    }

    @Test func insertOnANegativePageUsesTheFirst() {
        var g = grid([["A"]])
        g.insert([.app(app("X"))], page: -1, at: 0)
        #expect(g.pages.map(titles) == [["X", "A"]])
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
        #expect(g.pages.map(titles) == [["A", "B"], ["C", "D"], ["E"]])
        // Growing keeps every page as it is: nothing has to move.
        #expect(g.pageCountAfterResize(rows: 2, columns: 3) == 3)
        g.resize(rows: 2, columns: 3)
        #expect(g.pages.map(titles) == [["A", "B"], ["C", "D"], ["E"]])
        #expect(g.rows == 2 && g.columns == 3)
    }

    @Test func resizeKeepsPagesThatStillFit() {
        var g = grid([["A", "B"], ["C"]], columns: 4)
        g.setPageTitle(0, "Work")
        g.setPageTitle(1, "Games")
        #expect(!g.pagesDiffer(from: g.resized(rows: 2, columns: 2)), "same capacity")
        #expect(!g.pagesDiffer(from: g.resized(rows: 1, columns: 2)), "smaller, but every page fits")
        g.resize(rows: 1, columns: 2)
        #expect(g.pages.map(titles) == [["A", "B"], ["C"]])
        #expect(g.pages.map(\.title) == ["Work", "Games"])
    }

    @Test func resizeKeepsEmptyPagesWhereTheyWere() {
        var g = grid([["A", "B", "C"], [], ["D"], []])
        g.setPageTitle(1, "Later")
        g.setPageTitle(3, "Spare")
        let spare = g.pages[1].id
        g.resize(rows: 1, columns: 2)
        #expect(g.pages.map(titles) == [["A", "B"], ["C"], [], ["D"], []])
        #expect(g.pages.map(\.title) == [nil, nil, "Later", nil, "Spare"])
        #expect(g.pages[2].id == spare)
    }

    @Test func resizeKeepsLeadingPageIdentity() {
        var g = grid([["A", "B"], ["C"], ["D"]])
        g.setPageTitle(0, "First")
        g.setPageTitle(2, "Third")
        let first = g.pages[0].id
        g.resize(rows: 1, columns: 1)
        #expect(g.pages.map(titles) == [["A"], ["B"], ["C"], ["D"]])
        #expect(g.pages[0].id == first && g.pages[0].title == "First")
        #expect(g.pages[3].title == "Third", "with D, the third page's first item")
    }

    @Test func resizeTitlesFollowTheirPagesFirstItem() {
        var g = grid([["A", "B"], ["C", "D", "E"], ["F"]], columns: 5)
        g.setPageTitle(1, "Games")
        g.setPageTitle(2, "Tools")
        #expect(g.pagesDiffer(from: g.resized(rows: 1, columns: 2)))
        g.resize(rows: 1, columns: 2)
        #expect(g.pages.map(titles) == [["A", "B"], ["C", "D"], ["E", "F"]])
        #expect(g.pages.map(\.title) == [nil, "Games", "Games"], "E, from the Games page, starts the last one")
        g.resize(rows: 1, columns: 3)
        #expect(g.pages.map(\.title) == [nil, "Games", "Games"], "every page still fits, so none moves")
        #expect(!g.pagesDiffer(from: g.resized(rows: 3, columns: 1)), "same capacity, nothing moves")

        // Shrinking spills full pages onto the next ones; titles still go by where items came from.
        var big = grid([["A", "B", "C", "D"], ["E"], ["F", "G"]], columns: 4)
        big.setPageTitle(0, "One")
        big.setPageTitle(1, "Two")
        big.setPageTitle(2, "Three")
        big.resize(rows: 1, columns: 2)
        #expect(big.pages.map(titles) == [["A", "B"], ["C", "D"], ["E", "F"], ["G"]])
        #expect(big.pages.map(\.title) == ["One", "One", "Two", "Three"])
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

    @Test func sortEverythingClearsPageTitles() {
        var g = grid([["E", "A"], ["D", "C", "B"], []])
        g.pages[0].title = "Work"
        g.pages[1].title = "Play"
        let ids = g.pages.map(\.id)
        g.sortEverything()
        #expect(g.pages.map(titles) == [["A", "B", "C"], ["D", "E"]])
        #expect(g.pages.map(\.title) == [nil, nil], "the titles named what the pages held before")
        #expect(g.pages.map(\.id) == Array(ids.prefix(2)))
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

    @Test func deletingTheFirstPageMovesItsItemsToTheStartOfTheNext() {
        var g = grid([["A", "B"], ["C", "D"]])
        g.deletePage(0)
        #expect(g.pages.map(titles) == [["A", "B", "C"], ["D"]])
    }

    @Test func deletingAPageKeepsLeftoversOffTheNextTitledPage() {
        var g = grid([["A", "B"], ["C"], ["D", "E"]], columns: 2)
        g.pages[0].title = "T1"
        g.pages[2].title = "T3"
        g.deletePage(1)
        #expect(g.pages.map(titles) == [["A", "B"], ["C"], ["D", "E"]])
        #expect(g.pages.map(\.title) == ["T1", nil, "T3"])

        var h = grid([["A", "B"], ["C"], ["D"]], columns: 2)
        h.deletePage(1)
        #expect(h.pages.map(titles) == [["A", "B"], ["C", "D"]], "an untitled page with room takes them")
    }

    @Test func ungroupInPlace() {
        var g = grid([["A", "B", "C"]])
        let fid = g.group([g.pages[0].items[1].id, g.pages[0].items[2].id], name: "F")!
        g.ungroup(fid)
        #expect(titles(g.pages[0]) == ["A", "B", "C"])
    }

    @Test func ungroupOnAFullPageSpillsOntoTheNext() {
        var g = grid([["A", "B", "C"], ["X"]])
        let fid = g.group([g.pages[0].items[0].id, g.pages[0].items[1].id], name: "F")!
        g.insert([.app(app("D"))], page: 0, at: 2)
        #expect(g.pages.map(titles) == [["F", "C", "D"], ["X"]])
        g.ungroup(fid)
        #expect(g.pages.map(titles) == [["A", "B", "C"], ["D", "X"]])
    }

    @Test func deletingTheOnlyPageKeepsItsItems() {
        var g = grid([["A", "B"]])
        g.pages[0].title = "Work"
        g.deletePage(0)
        #expect(g.pages.map(titles) == [["A", "B"]])
        #expect(g.pages[0].title == nil)
        g.deletePage(5)
        #expect(g.pages.count == 1)
    }

    @Test func addPageAndSetPageTitle() {
        var g = grid([["A"], ["B"]])
        #expect(g.addPage() == 2)
        #expect(g.addPage(after: 0, title: "New") == 1)
        #expect(g.pages.map(titles) == [["A"], [], ["B"], []])
        #expect(g.pages[1].title == "New")
        #expect(g.addPage(after: -5) == 0, "a negative index means the start")
        #expect(g.addPage(after: 99) == g.pages.count - 1)

        g.setPageTitle(0, "  Games  ")
        #expect(g.pages[0].title == "Games")
        g.setPageTitle(0, " ")
        #expect(g.pages[0].title == nil)
        g.setPageTitle(2, nil)
        #expect(g.pages[2].title == nil)
        g.setPageTitle(99, "Nope")
        #expect(!g.pages.contains { $0.title == "Nope" })
    }

    @Test func gridSizeStaysPositive() {
        var g = grid([["A"]])
        g.rows = 0
        g.columns = -2
        #expect(g.rows == 1 && g.columns == 1)
        g.resize(rows: 0, columns: 0)
        #expect(g.capacity == 1)
        #expect(Grid(rows: 0, columns: -1).capacity == 1)
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

    @Test func rejectsCorruptJSON() {
        #expect(throws: GridFileError.self) { try GridStore.decode(Data("{\"rows\": 5, \"pages\": [".utf8)) }
        #expect(throws: GridFileError.self) { try GridStore.decode(Data(#"{"pages": [{"items": [{"type": "nope"}]}]}"#.utf8)) }
    }

    @Test func aNewerVersionWrittenAsTextIsStillNewer() {
        #expect {
            try GridStore.decode(Data(#"{"version": "2", "rows": 5, "columns": 7, "pages": []}"#.utf8))
        } throws: { error in
            if case GridFileError.unsupportedVersion(2) = error { true } else { false }
        }
    }

    @Test func rejectsOutOfRangeSize() {
        let data = Data(#"{"version": 1, "rows": 51, "columns": 7, "pages": []}"#.utf8)
        #expect(throws: GridFileError.self) { try GridStore.decode(data) }
    }

    @Test func zeroSizeIsClampedToOne() throws {
        let g = try GridStore.decode(Data(#"{"version": 1, "rows": 0, "columns": -3, "pages": []}"#.utf8))
        #expect(g.rows == 1 && g.columns == 1)
    }

    @Test func saveKeepsThePreviousSaveAsABackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GridStore(url: dir.appendingPathComponent("grid.json"))
        let first = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(app("A"))])])
        var second = first
        second.pages[0].items.append(.app(app("B")))
        try store.save(first)
        #expect(throws: (any Error).self) { try store.loadBackup() }
        try store.save(second)
        #expect(try store.load() == second)
        #expect(try store.loadBackup() == first)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "the temporary file is renamed into place")
    }

    @Test func versionOneAsTextLoadsAndZeroIsRejected() throws {
        #expect(try GridStore.decode(Data(#"{"version": "1", "rows": 2, "columns": 2, "pages": []}"#.utf8)).rows == 2)
        #expect(throws: GridFileError.self) { try GridStore.decode(Data(#"{"version": 0, "pages": []}"#.utf8)) }
    }

    @Test func encodingTheSameGridTwiceWritesTheSameBytes() throws {
        let g = Grid(removedBundleIDs: Set((0..<20).map { "com.test.\($0)" }))
        let once = try GridStore.encode(g)
        #expect(try GridStore.encode(GridStore.decode(once)) == once)
    }

    @Test func saveCanKeepAnOlderBackupAndSweepsLeftoverTemporaryFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GridStore(url: dir.appendingPathComponent("grid.json"))
        try store.save(Grid(rows: 1, columns: 1))
        #expect(try store.save(Grid(rows: 2, columns: 2)), "the first file becomes the backup")
        #expect(try !store.save(Grid(rows: 3, columns: 3), refreshingBackup: false))
        #expect(try store.loadBackup().rows == 1, "older than the save before this one")

        let stray = dir.appendingPathComponent(".grid.json.\(UUID().uuidString).tmp")
        try Data("half".utf8).write(to: stray)
        try store.save(Grid(rows: 4, columns: 4))
        #expect(!FileManager.default.fileExists(atPath: stray.path), "left by a save cut short")
        #expect(try store.loadBackup().rows == 3)
    }

    @Test func saveKeepsASymlinkedFileASymlink() throws {
        let fm = FileManager.default
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let real = dir.appendingPathComponent("dotfiles/grid.json")
        let link = dir.appendingPathComponent("support/grid.json")
        try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let g = Grid(rows: 2, columns: 3, pages: [Page(items: [.app(app("A"))])])
        try GridStore(url: link).save(g)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try GridStore(url: real).load() == g)
        try GridStore(url: link).save(Grid(rows: 3, columns: 3))
        #expect(try GridStore(url: real).load().rows == 3, "later saves land in the target too")
    }

    @Test func recentlyPrunedRoundTripsAndOldFilesStillLoad() throws {
        var g = Grid(rows: 1, columns: 2, pages: [Page(items: [.app(app("A"))])])
        g.recentlyPruned = [PrunedApp(app: app("B"), prunedAt: Date(timeIntervalSinceReferenceDate: 1000),
                                      pageID: g.pages[0].id, index: 1, folderID: UUID(), folderName: "F", folderIndex: 0)]
        #expect(try GridStore.decode(GridStore.encode(g)) == g)
        let old = Data(#"{"version": 1, "rows": 1, "columns": 2, "pages": [], "removedBundleIDs": []}"#.utf8)
        #expect(try GridStore.decode(old).recentlyPruned.isEmpty)
    }

    @Test func repeatedItemIDsGetFreshOnes() throws {
        let id = UUID()
        let a = AppRef(id: id, bundleID: "com.test.a", path: "/Applications/A.app")
        let b = AppRef(id: id, bundleID: "com.test.b", path: "/Applications/B.app")
        let c = AppRef(id: id, bundleID: "com.test.c", path: "/Applications/C.app")
        let g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(a), .folder(Folder(id: id, name: "F", apps: [b, c]))])])
        var decoded = try GridStore.decode(GridStore.encode(g))
        let ids = [decoded.pages[0].items[0].id, decoded.pages[0].items[1].id] + (decoded.pages[0].items[1].folder?.apps.map(\.id) ?? [])
        #expect(ids.count == 4 && Set(ids).count == 4)
        #expect(ids[0] == id, "the first keeps its ID")
        #expect(decoded.allApps.map(\.name) == ["A", "B", "C"])
        decoded.remove([id])
        #expect(decoded.allApps.map(\.name) == ["B", "C"], "an ID now means one item")
    }

    @Test func repeatedPageIDsGetFreshOnes() throws {
        let id = UUID()
        let g = Grid(rows: 2, columns: 2, pages: [Page(id: id, items: [.app(app("A"))]), Page(id: id, items: [.app(app("B"))])])
        let decoded = try GridStore.decode(GridStore.encode(g))
        #expect(decoded.pages[0].id == id)
        #expect(decoded.pages[1].id != id)
    }

    @Test func anUnreadableEntrySkipsOnlyItself() throws {
        let json = #"""
        {"rows": 2, "columns": 2, "pages": [
          {"items": [
            {"type": "app", "app": {"path": "/Applications/A.app", "name": "A"}},
            {"type": "app", "app": {"name": "No path"}},
            {"type": "widget", "widget": {}},
            {"type": "folder", "folder": {"name": "F", "apps": [{"name": "Broken"}, {"path": "/Applications/B.app"}]}}
          ]},
          "not a page",
          {"items": [{"type": "app", "app": {"path": "/Applications/C.app"}}]}
        ]}
        """#
        let g = try GridStore.decode(Data(json.utf8))
        #expect(g.pages.map(titles) == [["A", "F"], ["C"]])
        #expect(g.pages[0].items[1].folder?.apps.map(\.name) == ["B"])
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
    @Test func otherScriptsLigaturesAndSeparatorOnlyQueries() {
        #expect(Search.score("网易云音乐", query: "网音") != nil, "two characters are enough outside ASCII")
        #expect(Search.score("Google Chrome", query: "gc") != nil, "initials, not the subsequence")
        #expect(Search.score("Mail", query: "ml") == nil, "two ASCII letters still aren't a subsequence")
        #expect(Search.score("カメラ", query: "かめら") == 1000)
        #expect(Search.score("Æther", query: "aeth") != nil)
        #expect(Search.score("Wi-Fi Explorer", query: "-") == nil)
        #expect(Search.score("Wi-Fi Explorer", query: " - ") == nil)
        #expect(Search.score("Почта", query: "пт") == nil, "two Cyrillic letters aren't a subsequence either")
        #expect(Search.score("Почта", query: "пчт") != nil)
    }

    @Test func aHangulSyllableStillBeingTypedMatches() {
        #expect(Search.score("한글", query: "하") != nil)
        #expect(Search.score("한글", query: "한ㄱ") != nil)
        #expect(Search.score("한글", query: "한글") == 1000)
        #expect(Search.score("카카오톡", query: "톡") != nil)
        #expect(Search.score("카카오톡", query: "하") == nil)
    }

    @Test func aHangulNameInDecomposedFormMatches() {
        let decomposed = "한글".decomposedStringWithCanonicalMapping
        #expect(decomposed.unicodeScalars.count > 2)
        #expect(Search.score(decomposed, query: "한") != nil)
        #expect(Search.score(decomposed, query: "하") != nil)
        #expect(Search.score(decomposed, query: "한글") == 1000)
    }

    @Test func initialsAndWordsTogether() {
        let code = app("Visual Studio Code")
        #expect(Search.score(code.name, query: "vs code") == 600, "as initials, not a fuzzy match")
        #expect(Search.score(code.name, query: "visual sc") == 600)
        #expect(Search.score(code.name, query: "vs") == 600)
        #expect(Search.score(code.name, query: "code vs") == nil || Search.score(code.name, query: "code vs")! < 600, "in order")
        #expect(Search.score("Final Cut Pro", query: "fc pro") == 600)
    }

    @Test func ranking() {
        let apps = ["Notes", "Keynote", "Notion", "Sonoma Notes", "Final Cut Pro", "GarageBand"].map { app($0) }
        let no = Search.results(in: apps, query: "no").map(\.name)
        #expect(no == ["Notes", "Notion", "Sonoma Notes", "Keynote"])
        #expect(Search.results(in: apps, query: "fcp").map(\.name) == ["Final Cut Pro"])
        #expect(Search.results(in: apps, query: "gb").map(\.name) == ["GarageBand"])
        #expect(Search.results(in: apps, query: "grbd").map(\.name) == ["GarageBand"])
        #expect(Search.results(in: apps, query: "zzz").isEmpty)
        #expect(Search.acronym(of: "PDFExpert") == "pe", "a hump after a run of capitals")
        #expect(Search.acronym(of: "Visual Studio Code") == "vsc")
        #expect(Search.acronym(of: "GarageBand") == "gb")
        #expect(Search.acronym(of: "iMovie") == "im")
        #expect(Search.acronym(of: "VLC") == "v")
    }

    @Test func wordStartBeatsInitialsForLongNames() {
        let long = app("Some Very Long Application Name That Goes On And On And On Pro")
        let initials = app("Photo Raw Organizer")
        #expect(Search.results(in: [initials, long], query: "pro").map(\.name) == [long.name, initials.name])
        for n in [1, 20, 50, 51, 99, 150] {
            let name = String(repeating: "x", count: n)
            let word = Search.score(name + " Pro", query: "pro")!
            #expect(Search.score("pro" + name, query: "pro")! > word)
            #expect(word > Search.score("Photo Raw Organizer", query: "pro")!)
            #expect(Search.score("Photo Raw Organizer", query: "pro")! > Search.score("x" + name + "pro", query: "pro")!)
            #expect(Search.score("x" + name + "pro", query: "pro")! > Search.score("p" + name + "ro", query: "pro")!)
        }
    }

    @Test func separatorsDontCountTowardsAPrefix() {
        let apps = ["WiFiman", "Kiwifier", "Wi-Fi Explorer", "Visual Studio Code"].map { app($0) }
        #expect(Search.results(in: apps, query: "wifi").map(\.name) == ["WiFiman", "Wi-Fi Explorer", "Kiwifier"])
        #expect(Search.results(in: apps, query: "visual-").map(\.name) == ["Visual Studio Code"])
        #expect(Search.results(in: apps, query: "code.").map(\.name) == ["Visual Studio Code"])
        #expect(Search.results(in: apps, query: "wi fi").map(\.name) == ["WiFiman", "Wi-Fi Explorer"])
    }

    @Test func aPrefixDoesNotRunAcrossASpaceInTheName() {
        #expect(Search.score("App Store", query: "apps").map { $0 < 500 } ?? true)
        #expect(Search.score("Visual Studio Code", query: "visuals").map { $0 < 500 } ?? true)
        #expect(Search.score("Visual  Studio Code", query: "visual studio")! > 800, "runs of spaces count as one")
        let apps = ["Notes", "Note Station", "Notes Manager Pro"].map { app($0) }
        #expect(Search.results(in: apps, query: "notes").map(\.name) == ["Notes", "Notes Manager Pro", "Note Station"])
    }

    @Test func eachQueryWordStartsADifferentWord() {
        let apps = ["Microsoft Word", "Word Counter"].map { app($0) }
        #expect(Search.results(in: apps, query: "word word").isEmpty)
        #expect(Search.results(in: apps, query: "word co").map(\.name) == ["Word Counter"])
    }

    @Test func queryWordsMatchInAnyOrder() {
        let apps = ["Microsoft Word", "Microsoft Excel", "Wordle", "Visual Studio Code"].map { app($0) }
        #expect(Search.results(in: apps, query: "word micro").map(\.name) == ["Microsoft Word"])
        #expect(Search.results(in: apps, query: "code  visual").map(\.name) == ["Visual Studio Code"])
        #expect(Search.score("Microsoft Word", query: "word micro") == Search.score("Microsoft Word", query: "wor"),
                "ranked in the word-start tier")
        #expect(Search.score("Microsoft Word", query: "word zzz") == nil)
        #expect(Search.score("Microsoft Word", query: "ord micro") == nil, "each word must start a word")
    }

    @Test func diacriticInsensitiveAndRenames() {
        var a = app("Café")
        a.displayName = "Coffee"
        #expect(Search.results(in: [a], query: "cafe").count == 1)
        #expect(Search.results(in: [a], query: "coff").count == 1)
    }
}

@Suite struct EmptiedPagesTests {
    @Test func removesOnlyPagesEmptiedByTheChange() {
        var g = Grid(rows: 1, columns: 3, pages: [Page(items: [.app(app("A"))]), Page(), Page(items: [.app(app("B"))])])
        let b = g.pages[2].items[0].id
        g.removingEmptiedPages { $0.move([b], toPage: 0, at: 1) }
        #expect(g.pages.count == 2) // the user-made empty page survives
        #expect(titles(g.pages[0]) == ["A", "B"])
    }
}
