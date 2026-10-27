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
        g.appendAtEnd(Self.names.prefix(Int.random(in: 1...Self.names.count, using: &rng)).map { .app(app($0)) })
        return g
    }

    /// Nothing lost or doubled, no page over capacity, no empty folder, no repeated ID.
    func checkInvariants(_ g: Grid, apps expected: [String], seed: UInt64, step: String) {
        let paths = g.allApps.map(\.path).sorted()
        #expect(paths == expected.sorted(), "seed \(seed), after \(step): apps lost or doubled")
        let capacity = g.rows * g.columns
        #expect(g.pages.allSatisfy { $0.items.count <= capacity }, "seed \(seed), after \(step): a page over capacity")
        #expect(!g.pages.contains { $0.items.contains { $0.folder?.apps.isEmpty == true } }, "seed \(seed), after \(step): an empty folder")
        let ids = g.pages.flatMap { [$0.id] + $0.items.flatMap { [$0.id] + ($0.folder?.apps.map(\.id) ?? []) } }
        #expect(Set(ids).count == ids.count, "seed \(seed), after \(step): a repeated ID")
    }

    @Test func randomEditsNeverLoseDoubleOrOverfillAnything() {
        for seed in UInt64(1)...300 {
            var rng = SeededRandom(state: seed)
            var g = makeGrid(&rng)
            let expected = g.allApps.map(\.path)
            for _ in 0..<40 {
                let items = g.pages.flatMap(\.items)
                let apps = g.allApps
                guard let any = items.randomElement(using: &rng) else { break }
                let step: String
                switch Int.random(in: 0..<9, using: &rng) {
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
                default:
                    _ = g.addPage(after: Int.random(in: 0..<g.pages.count, using: &rng))
                    step = "addPage"
                }
                checkInvariants(g, apps: expected, seed: seed, step: step)
            }
        }
    }

    @Test func appsThatVanishAndReturnComeBackToTheirPlaces() {
        let now = Date()
        for seed in UInt64(1)...200 {
            var rng = SeededRandom(state: seed)
            var g = makeGrid(&rng)
            let installedApps = g.allApps.map { InstalledApp(bundleID: $0.bundleID, path: $0.path, name: $0.name) }
            let original = g.pages.map { $0.items.map(\.title) }
            var present = Set(installedApps.map(\.path))
            // A few rounds of apps going (an update, a volume) and coming back, in batches. Never
            // all at once: an empty scan is taken as a failed one, and prunes nothing.
            for _ in 0..<4 {
                let gone = Set(installedApps.map(\.path).shuffled(using: &rng).prefix(Int.random(in: 0...(installedApps.count - 1), using: &rng)))
                present.subtract(gone)
                let shown = present
                _ = Reconciler.reconcile(&g, installed: installedApps.filter { shown.contains($0.path) }, autoAdd: true,
                                         pathExists: { shown.contains($0) }, now: now)
                checkInvariants(g, apps: Array(shown), seed: seed, step: "vanish")
                while present.count < installedApps.count {
                    let back = installedApps.map(\.path).filter { !present.contains($0) }.shuffled(using: &rng)
                    present.formUnion(back.prefix(Int.random(in: 1...back.count, using: &rng)))
                    let shown = present
                    _ = Reconciler.reconcile(&g, installed: installedApps.filter { shown.contains($0.path) }, autoAdd: true,
                                             pathExists: { shown.contains($0) }, now: now)
                    checkInvariants(g, apps: Array(shown), seed: seed, step: "return")
                }
            }
            #expect(g.pages.map { $0.items.map(\.title) } == original, "seed \(seed): the layout came back as it was")
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
