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
    ///     another path, or is pruned, only when its own app is gone from where it was.
    ///   - now: the clock for `Grid.recentlyPruned`; apps pruned within `restoreWindow` of it
    ///     return to their old slot (even with `autoAdd` off) when they show up again.
    ///   - aliases: `AppScanner.ScanResult.aliases`. A ref at an app's real path takes the
    ///     path the scan lists it at, so it isn't added a second time.
    ///   - wasInstalledBefore: whether an app was already at this path before the latest scan.
    ///     A ref whose app is gone follows a copy with another name (its app renamed) only when
    ///     that copy is new: Xcode deleted doesn't make its tile Xcode-beta, there all along.
    public static func reconcile(
        _ grid: inout Grid,
        installed: [InstalledApp],
        autoAdd: Bool,
        pruneMissing: Bool = true,
        isReachable: (String) -> Bool = { _ in true },
        pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        aliases: [String: String] = [:],
        wasInstalledBefore: (String) -> Bool = { _ in false },
        now: Date = Date()
    ) -> ReconcileReport {
        var report = ReconcileReport()
        let byPath = Dictionary(installed.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let byBundle = Dictionary(grouping: installed.filter { $0.bundleID != nil }, by: { $0.bundleID! })
        let byFoldedPath = Dictionary(installed.map { ($0.path.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        // An excluded copy can be found under another spelling just like a visible tile:
        // a case-only rename or a symlink must not make it a new, unexcluded app. Keep
        // bundle-wide exclusions and paths the scan can't resolve as they were.
        grid.removedBundleIDs = Set(grid.removedBundleIDs.map { key in
            guard key.hasPrefix("/"), byPath[key] == nil else { return key }
            return aliases[key].flatMap { byPath[$0]?.path } ?? byFoldedPath[key.lowercased()]?.path ?? key
        })
        // Paths some ref already points at; a moved ref must not take over another ref's app.
        let gridPaths = Set(grid.allApps.map(\.path))
        // Never prune when the scan came back empty: that's a failed scan, not an empty Mac.
        let prune = pruneMissing && !installed.isEmpty
        // Dedup by path: two copies of one app (Xcode and Xcode-beta) share a bundle ID.
        var seen = Set<String>()
        var pruned: [PrunedApp] = []
        // Folders this pass emptied, so older memory entries from them recreate them too.
        var emptiedFolders = Set<UUID>()
        // Pages this pass emptied, which go as Launchpad's do; a returning app brings its back.
        var emptiedPages = Set<UUID>()
        // A copy, so `match` reads no part of `grid` while the loops below write to it.
        let removed = grid.removedBundleIDs

        /// The installed app `ref` stands for: the one at its path, else (when its own app
        /// is gone from there, not merely out of reach) an unclaimed, unexcluded one with its
        /// bundle ID.
        func match(for ref: AppRef) -> (app: InstalledApp, moved: Bool)? {
            let atPath = byPath[ref.path] ?? aliases[ref.path].flatMap { byPath[$0] }
            // An app whose bundle ID can't be read now (a damaged Info.plist) is still the one there.
            if let atPath, ref.bundleID == nil || atPath.bundleID == nil || atPath.bundleID == ref.bundleID {
                return (atPath, false)
            }
            // The same app with its name now in other capitals (zoom.us.app updated into
            // Zoom.us.app): the case-insensitive disk still finds the old spelling, so the ref
            // would neither follow it nor be pruned, and the new spelling would be added again.
            if atPath == nil, let respelt = byFoldedPath[ref.path.lowercased()],
               ref.bundleID == nil || respelt.bundleID == nil || respelt.bundleID == ref.bundleID {
                return (respelt, false)
            }
            if let id = ref.bundleID, atPath != nil || (isReachable(ref.path) && !pathExists(ref.path)),
               let other = likelyMove(of: ref, among: byBundle[id]?.filter {
                   !gridPaths.contains($0.path) && !seen.contains($0.path)
                       && !removed.contains($0.key) && !removed.contains($0.path)
               } ?? [], wasInstalledBefore: wasInstalledBefore) {
                return (other, true)
            }
            // Another app now lives at this path (e.g. an update changed the bundle ID): adopt
            // it, unless the user excluded that app.
            if let atPath, !removed.contains(atPath.key), !removed.contains(atPath.path) { return (atPath, false) }
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
            } else if prune && isReachable(ref.path) && (byPath[ref.path] != nil || !pathExists(ref.path)) {
                // Pruned once its app is gone from disk, or replaced by one it mustn't become (an
                // excluded app): one the scan missed while it is still there (an update rewriting
                // its Info.plist) keeps its tile.
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
        /// The IDs before slot `i` among `ids`, nearest last, counting items an earlier pass
        /// pruned from just before it (`index` gives such an entry's slot there and the ID of
        /// what stood there, if it was in this list). One pruned at slot k sat just before the
        /// item now at k.
        func neighbours(_ ids: [UUID], before i: Int, index: (PrunedApp) -> (slot: Int, id: UUID, before: [UUID]?)?) -> [UUID] {
            var goneIDs = Set(ids)
            let gone = earlier.compactMap { e in
                index(e).flatMap { $0.slot <= i && goneIDs.insert($0.id).inserted ? $0 : nil }
            }
            return Self.interleave(here: Array(ids[..<i]), gone: gone).suffix(neighbourMemory)
        }

        let pageIDs = grid.pages.map(\.id)
        /// The pages before page `p`, nearest last, counting pages an earlier pass emptied from
        /// just before it, as `neighbours` does for items.
        func pagesBefore(_ p: Int) -> [UUID] {
            var gonePages = Set(pageIDs)
            let gone = earlier.compactMap { e -> (slot: Int, id: UUID, before: [UUID]?)? in
                guard e.pageEmptied == true, let at = e.pageIndex, at <= p,
                      gonePages.insert(e.pageID).inserted else { return nil }
                return (at, e.pageID, e.pageBefore)
            }
            return Self.interleave(here: Array(pageIDs[..<p]), gone: gone).suffix(neighbourMemory)
        }
        // Slots this pass removed, as they were before it: on each page, in each folder, and of
        // the pages themselves. Remembered slots are kept in terms of what is left after the pass.
        var removedSlots: [UUID: [Int]] = [:], removedFolderSlots: [UUID: [Int]] = [:]
        var emptiedPageSlots: [Int] = []

        for p in grid.pages.indices {
            let pageID = grid.pages[p].id
            let items = grid.pages[p].items
            defer {
                if !items.isEmpty && grid.pages[p].items.isEmpty {
                    emptiedPages.insert(pageID)
                    emptiedPageSlots.append(p)
                    for k in pruned.indices where pruned[k].pageID == pageID {
                        pruned[k].pageEmptied = true
                        pruned[k].pageIndex = p
                        pruned[k].pageTitle = grid.pages[p].title
                        pruned[k].pageBefore = pagesBefore(p)
                    }
                }
            }
            let itemIDs = items.map(\.id)
            grid.pages[p].items = items.enumerated().compactMap { i, item -> GridItem? in
                func before() -> [UUID] {
                    // A folder an earlier pass emptied comes back with its ID, so it counts as one.
                    neighbours(itemIDs, before: i) { e in
                        guard e.pageID == pageID else { return nil }
                        if let folderID = e.folderID { return e.folderEmptied == true ? (e.index, folderID, e.before) : nil }
                        return (e.index, e.app.id, e.before)
                    }
                }
                let kept: GridItem?
                switch item {
                case .app(let a):
                    kept = refresh(a) { PrunedApp(app: a, prunedAt: now, pageID: pageID, index: i, before: before()) }
                        .map(GridItem.app)
                case .folder(var f):
                    let (apps, folderID, folderName) = (f.apps, f.id, f.name)
                    f.apps = apps.enumerated().compactMap { fi, a in
                        let app = refresh(a) {
                            PrunedApp(app: a, prunedAt: now, pageID: pageID, index: i,
                                      folderID: folderID, folderName: folderName, folderIndex: fi,
                                      before: before(),
                                      folderBefore: neighbours(apps.map(\.id), before: fi) { e in e.folderID == folderID ? e.folderIndex.map { ($0, e.app.id, e.folderBefore) } : nil })
                        }
                        if app == nil { removedFolderSlots[folderID, default: []].append(fi) }
                        return app
                    }
                    if f.apps.isEmpty {
                        for k in pruned.indices where pruned[k].folderID == f.id { pruned[k].folderEmptied = true }
                        emptiedFolders.insert(f.id)
                        kept = nil
                    } else {
                        kept = .folder(f)
                    }
                }
                if kept == nil { removedSlots[pageID, default: []].append(i) }
                return kept
            }
        }

        let emptied = grid.pages.enumerated().filter { emptiedPages.contains($0.element.id) }
        grid.pages.removeAll { emptiedPages.contains($0.id) }

        // A slot counted before this pass, as one among what is left: less the slots removed
        // ahead of it. One removed at the slot itself was the item it sat before; it now sits
        // before the next, at the same slot.
        func shifted(_ slot: Int, past removed: [Int]?) -> Int {
            slot - (removed?.count(where: { $0 < slot }) ?? 0)
        }
        func settled(_ entry: PrunedApp) -> PrunedApp {
            var entry = entry
            entry.index = shifted(entry.index, past: removedSlots[entry.pageID])
            if let id = entry.folderID, let fi = entry.folderIndex { entry.folderIndex = shifted(fi, past: removedFolderSlots[id]) }
            if entry.pageEmptied == true, let at = entry.pageIndex { entry.pageIndex = shifted(at, past: emptiedPageSlots) }
            return entry
        }
        pruned = pruned.map(settled)

        // Bring back recently pruned apps that reappeared, then remember the newly pruned.
        var memory: [PrunedApp] = []
        for var entry in grid.recentlyPruned where (0..<restoreWindow).contains(now.timeIntervalSince(entry.prunedAt)) {
            guard !grid.isExcluded(key: entry.app.key, path: entry.app.path) else { continue }
            // Its folder (or page) outlived it until this pass pruned the folder's last app.
            if let id = entry.folderID, emptiedFolders.contains(id) { entry.folderEmptied = true }
            if let (p, page) = emptied.first(where: { $0.element.id == entry.pageID }) {
                (entry.pageEmptied, entry.pageIndex, entry.pageTitle) = (true, p, page.title)
                entry.pageBefore = pagesBefore(p)
            }
            entry = settled(entry)
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
            grid.appendAtEnd(unique.map { .app($0.makeRef()) })
            report.added = unique.map(\.name)
        }

        grid.normalize()
        return report
    }

    /// `here` with `gone` among them: one gone at slot k sat just before the item now at k.
    /// Several gone at one slot go in the order their own remembered neighbours give, one
    /// listing another standing after it; otherwise oldest first, as they stood.
    static func interleave(here: [UUID], gone: [(slot: Int, id: UUID, before: [UUID]?)]) -> [UUID] {
        var out: [UUID] = []
        for k in 0...here.count {
            var run = gone.filter { $0.slot == k }
            while !run.isEmpty {
                let left = Set(run.map(\.id))
                let next = run.firstIndex { !($0.before ?? []).contains(where: left.contains) } ?? 0
                out.append(run.remove(at: next).id)
            }
            if k < here.count { out.append(here[k]) }
        }
        return out
    }

    /// Of the copies of a moved app (same bundle ID), the one it most likely moved to: the
    /// one with its file name, then the one with its name, then the first that is new (the
    /// app renamed), not one that was there beside it all along.
    static func likelyMove(of ref: AppRef, among candidates: [InstalledApp],
                           wasInstalledBefore: (String) -> Bool = { _ in false }) -> InstalledApp? {
        let file = (ref.path as NSString).lastPathComponent
        return candidates.first { ($0.path as NSString).lastPathComponent == file }
            ?? candidates.first { $0.name == ref.name }
            ?? candidates.first { !wasInstalledBefore($0.path) }
    }

    /// Installed apps that are not on the grid, for "Add Missing Apps…". A copy sharing its
    /// bundle ID with one on the grid (Xcode-beta beside Xcode) counts as missing. As in
    /// `reconcile`, a ref out of reach (its volume ejected) isn't taken to have moved, so it
    /// doesn't hide an installed copy until it comes back. A ref still present outside the
    /// scan folders doesn't claim another copy either; `pathExists` can use cached disk reads.
    public static func missingApps(in grid: Grid, installed: [InstalledApp],
                                   isReachable: (String) -> Bool = { _ in true },
                                   pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                                   wasInstalledBefore: (String) -> Bool = { _ in false }) -> [InstalledApp] {
        let paths = Set(grid.allApps.map(\.path))
        let installedPaths = Set(installed.map(\.path))
        // A ref pointing nowhere installed is its app, moved: it stands for one copy with its
        // key (the likeliest), which isn't missing. Other copies still are.
        let offGrid = installed.filter { !paths.contains($0.path) }
        let byKey = Dictionary(grouping: offGrid, by: \.key)
        var claimed = Set<String>()
        for ref in grid.allApps where !installedPaths.contains(ref.path) && isReachable(ref.path) && !pathExists(ref.path) {
            // As in reconcile, a stale tile cannot follow an excluded copy. That copy
            // stays in the picker so the user can explicitly include it again.
            let free = (byKey[ref.key] ?? []).filter { !claimed.contains($0.path) && !grid.isExcluded($0) }
            if let copy = likelyMove(of: ref, among: free, wasInstalledBefore: wasInstalledBefore) { claimed.insert(copy.path) }
        }
        return offGrid
            .filter { !claimed.contains($0.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Adds apps explicitly, clearing them from the removed list. `installed` tells which
    /// apps share a bundle ID, so including one copy keeps the others excluded. An app picked
    /// at its real path (`aliases`, from the scan) is added at the path the scan lists it at.
    public static func add(_ apps: [InstalledApp], to grid: inout Grid, installed: [InstalledApp] = [],
                           aliases: [String: String] = [:]) {
        let byPath = Dictionary(installed.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let apps = apps.map { app in aliases[app.path].flatMap { byPath[$0] } ?? app }
        // Folded, as the disk is: a tile at zoom.us.app is already Zoom.us.app.
        var paths = Set(grid.allApps.map { $0.path.lowercased() })
        // `insert` also drops an app listed twice in `apps`.
        let new = apps.filter { paths.insert($0.path.lowercased()).inserted }
        let copies = CopyIndex(installed + apps)
        for app in apps { grid.setExcluded(app, false, copies: copies) }
        grid.appendAtEnd(new.map { .app($0.makeRef()) })
    }

    /// Applies a choice of which apps belong on the grid. Excluded apps leave it (folders and
    /// pages they empty go too) and are remembered as removed; included ones are added back.
    /// - Parameter isStale: whether a path holds an app no longer there (gone from a reachable
    ///   place, not merely on an unmounted volume). A tile left at such a path is the excluded
    ///   app's old place, not another copy of it, so it leaves with it.
    public static func choose(include: [InstalledApp], exclude: [InstalledApp], in grid: inout Grid,
                              installed: [InstalledApp] = [], isStale: (String) -> Bool = { _ in false }) {
        let among = installed.filter { !isStale($0.path) } + include + exclude
            + grid.allApps.filter { !isStale($0.path) }.map(InstalledApp.init)
        let copies = CopyIndex(among)
        let paths = Set(exclude.map(\.path))
        // Match by key too (a ref whose path is stale), unless other copies share that key.
        let keys = Set(exclude.filter { !copies.hasCopies($0) }.map(\.key))
        let ids = grid.allApps.filter { paths.contains($0.path) || keys.contains($0.key) }.map(\.id)
        // Only taken off: the exclusions recorded below cover every tile matched, and `remove`
        // would count a stale tile as another copy again.
        grid.removingEmptiedPages { $0.detach(ids); $0.normalize() }
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
    /// Puts a pruned app back where it was, recreating its folder and page if pruning emptied them.
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
        } else if entry.pageEmptied == true {
            let page = Page(id: entry.pageID, title: entry.pageTitle, items: [item])
            // Its page was the only one, so `normalize` left a blank page in its place.
            if pages.count == 1, pages[0].items.isEmpty, pages[0].title == nil {
                pages = [page]
                return
            }
            let at = Self.slot(after: entry.pageBefore, fallback: entry.pageIndex ?? pages.count, in: pages.map(\.id))
            pages.insert(page, at: min(max(0, at), pages.count))
        } else {
            appendToFirstFree([item])
        }
    }

    /// Just after the nearest remembered neighbour still present. With none left, the start
    /// if every item before it was remembered, else the old index. `before` can also list
    /// apps pruned before it, so it can hold more than the items that stood before it.
    static func slot(after before: [UUID]?, fallback: Int, in ids: [UUID]) -> Int {
        guard let before else { return fallback }
        for id in before.reversed() {
            if let i = ids.firstIndex(of: id) { return i + 1 }
        }
        return before.count >= fallback ? 0 : fallback
    }
}
