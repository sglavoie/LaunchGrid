import Foundation
import Testing
@testable import LaunchGridCore

@Suite struct UpdateEditTests {
    @Test func editsDuringUpdatesPreserveEveryApp() {
        let now = Date()
        for seed in UInt64(1)...200 {
            var rng = SeededRandom(state: seed)
            let refs = (0..<20).map { app("App\($0)") }
            let expected = refs.map(\.path).sorted()
            var grid = Grid(rows: 2, columns: 3)
            grid.appendAtEnd(refs.map(GridItem.app))
            var present = Set(expected)
            for step in 0..<80 {
                let items = grid.pages.flatMap(\.items)
                let ids = items.flatMap { [$0.id] + ($0.folder?.apps.map(\.id) ?? []) }
                let picked = Array(ids.shuffled(using: &rng).prefix(Int.random(in: 1...4, using: &rng)))
                switch Int.random(in: 0..<7, using: &rng) {
                case 0:
                    present = Set(expected.filter { _ in Bool.random(using: &rng) })
                    let installed = refs.filter { present.contains($0.path) }.map(InstalledApp.init)
                    _ = Reconciler.reconcile(&grid, installed: installed, autoAdd: false,
                        pruneOnEmpty: true, pathExists: present.contains, now: now)
                case 1:
                    grid.removingEmptiedPages { $0.group(picked, name: "Folder") }
                case 2:
                    if let folder = items.compactMap(\.folder).randomElement(using: &rng) {
                        grid.removingEmptiedPages { $0.addToFolder(picked, folder: folder.id, at: 0) }
                    }
                case 3:
                    if let folder = items.compactMap(\.folder).randomElement(using: &rng) {
                        grid.ungroup(folder.id)
                    }
                case 4:
                    let page = Int.random(in: 0..<grid.pages.count, using: &rng)
                    grid.removingEmptiedPages { $0.move(picked, toPage: page, at: 0) }
                case 5:
                    grid.resize(rows: 1, columns: Int.random(in: 1...5, using: &rng))
                default:
                    grid.deletePage(Int.random(in: 0..<grid.pages.count, using: &rng))
                }
                let known = grid.allApps.map(\.path) + grid.recentlyPruned.map { $0.app.path }
                guard known.sorted() == expected else {
                    Issue.record("seed \(seed), step \(step): apps lost or doubled")
                    return
                }
            }
        }
    }
}
