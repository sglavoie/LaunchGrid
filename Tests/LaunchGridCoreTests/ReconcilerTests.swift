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

    @Test func pathMatchWithADifferentBundleIDAdoptsTheNewIdentity() {
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(app("A")), .app(app("B"))])])
        let report = Reconciler.reconcile(&g, installed: [installed("A"), installed("B", id: "com.vendor.b")],
                                          autoAdd: true, pathExists: { _ in true })
        #expect(report.removed.isEmpty && report.added.isEmpty)
        #expect(g.allApps.map(\.bundleID) == ["com.test.a", "com.vendor.b"])
    }

    @Test func pathMatchWithADifferentBundleIDFollowsTheOriginalWhenItMoved() {
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(app("A")), .app(app("B"))])])
        let report = Reconciler.reconcile(&g, installed: [installed("A"), installed("B", id: "com.other"),
                                                          installed("B2", id: "com.test.b", path: "/Users/x/Applications/B.app")],
                                          autoAdd: false, pathExists: { _ in true })
        #expect(report.moved == ["B2"])
        #expect(g.pages[0].items[1].app?.path == "/Users/x/Applications/B.app")
    }

    @Test func copiesSharingABundleIDStayApart() {
        let xcode = AppRef(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", name: "Xcode")
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(xcode)])])
        let apps = [installed("Xcode-beta", id: "com.apple.dt.Xcode"), installed("Xcode", id: "com.apple.dt.Xcode")]
        let report = Reconciler.reconcile(&g, installed: apps, autoAdd: true)
        #expect(report.moved.isEmpty)
        #expect(g.allApps.map(\.path) == ["/Applications/Xcode.app", "/Applications/Xcode-beta.app"])

        // Only when Xcode.app itself is gone does its ref follow the bundle ID.
        var h = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(xcode)])])
        _ = Reconciler.reconcile(&h, installed: [apps[0]], autoAdd: false, pathExists: { _ in true })
        #expect(h.allApps.isEmpty, "Xcode.app still exists on disk, so it is not moved onto the beta")
        var i = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(xcode)])])
        let moved = Reconciler.reconcile(&i, installed: [apps[0]], autoAdd: false, pathExists: { _ in false })
        #expect(moved.moved == ["Xcode-beta"])
    }

    @Test func appBrieflyMissingReturnsToItsSlotFolderAndName() {
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: [.app(app("A")), .app(app("B")), .app(app("C")), .app(app("D"))])])
        let ids = g.pages[0].items.map(\.id)
        g.rename(ids[1], to: "Bee")
        let fid = g.group([ids[3]], name: "F")!
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let all = ["A", "B", "C", "D"].map { installed($0) }

        // An updater deletes B and D (D alone in its folder), then copies them back.
        let gone = Reconciler.reconcile(&g, installed: [all[0], all[2]], autoAdd: true, now: t0)
        #expect(gone.removed == ["Bee", "D"])
        #expect(titles(g.pages[0]) == ["A", "C"])
        let back = Reconciler.reconcile(&g, installed: all, autoAdd: true, now: t0 + 30)
        #expect(back.restored == ["Bee", "D"])
        #expect(back.added.isEmpty)
        #expect(titles(g.pages[0]) == ["A", "Bee", "C", "F"])
        #expect(g.item(ids[1])?.app?.displayName == "Bee", "same ref, same ID")
        #expect(g.folder(fid)?.apps.map(\.id) == [ids[3]])
        #expect(g.recentlyPruned.isEmpty)
    }

    @Test func appMissingInsideAFolderReturnsToItsPlaceThere() {
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: [.app(app("A")), .app(app("B")), .app(app("C"))])])
        let fid = g.group(g.pages[0].items.map(\.id), name: "F")!
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("C")], autoAdd: false, now: t0)
        _ = Reconciler.reconcile(&g, installed: ["A", "B", "C"].map { installed($0) }, autoAdd: false, now: t0 + 5)
        #expect(g.folder(fid)?.apps.map(\.name) == ["A", "B", "C"])
    }

    @Test func folderTheUserUngroupedIsNotRecreatedOnRestore() {
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: [.app(app("A")), .app(app("B")), .app(app("C"))])])
        let fid = g.group(g.pages[0].items.map(\.id), name: "F")!
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("C")], autoAdd: false, now: t0)
        g.ungroup(fid)
        _ = Reconciler.reconcile(&g, installed: ["A", "B", "C"].map { installed($0) }, autoAdd: false, now: t0 + 5)
        #expect(g.folder(fid) == nil)
        #expect(g.pages[0].items.allSatisfy { $0.app != nil })
        #expect(Set(titles(g.pages[0])) == ["A", "B", "C"])
    }

    @Test func restoreSkipsAReplacementTheUserRemoved() {
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: [.app(app("A")), .app(app("B"))])])
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = Reconciler.reconcile(&g, installed: [installed("A")], autoAdd: false, now: t0)
        g.removedBundleIDs.insert("com.other")
        // B's path comes back holding a different app, which the user has excluded.
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("B", id: "com.other")], autoAdd: false, now: t0 + 5)
        #expect(g.allApps.map(\.name) == ["A"])
    }

    @Test func appMissingPastTheWindowIsAddedAsNew() {
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: [.app(app("B")), .app(app("A"))])])
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = Reconciler.reconcile(&g, installed: [installed("A")], autoAdd: true, now: t0)
        let later = Reconciler.reconcile(&g, installed: [installed("A"), installed("B")], autoAdd: true,
                                         now: t0 + Reconciler.restoreWindow + 1)
        #expect(later.restored.isEmpty && later.added == ["B"])
        #expect(titles(g.pages[0]) == ["A", "B"])
        #expect(g.recentlyPruned.isEmpty)
    }

    @Test func prunedAppTheUserThenRemovedStaysOut() {
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: [.app(app("A")), .app(app("B"))])])
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = Reconciler.reconcile(&g, installed: [installed("A")], autoAdd: true, now: t0)
        g.removedBundleIDs.insert("com.test.b")
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("B")], autoAdd: true, now: t0 + 5)
        #expect(g.allApps.map(\.name) == ["A"])
        #expect(g.recentlyPruned.isEmpty)
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

/// Writes a minimal app bundle (just an Info.plist) at `rel` under `root`.
func makeFakeApp(_ rel: String, id: String, in root: URL) throws {
    let fm = FileManager.default
    let contents = root.appendingPathComponent(rel).appendingPathComponent("Contents")
    try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleExecutable": "x"]
    try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
}

func tempDir(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
}

@Suite struct ScannerTests {
    @Test func findsAppsInNestedFoldersButNotInsideBundles() throws {
        let fm = FileManager.default
        let root = tempDir("scan")
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

    @Test func respectsTheDepthLimitButWalksNestedRootsFully() throws {
        let root = tempDir("scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFakeApp("One.app", id: "t.one", in: root)
        try makeFakeApp("a/b/Three.app", id: "t.three", in: root)
        try makeFakeApp("a/b/c/Four.app", id: "t.four", in: root)
        try makeFakeApp("a/b/c/d/Five.app", id: "t.five", in: root)

        #expect(AppScanner.scan(roots: [root]).map(\.name) == ["One", "Three"])
        // An extra root inside a default root's depth limit is walked from its own depth.
        let nested = root.appendingPathComponent("a/b")
        let found = AppScanner.scan(roots: [root, nested]).map(\.name)
        #expect(found == ["One", "Three", "Four", "Five"])
    }

    @Test func keepsCopiesSharingABundleID() throws {
        let root = tempDir("scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFakeApp("Xcode.app", id: "com.apple.dt.Xcode", in: root)
        try makeFakeApp("Xcode-beta.app", id: "com.apple.dt.Xcode", in: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link.app"),
                                                   withDestinationURL: root.appendingPathComponent("Xcode.app"))
        let found = AppScanner.scan(roots: [root])
        #expect(found.map(\.name).sorted() == ["Link", "Xcode-beta"] || found.map(\.name).sorted() == ["Xcode", "Xcode-beta"])
        #expect(found.count == 2, "a symlink to a scanned bundle is the same app")
    }

    @Test func findsHiddenAppLinksButSkipsHiddenFolders() throws {
        let fm = FileManager.default
        let root = tempDir("scan")
        let elsewhere = tempDir("scan-target")
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: elsewhere) }
        try makeFakeApp("Safari.app", id: "t.safari", in: elsewhere)
        try makeFakeApp("Secret/Inner.app", id: "t.inner", in: root)
        try makeFakeApp(".Dot.app", id: "t.dot", in: root)
        let link = root.appendingPathComponent("Safari.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: elsewhere.appendingPathComponent("Safari.app"))
        // Like /Applications/Safari.app: a symlink carrying the hidden flag itself.
        #expect(lchflags(link.path, UInt32(UF_HIDDEN)) == 0)
        #expect(chflags(root.appendingPathComponent("Secret").path, UInt32(UF_HIDDEN)) == 0)
        #expect(AppScanner.scan(roots: [root]).map(\.bundleID) == ["t.safari"])
    }

    @Test func readIsNilWithoutAnInfoPlist() throws {
        let root = tempDir("scan")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        #expect(AppScanner.read(appAt: empty) == nil)
        #expect(AppScanner.read(appAt: root.appendingPathComponent("Missing.app")) == nil)
        try makeFakeApp("Real.app", id: "t.real", in: root)
        #expect(AppScanner.read(appAt: root.appendingPathComponent("Real.app"))?.bundleID == "t.real")
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

    @Test func usesCustomPathsAndRealIDsForManualApps() throws {
        let dir = tempDir("lp")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeApp("Tool.app", id: "t.tool", in: dir)
        try makeFakeApp("Elsewhere/Mail.app", id: "com.apple.mail", in: dir)
        let tool = dir.appendingPathComponent("Tool.app").path
        let mail = dir.appendingPathComponent("Elsewhere/Mail.app").path
        let url = dir.appendingPathComponent("db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        // AppGrid's layout: a type-3 root with parent 0, and a custom_path column.
        let sql = """
        CREATE TABLE items (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER NOT NULL, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, custom_path VARCHAR);
        INSERT INTO items VALUES (1,'',0,3,0,0), (10,'',0,3,1,0);
        INSERT INTO items VALUES (100,'',0,4,10,0), (101,'',0,4,10,1), (102,'',0,4,10,2), (103,'',0,4,10,3);
        INSERT INTO apps VALUES (100,'Tool','manual_app_1a2b','\(tool)');
        INSERT INTO apps VALUES (101,'Ghost','manual_app_3c4d','/nonexistent/Ghost.app');
        INSERT INTO apps VALUES (102,'Mail','com.apple.mail','\(mail)');
        INSERT INTO apps VALUES (103,'Safari','com.apple.Safari',NULL);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let r = try LaunchpadImporter.importDatabase(at: url, rows: 5, columns: 7) { "/Applications/\($0).app" }
        let apps = r.grid.allApps
        #expect(apps.map(\.name) == ["Tool", "Mail", "Safari"])
        #expect(apps.map(\.bundleID) == ["t.tool", "com.apple.mail", "com.apple.Safari"], "manual IDs are replaced by the bundle's")
        #expect(apps.map(\.path) == [tool, mail, "/Applications/com.apple.Safari.app"])
        #expect(r.skipped == ["Ghost"])
    }

    @Test func survivesParentCycles() throws {
        let url = tempDir("lp").appendingPathExtension("db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE items (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER NOT NULL, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR);
        INSERT INTO items VALUES (1,'',0,1,0,0), (2,'',0,1,3,0), (3,'',0,1,2,0), (4,'',0,1,4,0);  -- 2⇄3 cycle, 4 self-loop
        INSERT INTO items VALUES (5,'',0,3,2,0), (6,'',0,3,5,0), (7,'',0,3,6,0);
        UPDATE items SET parent_id = 7 WHERE rowid = 5;  -- page cycle 5→6→7→5
        INSERT INTO items VALUES (10,'',0,3,1,1), (100,'',0,4,10,0);
        INSERT INTO apps VALUES (100,'Mail','com.apple.mail');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let r = try LaunchpadImporter.importDatabase(at: url, rows: 5, columns: 7) { "/Applications/\($0).app" }
        #expect(r.grid.allApps.map(\.name) == ["Mail"])
    }

    @Test func queryThrowsWhenSteppingFails() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var rows = 0
        // The second row overflows abs() at step time, after one row came back fine.
        #expect(throws: LaunchpadImporter.ImportError.self) {
            try LaunchpadImporter.query(db!, "SELECT abs(x) FROM (SELECT 1 AS x UNION ALL SELECT -9223372036854775808)") { _ in rows += 1 }
        }
        #expect(rows == 1)
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
