import Foundation
import Testing
@testable import LaunchGridCore

/// A seeded generator, so a failing run can be replayed from the seed it reports.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random sequences of edits and scans, checked against what must always hold, rather than
/// against one expected layout each.
@Suite struct PropertyTests {
    static let names = (0..<40).map { "App\($0)" }

    func makeGrid(_ rng: inout SeededRandom) -> Grid {
        let rows = Int.random(in: 1...4, using: &rng), columns = Int.random(in: 1...5, using: &rng)
        var g = Grid(rows: rows, columns: columns, pages: [Page()])
        // Actions come from their own generator, so each seed's apps and edits stay as they were.
        var actionRNG = SeededRandom(state: rng.state ^ 0xAC71_0000_5EED)
        var items: [GridItem] = Self.names.prefix(Int.random(in: 1...Self.names.count, using: &rng)).map { .app(app($0)) }
        // Actions among the apps, and some search-only ones that take no slot.
        for k in 0..<Int.random(in: 0...4, using: &actionRNG) {
            items.insert(.action(Self.action("Act\(k)")), at: Int.random(in: 0...items.count, using: &actionRNG))
        }
        g.appendAtEnd(items)
        g.hiddenActions = (0..<Int.random(in: 0...2, using: &actionRNG)).map { Self.action("Hidden\($0)", showsOnGrid: false) }
        return g
    }

    static func action(_ name: String, showsOnGrid: Bool = true) -> Action {
        Action(name: name, keywords: [name], kind: .openURL(template: "https://example.com/\(name)"), showsOnGrid: showsOnGrid)
    }

    /// Nothing lost or doubled, no page over capacity, no empty folder, no repeated ID; each
    /// action where its `showsOnGrid` says (one in a folder is on the grid), never among the apps.
    func checkInvariants(_ g: Grid, apps expected: [String], actions: [UUID]? = nil, seed: UInt64, step: String) {
        let paths = g.allApps.map(\.path).sorted()
        #expect(paths == expected.sorted(), "seed \(seed), after \(step): apps lost or doubled")
        if let actions {
            #expect(g.allActions.map(\.id).sorted { $0.uuidString < $1.uuidString } == actions.sorted { $0.uuidString < $1.uuidString },
                    "seed \(seed), after \(step): actions lost or doubled")
        }
        #expect(g.pages.allSatisfy { $0.items.allSatisfy { $0.action?.showsOnGrid != false } }, "seed \(seed), after \(step): a search-only action on a page")
        #expect(g.pages.allSatisfy { $0.items.allSatisfy { $0.folder?.actions.allSatisfy(\.showsOnGrid) != false } },
                "seed \(seed), after \(step): a search-only action in a folder")
        #expect(g.hiddenActions.allSatisfy { !$0.showsOnGrid }, "seed \(seed), after \(step): a visible action hidden")
        let capacity = g.rows * g.columns
        #expect(g.pages.allSatisfy { $0.items.count <= capacity }, "seed \(seed), after \(step): a page over capacity")
        #expect(!g.pages.contains { $0.items.contains { $0.folder?.items.isEmpty == true } }, "seed \(seed), after \(step): an empty folder")
        let ids = g.pages.flatMap { [$0.id] + $0.items.flatMap { [$0.id] + ($0.folder?.itemIDs ?? []) } } + g.hiddenActions.map(\.id)
        #expect(Set(ids).count == ids.count, "seed \(seed), after \(step): a repeated ID")
    }

    @Test func randomEditsNeverLoseDoubleOrOverfillAnything() {
        for seed in UInt64(1)...300 {
            var rng = SeededRandom(state: seed)
            var g = makeGrid(&rng)
            let expected = g.allApps.map(\.path)
            let actions = g.allActions.map(\.id)
            for _ in 0..<40 {
                let items = g.pages.flatMap(\.items)
                let apps = g.allApps
                guard let any = items.randomElement(using: &rng) else { break }
                var step = ""
                // Mixed-folder edits draw from their own generator, so the older steps' seeds
                // still produce the same sequences.
                switch Int.random(in: 0..<11, using: &rng) {
                case 0:
                    let page = Int.random(in: 0..<g.pages.count, using: &rng)
                    let at = Int.random(in: 0...g.rows * g.columns, using: &rng)
                    g.removingEmptiedPages { $0.move([any.id], toPage: page, at: at) }
                    step = "move"
                case 1:
                    let picked = Array(apps.shuffled(using: &rng).prefix(Int.random(in: 2...4, using: &rng)))
                    g.removingEmptiedPages { _ = $0.group(picked.map(\.id), name: "F", anchor: picked.first?.id) }
                    step = "group"
                case 2:
                    guard let folder = items.compactMap(\.folder).randomElement(using: &rng),
                          let loose = items.filter({ $0.app != nil }).randomElement(using: &rng) else { continue }
                    let at = Int.random(in: 0...folder.apps.count, using: &rng)
                    g.removingEmptiedPages { $0.addToFolder([loose.id], folder: folder.id, at: at) }
                    step = "addToFolder"
                case 3:
                    guard let folder = items.compactMap(\.folder).randomElement(using: &rng) else { continue }
                    g.ungroup(folder.id)
                    step = "ungroup"
                case 4:
                    guard let inner = apps.randomElement(using: &rng), g.locate(inner.id)?.folderIndex != nil else { continue }
                    // Out of its folder onto a page, as dragging it out does.
                    let page = Int.random(in: 0..<g.pages.count, using: &rng)
                    g.removingEmptiedPages { $0.move([inner.id], toPage: page, at: 0) }
                    step = "moveOutOfFolder"
                case 5:
                    g.deletePage(Int.random(in: 0..<g.pages.count, using: &rng))
                    step = "deletePage"
                case 6:
                    g.resize(rows: Int.random(in: 1...5, using: &rng), columns: Int.random(in: 1...6, using: &rng))
                    step = "resize"
                case 7:
                    g.sortEverything(folders: FolderPlacement.allCases.randomElement(using: &rng)!)
                    step = "sortEverything"
                case 8:
                    // Actions on the grid go in the folder with the apps; search-only ones
                    // stay search-only, and no action changes.
                    let picked = Array((apps.map(\.id) + g.allActions.map(\.id)).shuffled(using: &rng).prefix(Int.random(in: 2...4, using: &rng)))
                    let before = Dictionary(uniqueKeysWithValues: g.allActions.map { ($0.id, $0) })
                    let hidden = g.hiddenActions.map(\.id)
                    var folderID: UUID?
                    g.removingEmptiedPages { folderID = $0.group(picked, name: "F", anchor: picked.first) }
                    #expect(Dictionary(uniqueKeysWithValues: g.allActions.map { ($0.id, $0) }) == before, "seed \(seed): grouping changed an action")
                    #expect(g.hiddenActions.map(\.id) == hidden, "seed \(seed): grouping moved a search-only action")
                    if let folderID, let folder = g.folder(folderID) {
                        let grouped = Set(picked).subtracting(hidden)
                        #expect(Set(folder.itemIDs) == grouped, "seed \(seed): the folder holds what was grouped")
                    }
                    step = "groupWithActions"
                    var mixedRNG = SeededRandom(state: rng.state ^ 0x0F01_DE25)
                    // Then an action dragged into, around or out of a folder.
                    let current = g.pages.flatMap(\.items)
                    guard let action = g.allActions.filter(\.showsOnGrid).randomElement(using: &mixedRNG) else { break }
                    switch Int.random(in: 0..<3, using: &mixedRNG) {
                    case 0:
                        guard let folder = current.compactMap(\.folder).randomElement(using: &mixedRNG) else { break }
                        let at = Int.random(in: 0...folder.items.count, using: &mixedRNG)
                        g.removingEmptiedPages { $0.addToFolder([action.id], folder: folder.id, at: at) }
                        #expect(g.folder(containing: action.id)?.id == folder.id, "seed \(seed): the action went in the folder")
                        step += "+addActionToFolder"
                    case 1:
                        guard g.locate(action.id)?.folderIndex != nil else { break }
                        let page = Int.random(in: 0..<g.pages.count, using: &mixedRNG)
                        g.removingEmptiedPages { $0.move([action.id], toPage: page, at: 0) }
                        #expect(g.locate(action.id)?.folderIndex == nil, "seed \(seed): the action left its folder")
                        step += "+moveActionOutOfFolder"
                    default:
                        guard let target = current.filter({ $0.id != action.id && $0.folder == nil }).randomElement(using: &mixedRNG) else { break }
                        g.removingEmptiedPages { _ = $0.group([target.id, action.id], name: "F", anchor: target.id) }
                        step += "+groupActionWithItem"
                    }
                case 9:
                    guard var action = g.allActions.randomElement(using: &rng) else { continue }
                    action.showsOnGrid.toggle()
                    g.updateAction(action)
                    step = "toggleActionVisibility"
                default:
                    _ = g.addPage(after: Int.random(in: 0..<g.pages.count, using: &rng))
                    step = "addPage"
                }
                checkInvariants(g, apps: expected, actions: actions, seed: seed, step: step)
            }
        }
    }

    @Test(arguments: [false, true])
    func appsThatVanishAndReturnComeBackToTheirPlaces(withFolders: Bool) {
        let now = Date()
        for seed in UInt64(1)...200 {
            var rng = SeededRandom(state: seed)
            var g = makeGrid(&rng)
            // Updates also empty folders and their pages, sometimes over several scans.
            if withFolders {
                for _ in 0..<3 {
                    let picked = Array(g.allApps.shuffled(using: &rng).prefix(3))
                    if picked.count > 1 { g.removingEmptiedPages { $0.group(picked.map(\.id), name: "Folder") } }
                }
                // Mixed folders: some actions join them, from a generator of their own so each
                // seed's apps vanish and return as before.
                var mixedRNG = SeededRandom(state: seed ^ 0x0F01_DE25)
                let folders = g.pages.flatMap(\.items).compactMap(\.folder)
                for action in g.pages.flatMap(\.items).compactMap(\.action) where Bool.random(using: &mixedRNG) {
                    guard let folder = folders.randomElement(using: &mixedRNG), let f = g.folder(folder.id) else { continue }
                    let at = Int.random(in: 0...f.items.count, using: &mixedRNG)
                    g.removingEmptiedPages { $0.addToFolder([action.id], folder: folder.id, at: at) }
                }
            }
            let installedApps = g.allApps.map { InstalledApp(bundleID: $0.bundleID, path: $0.path, name: $0.name) }
            let original = g.pages.map { $0.items.map(\.title) }
            let originalApps = g.allApps.map(\.id)
            let originalMembers = g.pages.flatMap(\.items).compactMap(\.folder).map(\.itemIDs)
            let originalActions = g.allActions
            var present = Set(installedApps.map(\.path))
            // A few rounds of apps going (an update, a volume) and coming back, in batches. Never
            // all at once: the default empty scan is treated as unconfirmed and prunes nothing.
            for _ in 0..<4 {
                let gone = Set(installedApps.map(\.path).shuffled(using: &rng).prefix(Int.random(in: 0...(installedApps.count - 1), using: &rng)))
                present.subtract(gone)
                let shown = present
                _ = Reconciler.reconcile(&g, installed: installedApps.filter { shown.contains($0.path) }, autoAdd: true,
                                         pathExists: { shown.contains($0) }, now: now)
                checkInvariants(g, apps: Array(shown), actions: originalActions.map(\.id), seed: seed, step: "vanish")
                while present.count < installedApps.count {
                    let back = installedApps.map(\.path).filter { !present.contains($0) }.shuffled(using: &rng)
                    present.formUnion(back.prefix(Int.random(in: 1...back.count, using: &rng)))
                    let shown = present
                    _ = Reconciler.reconcile(&g, installed: installedApps.filter { shown.contains($0.path) }, autoAdd: true,
                                             pathExists: { shown.contains($0) }, now: now)
                    checkInvariants(g, apps: Array(shown), actions: originalActions.map(\.id), seed: seed, step: "return")
                }
            }
            #expect(g.pages.map { $0.items.map(\.title) } == original, "seed \(seed): the layout came back as it was")
            #expect(g.allApps.map(\.id) == originalApps, "seed \(seed): folder contents came back in order")
            #expect(g.pages.flatMap(\.items).compactMap(\.folder).map(\.itemIDs) == originalMembers,
                    "seed \(seed): apps came back among a folder's actions in order")
            #expect(g.allActions == originalActions, "seed \(seed): actions untouched")
        }
    }

    /// With apps waiting to come back, some returning (which can recreate their folder and page)
    /// and edits between scans, a second reconcile of the same scan still changes nothing: not
    /// the layout, nor what the waiting apps remember of where they were.
    @Test func aSecondReconcileChangesNothingWhileAppsWaitToReturn() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        for seed in UInt64(1)...600 {
            var rng = SeededRandom(state: seed)
            var g = Grid(rows: Int.random(in: 1...3, using: &rng), columns: Int.random(in: 1...4, using: &rng))
            g.appendAtEnd((0..<Int.random(in: 2...20, using: &rng)).map { n in
                .app(AppRef(bundleID: "com.x.a\(n)", path: "/Applications/A\(n).app", name: "A\(n)"))
            })
            for _ in 0..<2 {
                let picked = Array(g.allApps.shuffled(using: &rng).prefix(3))
                g.removingEmptiedPages { _ = $0.group(picked.map(\.id), name: "F", anchor: picked.first?.id) }
            }
            let installedApps = g.allApps.map { InstalledApp(bundleID: $0.bundleID, path: $0.path, name: $0.name) }
            var present = Set(installedApps.map(\.path))
            for round in 0..<5 {
                if Bool.random(using: &rng) {
                    let gone = installedApps.map(\.path).shuffled(using: &rng).prefix(Int.random(in: 0..<installedApps.count, using: &rng))
                    present.subtract(gone)
                    if present.isEmpty { present.insert(installedApps[0].path) }
                } else {
                    let back = installedApps.map(\.path).filter { !present.contains($0) }.shuffled(using: &rng)
                    if !back.isEmpty { present.formUnion(back.prefix(Int.random(in: 1...back.count, using: &rng))) }
                }
                let items = g.pages.flatMap(\.items)
                if let any = items.randomElement(using: &rng) {
                    switch Int.random(in: 0..<5, using: &rng) {
                    case 0:
                        let page = Int.random(in: 0..<g.pages.count, using: &rng), at = Int.random(in: 0...g.capacity, using: &rng)
                        g.removingEmptiedPages { $0.move([any.id], toPage: page, at: at) }
                    case 1: g.deletePage(Int.random(in: 0..<g.pages.count, using: &rng))
                    case 2: if let f = items.compactMap(\.folder).first { g.ungroup(f.id) }
                    case 3: g.resize(rows: Int.random(in: 1...3, using: &rng), columns: Int.random(in: 1...4, using: &rng))
                    default: break
                    }
                }
                let shown = present
                let scan = installedApps.filter { shown.contains($0.path) }
                _ = Reconciler.reconcile(&g, installed: scan, autoAdd: true, pathExists: { shown.contains($0) }, now: now)
                let once = g
                _ = Reconciler.reconcile(&g, installed: scan, autoAdd: true, pathExists: { shown.contains($0) }, now: now)
                #expect(g.pages == once.pages, "seed \(seed) round \(round): the layout")
                #expect(g.recentlyPruned == once.recentlyPruned, "seed \(seed) round \(round): what waiting apps remember")
                if g != once { break }
            }
        }
    }

    @Test func aSecondReconcileOfTheSameScanChangesNothing() {
        for seed in UInt64(1)...200 {
            var rng = SeededRandom(state: seed)
            var g = makeGrid(&rng)
            // Some of the grid's apps gone, some new ones installed, some sharing a bundle ID.
            var installed = g.allApps.filter { _ in Bool.random(using: &rng) }
                .map { InstalledApp(bundleID: $0.bundleID, path: $0.path, name: $0.name) }
            for i in 0..<Int.random(in: 0...5, using: &rng) {
                let shared = Bool.random(using: &rng)
                installed.append(InstalledApp(bundleID: shared ? installed.first?.bundleID : "com.new.\(i)",
                                              path: "/Applications/New\(i).app", name: "New\(i)"))
            }
            let paths = Set(installed.map(\.path))
            let autoAdd = Bool.random(using: &rng)
            _ = Reconciler.reconcile(&g, installed: installed, autoAdd: autoAdd, pathExists: { paths.contains($0) })
            let once = g
            _ = Reconciler.reconcile(&g, installed: installed, autoAdd: autoAdd, pathExists: { paths.contains($0) })
            #expect(g == once, "seed \(seed)")
        }
    }
}
