import AppKit
import Observation
import SwiftUI
import LaunchGridCore

/// Inline text editing requested by the UI (rename, page title).
struct TextEditRequest: Identifiable {
    enum Target { case item(UUID), pageTitle(Int) }
    let id = UUID()
    var target: Target
    var title: String
    var text: String
}

@MainActor @Observable
final class AppState {
    let prefs: Preferences
    @ObservationIgnored let store: GridStore

    // MARK: Model

    private(set) var grid: Grid {
        didSet { gridGeneration &+= 1; scheduleSave() }
    }
    /// Bumped on every grid change; keys the search cache without comparing grids.
    @ObservationIgnored private var gridGeneration = 0
    @ObservationIgnored private var searchCache: (query: String, generation: Int, results: [AppRef])?
    private(set) var installed: [InstalledApp] = []
    @ObservationIgnored private(set) var installedByPath: [String: InstalledApp] = [:]
    /// Apps on the grid from outside the scan folders, read off the main thread with each
    /// scan. `outsideChecked` holds every path looked at, found or not.
    @ObservationIgnored private var outsideApps: [String: InstalledApp] = [:]
    @ObservationIgnored private var outsideChecked: Set<String> = []
    /// Folders the last scan couldn't list (denied, stalled, a lapsed bookmark): their apps
    /// went unseen, not away.
    @ObservationIgnored private var unlistedFolders: [String] = []
    /// LaunchGrid's own bundle ID: it never belongs on its own grid.
    @ObservationIgnored var ownBundleID = Bundle.main.bundleIdentifier
    private(set) var hasGridFile: Bool
    /// Set when the saved layout could not be loaded at launch and was moved aside.
    private(set) var loadProblem: (message: String, backup: URL)?
    /// Set when an unreadable layout was replaced by the previous save, to tell the person once.
    @ObservationIgnored var recoveryNotice: (message: String, file: URL)?

    @ObservationIgnored private var undoStack: [Grid] = []
    @ObservationIgnored private var redoStack: [Grid] = []
    private(set) var canUndo = false
    private(set) var canRedo = false
    static let undoLimit = 50

    // MARK: UI state

    var currentPage = 0
    var openFolderID: UUID?
    var folderPage = 0
    var query = "" {
        didSet {
            queryCaret = query.count
            if query != oldValue { focusIndex = query.isEmpty ? nil : 0 }
        }
    }
    /// Caret in the search, in characters. Setting `query` puts it at the end.
    private(set) var queryCaret = 0
    /// The search with its caret, for keyboard editing.
    var searchLine: TextLine {
        get { TextLine(text: query, caret: queryCaret) }
        set { query = newValue.text; queryCaret = newValue.caret }
    }
    var editing = false { didSet { if !editing { selection.removeAll() } } }
    var selection: Set<UUID> = [] {
        didSet { if selection.isEmpty { selectionAnchor = nil; shiftRange = [] } }
    }
    /// Where ⇧-click ranges start: the item last clicked without ⇧.
    @ObservationIgnored private var selectionAnchor: UUID?
    /// What the last ⇧-click added; the next one replaces it, as in Finder.
    @ObservationIgnored private var shiftRange: Set<UUID> = []
    /// Keyboard focus: index on the current page, folder or search results.
    var focusIndex: Int?
    var textEdit: TextEditRequest?
    var toast: String?
    /// Bumped when cached icons were dropped, so icon views load them again.
    var iconGeneration = 0
    /// Horizontal offset of the pager while a trackpad swipe is in progress.
    var swipeOffset: CGFloat = 0
    var isShown = false
    /// Why the global shortcut could not be registered, shown in Settings.
    var hotkeyProblem: String?
    /// The Settings window's tab, by its label.
    var settingsTab = "General"
    /// The Settings window's height; the debug script makes it taller to capture a whole tab.
    var settingsHeight: CGFloat = 600
    let drag = DragController()

    // MARK: Hooks wired by the app delegate

    @ObservationIgnored var onHide: () -> Void = {}
    /// Hides without handing focus back, so the app being launched can take it.
    @ObservationIgnored var onHideForLaunch: () -> Void = {}
    @ObservationIgnored var onError: (_ title: String, _ detail: String) -> Void = { _, _ in }
    @ObservationIgnored var onOpenSettings: () -> Void = {}
    @ObservationIgnored var onAddMissing: () -> Void = {}
    /// After each save, with the paths of every app the grid, its undo history or its
    /// recently pruned apps still refer to; access kept to any other app can go.
    @ObservationIgnored var onAppPathsInUse: (Set<String>) -> Void = { _ in }

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var toastPostedAt = Date.distantPast
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var rescanQueued = false
    /// Completions waiting for the queued scan: the one under way may predate what they need.
    @ObservationIgnored private var queuedCompletions: [@MainActor () -> Void] = []
    /// The scan itself; tests swap in a fake.
    @ObservationIgnored var scanner: @Sendable ([URL]) -> AppScanner.ScanResult = { AppScanner.scanReporting(roots: $0) }
    /// Set when an unreadable layout couldn't be moved aside: saving would replace it.
    @ObservationIgnored private var savesBlocked = false

    init(prefs: Preferences, store: GridStore) {
        self.prefs = prefs
        self.store = store
        var loaded: Grid?
        if store.exists {
            do {
                loaded = try store.load()
            } catch {
                // Keep the file for inspection (or for the newer version) and start fresh.
                let newer = if case GridFileError.unsupportedVersion = error { true } else { false }
                let backup = store.url.deletingPathExtension()
                    .appendingPathExtension("\(newer ? "newer" : "corrupt")-\(Int(Date().timeIntervalSince1970)).json")
                do {
                    try FileManager.default.moveItem(at: store.url, to: backup)
                    NSLog("LaunchGrid: could not load grid (\(error)); moved to \(backup.path)")
                    if !newer, let previous = try? store.loadBackup() {
                        // The save before last: at most a few changes behind.
                        NSLog("LaunchGrid: restored the previous save from \(store.backupURL.path)")
                        loaded = previous
                        recoveryNotice = (
                            String(localized: "Your saved layout could not be read, so LaunchGrid restored the save before it. The last few changes may be missing; the unreadable file was kept as \(backup.lastPathComponent)."),
                            backup)
                    } else {
                        let message = newer
                            ? String(localized: "Your saved layout was made by a newer version of LaunchGrid. It was kept as \(backup.lastPathComponent).")
                            : String(localized: "Your saved layout could not be read, so it was set aside as \(backup.lastPathComponent).")
                        loadProblem = (message, backup)
                    }
                } catch let moveError {
                    // It stays where it is, the only copy: don't save over it until it's gone.
                    NSLog("LaunchGrid: could not load grid (\(error)) nor move it aside (\(moveError)); not saving over it")
                    savesBlocked = true
                    let name = store.url.lastPathComponent
                    let message = newer
                        ? String(localized: "Your saved layout was made by a newer version of LaunchGrid and couldn't be set aside, so LaunchGrid won't save over it. Move \(name) elsewhere and your changes will be saved.")
                        : String(localized: "Your saved layout could not be read and couldn't be set aside, so LaunchGrid won't save over it. Move \(name) elsewhere and your changes will be saved.")
                    loadProblem = (message, store.url)
                }
            }
        }
        // A file with no apps holds only exclusions chosen in the welcome window: the layout
        // is still to be made.
        hasGridFile = loaded.map { !$0.allApps.isEmpty } ?? false
        grid = loaded ?? Grid()
    }

    // MARK: Mutations

    /// Applies a user-visible change as one undo step.
    func apply(_ change: (inout Grid) -> Void) {
        var g = grid
        change(&g)
        guard g != grid else { return }
        undoStack.append(grid)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        grid = g
        afterChange()
    }

    /// Replaces the whole grid (import, rebuild, load) as one undo step.
    func replaceGrid(_ new: Grid) {
        if grid.allApps.isEmpty && undoStack.isEmpty {
            // Nothing worth undoing back to (first run). Redo history would replay edits of
            // the empty grid over the new one.
            redoStack.removeAll()
            grid = new
            afterChange()
        } else {
            apply { $0 = new }
        }
        hasGridFile = true
        currentPage = 0
        openFolderID = nil
        reconcile()
        IconProvider.shared.prewarm(grid.allApps.map(\.path))
    }

    /// A loaded or imported layout with the user's current exclusions added to its own, minus
    /// the apps it has on it: apps excluded earlier stay out unless the layout includes them.
    nonisolated static func keepingExclusions(_ current: Set<String>, in new: Grid) -> Grid {
        var new = new
        new.removedBundleIDs = current.union(new.removedBundleIDs)
            .subtracting(new.appKeys.union(new.allApps.map(\.path)))
        return new
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(grid)
        grid = previous
        afterChange()
        // The snapshot predates later scans; bring it up to date with the disk.
        reconcile()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(grid)
        grid = next
        afterChange()
        reconcile()
    }

    private func afterChange() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        currentPage = min(currentPage, grid.pages.count - 1)
        if let id = openFolderID, grid.folder(id) == nil { openFolderID = nil }
        // A folder that lost its last page's apps shrinks; don't leave the view on a page it no longer has.
        if let f = openFolder {
            folderPage = max(0, min(folderPage, FolderLayout.pageCount(apps: f.apps.count, grid: grid) - 1))
        }
        if let i = focusIndex {
            let count = !query.isEmpty ? searchResults.count : openFolder?.apps.count ?? currentItems.count
            focusIndex = count > 0 ? min(i, count - 1) : nil
        }
        selection = selection.filter { grid.locate($0) != nil }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Set once a failed save was reported, so a failing disk doesn't alert on every change.
    @ObservationIgnored private var saveFailureReported = false
    /// Why the last `saveNow` failed.
    @ObservationIgnored private(set) var lastSaveError: Error?

    /// Saves the grid now; false when that failed.
    @discardableResult
    func saveNow(reportingFailure: Bool = true) -> Bool {
        lastSaveError = nil
        saveTask?.cancel()
        // Before the first layout, exclusions chosen in the welcome window are still worth keeping,
        // and so is emptying them: the file on disk would otherwise keep the last one.
        guard hasGridFile || !grid.allApps.isEmpty || !grid.removedBundleIDs.isEmpty || store.exists else { return true }
        if savesBlocked {
            guard !store.exists else {
                NSLog("LaunchGrid: not saving over the layout that couldn't be read")
                if reportingFailure {
                    reportSaveFailure(String(localized: "LaunchGrid won't replace \(store.url.lastPathComponent), the saved layout it couldn't read. Move that file elsewhere and your changes will be saved."))
                }
                return true // on purpose, and already said
            }
            savesBlocked = false // moved out of the way since
        }
        do {
            try store.save(grid)
            if !grid.allApps.isEmpty { hasGridFile = true }
            saveFailureReported = false
            // Before the first layout nothing is on the grid yet, so nothing is unused either.
            if hasGridFile { onAppPathsInUse(appPathsInUse) }
            return true
        } catch {
            NSLog("LaunchGrid: save failed: \(error)")
            lastSaveError = error
            if reportingFailure {
                reportSaveFailure(String(localized: "Changes are kept while LaunchGrid runs, but may be lost when it quits.\n\n\(error.localizedDescription)"))
            }
            return false
        }
    }

    /// Paths of the apps on the grid, in its undo and redo history, and recently pruned (which
    /// can still return to their slot).
    var appPathsInUse: Set<String> {
        let recent = grid.recentlyPruned.filter { Date().timeIntervalSince($0.prunedAt) < Reconciler.restoreWindow }
        var paths = Set(recent.map(\.app.path))
        for g in [grid] + undoStack + redoStack { paths.formUnion(g.allApps.map(\.path)) }
        return paths
    }

    private func reportSaveFailure(_ detail: String) {
        // An alert would open behind the full-screen overlay and block it.
        if isShown { showToast(String(localized: "Could not save your layout")); return }
        guard !saveFailureReported else { return }
        saveFailureReported = true
        onError(String(localized: "Could not save your layout"), detail)
    }

    // MARK: Catalog

    /// Rescans the application folders off the main thread, then reconciles. A request while
    /// a scan is under way queues one more, and `completion` runs after that one.
    func rescan(completion: (@MainActor () -> Void)? = nil) {
        if scanning {
            rescanQueued = true
            if let completion { queuedCompletions.append(completion) }
            return
        }
        scanning = true
        let roots = prefs.scanRoots
        let scanner = scanner
        // Apps from elsewhere are checked in the same pass, so reconciling needs no disk access.
        let candidates = outsideCandidates()
        Task {
            let started = Date()
            let (result, outside) = await Task.detached(priority: .utility) {
                let result = scanner(roots)
                let scanned = Set(result.apps.map(\.path))
                return (result, Self.readOutsideApps(candidates.filter { !scanned.contains($0) }))
            }.value
            NSLog("LaunchGrid: scanned \(result.apps.count) apps in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            if !result.unlisted.isEmpty {
                NSLog("LaunchGrid: could not list \(result.unlisted.joined(separator: ", ")); keeping their apps")
            }
            self.scanning = false
            self.catalogScanned(result.apps, outside: outside, unlisted: result.unlisted)
            completion?()
            if self.rescanQueued {
                self.rescanQueued = false
                let waiting = self.queuedCompletions
                self.queuedCompletions = []
                self.rescan { for done in waiting { done() } }
            }
        }
    }

    /// Takes in a finished scan. `outside` holds what was read of the grid's apps outside the
    /// scan folders; any not covered are read when reconciling. `unlisted` holds the folders
    /// the scan couldn't list.
    func catalogScanned(_ apps: [InstalledApp], outside: (apps: [String: InstalledApp], checked: Set<String>) = ([:], []),
                        unlisted: [String] = []) {
        let apps = apps.filter { !isSelf($0.bundleID) }
        installed = apps
        installedByPath = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        outsideApps = outside.apps
        outsideChecked = outside.checked
        unlistedFolders = unlisted
        if hasGridFile { reconcile() }
        refreshUpdatedIcons()
    }

    /// Paths of grid apps, and of recently pruned ones (which can still return to their slot),
    /// that could be from outside the scan folders.
    private func outsideCandidates() -> [String] {
        let recent = grid.recentlyPruned.filter { Date().timeIntervalSince($0.prunedAt) < Reconciler.restoreWindow }
        var seen = Set<String>()
        return (grid.allApps + recent.map(\.app))
            .filter { !isSelf($0.bundleID) && seen.insert($0.path).inserted }
            .map(\.path)
    }

    /// Reads the apps at `paths`; those missing or unreadable are left out of `apps`.
    nonisolated static func readOutsideApps(_ paths: [String]) -> (apps: [String: InstalledApp], checked: Set<String>) {
        let apps = paths.filter { FileManager.default.fileExists(atPath: $0) }
            .compactMap { AppScanner.read(appAt: URL(fileURLWithPath: $0)) }
        return (Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }), Set(paths))
    }

    /// Drops icons of apps updated in place since they were rendered, then reloads them.
    private func refreshUpdatedIcons() {
        let paths = grid.allApps.map(\.path)
        Task {
            let stale = await Task.detached(priority: .utility) { IconProvider.shared.dropStale(paths) }.value
            guard !stale.isEmpty else { return }
            // Re-render before bumping the generation, so views reload the new icons, not a miss.
            await IconProvider.shared.renderAll(stale)
            self.iconGeneration += 1
        }
    }

    /// "Regenerate Icons": re-renders every icon; `completion` runs once they are all back in the cache.
    func regenerateIcons(completion: (@MainActor () -> Void)? = nil) {
        IconProvider.shared.clear()
        iconGeneration += 1
        let paths = grid.allApps.map(\.path)
        Task {
            await IconProvider.shared.renderAll(paths)
            completion?()
        }
    }

    /// Whether a scan could have seen an app at `path`. Absence says nothing about apps on
    /// an unmounted volume or under a scan folder that is currently missing or couldn't be listed.
    nonisolated static func isReachable(_ path: String, unreachableFolders: [String]) -> Bool {
        if unreachableFolders.contains(where: { path.hasPrefix($0 + "/") }) { return false }
        return Volume.unmountedVolume(for: path) == nil
    }

    /// Scan folders that are missing now, and folders the last scan couldn't list.
    private var unreachableFolders: [String] {
        prefs.scanRoots.map(\.path).filter { !FileManager.default.fileExists(atPath: $0) } + unlistedFolders
    }

    /// Merges the catalog into the grid. Not an undo step: it mirrors the disk.
    func reconcile() {
        guard !installed.isEmpty else { return }
        // Apps added from outside the scanned folders stay as long as they exist on disk,
        // and recently pruned ones there can still return to their slot. The scan read them;
        // only ones that reached the grid since are read here.
        let candidates = outsideCandidates().filter { installedByPath[$0] == nil }
        let unchecked = candidates.filter { !outsideChecked.contains($0) }
        if !unchecked.isEmpty {
            let read = Self.readOutsideApps(unchecked)
            outsideApps.merge(read.apps) { _, new in new }
            outsideChecked.formUnion(read.checked)
        }
        let extra = candidates.compactMap { outsideApps[$0] }
        var g = grid
        let unreachable = unreachableFolders
        let report = Reconciler.reconcile(&g, installed: installed + extra, autoAdd: prefs.autoAddApps,
                                          isReachable: { Self.isReachable($0, unreachableFolders: unreachable) })
        guard g != grid else { return }
        if !report.isEmpty {
            NSLog("LaunchGrid: reconcile added \(report.added), removed \(report.removed), moved \(report.moved), restored \(report.restored)")
        }
        grid = g
        afterChange()
        if !report.added.isEmpty || !report.restored.isEmpty {
            IconProvider.shared.prewarm(g.allApps.map(\.path))
        }
    }

    private func isSelf(_ bundleID: String?) -> Bool {
        bundleID != nil && bundleID == ownBundleID
    }

    var missingApps: [InstalledApp] { Reconciler.missingApps(in: grid, installed: installed) }

    /// Installed apps kept off the grid by an exclusion. Not the size of `removedBundleIDs`,
    /// which also remembers apps deleted since, and may hold a bundle ID and a path for one app.
    var excludedApps: [InstalledApp] {
        let onGrid = Set(grid.allApps.map(\.path))
        return installed.filter { grid.isExcluded($0) && !onGrid.contains($0.path) }
    }

    func addApps(_ apps: [InstalledApp]) {
        let installed = self.installed
        apply { Reconciler.add(apps, to: &$0, installed: installed) }
        showToast(apps.count == 1 ? String(localized: "Added \(apps[0].name)") : String(localized: "Added \(apps.count) apps"))
    }

    func installedApp(for ref: AppRef) -> InstalledApp? {
        installedByPath[ref.path]
    }

    /// Lays out every installed app the user hasn't excluded, and those on the grid from
    /// outside the scan folders (added with Browse), keeping the exclusions.
    func build(style: BuildStyle) {
        var seen = Set<String>()
        let apps = (installed + outsideGridApps).filter { !grid.isExcluded($0) && seen.insert($0.path).inserted }
        var new = GridBuilder.build(from: apps, style: style,
                                    rows: grid.rows, columns: grid.columns)
        new.removedBundleIDs = grid.removedBundleIDs
        replaceGrid(new)
    }

    // MARK: Choosing apps

    /// The grid's apps from outside the scan folders, as last read from disk (with their
    /// category), or as the grid knows them when not read yet.
    private var outsideGridApps: [InstalledApp] {
        grid.allApps.filter { installedByPath[$0.path] == nil }
            .map { outsideApps[$0.path] ?? InstalledApp(bundleID: $0.bundleID, path: $0.path, name: $0.name) }
    }

    /// Apps the user can include or exclude: the installed ones plus any added from elsewhere.
    /// One entry per copy, so Xcode and Xcode-beta are chosen separately.
    var selectableApps: [InstalledApp] {
        var seen = Set<String>()
        return (installed + outsideGridApps)
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Paths of the included apps. Before the first layout that's every app not excluded,
    /// since the build lays them all out; after it, the apps on the grid.
    var includedPaths: Set<String> {
        hasGridFile ? Set(grid.allApps.map(\.path)) : Set(selectableApps.filter { !grid.isExcluded($0) }.map(\.path))
    }

    /// Applies changes from the app chooser. Before the first layout it only records them,
    /// for the build or import that follows.
    func chooseApps(include: [InstalledApp], exclude: [InstalledApp]) {
        guard !include.isEmpty || !exclude.isEmpty else { return }
        let among = selectableApps
        guard hasGridFile else {
            var g = grid
            g.setExcluded(include: include, exclude: exclude, among: among)
            grid = g
            return
        }
        // A tile whose app is gone from a reachable place is the old place of an installed copy.
        let scanned = installedByPath, unreachable = unreachableFolders
        let isStale: (String) -> Bool = {
            scanned[$0] == nil && Self.isReachable($0, unreachableFolders: unreachable) && !FileManager.default.fileExists(atPath: $0)
        }
        apply { Reconciler.choose(include: include, exclude: exclude, in: &$0, installed: among, isStale: isStale) }
        IconProvider.shared.prewarm(include.map(\.path))
        let toast = switch (include.isEmpty, exclude.isEmpty) {
        case (false, true): String(localized: "\(include.count) included — ⌘Z to undo")
        case (true, false): String(localized: "\(exclude.count) excluded — ⌘Z to undo")
        default: String(localized: "\(include.count) included, \(exclude.count) excluded — ⌘Z to undo")
        }
        showToast(toast)
    }

    // MARK: Derived

    /// Every match, best first. Cached per query and grid: several views and the key
    /// handler read it on each keystroke.
    var allSearchResults: [AppRef] {
        // Read both through observation so views still track them on a cache hit.
        let q = query, g = grid
        if let c = searchCache, c.query == q, c.generation == gridGeneration { return c.results }
        let results = Search.results(in: g.allApps, query: q)
        searchCache = (q, gridGeneration, results)
        return results
    }

    /// The matches shown: one page of them.
    var searchResults: [AppRef] {
        Array(allSearchResults.prefix(grid.capacity))
    }

    var openFolder: Folder? { openFolderID.flatMap { grid.folder($0) } }

    var currentItems: [GridItem] {
        grid.pages.indices.contains(currentPage) ? grid.pages[currentPage].items : []
    }

    // MARK: Actions

    func launch(_ app: AppRef) {
        // Get out of the way at once, as Launchpad does; a slow app can take seconds.
        if prefs.hideAfterLaunch { onHideForLaunch() }
        Task {
            do {
                let path = try await Launcher.launch(app)
                let unreachable = unreachableFolders
                if Self.followsLaunch(to: path, of: app, in: grid,
                                      isReachable: { Self.isReachable($0, unreachableFolders: unreachable) }) {
                    rememberPath(path, of: app.id)
                }
            } catch {
                // Cancelled by the person, e.g. at Gatekeeper's prompt: they know.
                if Launcher.isUserCancel(error) { return }
                if isShown {
                    showToast(String(localized: "Could not open \(app.title): \(error.localizedDescription)"))
                } else {
                    onError(String(localized: "Could not open \(app.title)"), error.localizedDescription)
                }
            }
        }
    }

    /// Whether launching `app` through its bundle ID, which opened the copy at `launched`,
    /// means the app moved there. Not when another tile already stands for that copy
    /// (Xcode-beta's tile opened Xcode), when its own path is only out of reach (an unmounted
    /// volume), or when its app is still there and merely failed to open.
    nonisolated static func followsLaunch(
        to launched: String, of app: AppRef, in grid: Grid,
        isReachable: (String) -> Bool,
        pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        launched != app.path && isReachable(app.path) && !pathExists(app.path)
            && !grid.allApps.contains { $0.id != app.id && $0.path == launched }
    }

    /// Records where a moved app now lives. Not an undo step: like `reconcile()`, it mirrors the disk.
    func rememberPath(_ path: String, of id: UUID) {
        guard let loc = grid.locate(id) else { return }
        var g = grid
        if case .folder(var f) = g.pages[loc.page].items[loc.index], let fi = loc.folderIndex {
            f.apps[fi].path = path
            g.pages[loc.page].items[loc.index] = .folder(f)
        } else if case .app(var a) = g.pages[loc.page].items[loc.index] {
            a.path = path
            g.pages[loc.page].items[loc.index] = .app(a)
        }
        grid = g
        afterChange()
    }

    /// Follows apps that moved, old path to new, as found by their sandbox bookmarks. Not an
    /// undo step: it mirrors the disk.
    func followMovedApps(_ moves: [String: String]) {
        guard !moves.isEmpty else { return }
        for app in grid.allApps {
            if let path = moves[app.path] { rememberPath(path, of: app.id) }
        }
    }

    /// Click / Return on an item.
    func activate(_ item: GridItem) {
        switch item {
        case .app(let a): launch(a)
        case .folder(let f): openFolder(f.id)
        }
    }

    func openFolder(_ id: UUID) {
        folderPage = 0
        focusIndex = nil
        withAnimationIfShown { openFolderID = id }
    }

    /// - Parameter restoringFocus: put keyboard focus back on the folder's cell (Esc).
    func closeFolder(restoringFocus: Bool = false) {
        let cell = restoringFocus ? openFolderID.flatMap { id in currentItems.firstIndex { $0.id == id } } : nil
        withAnimationIfShown { openFolderID = nil }
        focusIndex = cell
    }

    func goToPage(_ p: Int) {
        let clamped = max(0, min(p, grid.pages.count - 1))
        guard clamped != currentPage else { return }
        withAnimationIfShown { currentPage = clamped }
        focusIndex = focusIndex.map { min($0, max(0, currentItems.count - 1)) }
    }

    func flipPage(_ delta: Int) {
        if let f = openFolder {
            let pages = FolderLayout.pageCount(apps: f.apps.count, grid: grid)
            let p = max(0, min(folderPage + delta, pages - 1))
            withAnimationIfShown { folderPage = p }
            // Keep keyboard focus on the page being shown, in the same slot where there is one.
            let perPage = FolderLayout.perPage(grid)
            if let i = focusIndex, i / perPage != p {
                focusIndex = min(p * perPage + i % perPage, f.apps.count - 1)
            }
        } else {
            goToPage(currentPage + delta)
        }
    }

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        selectionAnchor = id
        shiftRange = []
    }

    /// Shift-click: select the range on the current page from the anchor (the item last
    /// clicked), replacing the range the previous shift-click added.
    func extendSelection(to id: UUID) {
        let ids = (openFolder?.apps.map(\.id)) ?? currentItems.map(\.id)
        guard let end = ids.firstIndex(of: id) else { return }
        let start = selectionAnchor.flatMap { selection.contains($0) ? ids.firstIndex(of: $0) : nil }
            ?? ids.lastIndex { selection.contains($0) } ?? end
        if selectionAnchor == nil { selectionAnchor = ids[start] }
        var kept = selection.subtracting(shiftRange)
        let range = Set(ids[min(start, end)...max(start, end)])
        let added = range.subtracting(kept)
        kept.formUnion(range)
        selection = kept
        shiftRange = added
    }

    /// The items an action on `id` applies to: the selection if `id` is part of it.
    func targets(for id: UUID) -> [UUID] {
        selection.contains(id) ? orderedSelection : [id]
    }

    var orderedSelection: [UUID] {
        // A folder's own apps follow it, so ones selected inside an open folder count too.
        grid.pages.flatMap { $0.items.flatMap { [$0.id] + ($0.folder?.apps.map(\.id) ?? []) } }.filter { selection.contains($0) }
    }

    func remove(_ ids: [UUID]) {
        let count = ids.count
        let installed = self.installed
        apply { g in g.removingEmptiedPages { $0.remove(ids, installed: installed) } }
        selection.subtract(ids)
        showToast(count == 1 ? String(localized: "Removed — ⌘Z to undo") : String(localized: "Removed \(count) items — ⌘Z to undo"))
    }

    func moveToPage(_ ids: [UUID], page: Int) {
        apply { g in
            if page >= g.pages.count { g.addPage() }
            let count = g.pages[page].items.filter { !ids.contains($0.id) }.count
            g.removingEmptiedPages { $0.move(ids, toPage: page, at: count) }
        }
        selection.removeAll()
    }

    func groupSelection(anchor: UUID? = nil) {
        let ids = orderedSelection
        guard ids.count > 1 else { return }
        let name = GridBuilder.folderName(for: ids.compactMap { grid.item($0)?.app }.map { installedApp(for: $0) })
        var newID: UUID?
        apply { newID = $0.group(ids, name: name, anchor: anchor) }
        selection.removeAll()
        if let newID { openFolder(newID) }
    }

    func newPage() {
        var index = 0
        apply { index = $0.addPage(after: currentPage) }
        goToPage(index)
    }

    func deleteCurrentPage() {
        let p = currentPage
        apply { $0.deletePage(p) }
        goToPage(p - 1)
    }

    func sortCurrentPage() {
        let p = currentPage
        apply { $0.sortPage(p, folders: prefs.folderPlacement) }
    }

    func sortEverything() {
        let hadTitles = grid.pages.contains { $0.title != nil }
        apply { $0.sortEverything(folders: prefs.folderPlacement) }
        goToPage(0)
        // Re-flowing makes page titles meaningless, so they go; say so.
        if hadTitles { showToast(String(localized: "Sorted; page titles were cleared — ⌘Z to undo")) }
    }

    func beginRename(_ id: UUID) {
        guard let item = grid.item(id) else { return }
        textEdit = TextEditRequest(target: .item(id), title: item.folder == nil ? String(localized: "Rename App") : String(localized: "Rename Folder"), text: item.title)
    }

    func beginPageTitleEdit(_ page: Int) {
        guard grid.pages.indices.contains(page) else { return }
        textEdit = TextEditRequest(target: .pageTitle(page), title: String(localized: "Page Title"), text: grid.pages[page].title ?? "")
    }

    func commitTextEdit(_ text: String) {
        guard let edit = textEdit else { return }
        textEdit = nil
        switch edit.target {
        case .item(let id): apply { $0.rename(id, to: text) }
        case .pageTitle(let p): apply { $0.setPageTitle(p, text) }
        }
    }

    func resize(rows: Int, columns: Int) {
        apply { $0.resize(rows: rows, columns: columns) }
    }

    /// While the overlay is hidden (an action from Settings, the menu bar or Finder), the
    /// message waits for the next time it's shown, unless that's a minute or more later.
    func showToast(_ text: String) {
        toast = text
        toastPostedAt = Date()
        toastTask?.cancel()
        toastTask = nil
        if isShown { scheduleToastDismissal() }
    }

    /// How long a seen toast stays up; tests shorten it.
    @ObservationIgnored var toastDuration: Duration = .seconds(2.5)

    private func scheduleToastDismissal() {
        let duration = toastDuration
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.toastTask = nil
        }
    }

    /// Called when the overlay appears.
    func didShow() {
        isShown = true
        guard toast != nil, toastTask == nil else { return }
        if Date().timeIntervalSince(toastPostedAt) > 60 {
            toast = nil
        } else {
            scheduleToastDismissal()
        }
    }

    /// Resets transient state when the overlay closes.
    func didHide() {
        query = ""
        openFolderID = nil
        editing = false
        focusIndex = nil
        textEdit = nil
        cancelDrag()
        swipeOffset = 0
    }

    /// Cancels a drag in progress. An edge flip may have moved the view onto the extra
    /// empty page, which goes away with the drag, so the view returns to a real page.
    func cancelDrag() {
        drag.cancel()
        currentPage = min(currentPage, grid.pages.count - 1)
    }

    /// Page and folder transitions; none with Reduce Motion, so nothing slides.
    static var pageAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)
    }

    private func withAnimationIfShown(_ body: () -> Void) {
        if isShown {
            withAnimation(Self.pageAnimation, body)
        } else {
            body()
        }
    }
}
