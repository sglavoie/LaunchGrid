import Foundation
import SQLite3
import Testing
@testable import LaunchGridCore

func installed(_ name: String, id: String? = nil, path: String? = nil, category: String? = nil) -> InstalledApp {
    InstalledApp(bundleID: id ?? "com.test.\(name.lowercased())", path: path ?? "/Applications/\(name).app",
                 name: name, category: category)
}

@Suite struct ReconcilerTests {
    @Test(arguments: [false, true])
    func removingOneCopyKeepsATemporarilyMissingCopyIncluded(throughChooser: Bool) {
        let a = installed("A"), copy = installed("A-copy", id: "com.test.a")
        let missing = a.makeRef(), kept = copy.makeRef()
        var g = Grid(pages: [Page(items: [.app(missing), .app(kept)])])
        _ = Reconciler.reconcile(&g, installed: [copy], autoAdd: false,
                                 pathExists: { $0 == copy.path })

        if throughChooser {
            Reconciler.choose(include: [], exclude: [copy], in: &g, installed: [copy])
        } else {
            g.remove([kept.id], installed: [copy])
        }
        _ = Reconciler.reconcile(&g, installed: [a, copy], autoAdd: false)

        #expect(g.allApps.map(\.id) == [missing.id])
        #expect(!g.isExcluded(a))
        #expect(g.isExcluded(copy))
    }

    @Test(arguments: [false, true])
    func removingAFolderAlsoExcludesItsTemporarilyMissingApps(autoAdd: Bool) {
        let a = installed("A"), b = installed("B")
        let copy = installed("A-copy", id: a.bundleID)
        let folder = Folder(name: "Work", apps: [a.makeRef(), b.makeRef()])
        var g = Grid(pages: [Page(items: [.folder(folder), .app(copy.makeRef())])])
        _ = Reconciler.reconcile(&g, installed: [b, copy], autoAdd: autoAdd,
                                 pathExists: { $0 != a.path })
        #expect(g.recentlyPruned.map(\.app.path) == [a.path])

        g.remove([folder.id], installed: [b, copy])
        _ = Reconciler.reconcile(&g, installed: [a, b, copy], autoAdd: autoAdd)

        #expect(g.allApps.map(\.path) == [copy.path])
        #expect(g.isExcluded(a))
        #expect(g.isExcluded(b))
        #expect(!g.isExcluded(copy), "removing a missing copy must not exclude the one kept")
        #expect(g.recentlyPruned.isEmpty)
    }

    @Test(arguments: [false, true])
    func aGoneCopyCannotTakeATileWhosePathHasAnotherSpelling(throughAlias: Bool) {
        let gone = installed("Editor", path: "/Applications/Editor.app").makeRef()
        let kept = installed("Editor", path: "/Applications/Tools/Editor.app")
        let oldPath = throughAlias ? "/Tools/Editor.app" : "/Applications/Tools/EDITOR.app"
        let ref = AppRef(bundleID: kept.bundleID, path: oldPath, name: kept.name, displayName: "Work Editor")
        let folder = Folder(name: "Work", apps: [ref])
        var g = Grid(pages: [Page(items: [.app(gone), .folder(folder)])])

        let report = Reconciler.reconcile(&g, installed: [kept], autoAdd: true,
                                          pathExists: { $0 != gone.path },
                                          aliases: throughAlias ? [oldPath: kept.path] : [:])

        #expect(g.allApps.map(\.id) == [ref.id])
        #expect(g.folder(folder.id)?.apps.first?.title == "Work Editor")
        #expect(g.allApps.first?.path == kept.path)
        #expect(report.removed == [gone.title])
        #expect(report.moved.isEmpty && report.duplicatesDropped == 0)
    }

    @Test func addingAScannedAppAlreadyOnTheGridThroughAnAliasKeepsItsTile() {
        let scanned = installed("Safari")
        let real = "/System/Cryptexes/App/System/Applications/Safari.app"
        let ref = AppRef(bundleID: scanned.bundleID, path: real, name: "Safari", displayName: "Browser")
        var g = Grid(pages: [Page(items: [.app(ref)])])

        Reconciler.add([scanned], to: &g, installed: [scanned], aliases: [real: scanned.path])

        #expect(g.allApps == [ref], "adding the same app must preserve its tile and custom name")
    }

    @Test(arguments: [false, true])
    func addingACopyClearsItsExclusionUnderAnOlderSpelling(throughAlias: Bool) {
        let original = installed("Xcode", id: "com.apple.dt.Xcode")
        let beta = installed("Xcode-beta", id: original.bundleID)
        let oldPath = throughAlias ? "/Tools/Xcode-beta.app" : "/Applications/XCODE-BETA.app"
        var g = Grid(pages: [Page(items: [.app(original.makeRef())])], removedBundleIDs: [oldPath])

        Reconciler.add([beta], to: &g, installed: [original, beta],
                       aliases: throughAlias ? [oldPath: beta.path] : [:])
        _ = Reconciler.reconcile(&g, installed: [original, beta], autoAdd: true)

        #expect(g.removedBundleIDs.isEmpty, "a later rebuild must not exclude the app just added")
        #expect(g.allApps.map(\.path) == [original.path, beta.path])
    }

    @Test func addingDistinctScannedCopiesWhosePathsDifferOnlyInCaseKeepsBoth() {
        // A case-sensitive volume can contain both; the scanner has identified two bundles.
        let upper = installed("Editor", id: "com.test.editor")
        let lower = installed("editor", id: upper.bundleID)
        var g = Grid(pages: [Page(items: [.app(upper.makeRef())])])

        Reconciler.add([lower], to: &g, installed: [upper, lower])

        #expect(g.allApps.map(\.path) == [upper.path, lower.path])
    }

    @Test func addingAnExcludedCopyThroughAnotherCapitalizationClearsItsExclusion() {
        let original = installed("Xcode", id: "com.apple.dt.Xcode")
        let beta = installed("Xcode-beta", id: original.bundleID)
        var g = Grid(pages: [Page(items: [.app(original.makeRef()), .app(beta.makeRef())])])
        g.remove([g.allApps[1].id], installed: [original, beta])
        let picked = installed("XCODE-BETA", id: beta.bundleID)

        Reconciler.add([picked], to: &g, installed: [original, beta])

        #expect(!g.isExcluded(beta), "rebuilding must not remove the explicitly re-added copy")
        #expect(g.allApps.map(\.path) == [original.path, beta.path])
        #expect(g.allApps.last?.name == beta.name)
    }

    @Test func pathExclusionsFollowCaseOnlyRenames() {
        let original = installed("Xcode", id: "com.apple.dt.Xcode")
        let beta = installed("Xcode-beta", id: original.bundleID)
        var g = Grid(pages: [Page(items: [.app(original.makeRef()), .app(beta.makeRef())])])
        g.remove([g.allApps[1].id], installed: [original, beta])
        let renamed = installed("Xcode-Beta", id: original.bundleID)

        let report = Reconciler.reconcile(&g, installed: [original, renamed], autoAdd: true)

        #expect(g.allApps.map(\.path) == [original.path])
        #expect(g.removedBundleIDs == [renamed.path])
        #expect(report.added.isEmpty)
        Reconciler.add([renamed], to: &g, installed: [original, renamed])
        #expect(g.removedBundleIDs.isEmpty)
        #expect(g.allApps.map(\.path) == [original.path, renamed.path])
    }

    @Test func pathExclusionsFollowScannerAliases() {
        let original = installed("Xcode", id: "com.apple.dt.Xcode")
        let beta = installed("Xcode-beta", id: original.bundleID, path: "/Tools/Xcode-beta.app")
        let listed = installed("Xcode-beta", id: original.bundleID)
        var g = Grid(pages: [Page(items: [.app(original.makeRef()), .app(beta.makeRef())])])
        g.remove([g.allApps[1].id], installed: [original, beta])

        let report = Reconciler.reconcile(&g, installed: [original, listed], autoAdd: true,
                                          aliases: [beta.path: listed.path])

        #expect(g.allApps.map(\.path) == [original.path])
        #expect(g.removedBundleIDs == [listed.path])
        #expect(report.added.isEmpty)
        Reconciler.add([beta], to: &g, installed: [original, listed], aliases: [beta.path: listed.path])
        #expect(g.removedBundleIDs.isEmpty)
        #expect(g.allApps.map(\.path) == [original.path, listed.path])
    }

    @Test func addsNewAppsWhenAutoAddIsOn() {
        var g = Grid(rows: 1, columns: 2, pages: [Page(items: [.app(app("A"))])])
        let report = Reconciler.reconcile(&g, installed: [installed("A"), installed("C"), installed("B")], autoAdd: true)
        #expect(report.added == ["B", "C"])
        #expect(g.pages.map(titles) == [["A", "B"], ["C"]])
    }

    @Test func newAppsGoAtTheEndNotIntoEarlierGaps() {
        var g = Grid(rows: 1, columns: 4, pages: [
            Page(title: "Dev", items: [.app(app("A"))]),
            Page(title: "Games", items: [.app(app("C")), .app(app("D")), .app(app("E"))]),
        ])
        _ = Reconciler.reconcile(&g, installed: ["A", "C", "D", "E", "Y", "Z"].map { installed($0) }, autoAdd: true)
        #expect(g.pages.map(titles) == [["A"], ["C", "D", "E", "Y"], ["Z"]])

        Reconciler.add([installed("X")], to: &g)
        #expect(g.pages.map(titles) == [["A"], ["C", "D", "E", "Y"], ["Z", "X"]], "Add Missing Apps too")
    }

    @Test func anAppRenamedInOtherCapitalsKeepsItsTile() {
        // The disk ignores case, so the old spelling still exists: it isn't a move nor a prune.
        var g = Grid(rows: 1, columns: 3, pages: [Page(items: [.app(app("zoom.us", id: "us.zoom.xos"))])])
        let zoom = installed("Zoom.us", id: "us.zoom.xos")
        let report = Reconciler.reconcile(&g, installed: [zoom], autoAdd: true, pathExists: { _ in true })
        #expect(g.allApps.map(\.path) == ["/Applications/Zoom.us.app"])
        #expect(report.added.isEmpty && report.removed.isEmpty)

        // Nor does adding it by hand make a second tile.
        Reconciler.add([installed("ZOOM.US", id: "us.zoom.xos")], to: &g)
        #expect(g.allApps.count == 1)
    }

    @Test func aDuplicateLeftByACaseOnlyRenameIsDropped() {
        var g = Grid(rows: 1, columns: 3, pages: [Page(items: [.app(app("zoom.us", id: "us.zoom.xos")), .app(app("Zoom.us", id: "us.zoom.xos"))])])
        let report = Reconciler.reconcile(&g, installed: [installed("Zoom.us", id: "us.zoom.xos")], autoAdd: true, pathExists: { _ in true })
        #expect(g.allApps.map(\.path) == ["/Applications/Zoom.us.app"])
        #expect(report.duplicatesDropped == 1)
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

    @Test func excludingAnAppAlsoTakesItsTileLeftAtAStalePath() {
        let old = AppRef(bundleID: "com.x", path: "/Volumes/Gone/Old/X.app", name: "X")
        let x = installed("X", id: "com.x")
        let start = Grid(rows: 2, columns: 3, pages: [Page(items: [.app(old), .app(x.makeRef()), .app(app("C"))])])
        var g = start
        Reconciler.choose(include: [], exclude: [x], in: &g, installed: [x, InstalledApp(old)],
                          isStale: { $0 == old.path })
        #expect(g.allApps.map(\.name) == ["C"], "the stale tile isn't another copy")
        #expect(g.removedBundleIDs == ["com.x"])

        // On an unmounted volume it may well be a second copy: it stays, and only this one is excluded.
        g = start
        Reconciler.choose(include: [], exclude: [x], in: &g, installed: [x, InstalledApp(old)])
        #expect(g.allApps.map(\.path) == [old.path, "/Applications/C.app"])
        #expect(g.removedBundleIDs == [x.path])
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
        #expect(h.allApps.map(\.path) == ["/Applications/Xcode.app"],
                "Xcode.app still exists on disk: not moved onto the beta, nor pruned")
        var i = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(xcode)])])
        let moved = Reconciler.reconcile(&i, installed: [apps[0]], autoAdd: false, pathExists: { _ in false })
        #expect(moved.moved == ["Xcode-beta"])
    }

    @Test func aGoneAppDoesNotBecomeACopyThatWasThereAllAlong() {
        let xcode = AppRef(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", name: "Xcode")
        let beta = installed("Xcode-beta", id: "com.apple.dt.Xcode")
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(xcode)])])
        // Xcode.app is deleted; the beta, never added, was installed beside it.
        let report = Reconciler.reconcile(&g, installed: [beta], autoAdd: false, pathExists: { _ in false },
                                          wasInstalledBefore: { $0 == beta.path })
        #expect(report.moved.isEmpty && report.removed == ["Xcode"])
        #expect(g.allApps.isEmpty)
        #expect(Reconciler.missingApps(in: Grid(pages: [Page(items: [.app(xcode)])]), installed: [beta],
                                       pathExists: { _ in false },
                                       wasInstalledBefore: { $0 == beta.path }) == [beta],
                "nor does it stand for the beta in Add Missing Apps")

        // Renamed: the copy with another name is new, so it is the same app.
        var h = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(xcode)])])
        let renamed = Reconciler.reconcile(&h, installed: [beta], autoAdd: false, pathExists: { _ in false },
                                           wasInstalledBefore: { _ in false })
        #expect(renamed.moved == ["Xcode-beta"])
    }

    @Test func movedRefSkipsACopyTheUserRemoved() {
        let xcode = AppRef(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", name: "Xcode")
        let beta = installed("Xcode-beta", id: "com.apple.dt.Xcode")
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(xcode)])])
        Reconciler.add([beta], to: &g, installed: [InstalledApp(xcode)])
        g.remove([g.allApps[1].id], installed: [InstalledApp(xcode), beta])
        #expect(g.removedBundleIDs == [beta.path])
        // Xcode.app is deleted: its tile must not take over the excluded beta.
        let report = Reconciler.reconcile(&g, installed: [beta], autoAdd: true, pathExists: { _ in false })
        #expect(report.moved.isEmpty && report.added.isEmpty)
        #expect(g.allApps.isEmpty)
    }

    @Test func movedRefFollowsTheCopyWithItsFileName() {
        let xcode = AppRef(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", name: "Xcode")
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(xcode)])])
        let copies = [installed("Xcode-beta", id: "com.apple.dt.Xcode"),
                      installed("Xcode", id: "com.apple.dt.Xcode", path: "/Applications/Dev/Xcode.app")]
        let report = Reconciler.reconcile(&g, installed: copies, autoAdd: true, pathExists: { _ in false })
        #expect(report.moved == ["Xcode"])
        #expect(g.allApps.map(\.path) == ["/Applications/Dev/Xcode.app", "/Applications/Xcode-beta.app"])
    }

    @Test func aTileDoesNotTurnIntoAnExcludedAppAtItsPath() {
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(app("A"))])],
                     removedBundleIDs: ["com.vendor.new"])
        let report = Reconciler.reconcile(&g, installed: [installed("A", id: "com.vendor.new"), installed("B")],
                                          autoAdd: false, pathExists: { _ in true })
        #expect(report.removed == ["A"])
        #expect(g.allApps.isEmpty)
    }

    @Test func aMovedTileHidesOnlyOneCopyFromMissingApps() {
        let xcode = AppRef(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", name: "Xcode")
        let g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(xcode)])])
        let moved = installed("Xcode", id: "com.apple.dt.Xcode", path: "/Applications/Dev/Xcode.app")
        let beta = installed("Xcode-beta", id: "com.apple.dt.Xcode")
        #expect(Reconciler.missingApps(in: g, installed: [beta, moved], pathExists: { _ in false }) == [beta],
                "the moved Xcode is the tile's; the beta is still missing")
    }

    @Test func anExcludedCopyIsStillOfferedByMissingApps() {
        let original = installed("Xcode", id: "com.apple.dt.Xcode")
        let excluded = installed("Xcode", id: original.bundleID, path: "/Applications/Old/Xcode.app")
        let moved = installed("Xcode", id: original.bundleID, path: "/Applications/Dev/Xcode.app")
        let g = Grid(pages: [Page(items: [.app(original.makeRef())])], removedBundleIDs: [excluded.path])

        #expect(Reconciler.missingApps(in: g, installed: [excluded, moved], pathExists: { _ in false }) == [excluded],
                "the tile can follow the included copy; the excluded copy must remain available to add")
        #expect(Reconciler.missingApps(in: g, installed: [excluded], pathExists: { _ in false }) == [excluded],
                "a stale tile cannot claim a copy the reconciler refuses to follow")
    }

    @Test func anExistingUnscannedAppDoesNotHideAnotherCopyFromMissingApps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = dir.appendingPathComponent("A.app")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = installed("A", path: original.path).makeRef()
        let grid = Grid(pages: [Page(items: [.app(ref)])])
        let copy = installed("A")

        #expect(Reconciler.missingApps(in: grid, installed: [copy]) == [copy])
        try FileManager.default.removeItem(at: original)
        #expect(Reconciler.missingApps(in: grid, installed: [copy]).isEmpty,
                "once the original is gone, the tile can represent its moved copy")
    }

    @Test func aTileOnAnEjectedVolumeHidesNoInstalledCopy() {
        let ext = AppRef(bundleID: "com.foo", path: "/Volumes/Ext/Foo.app", name: "Foo")
        let g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(ext)])])
        let local = installed("Foo", id: "com.foo")
        #expect(Reconciler.missingApps(in: g, installed: [local], isReachable: { !$0.hasPrefix("/Volumes/Ext/") }) == [local])
        #expect(Reconciler.missingApps(in: g, installed: [local], pathExists: { _ in false }).isEmpty,
                "reachable and gone: it moved there")
    }

    @Test func aRestoredAppWhoseNeighboursAreAllGoneGoesToTheStart() {
        let ids = (0..<3).map { _ in UUID() }
        #expect(Grid.slot(after: [UUID(), UUID(), UUID(), UUID()], fallback: 3, in: ids) == 0,
                "four remembered (some pruned earlier) for slot 3")
        #expect(Grid.slot(after: [UUID(), UUID()], fallback: 3, in: ids) == 3)
        #expect(Grid.slot(after: [ids[1]], fallback: 0, in: ids) == 2)
    }

    @Test func unreachableAppIsNotMovedOntoAnotherCopy() {
        let ext = AppRef(bundleID: "com.test.foo", path: "/Volumes/Ext/Foo.app", name: "Foo")
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(ext)])])
        let report = Reconciler.reconcile(&g, installed: [installed("Foo")], autoAdd: false,
                                          isReachable: { !$0.hasPrefix("/Volumes/Ext/") }, pathExists: { _ in false })
        #expect(report.moved.isEmpty && report.removed.isEmpty)
        #expect(g.allApps.map(\.path) == ["/Volumes/Ext/Foo.app"])
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

    @Test func folderEmptiedOverTwoScansComesBackWhole() {
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: [.app(app("A")), .app(app("Word")), .app(app("Excel"))])])
        let fid = g.group([g.pages[0].items[1].id, g.pages[0].items[2].id], name: "Office")!
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("Excel")], autoAdd: false, now: t0)
        _ = Reconciler.reconcile(&g, installed: [installed("A")], autoAdd: false, now: t0 + 5)
        #expect(g.folder(fid) == nil)
        let back = Reconciler.reconcile(&g, installed: ["A", "Word", "Excel"].map { installed($0) }, autoAdd: false, now: t0 + 10)
        #expect(back.restored == ["Word", "Excel"])
        #expect(titles(g.pages[0]) == ["A", "Office"], "Word goes back in the folder, not beside it")
        #expect(g.folder(fid)?.apps.map(\.name) == ["Word", "Excel"], "in their old order")
    }

    @Test func appsPrunedOverTwoScansComeBackInOrder() {
        let all = ["A", "B", "C", "D"].map { installed($0) }
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: ["A", "B", "C", "D"].map { .app(app($0)) })])
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = Reconciler.reconcile(&g, installed: [all[0], all[2], all[3]], autoAdd: false, now: t0)
        _ = Reconciler.reconcile(&g, installed: [all[0], all[3]], autoAdd: false, now: t0 + 5)
        _ = Reconciler.reconcile(&g, installed: all, autoAdd: false, now: t0 + 10)
        #expect(titles(g.pages[0]) == ["A", "B", "C", "D"])
    }

    @Test func appsPrunedApartOverSeveralScansComeBackInOrder() {
        let all = ["A", "B", "C", "D"].map { installed($0) }
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: ["A", "B", "C", "D"].map { .app(app($0)) })])
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = Reconciler.reconcile(&g, installed: [all[1], all[3]], autoAdd: false, now: t0)
        _ = Reconciler.reconcile(&g, installed: [all[1]], autoAdd: false, now: t0 + 5)
        _ = Reconciler.reconcile(&g, installed: all, autoAdd: false, now: t0 + 10)
        #expect(titles(g.pages[0]) == ["A", "B", "C", "D"])
    }

    @Test func appsPrunedFromOneSlotInLaterScansComeBackInOrder() {
        let names = ["A", "B", "C", "D", "E", "F"]
        let all = names.map { installed($0) }
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: names.map { .app(app($0)) })])
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = Reconciler.reconcile(&g, installed: all.filter { ["A", "B", "D"].contains($0.name) }, autoAdd: false, now: t0)
        _ = Reconciler.reconcile(&g, installed: all.filter { ["A", "D"].contains($0.name) }, autoAdd: false, now: t0 + 5)
        _ = Reconciler.reconcile(&g, installed: [all[0]], autoAdd: false, now: t0 + 10)
        _ = Reconciler.reconcile(&g, installed: all, autoAdd: false, now: t0 + 15)
        #expect(titles(g.pages[0]) == names)
    }

    @Test func aFolderPrunedInAnEarlierScanKeepsItsPlaceAmongItsNeighbours() {
        let first = Folder(name: "F1", apps: [app("A"), app("B")]), second = Folder(name: "F2", apps: [app("C")])
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: [.folder(first), .folder(second), .app(app("E"))]),
                                                  Page(items: [.app(app("Z"))])])
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = Reconciler.reconcile(&g, installed: [installed("C"), installed("Z")], autoAdd: false, now: t0)
        _ = Reconciler.reconcile(&g, installed: [installed("Z")], autoAdd: false, now: t0 + 5)
        _ = Reconciler.reconcile(&g, installed: ["A", "B", "C", "E", "Z"].map { installed($0) }, autoAdd: false, now: t0 + 10)
        #expect(titles(g.pages[0]) == ["F1", "F2", "E"])
    }

    @Test func pagesEmptiedInSeparateScansComeBackInOrder() {
        let all = ["A", "X", "Y"].map { installed($0) }
        var g = Grid(rows: 2, columns: 3, pages: all.map { Page(title: "P\($0.name)", items: [.app(app($0.name))]) })
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = Reconciler.reconcile(&g, installed: [all[0], all[2]], autoAdd: false, now: t0)
        _ = Reconciler.reconcile(&g, installed: [all[0]], autoAdd: false, now: t0 + 5)
        _ = Reconciler.reconcile(&g, installed: all, autoAdd: false, now: t0 + 10)
        #expect(g.pages.map(\.title) == ["PA", "PX", "PY"])
    }

    @Test func appsPrunedInWavesAndRestoredComeBackAsTheyStood() {
        struct XorShift: RandomNumberGenerator {
            var s: UInt64
            mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
        }
        func layout(_ g: Grid) -> [[String]] {
            g.pages.map { $0.items.map { i in i.folder.map { "[" + $0.apps.map(\.name).joined(separator: ",") + "]" } ?? i.title } }
        }
        var failures: [Int] = []
        for seed in 1...600 {
            var r = XorShift(s: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 | 1)
            let rows = Int.random(in: 1...3, using: &r), columns = Int.random(in: 1...3, using: &r)
            var apps: [InstalledApp] = []
            func make() -> AppRef {
                let a = InstalledApp(bundleID: "com.fuzz.\(apps.count)", path: "/Fuzz/\(apps.count).app", name: "N\(apps.count)")
                apps.append(a)
                return a.makeRef()
            }
            var pages: [Page] = []
            for _ in 0..<Int.random(in: 1...4, using: &r) {
                let items = (0..<Int.random(in: 1...(rows * columns), using: &r)).map { _ -> GridItem in
                    Int.random(in: 0..<4, using: &r) == 0
                        ? .folder(Folder(name: "F", apps: (0..<Int.random(in: 1...3, using: &r)).map { _ in make() }))
                        : .app(make())
                }
                pages.append(Page(title: Bool.random(using: &r) ? "T\(pages.count)" : nil, items: items))
            }
            var g = Grid(rows: rows, columns: columns, pages: pages)
            g.normalize()
            let original = layout(g), titles = g.pages.map(\.title)
            var gone = Set<String>(), now = Date(timeIntervalSinceReferenceDate: 0)
            func scan() {
                now += 10
                let present = apps.filter { !gone.contains($0.path) }
                _ = Reconciler.reconcile(&g, installed: present, autoAdd: false, pathExists: { !gone.contains($0) }, now: now)
            }
            for _ in 0..<Int.random(in: 1...3, using: &r) {
                let left = apps.filter { !gone.contains($0.path) }
                guard left.count > 1 else { break }
                for a in left.shuffled(using: &r).prefix(Int.random(in: 1...(left.count - 1), using: &r)) { gone.insert(a.path) }
                scan()
            }
            if Bool.random(using: &r) {
                let back = Array(gone).shuffled(using: &r)
                for part in [back[..<(back.count / 2)], back[(back.count / 2)...]] where !part.isEmpty {
                    gone.subtract(part)
                    scan()
                }
            } else {
                gone = []
                scan()
            }
            if layout(g) != original || g.pages.map(\.title) != titles { failures.append(seed) }
        }
        #expect(failures.isEmpty)
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

    @Test func restoredAppSkipsNeighboursThatNeverCameBack() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let all = ["A", "B", "C", "D"].map { installed($0) }
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: ["A", "B", "C", "D"].map { .app(app($0)) })])
        _ = Reconciler.reconcile(&g, installed: [all[0], all[3]], autoAdd: false, now: t0)
        _ = Reconciler.reconcile(&g, installed: [all[0], all[2], all[3]], autoAdd: false, now: t0 + 5)
        #expect(titles(g.pages[0]) == ["A", "C", "D"], "after A, not one slot late because B is still gone")
        _ = Reconciler.reconcile(&g, installed: all, autoAdd: false, now: t0 + 10)
        #expect(titles(g.pages[0]) == ["A", "B", "C", "D"])

        // Every neighbour before it gone: back to the start.
        var h = Grid(rows: 2, columns: 3, pages: [Page(items: ["A", "B", "C"].map { .app(app($0)) })])
        _ = Reconciler.reconcile(&h, installed: [all[2]], autoAdd: false, now: t0)
        _ = Reconciler.reconcile(&h, installed: [all[1], all[2]], autoAdd: false, now: t0 + 5)
        #expect(titles(h.pages[0]) == ["B", "C"])
    }

    @Test func removingOneCopyLeavesTheOtherIncludable() {
        let xcode = AppRef(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", name: "Xcode")
        let betaApp = installed("Xcode-beta", id: "com.apple.dt.Xcode")
        var g = Grid(rows: 2, columns: 3, pages: [Page(items: [.app(xcode)])])
        #expect(Reconciler.missingApps(in: g, installed: [InstalledApp(xcode), betaApp]) == [betaApp],
                "a second copy counts as missing")
        Reconciler.add([betaApp], to: &g)
        let betaID = g.allApps[1].id
        g.remove([betaID])
        #expect(g.removedBundleIDs == [betaApp.path])
        _ = Reconciler.reconcile(&g, installed: [InstalledApp(xcode), betaApp], autoAdd: true)
        #expect(g.allApps.map(\.name) == ["Xcode"])
        g.remove([g.allApps[0].id], installed: [InstalledApp(xcode), betaApp])
        #expect(g.removedBundleIDs == [betaApp.path, xcode.path], "each copy by path")
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

    @Test func restoreIntoAFullPageSpillsTheLastItem() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var g = Grid(rows: 1, columns: 2, pages: [Page(items: [.app(app("A")), .app(app("B"))])])
        _ = Reconciler.reconcile(&g, installed: [installed("B")], autoAdd: false, now: t0)
        Reconciler.add([installed("C")], to: &g)
        #expect(g.pages.map(titles) == [["B", "C"]])
        let back = Reconciler.reconcile(&g, installed: ["A", "B", "C"].map { installed($0) }, autoAdd: false, now: t0 + 5)
        #expect(back.restored == ["A"])
        #expect(g.pages.map(titles) == [["A", "B"], ["C"]])
    }

    @Test func restoreOnAPageThatIsGoneUsesTheFirstFreeSlot() {
        var g = Grid(rows: 1, columns: 2, pages: [Page(items: [.app(app("A")), .app(app("C"))]), Page(items: [.app(app("D"))])])
        g.restore(PrunedApp(app: app("B"), prunedAt: Date(), pageID: UUID(), index: 0))
        #expect(g.pages.map(titles) == [["A", "C"], ["D", "B"]])

        // Through the reconciler: the user emptied and deleted the page meanwhile.
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var h = Grid(rows: 1, columns: 3, pages: [Page(items: [.app(app("A"))]), Page(items: [.app(app("B")), .app(app("X"))])])
        _ = Reconciler.reconcile(&h, installed: [installed("A"), installed("X")], autoAdd: false, now: t0)
        h.move([h.pages[1].items[0].id], toPage: 0, at: 1)
        h.removeEmptyPages()
        _ = Reconciler.reconcile(&h, installed: ["A", "B", "X"].map { installed($0) }, autoAdd: false, now: t0 + 5)
        #expect(h.pages.map(titles) == [["A", "X", "B"]])
    }

    @Test func aPageThePruneEmptiesGoesAndComesBackWithItsApps() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var g = Grid(rows: 1, columns: 2, pages: [
            Page(items: [.app(app("A"))]),
            Page(title: "Games", items: [.app(app("B"))]),
            Page(items: [.app(app("C"))]),
            Page(title: "Made by hand"),
        ])
        g.group([g.pages[1].items[0].id], name: "F")
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("C")], autoAdd: false, now: t0)
        #expect(g.pages.map(titles) == [["A"], ["C"], []], "an empty page the user made stays")
        #expect(g.recentlyPruned.first?.pageEmptied == true)

        _ = Reconciler.reconcile(&g, installed: ["A", "B", "C"].map { installed($0) }, autoAdd: false, now: t0 + 5)
        #expect(g.pages.map(titles) == [["A"], ["F"], ["C"], []])
        #expect(g.pages[1].title == "Games")
        #expect(g.pages[1].items[0].folder?.apps.map(\.name) == ["B"])
    }

    @Test func theOnlyPageComesBackWithoutABlankOneBeside() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var g = Grid(rows: 2, columns: 2, pages: [Page(title: "Mine", items: [.app(app("A"))])])
        _ = Reconciler.reconcile(&g, installed: [installed("B")], autoAdd: false, now: t0)
        #expect(g.pages.map(titles) == [[]])
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("B")], autoAdd: false, now: t0 + 5)
        #expect(g.pages.map(titles) == [["A"]])
        #expect(g.pages[0].title == "Mine")
    }

    @Test func pagesEmptiedTogetherComeBackInPlaceWhateverTheOrder() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let names = ["A", "X", "Y", "C"]
        for returning in [["X", "Y"], ["Y", "X"]] {
            var g = Grid(rows: 1, columns: 1, pages: names.map { Page(items: [.app(app($0))]) })
            _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("C")], autoAdd: false, now: t0)
            #expect(g.pages.map(titles) == [["A"], ["C"]])
            var back = ["A", "C"]
            for (i, name) in returning.enumerated() {
                back.append(name)
                _ = Reconciler.reconcile(&g, installed: back.map { installed($0) }, autoAdd: false, now: t0 + Double(i + 1))
            }
            #expect(g.pages.map(titles) == names.map { [$0] }, "returning \(returning)")
        }
    }

    @Test func aPageEmptiedLaterStillComesBackForAnAppPrunedEarlier() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var g = Grid(rows: 1, columns: 2, pages: [Page(items: [.app(app("A"))]), Page(title: "P", items: [.app(app("B")), .app(app("C"))])])
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("C")], autoAdd: false, now: t0)
        _ = Reconciler.reconcile(&g, installed: [installed("A")], autoAdd: false, now: t0 + 5)
        #expect(g.pages.map(titles) == [["A"]])
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("B")], autoAdd: false, now: t0 + 10)
        #expect(g.pages.map(titles) == [["A"], ["B"]])
        #expect(g.pages[1].title == "P")
    }

    @Test func aMemoryEntryFromTheFutureExpires() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var g = Grid(rows: 1, columns: 3, pages: [Page(items: [.app(app("A"))])])
        g.recentlyPruned = [PrunedApp(app: app("B"), prunedAt: t0 + 365 * 86400, pageID: g.pages[0].id, index: 0)]
        _ = Reconciler.reconcile(&g, installed: [installed("A")], autoAdd: false, now: t0)
        #expect(g.recentlyPruned.isEmpty)
        _ = Reconciler.reconcile(&g, installed: [installed("A"), installed("B")], autoAdd: false, now: t0 + 5)
        #expect(g.allApps.map(\.name) == ["A"])
    }

    @Test func anAppAtItsRealPathTakesThePathTheScanListsItAt() {
        let scanned = installed("Safari", path: "/Applications/Safari.app")
        let real = "/System/Cryptexes/App/System/Applications/Safari.app"
        let aliases = [real: scanned.path]
        // Browse gives the real path; the scan, the link in /Applications.
        var g = Grid(rows: 1, columns: 3, pages: [Page(items: [.app(app("A"))])])
        Reconciler.add([installed("Safari", path: real)], to: &g, installed: [installed("A"), scanned], aliases: aliases)
        #expect(g.allApps.map(\.path) == ["/Applications/A.app", scanned.path])

        // One added at its real path before, with apps added automatically: one Safari, not two.
        var h = Grid(rows: 1, columns: 3, pages: [Page(items: [.app(app("A")), .app(AppRef(bundleID: scanned.bundleID, path: real, name: "Safari"))])])
        _ = Reconciler.reconcile(&h, installed: [installed("A"), scanned], autoAdd: true, pathExists: { _ in true }, aliases: aliases)
        #expect(h.allApps.map(\.path) == ["/Applications/A.app", scanned.path])
    }

    @Test func anAppWhoseBundleIDCantBeReadStaysItself() {
        let xcode = AppRef(bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", name: "Xcode")
        var g = Grid(rows: 1, columns: 3, pages: [Page(items: [.app(xcode)])])
        let now = [InstalledApp(bundleID: nil, path: xcode.path, name: "Xcode"),
                   installed("Xcode-beta", id: "com.apple.dt.Xcode", path: "/Applications/Xcode-beta.app")]
        let report = Reconciler.reconcile(&g, installed: now, autoAdd: false, pathExists: { _ in true })
        #expect(report.moved.isEmpty)
        #expect(g.allApps.map(\.path) == [xcode.path])
        #expect(g.allApps.first?.bundleID == xcode.bundleID, "keeps the ID it had")
    }

    @Test func pruneMemoryKeepsTheNewestEntries() {
        let names = (0..<(Reconciler.pruneMemory + 5)).map { String(format: "App%03d", $0) }
        var g = Grid(rows: 15, columns: 15, pages: [Page(items: names.map { .app(app($0)) })])
        _ = Reconciler.reconcile(&g, installed: [installed("Keep")], autoAdd: false)
        #expect(g.recentlyPruned.count == Reconciler.pruneMemory)
        #expect(g.recentlyPruned.first?.app.name == "App005", "oldest first out")
        #expect(g.recentlyPruned.last?.app.name == names.last)
    }

    @Test func pruneMissingOffKeepsAppsAndRemembersNothing() {
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(app("A")), .app(app("Gone"))])])
        let report = Reconciler.reconcile(&g, installed: [installed("A")], autoAdd: false, pruneMissing: false)
        #expect(report.removed.isEmpty)
        #expect(titles(g.pages[0]) == ["A", "Gone"])
        #expect(g.recentlyPruned.isEmpty)
    }

    @Test func addDropsAnAppListedTwice() {
        var g = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(app("A"))])])
        Reconciler.add([installed("B"), installed("B"), installed("A")], to: &g)
        #expect(g.allApps.map(\.name) == ["A", "B"])
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

    @Test func findsAppsWhoseExtensionIsInCapitals() throws {
        let root = tempDir("scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFakeApp("Shouting.APP", id: "t.shout", in: root)
        try makeFakeApp("Plain.app", id: "t.plain", in: root)
        #expect(Set(AppScanner.scan(roots: [root]).compactMap(\.bundleID)) == ["t.shout", "t.plain"])
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

    @Test func reportsTheRealPathOfAnAppFoundThroughASymlink() throws {
        let fm = FileManager.default
        let root = tempDir("scan")
        let elsewhere = tempDir("scan-target")
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: elsewhere) }
        try makeFakeApp("Safari.app", id: "t.safari", in: elsewhere)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Safari.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: elsewhere.appendingPathComponent("Safari.app"))
        let result = AppScanner.scanReporting(roots: [root])
        let real = elsewhere.appendingPathComponent("Safari.app").resolvingSymlinksInPath().path
        #expect(result.apps.count == 1)
        #expect(result.aliases[real] == result.apps.first?.path)
    }

    @Test(arguments: [false, true])
    func alternateAppLinksDoNotCreateDuplicateTiles(realRootFirst: Bool) throws {
        let fm = FileManager.default
        let root = tempDir("scan")
        let elsewhere = tempDir("scan-target")
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: elsewhere) }
        try makeFakeApp("Real.app", id: "t.linked", in: elsewhere)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let real = elsewhere.appendingPathComponent("Real.app")
        let first = root.appendingPathComponent("First.app")
        let second = root.appendingPathComponent("Second.app")
        for link in [first, second] {
            try fm.createSymbolicLink(at: link, withDestinationURL: real)
        }
        let result = AppScanner.scanReporting(roots: realRootFirst ? [elsewhere, root] : [root, elsewhere])
        let scanned = try #require(result.apps.first)
        #expect(result.apps.count == 1)
        #expect(result.aliases[second.path] == scanned.path)

        let ref = AppRef(bundleID: scanned.bundleID, path: second.path, displayName: "My App")
        var grid = Grid(pages: [Page(items: [.app(ref)])])
        _ = Reconciler.reconcile(&grid, installed: result.apps, autoAdd: true, aliases: result.aliases)
        #expect(grid.allApps.map(\.path) == [scanned.path])
        #expect(grid.allApps.first?.id == ref.id)
        #expect(grid.allApps.first?.title == "My App")

        var picked = Grid(pages: [Page(items: [.app(scanned.makeRef())])])
        Reconciler.add([try #require(AppScanner.read(appAt: second))], to: &picked,
                       installed: result.apps, aliases: result.aliases)
        #expect(picked.allApps.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func alternateDirectoryLinksDoNotCreateDuplicateTiles(realRootFirst: Bool, linkedApp: Bool) throws {
        let fm = FileManager.default
        let root = tempDir("scan-directory-links")
        defer { try? fm.removeItem(at: root) }
        try makeFakeApp("Real/Nested/App.app", id: "t.linked", in: root)
        let real = root.appendingPathComponent("Real")
        if linkedApp {
            let bundle = real.appendingPathComponent("Nested/App.app")
            let target = root.appendingPathComponent("Elsewhere.app")
            try fm.moveItem(at: bundle, to: target)
            try fm.createSymbolicLink(at: bundle, withDestinationURL: target)
        }
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        for link in [first, second] {
            try fm.createSymbolicLink(at: link, withDestinationURL: real)
        }
        let result = AppScanner.scanReporting(roots: realRootFirst ? [real, first, second] : [first, second, real])
        let scanned = try #require(result.apps.first)
        #expect(result.apps.count == 1)
        let alternate = second.appendingPathComponent("Nested/App.app")
        #expect(result.aliases[alternate.path] == scanned.path)
        let canonical = real.appendingPathComponent("Nested").resolvingSymlinksInPath().appendingPathComponent("App.app").path
        #expect(canonical == scanned.path || result.aliases[canonical] == scanned.path)

        let ref = AppRef(bundleID: scanned.bundleID, path: alternate.path, displayName: "My App")
        var grid = Grid(pages: [Page(items: [.app(ref)])])
        _ = Reconciler.reconcile(&grid, installed: result.apps, autoAdd: true, aliases: result.aliases)
        #expect(grid.allApps.map(\.path) == [scanned.path])
        #expect(grid.allApps.first?.id == ref.id)
        #expect(grid.allApps.first?.title == "My App")

        var picked = Grid(pages: [Page(items: [.app(scanned.makeRef())])])
        Reconciler.add([try #require(AppScanner.read(appAt: alternate))], to: &picked,
                       installed: result.apps, aliases: result.aliases)
        #expect(picked.allApps.count == 1)
    }

    @Test func skipsAppsHiddenByDefaultButReadsThemByHand() throws {
        let root = tempDir("scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFakeApp("Shown.app", id: "t.shown", in: root)
        try makeFakeApp("Hidden.app", id: "t.hidden", in: root)
        let hidden = root.appendingPathComponent("Hidden.app")
        let plist: [String: Any] = ["CFBundleIdentifier": "t.hidden", "CFBundlePackageType": "APPL", "LSDefaultSystemHidden": true]
        try (plist as NSDictionary).write(to: hidden.appendingPathComponent("Contents/Info.plist"))
        #expect(AppScanner.scan(roots: [root]).map(\.bundleID) == ["t.shown"])
        #expect(AppScanner.read(appAt: hidden)?.bundleID == "t.hidden")
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

    @Test func readSeesAnUpdatedInfoPlist() throws {
        let root = tempDir("scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeFakeApp("App.app", id: "t.old", in: root)
        let url = root.appendingPathComponent("App.app")
        #expect(AppScanner.read(appAt: url)?.bundleID == "t.old")
        // An update rewrites the bundle in place; Bundle(url:) would keep the first answer.
        let plist: [String: Any] = ["CFBundleIdentifier": "t.new", "CFBundlePackageType": "APPL",
                                    "LSApplicationCategoryType": "public.app-category.utilities"]
        try (plist as NSDictionary).write(to: url.appendingPathComponent("Contents/Info.plist"))
        let again = AppScanner.read(appAt: url)
        #expect(again?.bundleID == "t.new")
        #expect(again?.category == "public.app-category.utilities")
    }

    @Test func findsHomebrewFormulaAppsThroughTheFormulasOwnLinks() throws {
        let fm = FileManager.default
        let prefix = tempDir("brew")
        defer { try? fm.removeItem(at: prefix) }
        try makeFakeApp("Cellar/python@3.15/3.15.0/IDLE 3.app", id: "org.python.IDLE", in: prefix)
        try makeFakeApp("Cellar/python@3.14/3.14.8/IDLE 3.app", id: "org.python.IDLE", in: prefix)
        try makeFakeApp("Cellar/qt/6.9/libexec/Designer.app", id: "org.qt.designer", in: prefix)
        try fm.createDirectory(at: prefix.appendingPathComponent("Cellar/ripgrep/15.0/bin"), withIntermediateDirectories: true)
        let opt = prefix.appendingPathComponent("opt")
        try fm.createDirectory(at: opt, withIntermediateDirectories: true)
        for (name, keg) in [("python", "python@3.15/3.15.0"), ("python3", "python@3.15/3.15.0"),
                            ("python@3.14", "python@3.14/3.14.8"), ("python@3.15", "python@3.15/3.15.0"),
                            ("ripgrep", "ripgrep/15.0"), ("qt", "qt/6.9")] {
            try fm.createSymbolicLink(atPath: opt.appendingPathComponent(name).path, withDestinationPath: "../Cellar/\(keg)")
        }
        // Listed through the formulas' own links, not the aliases nor the versioned kegs; only
        // the top of a keg is looked at.
        let paths = AppScanner.scan(roots: [opt]).map { $0.path.split(separator: "/").suffix(3).joined(separator: "/") }
        #expect(paths == ["opt/python@3.14/IDLE 3.app", "opt/python@3.15/IDLE 3.app"])
        #expect(AppScanner.isHomebrewOpt(opt))
        #expect(!AppScanner.isHomebrewOpt(prefix.appendingPathComponent("Cellar")))
    }

    @Test func homebrewAliasesDoNotCreateDuplicateTiles() throws {
        let fm = FileManager.default
        let prefix = tempDir("brew-alias")
        defer { try? fm.removeItem(at: prefix) }
        try makeFakeApp("Cellar/python@3.15/3.15.0/IDLE.app", id: "org.python.IDLE", in: prefix)
        let opt = prefix.appendingPathComponent("opt")
        try fm.createDirectory(at: opt, withIntermediateDirectories: true)
        for name in ["python3", "python@3.15"] {
            try fm.createSymbolicLink(atPath: opt.appendingPathComponent(name).path,
                                      withDestinationPath: "../Cellar/python@3.15/3.15.0")
        }
        let result = AppScanner.scanReporting(roots: [opt])
        let scanned = try #require(result.apps.first)
        let alias = opt.appendingPathComponent("python3/IDLE.app")
        #expect(result.aliases[alias.path] == scanned.path)

        let ref = AppRef(bundleID: scanned.bundleID, path: alias.path, displayName: "My IDLE")
        var grid = Grid(pages: [Page(items: [.app(ref)])])
        _ = Reconciler.reconcile(&grid, installed: result.apps, autoAdd: true, aliases: result.aliases)
        #expect(grid.allApps.map(\.path) == [scanned.path])
        #expect(grid.allApps.first?.id == ref.id)
        #expect(grid.allApps.first?.title == "My IDLE")

        Reconciler.add([try #require(AppScanner.read(appAt: alias))], to: &grid,
                       installed: result.apps, aliases: result.aliases)
        #expect(grid.allApps.count == 1)
    }

    @Test(arguments: [false, true])
    func extraRootCanScanDeeperThanHomebrewOpt(extraRootFirst: Bool) throws {
        let fm = FileManager.default
        let prefix = tempDir("brew-depth")
        defer { try? fm.removeItem(at: prefix) }
        try makeFakeApp("Cellar/qt/6.9/libexec/Designer.app", id: "org.qt.designer", in: prefix)
        let opt = prefix.appendingPathComponent("opt")
        try fm.createDirectory(at: opt, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: opt.appendingPathComponent("qt").path,
                                  withDestinationPath: "../Cellar/qt/6.9")
        let extra = prefix.appendingPathComponent("Extra")
        try fm.createSymbolicLink(at: extra, withDestinationURL: opt)
        #expect(AppScanner.scan(roots: [opt]).isEmpty, "the automatic Homebrew scan stays shallow")
        let result = AppScanner.scan(roots: extraRootFirst ? [extra, opt] : [opt, extra])
        #expect(result.map(\.bundleID) == ["org.qt.designer"], "the explicit root has the full depth budget")
    }

    @Test func anAppReachedThroughSymlinksIsFoundOnce() throws {
        let fm = FileManager.default
        let root = tempDir("scan")
        defer { try? fm.removeItem(at: root) }
        try makeFakeApp("Real/X.app", id: "t.x", in: root)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Alias"), withDestinationURL: root.appendingPathComponent("Real"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("XLink.app"),
                                  withDestinationURL: root.appendingPathComponent("Real/X.app"))
        #expect(AppScanner.scan(roots: [root]).count == 1)
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
        #expect(r.duplicates == ["Mail again"], "a second entry for one app")
        #expect(r.imported == 3)
    }

    @Test func foldersInsideFoldersGiveTheirAppsToTheOuterOne() {
        typealias Row = LaunchpadImporter.Row
        let items = [
            Row(id: 1, type: 1, parent: 0, ordering: 0), Row(id: 10, type: 3, parent: 1, ordering: 0),
            Row(id: 20, type: 2, parent: 10, ordering: 0), Row(id: 30, type: 3, parent: 20, ordering: 0),
            Row(id: 40, type: 4, parent: 30, ordering: 0), Row(id: 50, type: 2, parent: 30, ordering: 1),
            Row(id: 60, type: 3, parent: 50, ordering: 0), Row(id: 70, type: 4, parent: 60, ordering: 0),
        ]
        let apps = [40: LaunchpadImporter.AppRow(title: "Notes", bundleID: "com.apple.Notes"),
                    70: LaunchpadImporter.AppRow(title: "", bundleID: "com.apple.Maps")]
        let r = LaunchpadImporter.build(items: items, apps: apps, groupTitles: [20: "Outer"], rows: 5, columns: 7) { "/Applications/\($0).app" }
        #expect(titles(r.grid.pages[0]) == ["Outer"])
        #expect(r.grid.pages[0].items[0].folder?.apps.map(\.name) == ["Notes", "com.apple.Maps"], "an empty title isn't a name")
        #expect(r.imported == 2)
    }

    @Test func aPageFullerThanTheGridSplitsInsteadOfShiftingTheNext() {
        typealias Row = LaunchpadImporter.Row
        // Two pages of three apps each, imported into a grid of two.
        let items = [Row(id: 1, type: 1, parent: 0, ordering: 0),
                     Row(id: 10, type: 3, parent: 1, ordering: 0), Row(id: 20, type: 3, parent: 1, ordering: 1)]
            + (0..<3).map { Row(id: 100 + $0, type: 4, parent: 10, ordering: $0) }
            + (0..<3).map { Row(id: 200 + $0, type: 4, parent: 20, ordering: $0) }
        var apps: [Int: LaunchpadImporter.AppRow] = [:]
        for i in 0..<3 {
            apps[100 + i] = LaunchpadImporter.AppRow(title: "W\(i)", bundleID: "com.w\(i)")
            apps[200 + i] = LaunchpadImporter.AppRow(title: "G\(i)", bundleID: "com.g\(i)")
        }
        let r = LaunchpadImporter.build(items: items, apps: apps, groupTitles: [10: "Work", 20: "Games"],
                                        rows: 1, columns: 2) { "/Applications/\($0).app" }
        #expect(r.grid.pages.map(titles) == [["W0", "W1"], ["W2"], ["G0", "G1"], ["G2"]])
        #expect(r.grid.pages.map(\.title) == ["Work", "Work", "Games", "Games"])
    }

    @Test func importedAppsTakeTheScansSpellingOfTheirPath() throws {
        // Launch Services gives Safari's cryptex path; the scan finds it through the
        // /Applications symlink. The grid must use the scan's, or the app shows up twice.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let real = dir.appendingPathComponent("Cryptex/Safari.app")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("Safari.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        typealias Row = LaunchpadImporter.Row
        let items = [Row(id: 1, type: 1, parent: 0, ordering: 0), Row(id: 10, type: 3, parent: 1, ordering: 0),
                     Row(id: 11, type: 4, parent: 10, ordering: 0)]
        let apps = [11: LaunchpadImporter.AppRow(title: "Safari", bundleID: "com.apple.Safari")]
        let r = LaunchpadImporter.build(items: items, apps: apps, groupTitles: [:], rows: 5, columns: 7,
                                        installed: [link.path]) { _ in real.path }
        #expect(r.grid.allApps.map(\.path) == [link.path])
        let unknown = LaunchpadImporter.build(items: items, apps: apps, groupTitles: [:], rows: 5, columns: 7) { _ in real.path }
        #expect(unknown.grid.allApps.map(\.path) == [real.path], "an app the scan didn't find keeps its own path")
    }

    @Test func launchServicesCopiesInTheTrashOrOnOtherVolumesAreSkipped() throws {
        let dir = tempDir("lasting")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeApp("Kept.app", id: "com.kept", in: dir)
        let kept = dir.appendingPathComponent("Kept.app").path
        #expect(LaunchpadImporter.isLastingCopy(kept))
        #expect(!LaunchpadImporter.isLastingCopy(dir.appendingPathComponent("Gone.app").path), "deleted since")
        #expect(!LaunchpadImporter.isLastingCopy(NSHomeDirectory() + "/.Trash/Old.app"))
        #expect(!LaunchpadImporter.isLastingCopy("/Volumes/Backup/Applications/Old.app"))
        #expect(!LaunchpadImporter.isLastingCopy("/Volumes/Old 1.0/.Trashes/501/Old.app"))
        #expect(!LaunchpadImporter.isLastingCopy("/private/var/folders/x/T/AppTranslocation/ABC/d/Old.app"))

        // Only for an app the scan didn't find: the database's own paths and the scan's copies stand.
        typealias Row = LaunchpadImporter.Row
        let items = [Row(id: 1, type: 1, parent: 0, ordering: 0), Row(id: 10, type: 3, parent: 1, ordering: 0),
                     Row(id: 11, type: 4, parent: 10, ordering: 0), Row(id: 12, type: 4, parent: 10, ordering: 1)]
        let apps = [11: LaunchpadImporter.AppRow(title: "Kept", bundleID: "com.kept"),
                    12: LaunchpadImporter.AppRow(title: "Old", bundleID: "com.old")]
        let r = LaunchpadImporter.build(items: items, apps: apps, groupTitles: [:], rows: 5, columns: 7,
                                        keeps: LaunchpadImporter.isLastingCopy) {
            $0 == "com.kept" ? kept : "/Volumes/Old 1.0/Old.app"
        }
        #expect(r.grid.allApps.map(\.path) == [kept])
        #expect(r.skipped == ["Old"])
    }

    @Test func copiesSharingABundleIDAreToldApartByTheirBookmarks() throws {
        // Apple's table has no custom_path: Launch Services alone would give Xcode twice.
        let dir = tempDir("import")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeApp("Xcode.app", id: "com.apple.dt.Xcode", in: dir)
        try makeFakeApp("Xcode-beta.app", id: "com.apple.dt.Xcode", in: dir)
        let xcode = dir.appendingPathComponent("Xcode.app"), beta = dir.appendingPathComponent("Xcode-beta.app")
        typealias Row = LaunchpadImporter.Row
        let items = [Row(id: 1, type: 1, parent: 0, ordering: 0), Row(id: 10, type: 3, parent: 1, ordering: 0),
                     Row(id: 11, type: 4, parent: 10, ordering: 0), Row(id: 12, type: 4, parent: 10, ordering: 1)]
        let apps = [11: LaunchpadImporter.AppRow(title: "Xcode", bundleID: "com.apple.dt.Xcode", bookmark: try xcode.bookmarkData()),
                    12: LaunchpadImporter.AppRow(title: "Xcode-beta", bundleID: "com.apple.dt.Xcode", bookmark: try beta.bookmarkData())]
        let r = LaunchpadImporter.build(items: items, apps: apps, groupTitles: [:], rows: 5, columns: 7) { _ in xcode.path }
        #expect(r.duplicates.isEmpty)
        #expect(r.grid.allApps.map { ($0.path as NSString).lastPathComponent } == ["Xcode.app", "Xcode-beta.app"])

        // A bookmark to an app deleted since falls back to the bundle ID.
        let gone = [11: LaunchpadImporter.AppRow(title: "Xcode", bundleID: "com.apple.dt.Xcode", bookmark: Data("junk".utf8))]
        let fallback = LaunchpadImporter.build(items: Array(items.prefix(3)), apps: gone, groupTitles: [:], rows: 5, columns: 7) { _ in xcode.path }
        #expect(fallback.grid.allApps.map(\.path) == [xcode.path])
    }

    @Test func categoriesHaveFriendlyNames() {
        #expect(AppCategory.name(for: "public.app-category.developer-tools") == "Developer Tools")
        #expect(AppCategory.name(for: "public.app-category.Utilities") == "Utilities")
        #expect(AppCategory.name(for: "public.app-category.puzzle-games") == "Games", "every kind of game")
        #expect(AppCategory.name(for: "public.app-category.finance") == "Productivity")
        #expect(AppCategory.name(for: "public.app-category.something-new") == AppCategory.other)
        #expect(AppCategory.name(for: nil) == AppCategory.other)
    }

    @Test func choosingAppsExcludesOneCopyByPathAndTheOnlyCopyByBundleID() {
        let xcode = installed("Xcode", id: "com.apple.dt.Xcode"), beta = installed("Xcode-beta", id: "com.apple.dt.Xcode")
        let notes = installed("Notes")
        var g = Grid(rows: 1, columns: 3, pages: [Page()])
        g.setExcluded(include: [], exclude: [beta, notes], among: [xcode, beta, notes])
        #expect(g.removedBundleIDs == [beta.path, notes.key])
        #expect(!g.isExcluded(xcode) && g.isExcluded(beta) && g.isExcluded(notes))

        g.setExcluded(include: [beta, notes], exclude: [], among: [xcode, beta, notes])
        #expect(g.removedBundleIDs.isEmpty)

        // Including one copy when the whole bundle ID was out keeps the other copy out.
        g.removedBundleIDs = [xcode.key]
        g.setExcluded(include: [beta], exclude: [], among: [xcode, beta])
        #expect(g.removedBundleIDs == [xcode.path])
    }

    @Test func copiesSharingABundleIDWithoutBookmarksAreToldApartByName() throws {
        // AppGrid's table: no bookmark nor custom_path, so the bundle ID is all there is.
        let dir = tempDir("import-appgrid")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeApp("Xcode.app", id: "com.apple.dt.Xcode", in: dir)
        try makeFakeApp("Xcode-beta.app", id: "com.apple.dt.Xcode", in: dir)
        let xcode = dir.appendingPathComponent("Xcode.app"), beta = dir.appendingPathComponent("Xcode-beta.app")
        typealias Row = LaunchpadImporter.Row
        let items = [Row(id: 1, type: 1, parent: 0, ordering: 0), Row(id: 10, type: 3, parent: 1, ordering: 0),
                     Row(id: 11, type: 4, parent: 10, ordering: 0), Row(id: 12, type: 4, parent: 10, ordering: 1),
                     Row(id: 13, type: 4, parent: 10, ordering: 2)]
        // The beta first, so Launch Services' answer (Xcode) would go to the wrong row.
        let apps = [11: LaunchpadImporter.AppRow(title: "Xcode-beta", bundleID: "com.apple.dt.Xcode"),
                    12: LaunchpadImporter.AppRow(title: "Xcode", bundleID: "com.apple.dt.Xcode"),
                    13: LaunchpadImporter.AppRow(title: "Xcode", bundleID: "com.apple.dt.Xcode")]
        let r = LaunchpadImporter.build(items: items, apps: apps, groupTitles: [:], rows: 5, columns: 7,
                                        installed: [xcode.path, beta.path]) { _ in xcode.path }
        #expect(r.grid.allApps.map { ($0.path as NSString).lastPathComponent } == ["Xcode-beta.app", "Xcode.app"])
        #expect(r.duplicates == ["Xcode"], "a row listed twice is still a duplicate")
    }

    @Test func theOneCopyTheScanFoundWinsOverLaunchServices() throws {
        let dir = tempDir("import-one-copy")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeApp("Foo.app", id: "com.test.Foo", in: dir)
        let foo = dir.appendingPathComponent("Foo.app")
        typealias Row = LaunchpadImporter.Row
        let items = [Row(id: 1, type: 1, parent: 0, ordering: 0), Row(id: 10, type: 3, parent: 1, ordering: 0),
                     Row(id: 11, type: 4, parent: 10, ordering: 0)]
        let apps = [11: LaunchpadImporter.AppRow(title: "Foo", bundleID: "com.test.Foo")]
        let elsewhere = LaunchpadImporter.build(items: items, apps: apps, groupTitles: [:], rows: 5, columns: 7,
                                                installed: [foo.path]) { _ in "/Volumes/Foo 2.0/Foo.app" }
        #expect(elsewhere.grid.allApps.map(\.path) == [foo.path], "not the copy on a disk image")
        let unknown = LaunchpadImporter.build(items: items, apps: apps, groupTitles: [:], rows: 5, columns: 7,
                                              installed: [foo.path]) { _ in nil }
        #expect(unknown.grid.allApps.map(\.path) == [foo.path])
        #expect(unknown.skipped.isEmpty, "installed, so not skipped")
    }

    @Test func launchServicesOnlyPicksAmongTheScansCopies() throws {
        let dir = tempDir("import-copies")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeApp("Xcode.app", id: "com.apple.dt.Xcode", in: dir)
        try makeFakeApp("Xcode-beta.app", id: "com.apple.dt.Xcode", in: dir)
        let xcode = dir.appendingPathComponent("Xcode.app"), beta = dir.appendingPathComponent("Xcode-beta.app")
        typealias Row = LaunchpadImporter.Row
        let items = [Row(id: 1, type: 1, parent: 0, ordering: 0), Row(id: 10, type: 3, parent: 1, ordering: 0),
                     Row(id: 11, type: 4, parent: 10, ordering: 0)]
        // A title naming neither copy, so the name doesn't decide.
        let apps = [11: LaunchpadImporter.AppRow(title: "Xcode (old)", bundleID: "com.apple.dt.Xcode")]
        let r = LaunchpadImporter.build(items: items, apps: apps, groupTitles: [:], rows: 5, columns: 7,
                                        installed: [xcode.path, beta.path]) { _ in "/Users/x/Library/Developer/Xcode.app" }
        #expect(r.grid.allApps.map(\.path) == [xcode.path])
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

    @Test func importsCopiesSharingABundleIDAndReportsTrueDuplicates() throws {
        let dir = tempDir("lp")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeApp("Xcode.app", id: "com.apple.dt.Xcode", in: dir)
        try makeFakeApp("Xcode-beta.app", id: "com.apple.dt.Xcode", in: dir)
        let xcode = dir.appendingPathComponent("Xcode.app").path
        let beta = dir.appendingPathComponent("Xcode-beta.app").path
        let url = dir.appendingPathComponent("db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE items (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER NOT NULL, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, custom_path VARCHAR);
        INSERT INTO items VALUES (1,'',0,3,0,0), (10,'',0,3,1,0);
        INSERT INTO items VALUES (100,'',0,4,10,0), (101,'',0,4,10,1), (102,'',0,4,10,2);
        INSERT INTO apps VALUES (100,'Xcode','com.apple.dt.Xcode','\(xcode)');
        INSERT INTO apps VALUES (101,'Xcode-beta','com.apple.dt.Xcode','\(beta)');
        INSERT INTO apps VALUES (102,'Xcode again','com.apple.dt.Xcode','\(xcode)');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let r = try LaunchpadImporter.importDatabase(at: url, rows: 5, columns: 7) { _ in nil }
        #expect(r.grid.allApps.map(\.path) == [xcode, beta])
        #expect(r.imported == 2)
        #expect(r.skipped.isEmpty)
        #expect(r.duplicates == ["Xcode again"])
    }

    @Test func pageTitlesComeFromGroups() throws {
        let url = tempDir("lp").appendingPathExtension("db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE items (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER NOT NULL, ordering INTEGER);
        CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR);
        CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR);
        INSERT INTO items VALUES (1,'',0,1,0,0), (10,'',0,3,1,0), (11,'',0,3,1,1), (12,'',0,3,1,2);
        INSERT INTO items VALUES (100,'',0,4,10,0), (101,'',0,4,11,0), (102,'',0,4,12,0);
        INSERT INTO apps VALUES (100,'Mail','com.apple.mail'), (101,'Notes','com.apple.Notes'), (102,'Maps','com.apple.Maps');
        INSERT INTO groups VALUES (10,NULL,'Work'), (11,NULL,'');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let r = try LaunchpadImporter.importDatabase(at: url, rows: 5, columns: 7) { "/Applications/\($0).app" }
        #expect(r.grid.pages.map(\.title) == ["Work", nil, nil], "an empty title is no title")
        #expect(r.grid.pages.map(titles) == [["Mail"], ["Notes"], ["Maps"]])
    }

    @Test func walHeaderChangesWhenTheLogIsReset() throws {
        let url = tempDir("lp").appendingPathExtension("db")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        #expect(LaunchpadImporter.walHeader(url.path + "-wal") == nil)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let setup = "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE t (a); INSERT INTO t VALUES (1);"
        #expect(sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK)
        let first = LaunchpadImporter.walHeader(url.path + "-wal")
        #expect(first?.count == 12)
        #expect(sqlite3_exec(db, "INSERT INTO t VALUES (2);", nil, nil, nil) == SQLITE_OK)
        #expect(LaunchpadImporter.walHeader(url.path + "-wal") == first, "appending keeps the header")
        #expect(sqlite3_exec(db, "PRAGMA wal_checkpoint(RESTART); INSERT INTO t VALUES (3);", nil, nil, nil) == SQLITE_OK)
        #expect(LaunchpadImporter.walHeader(url.path + "-wal") != first, "a reset log has new salts")
    }

    @Test func aLogResetBetweenTheTwoCopiesIsCopiedAgain() throws {
        let url = tempDir("lp").appendingPathExtension("db")
        let copy = tempDir("lp-copy").appendingPathExtension("db")
        defer {
            for base in [url, copy] { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: base.path + suffix) } }
        }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let setup = "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE t (a); INSERT INTO t VALUES (1);"
        #expect(sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK)
        func reset() { sqlite3_exec(db, "PRAGMA wal_checkpoint(RESTART); INSERT INTO t VALUES (2);", nil, nil, nil) }

        var resets = 0
        try LaunchpadImporter.copyDatabase(at: url, to: copy) { if resets == 0 { resets += 1; reset() } }
        #expect(LaunchpadImporter.walHeader(copy.path + "-wal") == LaunchpadImporter.walHeader(url.path + "-wal"),
                "the second try copied a matching pair")

        #expect(throws: LaunchpadImporter.ImportError.self, "a log reset every time is given up on") {
            try LaunchpadImporter.copyDatabase(at: url, to: copy, attempts: 3) { reset() }
        }
    }

    @Test func aLogCheckpointedAwayMidCopyIsNotAnError() throws {
        let url = tempDir("lp").appendingPathExtension("db")
        let copy = tempDir("lp-copy").appendingPathExtension("db")
        defer {
            for base in [url, copy] { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: base.path + suffix) } }
        }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let setup = "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE t (a); INSERT INTO t VALUES (1);"
        #expect(sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK)
        var closed = false
        // Checkpointed and gone, as when the last connection closes (Apple's SQLite keeps the
        // file by default, so it is deleted here).
        try LaunchpadImporter.copyDatabase(at: url, to: copy) {
            guard !closed else { return }
            closed = true
            sqlite3_close(db)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: copy.path + "-wal"))
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
        #expect(r.grid.allApps.count == Set(r.grid.allApps.map(\.path)).count)
    }
}
