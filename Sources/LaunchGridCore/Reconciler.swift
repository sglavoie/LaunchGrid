import Foundation

public struct ReconcileReport: Equatable, Sendable {
    public var added: [String] = []
    public var removed: [String] = []
    public var moved: [String] = []
    /// Apps that came back soon after being pruned and returned to their old slot.
    public var restored: [String] = []
    public var duplicatesDropped = 0

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && moved.isEmpty && restored.isEmpty && duplicatesDropped == 0
    }
}

/// Merges the installed-app catalog into a grid.
public enum Reconciler {
    /// How long a pruned app keeps its slot, waiting for an updater to put it back.
    public static let restoreWindow: TimeInterval = 3600
    /// Bound on `Grid.recentlyPruned`, oldest first out.
    static let pruneMemory = 200
    /// How many preceding neighbours a pruned app remembers to find its way back.
    static let neighbourMemory = 8

    /// - Parameters:
    ///   - autoAdd: append installed apps that are neither on the grid nor in `removedBundleIDs`.
    ///   - pruneMissing: drop apps that are no longer installed. Callers disable this when the
    ///     scan looks unreliable (e.g. it found nothing at all).
    ///   - isReachable: whether the scan could have seen the app at this path. Apps on an
    ///     unmounted volume or under a missing scan folder are kept, not pruned.
    ///   - pathExists: whether something is on disk at a path. A ref follows its bundle ID to
    ///     another path only when its own app is gone from where it was.
    ///   - now: the clock for `Grid.recentlyPruned`; apps pruned within `restoreWindow` of it
    ///     return to their old slot (even with `autoAdd` off) when they show up again.
    public static func reconcile(
        _ grid: inout Grid,
        installed: [InstalledApp],
        autoAdd: Bool,
        pruneMissing: Bool = true,
        isReachable: (String) -> Bool = { _ in true },
        pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        now: Date = Date()
    ) -> ReconcileReport {
        var report = ReconcileReport()
        let byPath = Dictionary(installed.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let byBundle = Dictionary(grouping: installed.filter { $0.bundleID != nil }, by: { $0.bundleID! })
        // Paths some ref already points at; a moved ref must not take over another ref's app.
        let gridPaths = Set(grid.allApps.map(\.path))
        // Never prune when the scan came back empty: that's a failed scan, not an empty Mac.
        let prune = pruneMissing && !installed.isEmpty
        // Dedup by path: two copies of one app (Xcode and Xcode-beta) share a bundle ID.
        var seen = Set<String>()
        var pruned: [PrunedApp] = []
        // Folders this pass emptied, so older memory entries from them recreate them too.
        var emptiedFolders = Set<UUID>()
        // A copy, so `match` reads no part of `grid` while the loops below write to it.
        let removed = grid.removedBundleIDs

        /// The installed app `ref` stands for: the one at its path, else (when its own app
        /// is gone from there, not merely out of reach) an unclaimed, unexcluded one with its
        /// bundle ID.
        func match(for ref: AppRef) -> (app: InstalledApp, moved: Bool)? {
            let atPath = byPath[ref.path]
            if let atPath, ref.bundleID == nil || atPath.bundleID == ref.bundleID { return (atPath, false) }
            if let id = ref.bundleID, atPath != nil || (isReachable(ref.path) && !pathExists(ref.path)),
               let other = byBundle[id]?.first(where: {
                   !gridPaths.contains($0.path) && !seen.contains($0.path)
                       && !removed.contains($0.key) && !removed.contains($0.path)
               }) {
                return (other, true)
            }
            // Another app now lives at this path (e.g. an update changed the bundle ID): adopt it.
            if let atPath { return (atPath, false) }
            return nil
        }

        /// Returns the refreshed ref, or nil when it should leave the grid. `slot` is only
        /// built for an app actually pruned.
        func refresh(_ ref: AppRef, at slot: () -> PrunedApp) -> AppRef? {
            var ref = ref
            if let (found, moved) = match(for: ref) {
                if moved { report.moved.append(found.name) }
                ref.path = found.path
                ref.name = found.name
                ref.bundleID = found.bundleID ?? ref.bundleID
            } else if prune && isReachable(ref.path) {
                report.removed.append(ref.title)
                var slot = slot()
                slot.app = ref
                pruned.append(slot)
                return nil
            }
            guard seen.insert(ref.path).inserted else {
                report.duplicatesDropped += 1
                return nil
            }
            return ref
        }

        // Apps pruned by earlier passes, which no longer show among their old neighbours.
        let earlier = grid.recentlyPruned
        /// The IDs before slot `i` among `ids`, nearest last, counting apps an earlier pass
        /// pruned from just before it (`index` gives such an entry's slot there, if it was in
        /// this list). One pruned at slot k sat just before the item now at k.
        func neighbours(_ ids: [UUID], before i: Int, index: (PrunedApp) -> Int?) -> [UUID] {
            let gone = earlier.compactMap { e in index(e).flatMap { $0 <= i ? (Double($0) - 0.5, e.app.id) : nil } }
            let here = ids[..<i].enumerated().map { (Double($0.offset), $0.element) }
            // A stable sort keeps several pruned at one slot oldest first, as they stood.
            let all = (gone + here).enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
            return all.suffix(neighbourMemory).map(\.element.1)
        }

        for p in grid.pages.indices {
            let pageID = grid.pages[p].id
            let items = grid.pages[p].items
            let itemIDs = items.map(\.id)
            grid.pages[p].items = items.enumerated().compactMap { i, item in
                func before() -> [UUID] {
                    neighbours(itemIDs, before: i) { $0.pageID == pageID && $0.folderID == nil ? $0.index : nil }
                }
                switch item {
                case .app(let a):
                    return refresh(a) { PrunedApp(app: a, prunedAt: now, pageID: pageID, index: i, before: before()) }
                        .map(GridItem.app)
                case .folder(var f):
                    let (apps, folderID, folderName) = (f.apps, f.id, f.name)
                    f.apps = apps.enumerated().compactMap { fi, a in
                        refresh(a) {
                            PrunedApp(app: a, prunedAt: now, pageID: pageID, index: i,
                                      folderID: folderID, folderName: folderName, folderIndex: fi,
                                      before: before(),
                                      folderBefore: neighbours(apps.map(\.id), before: fi) { $0.folderID == folderID ? $0.folderIndex : nil })
                        }
                    }
                    guard f.apps.isEmpty else { return .folder(f) }
                    for k in pruned.indices where pruned[k].folderID == f.id { pruned[k].folderEmptied = true }
                    emptiedFolders.insert(f.id)
                    return nil
                }
            }
        }

        // Bring back recently pruned apps that reappeared, then remember the newly pruned.
        var memory: [PrunedApp] = []
        for var entry in grid.recentlyPruned where now.timeIntervalSince(entry.prunedAt) < restoreWindow {
            guard !grid.isExcluded(key: entry.app.key, path: entry.app.path) else { continue }
            // Its folder outlived it until this pass pruned the folder's last app.
            if let id = entry.folderID, emptiedFolders.contains(id) { entry.folderEmptied = true }
            guard let (found, _) = match(for: entry.app) else {
                memory.append(entry)
                continue
            }
            if seen.contains(found.path) || grid.isExcluded(found) { continue }
            entry.app.path = found.path
            entry.app.name = found.name
            entry.app.bundleID = found.bundleID ?? entry.app.bundleID
            seen.insert(found.path)
            grid.restore(entry)
            report.restored.append(entry.app.title)
        }
        grid.recentlyPruned = Array((memory + pruned).suffix(pruneMemory))

        if autoAdd {
            let fresh = installed
                .filter { !seen.contains($0.path) && !grid.isExcluded($0) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var paths = seen
            let unique = fresh.filter { paths.insert($0.path).inserted }
            grid.appendToFirstFree(unique.map { .app($0.makeRef()) })
            report.added = unique.map(\.name)
        }

        grid.normalize()
        return report
    }

    /// Installed apps that are not on the grid, for "Add Missing Apps…". A copy sharing its
    /// bundle ID with one on the grid (Xcode-beta beside Xcode) counts as missing.
    public static func missingApps(in grid: Grid, installed: [InstalledApp]) -> [InstalledApp] {
        let paths = Set(grid.allApps.map(\.path))
        let installedPaths = Set(installed.map(\.path))
        // Grid paths per key; a key whose ref points nowhere installed is that app, moved.
        let onGrid = Dictionary(grouping: grid.allApps, by: \.key).mapValues { $0.map(\.path) }
        return installed
            .filter { app in
                !paths.contains(app.path) && (onGrid[app.key]?.allSatisfy(installedPaths.contains) ?? true)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Adds apps explicitly, clearing them from the removed list. `installed` tells which
    /// apps share a bundle ID, so including one copy keeps the others excluded.
    public static func add(_ apps: [InstalledApp], to grid: inout Grid, installed: [InstalledApp] = []) {
        var paths = Set(grid.allApps.map(\.path))
        // `insert` also drops an app listed twice in `apps`.
        let new = apps.filter { paths.insert($0.path).inserted }
        let copies = CopyIndex(installed + apps)
        for app in apps { grid.setExcluded(app, false, copies: copies) }
        grid.appendToFirstFree(new.map { .app($0.makeRef()) })
    }

    /// Applies a choice of which apps belong on the grid. Excluded apps leave it (folders and
    /// pages they empty go too) and are remembered as removed; included ones are added back.
    public static func choose(include: [InstalledApp], exclude: [InstalledApp], in grid: inout Grid,
                              installed: [InstalledApp] = []) {
        let among = installed + include + exclude + grid.allApps.map(InstalledApp.init)
        let copies = CopyIndex(among)
        let paths = Set(exclude.map(\.path))
        // Match by key too (a ref whose path is stale), unless other copies share that key.
        let keys = Set(exclude.filter { !copies.hasCopies($0) }.map(\.key))
        let ids = grid.allApps.filter { paths.contains($0.path) || keys.contains($0.key) }.map(\.id)
        grid.removingEmptiedPages { $0.remove(ids, installed: among) }
        for app in exclude { grid.setExcluded(app, true, copies: copies) }
        add(include, to: &grid, installed: among)
    }
}

extension InstalledApp {
    init(_ ref: AppRef) {
        self.init(bundleID: ref.bundleID, path: ref.path, name: ref.name)
    }
}

/// Paths per bundle ID, built once so looking up an app's copies doesn't rescan the list.
struct CopyIndex {
    private var paths: [String: Set<String>] = [:]

    init(_ apps: [InstalledApp]) {
        for app in apps {
            if let id = app.bundleID { paths[id, default: []].insert(app.path) }
        }
    }

    /// Paths of the other apps sharing `app`'s bundle ID (Xcode and Xcode-beta).
    func copies(of app: InstalledApp) -> Set<String> {
        guard let id = app.bundleID, var found = paths[id] else { return [] }
        found.remove(app.path)
        return found
    }

    func hasCopies(_ app: InstalledApp) -> Bool { !copies(of: app).isEmpty }
}

extension Grid {
    /// Excluded by bundle ID (every copy) or by path (that copy only).
    public func isExcluded(key: String, path: String) -> Bool {
        removedBundleIDs.contains(key) || removedBundleIDs.contains(path)
    }

    public func isExcluded(_ app: InstalledApp) -> Bool {
        isExcluded(key: app.key, path: app.path)
    }

    /// Records or clears one app's exclusion. A copy sharing its bundle ID with another in
    /// `among` is excluded by path, and including it when the whole bundle ID was excluded
    /// keeps the other copies out.
    public mutating func setExcluded(_ app: InstalledApp, _ excluded: Bool, among: [InstalledApp]) {
        setExcluded(app, excluded, copies: CopyIndex(among))
    }

    /// Clears `include`'s exclusions and records `exclude`'s, indexing `among` once.
    public mutating func setExcluded(include: [InstalledApp], exclude: [InstalledApp], among: [InstalledApp]) {
        let copies = CopyIndex(among)
        for app in include { setExcluded(app, false, copies: copies) }
        for app in exclude { setExcluded(app, true, copies: copies) }
    }

    /// `setExcluded(_:_:among:)` with the copies indexed once, for callers setting many apps.
    mutating func setExcluded(_ app: InstalledApp, _ excluded: Bool, copies index: CopyIndex) {
        let copies = index.copies(of: app)
        if excluded {
            removedBundleIDs.insert(copies.isEmpty ? app.key : app.path)
        } else {
            removedBundleIDs.remove(app.path)
            if removedBundleIDs.remove(app.key) != nil { removedBundleIDs.formUnion(copies) }
        }
    }
}

extension Grid {
    /// Puts a pruned app back where it was, recreating its folder if pruning emptied it.
    mutating func restore(_ entry: PrunedApp) {
        if let folderID = entry.folderID {
            if let loc = locate(folderID), loc.folderIndex == nil, case .folder(var f) = pages[loc.page].items[loc.index] {
                let at = Self.slot(after: entry.folderBefore, fallback: entry.folderIndex ?? f.apps.count, in: f.apps.map(\.id))
                f.apps.insert(entry.app, at: min(max(0, at), f.apps.count))
                pages[loc.page].items[loc.index] = .folder(f)
                return
            }
            if entry.folderEmptied == true {
                place(.folder(Folder(id: folderID, name: entry.folderName ?? String(localized: "Folder"), apps: [entry.app])), entry)
            } else {
                place(.app(entry.app), entry) // the user ungrouped or emptied it meanwhile
            }
        } else {
            place(.app(entry.app), entry)
        }
    }

    private mutating func place(_ item: GridItem, _ entry: PrunedApp) {
        if let p = pages.firstIndex(where: { $0.id == entry.pageID }) {
            insert([item], page: p, at: Self.slot(after: entry.before, fallback: entry.index, in: pages[p].items.map(\.id)))
        } else {
            appendToFirstFree([item])
        }
    }

    /// Just after the nearest remembered neighbour still present. With none left, the start
    /// if every item before it was remembered, else the old index.
    static func slot(after before: [UUID]?, fallback: Int, in ids: [UUID]) -> Int {
        guard let before else { return fallback }
        for id in before.reversed() {
            if let i = ids.firstIndex(of: id) { return i + 1 }
        }
        return before.count == fallback ? 0 : fallback
    }
}
