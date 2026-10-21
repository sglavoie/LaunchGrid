import Foundation
import SQLite3
import Testing
@testable import LaunchGridCore

func installed(_ name: String, id: String? = nil, path: String? = nil, category: String? = nil) -> InstalledApp {
    InstalledApp(bundleID: id ?? "com.test.\(name.lowercased())", path: path ?? "/Applications/\(name).app",
                 name: name, category: category)
}

@Suite struct ReconcilerTests {
    @Test func addsNewAppsWhenAutoAddIsOn() {
        var g = Grid(rows: 1, columns: 2, pages: [Page(items: [.app(app("A"))])])
        let report = Reconciler.reconcile(&g, installed: [installed("A"), installed("C"), installed("B")], autoAdd: true)
        #expect(report.added == ["B", "C"])
        #expect(g.pages.map(titles) == [["A", "B"], ["C"]])
    }

    @Test func doesNotAddWhenAutoAddIsOff() {
        var g = Grid(rows: 1, columns: 2, pages: [Page(items: [.app(app("A"))])])
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("B")], autoAdd: false)
        #expect(g.allApps.map(\.name) == ["A"])
    }

    @Test func removesUninstalledAppsAndEmptyFolders() {
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(app("A")), .app(app("B"))])])
        g.group([g.pages[0].items[1].id], name: "F")
        let report = Reconciler.reconcile(&g, installed: [installed("A")], autoAdd: true)
        #expect(report.removed == ["B"])
        #expect(titles(g.pages[0]) == ["A"])
    }

    @Test func emptyScanNeverPrunes() {
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(app("A"))])])
        _ = Reconciler.reconcile(&g, installed: [], autoAdd: true)
        #expect(g.allApps.count == 1)
    }

    @Test func unreachableAppsAreKept() {
        let ext = AppRef(bundleID: "com.test.ext", path: "/Volumes/Drive/Ext.app")
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(app("A")), .app(ext), .app(app("Gone"))])])
        let report = Reconciler.reconcile(&g, installed: [installed("A")], autoAdd: true,
                                          isReachable: { !$0.hasPrefix("/Volumes/Drive/") })
        #expect(report.removed == ["Gone"])
        #expect(titles(g.pages[0]) == ["A", "Ext"])
    }

    @Test func movedAppKeepsItsSlot() {
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(app("A")), .app(app("B"))])])
        let report = Reconciler.reconcile(&g, installed: [installed("A"), installed("B", path: "/Users/x/Applications/B.app")],
                                          autoAdd: true)
        #expect(report.moved == ["B"])
        #expect(g.pages[0].items[1].app?.path == "/Users/x/Applications/B.app")
    }

    @Test func respectsRemovedList() {
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(app("A")), .app(app("B"))])])
        g.remove([g.pages[0].items[1].id])
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("B")], autoAdd: true)
        #expect(g.allApps.map(\.name) == ["A"])

        let missing = Reconciler.missingApps(in: g, installed: [installed("A"), installed("B")])
        #expect(missing.map(\.name) == ["B"])
        Reconciler.add(missing, to: &g)
        #expect(g.removedBundleIDs.isEmpty)
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("B")], autoAdd: true)
        #expect(g.allApps.map(\.name) == ["A", "B"])
    }

    @Test func choosingAppsRemovesExcludedAndAddsIncluded() {
        var g = Grid(rows: 1, columns: 2, pages: [Page(items: [.app(app("A"))]), Page(items: [.app(app("B"))])])
        g.group([g.pages[0].items[0].id], name: "F")
        g.removedBundleIDs = ["com.test.c"]
        Reconciler.choose(include: [installed("C")], exclude: [installed("A"), installed("B"), installed("D")], in: &g)
        #expect(g.pages.map(titles) == [["C"]], "emptied folder and page go")
        #expect(g.removedBundleIDs == ["com.test.a", "com.test.b", "com.test.d"])
        _ = Reconciler.reconcile(&g, installed: ["A", "B", "C", "D"].map { installed($0) }, autoAdd: true)
        #expect(g.allApps.map(\.name) == ["C"], "scans keep excluded apps out")
    }

    @Test func dropsDuplicatesAndRefreshesNames() {
        var a2 = app("A")
        a2.name = "Old"
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(a2), .app(app("A"))])])
        let report = Reconciler.reconcile(&g, installed: [installed("A")], autoAdd: false)
        #expect(report.duplicatesDropped == 1)
        #expect(g.allApps.map(\.name) == ["A"])
    }

    @Test func appWithoutBundleIDMatchesByPath() {
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(AppRef(bundleID: nil, path: "/Applications/X.app"))])])
        _ = Reconciler.reconcile(&g, installed: [InstalledApp(bundleID: nil, path: "/Applications/X.app", name: "X")], autoAdd: true)
        #expect(g.allApps.count == 1)
    }
}

@Suite struct BuilderTests {
    @Test func pagesByCategory() {
        let apps = [
            installed("Xcode", category: "public.app-category.developer-tools"),
            installed("Chess", category: "public.app-category.board-games"),
            installed("Pages", category: "public.app-category.productivity"),
            installed("Weird"),
            installed("Terminal", category: "public.app-category.developer-tools"),
        ]
        let g = GridBuilder.build(from: apps, style: .byCategory, rows: 1, columns: 1)
        #expect(g.pages.map(\.title) == ["Developer Tools", "Developer Tools", "Games", "Productivity", "Other"])
        #expect(g.pages.map(titles) == [["Terminal"], ["Xcode"], ["Chess"], ["Pages"], ["Weird"]])
    }

    @Test func alphabetical() {
        let g = GridBuilder.build(from: [installed("b"), installed("A"), installed("c")], style: .alphabetical, rows: 1, columns: 2)
        #expect(g.pages.map(titles) == [["A", "b"], ["c"]])
    }
}

@Suite struct ScannerTests {
    @Test func findsAppsInNestedFoldersButNotInsideBundles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        func makeApp(_ rel: String, id: String) throws {
            let contents = root.appendingPathComponent(rel).appendingPathComponent("Contents")
            try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleExecutable": "x"]
            try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try makeApp("One.app", id: "t.one")
        try makeApp("Suite/Two.app", id: "t.two")
        try makeApp("One.app/Contents/Helpers/Helper.app", id: "t.helper")
        try makeApp("Copy/One.app", id: "t.one")
        try fm.createSymbolicLink(at: root.appendingPathComponent("Suite/loop"), withDestinationURL: root)
        defer { try? fm.removeItem(at: root) }

        let found = AppScanner.scan(roots: [root])
        #expect(Set(found.compactMap(\.bundleID)) == ["t.one", "t.two"])
        #expect(found.first { $0.bundleID == "t.two" }?.name == "Two")
    }
}

@Suite struct ImporterTests {
    /// Builds a Launchpad-style DB: root(1) → pages → apps and a folder (type 2) with its own page.
    func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lp-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE items (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER NOT NULL, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR, category_id INTEGER, moddate REAL, bookmark BLOB);
        CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR);
        INSERT INTO items VALUES (1,'',0,1,0,0), (2,'',0,1,0,0), (3,'',0,1,0,0);
        INSERT INTO items VALUES (10,'',0,3,1,0);          -- holding page on root 1
        INSERT INTO items VALUES (20,'',0,3,2,1), (21,'',0,3,2,0);  -- pages, out of order
        INSERT INTO items VALUES (100,'',0,4,20,0), (101,'',0,4,21,1), (102,'',0,2,21,0), (103,'',0,3,102,0);
        INSERT INTO items VALUES (104,'',0,4,103,0), (105,'',0,4,103,1), (106,'',0,4,21,2), (107,'',0,6,21,3);
        INSERT INTO apps VALUES (100,'Safari','com.apple.Safari',NULL,NULL,0,NULL);
        INSERT INTO apps VALUES (101,'Mail','com.apple.mail',NULL,NULL,0,NULL);
        INSERT INTO apps VALUES (104,'Notes','com.apple.Notes',NULL,NULL,0,NULL);
        INSERT INTO apps VALUES (105,'Gone','com.gone',NULL,NULL,0,NULL);
        INSERT INTO apps VALUES (106,'Mail again','com.apple.mail',NULL,NULL,0,NULL);
        INSERT INTO groups VALUES (102,NULL,'Stuff');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return url
    }

    @Test func importsPagesFoldersAndSkipsUnresolvable() throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try LaunchpadImporter.importDatabase(at: url, rows: 5, columns: 7) { id in
            id == "com.gone" ? nil : "/Applications/\(id).app"
        }
        #expect(r.grid.pages.count == 2)
        #expect(titles(r.grid.pages[0]) == ["Stuff", "Mail"])
        #expect(r.grid.pages[0].items[0].folder?.apps.map(\.name) == ["Notes"])
        #expect(titles(r.grid.pages[1]) == ["Safari"])
        #expect(r.skipped == ["Gone"])
        #expect(r.imported == 3)
    }

    @Test func readsChangesStillInTheWriteAheadLog() throws {
        let url = try makeFixture()
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        // Keep a writer open with checkpointing off, as a running Dock or AppGrid would.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA wal_autocheckpoint=0;
        INSERT INTO items VALUES (108,'',0,4,20,1);
        INSERT INTO apps VALUES (108,'Maps','com.apple.Maps',NULL,NULL,0,NULL);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))

        let r = try LaunchpadImporter.importDatabase(at: url, rows: 5, columns: 7) { "/Applications/\($0).app" }
        #expect(titles(r.grid.pages[1]) == ["Safari", "Maps"])
    }

    @Test func rejectsNonLaunchpadFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).db")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "CREATE TABLE foo (a);", nil, nil, nil)
        sqlite3_close(db)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: LaunchpadImporter.ImportError.self) {
            try LaunchpadImporter.importDatabase(at: url, rows: 5, columns: 7) { _ in nil }
        }
    }

    /// Runs against a copy of a real AppGrid database when one is supplied.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPGRID_FIXTURE"] != nil))
    func importsRealAppGridDatabase() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["APPGRID_FIXTURE"]!)
        let r = try LaunchpadImporter.importDatabase(at: url, rows: 5, columns: 7) { _ in nil }
        print("AppGrid import: \(r.grid.pages.count) pages, \(r.imported) apps, skipped \(r.skipped.count)")
        #expect(r.imported > 0)
        #expect(r.grid.allApps.count == Set(r.grid.allApps.map(\.key)).count)
    }
}
