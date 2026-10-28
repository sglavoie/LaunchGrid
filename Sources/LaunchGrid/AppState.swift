import AppKit
import Observation
import SwiftUI
import LaunchGridCore

/// Inline text editing requested by the UI (rename, page title).
/// What a scan saw of the disk besides the apps, read with it.
struct DiskState: Equatable, Sendable {
    /// Scan folders that didn't exist.
    var missingRoots: [String] = []
    /// Of the folders the scan couldn't list, those that exist.
    var unreadable: [String] = []
    /// Names of mounted volumes; nil until read.
    var mountedVolumes: Set<String>?

    nonisolated static func read(roots: [String], unlisted: [String]) -> DiskState {
        let fm = FileManager.default
        return DiskState(missingRoots: roots.filter { !fm.fileExists(atPath: $0) },
                         unreadable: unlisted.filter { fm.fileExists(atPath: $0) },
                         mountedVolumes: Volume.mountedNames())
    }
}

struct TextEditRequest: Identifiable {
    /// By ID, not index: a rescan can remove pages while the edit is open.
    enum Target { case item(UUID), pageTitle(UUID) }
    let id = UUID()
    var target: Target
    var title: String
    var text: String

    var isPageTitle: Bool {
        if case .pageTitle = target { true } else { false }
    }
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
    /// `gridGeneration` as of the last save (or load), so saving an unchanged grid doesn't
    /// replace the backup of the save before it with a copy of the same one.
    @ObservationIgnored private var savedGeneration = 0
    @ObservationIgnored private var searchCache: (query: String, generation: Int, results: [AppRef])?
    private(set) var installed: [InstalledApp] = []
    @ObservationIgnored private(set) var installedByPath: [String: InstalledApp] = [:]
    /// The scan's paths in lower case: the disk ignores case, so a tile at zoom.us.app whose
    /// app is now Zoom.us.app is the scan's app, not one outside the scan folders.
    @ObservationIgnored private var installedFoldedPaths: Set<String> = []
    /// Real paths of apps the scan found through a symlink, to the paths it lists them at.
    @ObservationIgnored private var pathAliases: [String: String] = [:]
    /// Paths of apps any scan this run found, and those found before the latest scan: a tile
    /// whose app is gone doesn't become a copy that was there beside it all along.
    @ObservationIgnored private var everInstalled: Set<String> = []
    @ObservationIgnored private var installedBefore: Set<String> = []
    /// Apps on the grid from outside the scan folders, read off the main thread with each
    /// scan. `outsideChecked` holds every path looked at, found or not, and `outsideExisting`
    /// those with something on disk (an app, or a bundle that couldn't be read).
    @ObservationIgnored private var outsideApps: [String: InstalledApp] = [:]
    @ObservationIgnored private var outsideChecked: Set<String> = []
    @ObservationIgnored private var outsideExisting: Set<String> = []
    /// Paths being read off the main thread for `reconcile()`, which runs again once they are.
    @ObservationIgnored private(set) var outsideReading: Set<String> = []
    /// A completed scan replaces the outside-app snapshot and supersedes reads already in flight.
    @ObservationIgnored private var outsideReadGeneration = 0
    /// The outside-app read itself; tests can hold a read while a newer scan arrives.
    @ObservationIgnored var outsideReader: @Sendable ([String]) -> OutsideRead = { AppState.readOutsideApps($0) }
    /// Folders the last scan couldn't list (denied, stalled, a lapsed bookmark): their apps
    /// went unseen, not away. Observed, so Settings can point them out.
    private(set) var unlistedFolders: [String] = []
    /// What the disk looked like at the last scan, read with it off the main thread: a stalled
    /// volume would otherwise hang reconciling, undo and Settings at each look. Observed, for
    /// Settings' folder warnings.
    private var disk = DiskState()
    /// LaunchGrid's own bundle ID: it never belongs on its own grid.
    @ObservationIgnored var ownBundleID = Bundle.main.bundleIdentifier
    private(set) var hasGridFile: Bool
    /// Whether a scan has found the installed apps yet: building before then would lay out
    /// none of them, or none with their category.
    private(set) var hasScanned = false
    /// An empty scan can remove missing apps only after at least one root was listed.
    @ObservationIgnored private var lastScanHadReadableRoot = false
    /// A build asked for before the first scan finished, made once it has.
    @ObservationIgnored private var buildAfterScan: BuildStyle?
    /// Set when the saved layout could not be loaded at launch and was moved aside.
    private(set) var loadProblem: (message: String, backup: URL)?
    /// Set when an unreadable layout was replaced by the previous save, or entries of it had to
    /// be left out, to tell the person once.
    @ObservationIgnored var recoveryNotice: (title: String, message: String, file: URL)?

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
            if query != oldValue {
                searchPage = 0
                focusIndex = query.isEmpty ? nil : 0
            }
            // However the search ended (a page jump, a reveal, hiding), the folder it started
            // in is no longer one to go back to.
            if query.isEmpty { folderBeforeSearch = nil }
        }
    }
    /// Caret in the search, in characters. Setting `query` puts it at the end.
    private(set) var queryCaret = 0
    /// Page of ranked search matches currently shown.
    var searchPage = 0
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
    /// The same for the open folder's page.
    var folderSwipeOffset: CGFloat = 0
    var isShown = false
    /// Counts the times the overlay was shown, for what refreshes on each show but not on
    /// hiding (the background picture).
    private(set) var showCount = 0
    /// The display the overlay is on, whose wallpaper the background shows.
    var screenID: CGDirectDisplayID = 0
    /// Why the global shortcut could not be registered, shown in Settings.
    var hotkeyProblem: String?
    /// The Settings window's tab, by its label.
    var settingsTab = "General"
    /// The Settings window's height when the debug script sets one; otherwise each tab's own.
    var settingsHeight: CGFloat?
    let drag = DragController()

    // MARK: Hooks wired by the app delegate

    @ObservationIgnored var onHide: () -> Void = {}
    /// Hides without handing focus back, so the app being launched (or Finder) can take it.
    @ObservationIgnored var onHideForLaunch: () -> Void = {}
    /// An app opened behind the grid, which stayed up: it comes forward when the grid hides.
    @ObservationIgnored var onLaunchedBehind: (NSRunningApplication) -> Void = { _ in }
    @ObservationIgnored var onError: (_ title: String, _ detail: String) -> Void = { _, _ in }
    /// A failed save, told with ways to keep the layout meanwhile; `onError` when not set.
    @ObservationIgnored var onSaveFailure: ((_ title: String, _ detail: String) -> Void)?
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
    /// Bumped by each scan started, so a scan's watchdog knows its own.
    @ObservationIgnored private var scanGeneration = 0
    /// Set when the scan under way took too long and what waited for it was let go.
    @ObservationIgnored private var scanOverdue = false
    /// How long a scan may take before what waits for it goes ahead without it; tests shorten it.
    @ObservationIgnored var scanTimeout: Duration = .seconds(60)
    /// The scan itself; tests swap in a fake.
    @ObservationIgnored var scanner: @Sendable ([URL]) -> AppScanner.ScanResult = { AppScanner.scanReporting(roots: $0) }
    /// Set when an unreadable layout couldn't be moved aside (or a partly readable one copied
    /// aside): saving would replace it.
    @ObservationIgnored private var savesBlocked = false
    /// Why saves are blocked, for when one is tried.
    @ObservationIgnored private var savesBlockedDetail: String?

    init(prefs: Preferences, store: GridStore) {
        self.prefs = prefs
        self.store = store
        var loaded: Grid?
        var skipped = 0
        if store.exists {
            do {
                (loaded, skipped) = try store.loadCountingSkipped()
            } catch {
                // Keep the file for inspection (or for the newer version) and start fresh.
                let newer = if case GridFileError.unsupportedVersion = error { true } else { false }
                // The file a symlink points at, set aside beside its backup: moving the link
                // would lose both, and the next save would write a file over the link.
                let file = store.fileURL
                let backup = Self.recoveryFileURL(for: file, kind: newer ? "newer" : "corrupt")
                do {
                    try FileManager.default.moveItem(at: file, to: backup)
                    NSLog("LaunchGrid: could not load grid (\(error)); moved to \(backup.path)")
                    if !newer, let previous = try? store.loadBackup() {
                        // An earlier save: at most about `backupInterval` behind.
                        NSLog("LaunchGrid: restored the previous save from \(store.backupURL.path)")
                        loaded = previous
                        recoveryNotice = (
                            String(localized: "Your layout was restored from the previous save"),
                            String(localized: "Your saved layout could not be read, so LaunchGrid restored an earlier save. Changes from the last few minutes may be missing; the unreadable file was kept as \(backup.lastPathComponent)."),
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
        // Older files have no setup marker. Apps or restoration records still identify
        // their existing layout, and the next edit saves the marker even if it empties it.
        let hasLayout = loaded.map { $0.hasCreatedLayout || !$0.allApps.isEmpty || !$0.recentlyPruned.isEmpty } ?? false
        hasGridFile = hasLayout
        if hasLayout { loaded?.hasCreatedLayout = true }
        grid = loaded ?? Grid()
        if skipped > 0 { keepPartlyReadFile(skipped: skipped) }
        // The unreadable file is gone: write the restored layout back before anything else
        // can go wrong, or the next launch would find no layout at all.
        if recoveryNotice != nil && !savesBlocked { scheduleSave() }
    }

    /// Keep each damaged file under a distinct name, even after a second launch in the
    /// same second or when someone already has a file with the old timestamp-only name.
    private static func recoveryFileURL(for file: URL, kind: String) -> URL {
        file.deletingPathExtension()
            .appendingPathExtension("\(kind)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json")
    }

    /// Some entries of the saved layout couldn't be read and were left out: a copy of the
    /// file as it was is kept aside, as saves and backups will soon replace it with the rest.
    private func keepPartlyReadFile(skipped: Int) {
        let file = store.fileURL
        let copy = Self.recoveryFileURL(for: file, kind: "partial")
        do {
            try FileManager.default.copyItem(at: file, to: copy)
            NSLog("LaunchGrid: \(skipped) entries of the grid could not be read; kept a copy at \(copy.path)")
            // The file still holds them, unchanged since loading: count it as unsaved, so the save
            // `init` schedules writes the rest back and the next launch doesn't ask again.
            savedGeneration = gridGeneration &- 1
            recoveryNotice = (
                String(localized: "Part of your layout could not be read"),
                String(localized: "\(skipped) entries in your saved layout could not be read and were left out. The file as it was is kept as \(copy.lastPathComponent)."),
                copy)
        } catch {
            // Without a copy, saving would lose the entries for good.
            NSLog("LaunchGrid: \(skipped) entries of the grid could not be read nor the file copied (\(error)); not saving over it")
            savesBlocked = true
            let message = String(localized: "\(skipped) entries in your saved layout could not be read, and the file couldn't be copied aside, so LaunchGrid won't save over it. Move \(store.url.lastPathComponent) elsewhere and your changes will be saved.")
            loadProblem = (message, store.url)
            savesBlockedDetail = message
            // The rest loaded, so the welcome window, which tells of `loadProblem`, won't open.
            recoveryNotice = (String(localized: "Part of your layout could not be read"), message, store.url)
        }
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
        let old = grid
        grid = g
        afterChange(from: old)
    }

    /// Replaces the whole grid (import, rebuild, load) as one undo step.
    func replaceGrid(_ new: Grid) {
        var new = new
        new.hasCreatedLayout = true
        if !hasGridFile {
            // Nothing worth undoing back to (first run), whatever was changed before it (the grid
            // size). Redo history would replay edits of the empty grid over the new one.
            undoStack.removeAll()
            redoStack.removeAll()
            let old = grid
            grid = new
            afterChange(from: old)
        } else {
            apply { $0 = new }
        }
        hasGridFile = true
        currentPage = 0
        openFolderID = nil
        folderPage = 0
        // Replacing a layout leaves the old page or folder. Its focused index may not
        // exist on the first page; search results keep their independently adjusted focus.
        if query.isEmpty { focusIndex = nil }
        reconcile()
        IconProvider.shared.prewarm(grid.allApps.map(\.path))
    }

    /// A loaded or imported layout with the user's current exclusions added to its own, minus
    /// the apps it has on it: apps excluded earlier stay out unless the layout includes them.
    nonisolated static func keepingExclusions(_ current: Set<String>, in new: Grid, installed: [InstalledApp] = []) -> Grid {
        var new = new
        new.removedBundleIDs.formUnion(current)
        let included = new.allApps.map { InstalledApp(bundleID: $0.bundleID, path: $0.path, name: $0.name) }
        // Including one copy turns a bundle-wide exclusion into exclusions for the other
        // known copies, just as Choose Apps does. Clearing the bundle ID alone revives them.
        new.setExcluded(include: included, exclude: [], among: installed + included)
        return new
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(grid)
        let old = grid
        grid = previous
        afterChange(from: old)
        showChange(from: old)
        // The snapshot predates later scans; bring it up to date with the disk.
        reconcile()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(grid)
        let old = grid
        grid = next
        afterChange(from: old)
        showChange(from: old)
        reconcile()
    }

    /// After an undo or redo, goes to a page it brought back (a deleted page, one a move
    /// emptied), else to the page it changed when the page shown is untouched, so the step is seen.
    private func showChange(from old: Grid) {
        guard query.isEmpty, grid.pages.indices.contains(currentPage) else { return }
        let before = Dictionary(old.pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let back = grid.pages.indices.filter { before[grid.pages[$0].id] == nil }
        let changed = grid.pages.indices.filter { before[grid.pages[$0].id] != grid.pages[$0] }
        let target = back.contains(currentPage) ? nil
            : back.first ?? (changed.contains(currentPage) ? nil : changed.first)
        guard let page = target else { return }
        if openFolderID != nil { openFolderID = nil }
        goToPage(page)
    }

    private func afterChange(from old: Grid) {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        // A slot can now hold a different app after a scan, removal or sort. Remember
        // the focused item's identity before adjusting pages and folder visibility.
        let focusedID: UUID? = focusIndex.flatMap { i in
            let ids: [UUID]
            if !query.isEmpty {
                ids = Search.results(in: old.allApps, query: query)
                    .dropFirst(searchPage * old.capacity).prefix(old.capacity).map(\.id)
            } else if let id = openFolderID, let folder = old.folder(id) {
                ids = folder.apps.map(\.id)
            } else {
                ids = old.pages.indices.contains(currentPage) ? old.pages[currentPage].items.map(\.id) : []
            }
            return ids.indices.contains(i) ? ids[i] : nil
        }
        // The page shown stays the same page when pages before it come or go (a rescan
        // emptying one), not whichever now has its number.
        if old.pages.indices.contains(currentPage) {
            let pageIndex = { (id: UUID) in self.grid.pages.firstIndex { $0.id == id } }
            if let p = pageIndex(old.pages[currentPage].id) {
                currentPage = p
            } else {
                // The page shown went (its last items removed): back to the one before it, as
                // deleting a page does, with focus on its last item rather than whichever item
                // now has the focused one's number.
                currentPage = old.pages[..<currentPage].reversed().lazy.compactMap { pageIndex($0.id) }.first ?? 0
                if focusIndex != nil, openFolderID == nil, query.isEmpty { focusIndex = Int.max }
            }
        }
        currentPage = min(currentPage, grid.pages.count - 1)
        if let id = openFolderID {
            if grid.folder(id) != nil, let location = grid.locate(id) {
                // An insertion or restoration can spill the open folder onto another page.
                // Keep its background and the focus returned on closing with its icon.
                currentPage = location.page
            } else {
                openFolderID = nil
            }
        }
        // A folder that lost its last page's apps shrinks; don't leave the view on a page it no longer has.
        if let f = openFolder {
            folderPage = max(0, min(folderPage, FolderLayout.pageCount(apps: f.apps.count, grid: grid) - 1))
        }
        if !query.isEmpty {
            searchPage = min(searchPage, searchPageCount - 1)
            if let focusedID, let index = allSearchResults.firstIndex(where: { $0.id == focusedID }) {
                searchPage = index / grid.capacity
                focusIndex = index % grid.capacity
            }
        }
        if let i = focusIndex {
            let ids = !query.isEmpty ? searchResults.map(\.id) : openFolder?.apps.map(\.id) ?? currentItems.map(\.id)
            // Keep the same item when it is still in this view. If it left, focus the
            // item taking its slot, or the last item when the view became shorter.
            focusIndex = ids.isEmpty ? nil : focusedID.flatMap { ids.firstIndex(of: $0) } ?? min(i, ids.count - 1)
            // Insertions and removals can move the focused app across a folder page
            // boundary too, even when the grid dimensions haven't changed.
            if query.isEmpty, openFolder != nil, let focusIndex {
                folderPage = focusIndex / FolderLayout.perPage(grid)
            }
        }
        selection = selection.filter { grid.locate($0) != nil }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveInBackground()
        }
    }

    /// Set once a failed save was reported, so a failing disk doesn't alert on every change.
    @ObservationIgnored private var saveFailureReported = false
    /// Why the last `saveNow` failed.
    @ObservationIgnored private(set) var lastSaveError: Error?
    /// What to tell the person about the last failed save, for `reportLastSaveFailure()`.
    @ObservationIgnored private var lastSaveFailureDetail: String?
    /// Writes the saves in order, off the main thread unless one has to be done now.
    @ObservationIgnored private(set) lazy var writer = LayoutWriter(store: store)
    /// Counts the writes handed to `writer`, so a write knows whether a later one is queued.
    @ObservationIgnored private var lastWriteSerial = 0

    /// Saves the grid now, unless it is unchanged since the last save; false when that failed.
    /// Waits for the disk, so it is for quitting; `saveInBackground` doesn't hold up the screen.
    @discardableResult
    func saveNow(reportingFailure: Bool = true) -> Bool {
        guard let generation = prepareSave(reportingFailure: reportingFailure) else { return lastSaveError == nil }
        let grid = grid
        lastWriteSerial &+= 1
        let serial = lastWriteSerial
        return finishSave(generation, serial: serial, grid: grid, error: writer.save(grid), reportingFailure: reportingFailure)
    }

    /// `saveNow` with the writing done off the main thread; `done` gets whether it worked.
    func saveInBackground(reportingFailure: Bool = true, done: (@MainActor (Bool) -> Void)? = nil) {
        guard let generation = prepareSave(reportingFailure: reportingFailure) else {
            done?(lastSaveError == nil)
            return
        }
        let grid = grid
        lastWriteSerial &+= 1
        let serial = lastWriteSerial
        writer.saveInBackground(grid) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                // Not inside `done?(…)`: with no `done`, that would skip recording the save.
                let saved = self.finishSave(generation, serial: serial, grid: grid, error: error, reportingFailure: reportingFailure)
                done?(saved)
            }
        }
    }

    /// The generation to save, or nil when there is nothing to write: the grid is unchanged
    /// since the last save, or saving is blocked (which sets `lastSaveError`).
    private func prepareSave(reportingFailure: Bool) -> Int? {
        lastSaveError = nil
        lastSaveFailureDetail = nil
        saveTask?.cancel()
        // Before the first layout, exclusions chosen in the welcome window are still worth keeping,
        // and so is emptying them: the file on disk would otherwise keep the last one.
        guard hasGridFile || !grid.allApps.isEmpty || !grid.removedBundleIDs.isEmpty || store.exists else { return nil }
        if savesBlocked {
            guard !store.exists else {
                NSLog("LaunchGrid: not saving over the layout that couldn't be read")
                let detail = savesBlockedDetail ?? String(localized: "LaunchGrid won't replace \(store.url.lastPathComponent), the saved layout it couldn't read. Move that file elsewhere and your changes will be saved.")
                // Not saved, so quitting asks first, as for any other failed save.
                lastSaveError = CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: detail])
                lastSaveFailureDetail = detail
                if reportingFailure { reportSaveFailure(detail) }
                return nil
            }
            savesBlocked = false // moved out of the way since
            savesBlockedDetail = nil
        }
        // A partially loaded grid can have the same generation as the file, even though
        // recovery blocked writing it. Report that block before claiming it is saved.
        if savedGeneration == gridGeneration && store.exists { return nil }
        return gridGeneration
    }

    /// Records how the save of `generation`, the writer's `serial`th write, went; true when it
    /// worked or no longer matters.
    private func finishSave(_ generation: Int, serial: Int, grid saved: Grid, error: Error?, reportingFailure: Bool) -> Bool {
        // A later save, made at once when quitting, already wrote a newer grid.
        if generation &- savedGeneration < 0 { return true }
        if let error {
            // A write of this grid or a newer one is queued after it (hiding while a save was
            // under way queues the same grid twice): that one tells how saving went. Or an
            // earlier write already saved this very grid, so the file is up to date.
            if serial != lastWriteSerial || (generation == savedGeneration && store.exists) {
                NSLog("LaunchGrid: a save failed but another covers it: \(error)")
                return true
            }
            NSLog("LaunchGrid: save failed: \(error)")
            lastSaveError = error
            let detail = String(localized: "Changes are kept while LaunchGrid runs, but may be lost when it quits.\n\n\(error.localizedDescription)")
            lastSaveFailureDetail = detail
            if reportingFailure { reportSaveFailure(detail) }
            return false
        }
        savedGeneration = generation
        if !saved.allApps.isEmpty { hasGridFile = true }
        saveFailureReported = false
        // Before the first layout nothing is on the grid yet, so nothing is unused either.
        if hasGridFile { onAppPathsInUse(appPathsInUse) }
        return true
    }

    /// Shows the layout file in Finder. Before the first layout (or after an unreadable one was
    /// set aside) there is no file to select: the folder itself opens.
    func showDataFolder() {
        if store.exists {
            NSWorkspace.shared.activateFileViewerSelecting([store.url])
        } else {
            let folder = store.url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    /// Tells the person about the last failed save, if it failed; for a save made with
    /// `reportingFailure: false` while the overlay was still on screen.
    func reportLastSaveFailure() {
        if let detail = lastSaveFailureDetail { reportSaveFailure(detail) }
    }

    /// Paths of the apps on the grid, in its undo and redo history, and recently pruned (which
    /// can still return to their slot).
    var appPathsInUse: Set<String> {
        let now = Date()
        var paths = Set<String>()
        for g in [grid] + undoStack + redoStack {
            paths.formUnion(g.allApps.map(\.path))
            let recent = g.recentlyPruned.filter { (0..<Reconciler.restoreWindow).contains(now.timeIntervalSince($0.prunedAt)) }
            paths.formUnion(recent.map(\.app.path))
        }
        return paths
    }

    private func reportSaveFailure(_ detail: String) {
        // An alert would open behind the full-screen overlay and block it.
        if isShown { showToast(String(localized: "Could not save your layout")); return }
        guard !saveFailureReported else { return }
        saveFailureReported = true
        (onSaveFailure ?? onError)(String(localized: "Could not save your layout"), detail)
    }

    // MARK: Catalog

    /// Rescans the application folders off the main thread, then reconciles. A request while
    /// a scan is under way queues one more, and `completion` runs after that one.
    func rescan(completion: (@MainActor () -> Void)? = nil) {
        if scanning {
            rescanQueued = true
            // Behind a scan already overdue, it would wait as long: go ahead with the apps known.
            if scanOverdue { completion?() } else if let completion { queuedCompletions.append(completion) }
            return
        }
        scanning = true
        scanGeneration &+= 1
        let generation = scanGeneration
        let roots = prefs.scanRoots
        let scanner = scanner
        // Apps from elsewhere are checked in the same pass, so reconciling needs no disk access.
        let candidates = outsideCandidates()
        // Bookmarks of apps added with Browse, resolved again here for those found gone.
        let inUse = FileAccess.bookmarksInUse
        Task {
            let started = Date()
            let (result, outside, disk, reopened) = await Disk.run(on: .global(qos: .utility)) {
                let result = scanner(roots)
                // Check alternate capitalization too: only the disk can tell a renamed
                // app from a missing, separate copy on a case-sensitive volume.
                let scanned = Set(result.apps.map(\.path))
                let outside = Self.readOutsideApps(candidates.filter { !scanned.contains($0) && result.aliases[$0] == nil })
                let gone = outside.checked.subtracting(outside.existing)
                let reopened = inUse.map { inUse in inUse.bookmarks.filter { gone.contains($0.key) }.compactMapValues(inUse.open) }
                return (result, outside, DiskState.read(roots: roots.map(\.path), unlisted: result.unlisted), reopened)
            }
            NSLog("LaunchGrid: scanned \(result.apps.count) apps in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            // Its waiters went ahead already when it was overdue.
            let served = self.scanOverdue
            self.scanOverdue = false
            if !result.unlisted.isEmpty {
                NSLog("LaunchGrid: could not list \(result.unlisted.joined(separator: ", ")); keeping their apps")
            }
            self.scanning = false
            self.catalogScanned(result.apps, outside: outside, unlisted: result.unlisted, aliases: result.aliases, disk: disk,
                                reopened: reopened, hasReadableRoot: result.hasReadableRoot)
            if !served { completion?() }
            if self.rescanQueued {
                self.rescanQueued = false
                let waiting = self.queuedCompletions
                self.queuedCompletions = []
                self.rescan { for done in waiting { done() } }
            }
        }
        // A read that doesn't return (a volume that stopped answering) would hold up what
        // waits for the scan: the welcome window, a file opened at launch. After a while they go
        // ahead with the apps known so far. The scan keeps its place, so no other piles up behind
        // the same stalled read; if it ends, it's taken in and the queued one follows.
        let timeout = scanTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.scanning, self.scanGeneration == generation, !self.scanOverdue else { return }
            NSLog("LaunchGrid: a scan has taken over \(timeout); going ahead without it")
            self.scanOverdue = true
            let waiting = [completion].compactMap { $0 } + self.queuedCompletions
            self.queuedCompletions = []
            for done in waiting { done() }
        }
    }

    /// Takes in a finished scan. `outside` holds what was read of the grid's apps outside the
    /// scan folders; any not covered are read in the background when reconciling. `unlisted` holds the folders
    /// the scan couldn't list, and `aliases` the real paths of apps it found through a symlink.
    /// `outside` and `disk` are what the scan saw of the disk, read now when not given, and
    /// `reopened` the bookmarks of apps found gone, resolved again with them.
    func catalogScanned(_ apps: [InstalledApp], outside: OutsideRead? = nil,
                        unlisted: [String] = [], aliases: [String: String] = [:], disk: DiskState? = nil,
                        reopened: [String: FileAccess.Opened]? = nil, hasReadableRoot: Bool = false) {
        outsideReadGeneration &+= 1
        let apps = apps.filter { !isSelf($0.bundleID) }
        installed = apps
        lastScanHadReadableRoot = hasReadableRoot
        installedByPath = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        installedFoldedPaths = Set(apps.map { $0.path.lowercased() })
        pathAliases = aliases
        // Until a deferred scan reaches the grid, its new paths still count as possible
        // moves. A second scan during the same drag must not turn them into older copies.
        if drag.active, installedBeforeDrag == nil { installedBeforeDrag = everInstalled }
        installedBefore = installedBeforeDrag ?? everInstalled
        everInstalled.formUnion(apps.map(\.path))
        let outside = outside ?? Self.readOutsideApps(outsideCandidates().filter { needsDiskCheck($0) })
        outsideApps = outside.apps
        outsideChecked = outside.checked
        outsideExisting = outside.existing
        // Apps added with Browse that moved since they were read: their bookmarks know where
        // to, so they are followed before reconciling would prune them as gone.
        followMovedApps(FileAccess.followVanished(outside.checked.subtracting(outside.existing), prefs: prefs, reopened: reopened))
        let disk = disk ?? DiskState.read(roots: prefs.scanRoots.map(\.path), unlisted: unlisted)
        if self.disk != disk { self.disk = disk }
        if unlistedFolders != unlisted { unlistedFolders = unlisted }
        if !hasScanned { hasScanned = true }
        if let style = buildAfterScan {
            buildAfterScan = nil
            if !hasGridFile { build(style: style) } else { reconcile() }
        } else if hasGridFile {
            reconcile()
        }
        refreshUpdatedIcons()
    }

    /// Paths of grid apps, recently pruned ones, and path-based exclusions. Exclusions
    /// need disk checks too before following a change in capitalization.
    private func outsideCandidates() -> [String] {
        let recent = grid.recentlyPruned.filter { Date().timeIntervalSince($0.prunedAt) < Reconciler.restoreWindow }
        var seen = Set<String>()
        let paths = (grid.allApps + recent.map(\.app)).filter { !isSelf($0.bundleID) }.map(\.path)
            + grid.removedBundleIDs.filter { $0.hasPrefix("/") }.sorted()
        return paths.filter { seen.insert($0).inserted }
    }

    /// What was read of apps outside the scan folders.
    struct OutsideRead: Sendable {
        /// The apps found, by path.
        var apps: [String: InstalledApp] = [:]
        /// Every path looked at.
        var checked: Set<String> = []
        /// The paths with something on disk, readable as an app or not.
        var existing: Set<String> = []
    }

    /// Reads the apps at `paths`; those missing or unreadable are left out of `apps`.
    nonisolated static func readOutsideApps(_ paths: [String]) -> OutsideRead {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        let apps = existing.compactMap { AppScanner.read(appAt: URL(fileURLWithPath: $0)) }
        return OutsideRead(apps: Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }),
                           checked: Set(paths), existing: Set(existing))
    }

    /// Whether something was on disk at `path` when it was last read: a scanned app, or one
    /// outside the scan folders. No disk access, so reconciling can't hang on a stalled volume.
    private var knownToExist: (String) -> Bool {
        let scanned = installedByPath, outside = outsideApps, existing = outsideExisting
        return { scanned[$0] != nil || outside[$0] != nil || existing.contains($0) }
    }

    /// Drops icons of apps updated in place since they were rendered, then reloads them.
    private func refreshUpdatedIcons() {
        let paths = grid.allApps.map(\.path)
        Task {
            let stale = await Disk.run(on: .global(qos: .utility)) { IconProvider.shared.dropStale(paths) }
            guard !stale.isEmpty else { return }
            // Re-render before bumping the generation, so views reload the new icons, not a miss.
            await IconProvider.shared.renderAll(stale)
            self.iconGeneration += 1
        }
    }

    /// "Regenerate Icons": re-renders every icon; `completion` runs once they are all back in the
    /// cache. Views reload them only then, so none shows a placeholder meanwhile.
    func regenerateIcons(completion: (@MainActor () -> Void)? = nil) {
        let paths = grid.allApps.map(\.path)
        Task {
            await IconProvider.shared.regenerate(paths)
            iconGeneration += 1
            completion?()
        }
    }

    /// Whether a scan could have seen an app at `path`. Absence says nothing about apps on
    /// an unmounted volume or under a scan folder that is currently missing or couldn't be listed.
    /// `mountedVolumes`, the names in /Volumes, comes from the last scan when given.
    nonisolated static func isReachable(_ path: String, unreachableFolders: [String], mountedVolumes: Set<String>? = nil) -> Bool {
        if unreachableFolders.contains(where: { path.hasPrefix($0 + "/") }) { return false }
        return Volume.unmountedVolume(for: path, mounted: mountedVolumes) == nil
    }

    /// Whether a scan could have seen an app at `path`, as of the last scan. Never looks at the
    /// disk: when the mounted volumes couldn't be told, apps on any of them keep their tiles.
    private var isReachable: (String) -> Bool {
        let unreachable = unreachableFolders, mounted = disk.mountedVolumes ?? []
        return { Self.isReachable($0, unreachableFolders: unreachable, mountedVolumes: mounted) }
    }

    /// Folders that are there but the last scan couldn't list (privacy controls, a stalled
    /// volume, a lapsed sandbox bookmark), for Settings; a missing scan folder isn't one.
    var unreadableFolders: [String] {
        let unreadable = Set(disk.unreadable)
        return unlistedFolders.filter(unreadable.contains)
    }

    /// Scan folders that were missing at the last scan, for Settings.
    var missingFolders: [String] { disk.missingRoots }

    /// Scan folders missing at the last scan, and folders it couldn't list.
    private var unreachableFolders: [String] {
        disk.missingRoots + unlistedFolders
    }

    /// Merges the catalog into the grid. Not an undo step: it mirrors the disk.
    func reconcile() {
        guard !installed.isEmpty || lastScanHadReadableRoot else { return }
        // A drag's gap and targets are slots among the items on screen: changing them under
        // it would drop in the wrong place, or lose the item dragged. Wait for the drop.
        if drag.active {
            reconcileAfterDrag = true
            return
        }
        // Apps added from outside the scanned folders stay as long as they exist on disk,
        // and recently pruned ones there can still return to their slot. The scan read them;
        // only ones that reached the grid since are read here.
        let candidates = outsideCandidates().filter { needsDiskCheck($0) }
        // Ones that reached the grid since (an undo, an app added with Browse) are read off the
        // main thread; until then they count as out of reach, so they keep their tiles.
        let unchecked = Set(candidates.filter { !outsideChecked.contains($0) })
        readOutsideAppsInBackground(unchecked.subtracting(outsideReading))
        // Alternate capitalization is checked for existence, but must not introduce a
        // second installed copy alongside the scan's spelling.
        let extra = candidates.filter { isOutside($0) }.compactMap { outsideApps[$0] }
        let reachable = isReachable
        var g = grid
        let report = Reconciler.reconcile(&g, installed: installed + extra, autoAdd: prefs.autoAddApps,
                                          pruneOnEmpty: lastScanHadReadableRoot,
                                          isReachable: { !unchecked.contains($0) && reachable($0) },
                                          pathExists: knownToExist, aliases: pathAliases,
                                          wasInstalledBefore: installedBefore.contains)
        guard g != grid else { return }
        if !report.isEmpty {
            NSLog("LaunchGrid: reconcile added \(report.added), removed \(report.removed), moved \(report.moved), restored \(report.restored)")
        }
        let old = grid
        // A scan can discover a move or rename without a sandbox bookmark. Carry its
        // confirmed paths into history too, including exclusions in a pending redo.
        let previousPaths = Dictionary((old.allApps + old.recentlyPruned.map(\.app)).map { ($0.id, $0.path) },
                                       uniquingKeysWith: { first, _ in first })
        let moves = Dictionary(g.allApps.compactMap { app -> (String, String)? in
            guard let previous = previousPaths[app.id], previous != app.path else { return nil }
            return (previous, app.path)
        }, uniquingKeysWith: { first, _ in first })
        followMovesInHistory(moves)
        grid = g
        afterChange(from: old)
        if !report.added.isEmpty || !report.restored.isEmpty {
            IconProvider.shared.prewarm(g.allApps.map(\.path))
        }
    }

    private func readOutsideAppsInBackground(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        outsideReading.formUnion(paths)
        let reader = outsideReader
        let generation = outsideReadGeneration
        Task {
            let read = await Disk.run { reader(Array(paths)) }
            outsideReading.subtract(paths)
            if generation == outsideReadGeneration {
                outsideApps.merge(read.apps) { _, new in new }
                outsideChecked.formUnion(read.checked)
                outsideExisting.formUnion(read.existing)
            }
            // A newer scan may not cover apps added since it started. Reconcile even when
            // discarding this read, so those paths are checked again instead of kept forever.
            if hasGridFile { reconcile() }
        }
    }

    /// Whether the scan leaves this exact path's existence unanswered.
    private func needsDiskCheck(_ path: String) -> Bool {
        installedByPath[path] == nil && pathAliases[path] == nil
    }

    /// Whether `path` could add a copy beyond the scan's paths and alternate spellings.
    private func isOutside(_ path: String) -> Bool {
        needsDiskCheck(path) && !installedFoldedPaths.contains(path.lowercased())
    }

    private func isSelf(_ bundleID: String?) -> Bool {
        bundleID != nil && bundleID == ownBundleID
    }

    var missingApps: [InstalledApp] {
        // As when reconciling, only a path known to be gone can stand for a moved copy.
        // Use the background reads; inspecting a stalled volume here would block the menu.
        let exists = knownToExist, checked = outsideChecked
        return Reconciler.missingApps(in: grid, installed: installed, isReachable: isReachable,
                                     pathExists: { !checked.contains($0) || exists($0) },
                                     wasInstalledBefore: installedBefore.contains)
    }

    /// Installed apps kept off the grid by an exclusion. Not the size of `removedBundleIDs`,
    /// which also remembers apps deleted since, and may hold a bundle ID and a path for one app.
    var excludedApps: [InstalledApp] {
        let onGrid = Set(grid.allApps.map(\.path))
        return installed.filter { grid.isExcluded($0) && !onGrid.contains($0.path) }
    }

    func addApps(_ apps: [InstalledApp]) {
        // Before the first layout, one app saved alone would count as the layout: only include
        // them in the build to come.
        guard hasGridFile else { return chooseApps(include: apps, exclude: []) }
        let installed = self.installed
        let aliases = pathAliases
        let before = grid.allApps.count
        apply { Reconciler.add(apps, to: &$0, installed: installed, aliases: aliases) }
        // Picked with Browse, an app can already be on the grid: say so rather than "Added".
        let added = grid.allApps.count - before
        if added == 0 {
            showToast(apps.count == 1 ? String(localized: "\(apps[0].name) is already on the grid") : String(localized: "These apps are already on the grid"))
        } else {
            showToast(added == 1 && apps.count == 1 ? String(localized: "Added \(apps[0].name)") : String(localized: "Added \(added) apps"))
        }
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

    /// Builds now, or once the first scan has found the installed apps.
    func buildWhenScanned(style: BuildStyle) {
        if hasScanned { build(style: style) } else { buildAfterScan = style }
    }

    // MARK: Choosing apps

    /// The grid's apps from outside the scan folders, as last read from disk (with their
    /// category), or as the grid knows them when not read yet.
    private var outsideGridApps: [InstalledApp] {
        grid.allApps.filter { isOutside($0.path) }
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
        // From what the last reads saw, without touching the disk: a path not read yet isn't stale.
        let isReachable = isReachable, exists = knownToExist, checked = outsideChecked
        let isStale: (String) -> Bool = { checked.contains($0) && isReachable($0) && !exists($0) }
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

    var searchPageCount: Int {
        max(1, (allSearchResults.count + grid.capacity - 1) / grid.capacity)
    }

    /// The matches shown on the current search page.
    var searchResults: [AppRef] {
        Array(allSearchResults.dropFirst(searchPage * grid.capacity).prefix(grid.capacity))
    }

    func goToSearchPage(_ page: Int) {
        let next = max(0, min(page, searchPageCount - 1))
        guard next != searchPage else { return }
        searchPage = next
        focusIndex = focusIndex.map { min($0, searchResults.count - 1) }
    }

    var openFolder: Folder? { openFolderID.flatMap { grid.folder($0) } }

    /// The folder (and its page) that was open when typing started a search; ending the
    /// search returns to it.
    @ObservationIgnored var folderBeforeSearch: (id: UUID, page: Int)?

    /// Clears the search (Esc, emptying it, a click on the background), reopening the folder
    /// it started in.
    func endSearch() {
        let folder = folderBeforeSearch
        query = ""
        guard let folder, let page = grid.locate(folder.id)?.page else { return }
        // A rescan meanwhile can have moved it to another page number.
        goToPage(page)
        openFolder(folder.id)
        let pages = FolderLayout.pageCount(apps: openFolder?.apps.count ?? 0, grid: grid)
        folderPage = min(folder.page, pages - 1)
    }

    var currentItems: [GridItem] {
        grid.pages.indices.contains(currentPage) ? grid.pages[currentPage].items : []
    }

    // MARK: Actions

    func launch(_ app: AppRef) {
        // Get out of the way at once, as Launchpad does; a slow app can take seconds. Staying
        // up, the grid opens it behind itself and keeps the keyboard, to open more.
        let hides = prefs.hideAfterLaunch
        if hides { onHideForLaunch() }
        Task {
            do {
                let (path, running) = try await Launcher.launch(app, activates: hides)
                if !hides { onLaunchedBehind(running) }
                // Off the main thread: a stalled volume mustn't hang the app.
                let gone = path == app.path ? false
                    : await Disk.run { !FileManager.default.fileExists(atPath: app.path) }
                if Self.followsLaunch(to: path, of: app, in: grid, isReachable: isReachable, pathExists: { _ in !gone }) {
                    rememberPath(path, of: app.id)
                }
            } catch {
                // Cancelled by the person, e.g. at Gatekeeper's prompt: they know.
                if Launcher.isUserCancel(error) { return }
                // Gone: one outside the scan folders (added with Browse) has no watcher to tell,
                // and would stay until the next periodic scan. Look again now.
                if error is Launcher.NotFound { rescan() }
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
        guard let old = grid.item(id)?.app?.path, old != path else { return }
        // Its bookmark, if added with Browse, follows it too (and may find other moves),
        // resolved off the main thread where the system's calls go.
        guard FileAccess.followsInBackground(old) else {
            return followMovedApps(FileAccess.follow(old, prefs: prefs).merging([old: path]) { found, _ in found })
        }
        Task {
            let found = await FileAccess.followInBackground(old, prefs: prefs)
            followMovedApps(found.merging([old: path]) { found, _ in found })
        }
    }

    /// Follows apps that moved, old path to new (as found by their sandbox bookmarks), in the
    /// undo and redo history too: undoing must not bring back a place the app has left. Not an
    /// undo step: it mirrors the disk.
    func followMovedApps(_ moves: [String: String]) {
        guard !moves.isEmpty else { return }
        // Not under a drag, which may be on the extra page past the last that a change would
        // take the view off: at the drop.
        if drag.active {
            movesAfterDrag.append(moves)
            return
        }
        followMovesInHistory(moves)
        var g = grid
        g.followMoves(moves)
        guard g != grid else { return }
        let old = grid
        grid = g
        afterChange(from: old)
    }

    private func followMovesInHistory(_ moves: [String: String]) {
        guard !moves.isEmpty else { return }
        for i in undoStack.indices { undoStack[i].followMoves(moves) }
        for i in redoStack.indices { redoStack[i].followMoves(moves) }
    }

    /// A search result clicked (or Return) in edit mode: rather than launching it, as edit mode
    /// never launches, shows it where it is to arrange it. The search clears, the view goes to
    /// its page (its folder open, if it's in one) and keyboard focus lands on it.
    func reveal(_ app: AppRef) {
        guard let loc = grid.locate(app.id) else { return }
        query = ""
        if let fi = loc.folderIndex {
            goToPage(loc.page)
            openFolder(grid.pages[loc.page].items[loc.index].id)
            folderPage = fi / FolderLayout.perPage(grid)
            focusIndex = fi
        } else {
            if openFolderID != nil { openFolderID = nil }
            goToPage(loc.page)
            focusIndex = loc.index
        }
    }

    /// A search result clicked or chosen with Return: launched, or in edit mode revealed.
    func activateResult(_ app: AppRef) {
        if editing { reveal(app) } else { launch(app) }
    }

    /// Click / Return on an item.
    func activate(_ item: GridItem) {
        switch item {
        case .app(let a): launch(a)
        case .folder(let f): openFolder(f.id)
        }
    }

    func openFolder(_ id: UUID) {
        // Animated by the folder layer (GridRootView), not `withAnimation`: see there.
        folderPage = 0
        focusIndex = nil
        openFolderID = id
    }

    /// - Parameter restoringFocus: put keyboard focus back on the folder's cell (Esc).
    func closeFolder(restoringFocus: Bool = false) {
        let cell = restoringFocus ? openFolderID.flatMap { id in currentItems.firstIndex { $0.id == id } } : nil
        // Apps selected inside it would stay selected out of sight, for ⌫ or Group to act on
        // unseen. Not while they're being dragged out of it.
        if !drag.active, let folder = openFolder { selection.subtract(folder.apps.map(\.id)) }
        openFolderID = nil // animated by the folder layer, as opening is
        focusIndex = cell
    }

    func goToPage(_ p: Int) {
        let clamped = max(0, min(p, grid.pages.count - 1))
        guard clamped != currentPage else { return }
        withAnimationIfShown { currentPage = clamped }
        clampFocus()
    }

    /// Keeps keyboard focus on an item shown: of the open folder, else of the page.
    func clampFocus() {
        let count = openFolder?.apps.count ?? currentItems.count
        focusIndex = focusIndex.map { min($0, max(0, count - 1)) }
    }

    func flipPage(_ delta: Int) {
        if !query.isEmpty {
            goToSearchPage(searchPage + delta)
        } else if let f = openFolder {
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

    /// The pager's offset for a swipe of `dx` on a pager `width` wide: at most 0.6 of a page,
    /// and past the first or last page only a little, giving way less the further it goes,
    /// as a scroll view's edge does.
    /// How far the pages (or the open folder's) follow a swipe of `dx`: with some resistance
    /// past either end.
    func swipeOffset(for dx: CGFloat, width: CGFloat) -> CGFloat {
        let width = max(width, 1)
        let (page, count) = openFolder.map { (folderPage, FolderLayout.pageCount(apps: $0.apps.count, grid: grid)) }
            ?? (currentPage, grid.pages.count)
        let pastEnd = (dx > 0 && page == 0) || (dx < 0 && page >= count - 1)
        guard pastEnd else { return max(-width * 0.6, min(width * 0.6, dx)) }
        let reach = width * 0.2
        let give = (1 - 1 / (abs(dx) * 0.55 / reach + 1)) * reach
        return dx < 0 ? -give : give
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
        let anchor = selectionAnchor.flatMap { selection.contains($0) ? ids.firstIndex(of: $0) : nil }
        // A new anchor starts a new range. The old page's range stays selected,
        // just like its individually selected items, when selecting across pages.
        if anchor == nil { shiftRange = [] }
        let start = anchor ?? ids.lastIndex { selection.contains($0) } ?? end
        // An anchor on another page (or removed since the last click) is no longer usable.
        // Remember the fallback too, so subsequent ranges can shrink towards it.
        selectionAnchor = ids[start]
        var kept = selection.subtracting(shiftRange)
        let range = Set(ids[min(start, end)...max(start, end)])
        let added = range.subtracting(kept)
        kept.formUnion(range)
        selection = kept
        shiftRange = added
    }

    /// The items an action on `id` applies to: the selection if `id` is part of it. Search
    /// results hide the selection, so there an action applies to `id` alone.
    func targets(for id: UUID) -> [UUID] {
        query.isEmpty && selection.contains(id) ? orderedSelection : [id]
    }

    /// Whether the selection is in view to act on; search results hide it.
    var selectionActionable: Bool { query.isEmpty && !selection.isEmpty }

    /// How many selected items aren't in view: on other pages (a selection can span them).
    var selectionOutOfView: Int {
        let perPage = FolderLayout.perPage(grid)
        let folderApps = openFolder?.apps.dropFirst(folderPage * perPage).prefix(perPage).map(\.id) ?? []
        let shown = Set(folderApps + currentItems.map(\.id))
        return selection.subtracting(shown).count
    }

    var orderedSelection: [UUID] {
        // A folder's own apps follow it, so ones selected inside an open folder count too.
        grid.pages.flatMap { $0.items.flatMap { [$0.id] + ($0.folder?.apps.map(\.id) ?? []) } }.filter { selection.contains($0) }
    }

    func remove(_ ids: [UUID]) {
        let count = ids.count
        // Named when it's one, so it's clear which went (VoiceOver reads it out too).
        let name = count == 1 ? grid.item(ids[0])?.title : nil
        // A folder takes all its apps with it: say how many, as they leave the grid too.
        let folders = ids.compactMap { grid.item($0)?.folder }
        // Apps also selected inside a selected folder are among its apps already.
        let inFolders = Set(folders.flatMap { $0.apps.map(\.id) })
        let loose = ids.filter { grid.item($0)?.folder == nil && !inFolders.contains($0) }.count
        let apps = folders.reduce(loose) { $0 + $1.apps.count }
        let installed = self.installed
        apply { g in g.removingEmptiedPages { $0.remove(ids, installed: installed) } }
        selection.subtract(ids)
        if !folders.isEmpty {
            showToast(String(localized: "Removed \(apps) apps — ⌘Z to undo"))
        } else {
            showToast(count > 1 ? String(localized: "Removed \(count) items — ⌘Z to undo")
                      : name.map { String(localized: "Removed \($0) — ⌘Z to undo") } ?? String(localized: "Removed — ⌘Z to undo"))
        }
    }

    /// Moves to the page at `page`, or a new one past the last.
    func moveToPage(_ ids: [UUID], page: Int) {
        moveToPage(ids, pageID: grid.pages.indices.contains(page) ? grid.pages[page].id : nil)
    }

    /// Moves to the page with `pageID`, or a new one when it's nil. By ID, as a menu holding
    /// it can outlive pages a rescan removes; when that page is gone, nothing moves.
    func moveToPage(_ ids: [UUID], pageID: UUID?) {
        // Nothing left to move (a rescan removed it under an open menu): no blank page either.
        guard ids.contains(where: { grid.locate($0) != nil }) else { return }
        apply { g in
            let page: Int
            if let pageID {
                guard let p = g.pages.firstIndex(where: { $0.id == pageID }) else { return }
                page = p
            } else {
                page = g.addPage()
            }
            let count = g.pages[page].items.filter { !ids.contains($0.id) }.count
            g.removingEmptiedPages { $0.move(ids, toPage: page, at: count) }
        }
        selection.removeAll()
    }

    /// Groups the selection into a folder where `anchor` is; without one, where the focused
    /// item is, if selected, else the first selected item on the page shown, so the folder
    /// opens where the person is looking.
    func groupSelection(anchor: UUID? = nil) {
        let ids = orderedSelection
        guard selectionActionable, ids.count > 1 else { return }
        let name = GridBuilder.folderName(for: ids.compactMap { grid.item($0)?.app }.map { installedApp(for: $0) })
        let shown = openFolder.map { $0.apps.map(\.id) } ?? currentItems.map(\.id)
        let focused = focusIndex.flatMap { shown.indices.contains($0) ? shown[$0] : nil }
        let onPage = currentItems.flatMap { [$0.id] + ($0.folder?.apps.map(\.id) ?? []) }
        let anchor = anchor ?? focused.flatMap { selection.contains($0) ? $0 : nil } ?? onPage.first(where: selection.contains)
        var newID: UUID?
        // Grouping can take the last item off another page; that page goes, as with a drag.
        apply { g in g.removingEmptiedPages { newID = $0.group(ids, name: name, anchor: anchor) } }
        selection.removeAll()
        guard let newID else { return }
        // Nothing selected on this page: show the folder's page, so it opens over its own.
        if let page = grid.locate(newID)?.page, page != currentPage { goToPage(page) }
        openFolder(newID)
    }

    /// Clears the search and closes the folder, so the page an action changes is the one in
    /// view: the ⋯ menu stays reachable over search results and an open folder.
    private func bringPageForward() {
        query = ""
        if openFolder != nil { closeFolder() }
    }

    func newPage() {
        bringPageForward()
        var index = 0
        apply { index = $0.addPage(after: currentPage) }
        goToPage(index)
    }

    func deleteCurrentPage() {
        bringPageForward()
        let p = currentPage
        apply { $0.deletePage(p) }
        goToPage(p - 1)
    }

    func sortCurrentPage() {
        bringPageForward()
        let p = currentPage
        apply { $0.sortPage(p, folders: prefs.folderPlacement) }
    }

    func sortEverything() {
        bringPageForward()
        let hadTitles = grid.pages.contains { $0.title != nil }
        apply { $0.sortEverything(folders: prefs.folderPlacement) }
        goToPage(0)
        // Re-flowing makes page titles meaningless, so they go; say so. Every app may have moved:
        // say how to get them back either way.
        showToast(hadTitles ? String(localized: "Sorted; page titles were cleared — ⌘Z to undo")
                  : String(localized: "Sorted everything — ⌘Z to undo"))
    }

    /// What Sort Everything does, for the questions asked before it where the grid is out of view.
    var sortEverythingDetail: String {
        switch prefs.folderPlacement {
        case .first: String(localized: "Apps and folders are sorted by name, folders first, and fill each page before the next. Folders keep their apps; page titles are cleared. ⌘Z in the grid undoes it.")
        case .last: String(localized: "Apps and folders are sorted by name, folders last, and fill each page before the next. Folders keep their apps; page titles are cleared. ⌘Z in the grid undoes it.")
        case .mixed: String(localized: "Apps and folders are sorted by name together and fill each page before the next. Folders keep their apps; page titles are cleared. ⌘Z in the grid undoes it.")
        }
    }

    func beginRename(_ id: UUID) {
        guard let item = grid.item(id) else { return }
        textEdit = TextEditRequest(target: .item(id), title: item.folder == nil ? String(localized: "Rename App") : String(localized: "Rename Folder"), text: item.title)
    }

    func beginPageTitleEdit(_ page: Int) {
        guard grid.pages.indices.contains(page) else { return }
        bringPageForward()
        textEdit = TextEditRequest(target: .pageTitle(grid.pages[page].id), title: String(localized: "Page Title"), text: grid.pages[page].title ?? "")
    }

    func commitTextEdit(_ text: String) {
        guard let edit = textEdit else { return }
        textEdit = nil
        switch edit.target {
        case .item(let id): apply { $0.rename(id, to: text) }
        case .pageTitle(let id):
            // The page may have gone meanwhile (its last app uninstalled): no other takes the title.
            guard let p = grid.pages.firstIndex(where: { $0.id == id }) else { return }
            apply { $0.setPageTitle(p, text) }
        }
    }

    func resize(rows: Int, columns: Int) {
        // Before the first layout only the size is kept, for the build: nothing to undo.
        guard hasGridFile else {
            var g = grid
            g.resize(rows: rows, columns: columns)
            grid = g
            return
        }
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
        showCount &+= 1
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
        cancelDrag(reopeningFolder: false)
        swipeOffset = 0
        folderSwipeOffset = 0
    }

    /// Cancels a drag in progress. An edge flip may have moved the view onto the extra
    /// empty page, which goes away with the drag, so the view returns to a real page. A drag
    /// that left an open folder (which closed) puts the folder back, as it was, with
    /// `reopeningFolder`: Esc undoes the whole gesture.
    func cancelDrag(reopeningFolder: Bool = true) {
        let (wasActive, source) = (drag.active, drag.source)
        drag.cancel()
        currentPage = min(currentPage, grid.pages.count - 1)
        clampFocus()
        if reopeningFolder, wasActive, case .folder(let id) = source, openFolderID == nil,
           let loc = grid.locate(id), loc.folderIndex == nil {
            currentPage = loc.page
            openFolderID = id
        }
        dragFinished()
    }

    /// Set when a scan finished mid-drag; `dragFinished()` applies it.
    @ObservationIgnored private var reconcileAfterDrag = false
    /// Paths known before the first scan deferred by this drag. Other refreshes can also
    /// set `reconcileAfterDrag`, so that flag alone doesn't identify a deferred scan.
    @ObservationIgnored private var installedBeforeDrag: Set<String>?
    /// Batches of moves found mid-drag, in order: A → B followed by B → C must reach C.
    /// History waits too, so swaps aren't applied to it both now and at the drop.
    @ObservationIgnored private var movesAfterDrag: [[String: String]] = []

    /// After a drop or a cancelled drag: applies a scan, or moved apps, that came in meanwhile.
    func dragFinished() {
        installedBeforeDrag = nil
        if !movesAfterDrag.isEmpty {
            let moves = movesAfterDrag
            movesAfterDrag = []
            for batch in moves { followMovedApps(batch) }
        }
        guard reconcileAfterDrag else { return }
        reconcileAfterDrag = false
        reconcile()
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

/// Writes the layout on one serial queue, so saves land in the order they were made: one
/// made at once (when quitting) waits for those under way instead of racing them.
final class LayoutWriter: @unchecked Sendable {
    /// The backup is refreshed at the first save of a run and then at most this often, so a
    /// change to regret (an import, a sort) doesn't reach it with the very next edit.
    static let backupInterval: TimeInterval = 10 * 60

    let store: GridStore
    /// Not private, so tests can line work up between two saves.
    let queue = DispatchQueue(label: "com.sglavoie.launchgrid.save", qos: .utility)
    /// When a save last refreshed the backup; only read and written on `queue`.
    private var lastBackup: Date?
    /// The clock for `backupInterval`, for tests.
    private let now: @Sendable () -> Date

    init(store: GridStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Saves now, after any save still under way; the error, if it failed.
    func save(_ grid: Grid) -> Error? {
        queue.sync { write(grid) }
    }

    func saveInBackground(_ grid: Grid, done: @escaping @Sendable (Error?) -> Void) {
        queue.async { done(self.write(grid)) }
    }

    #if !APP_STORE
    /// Seconds each save waits before writing, so the debug scripts can see one under way.
    private let debugDelay = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_SAVE_DELAY"].flatMap(Double.init)
    #endif

    private func write(_ grid: Grid) -> Error? {
        #if !APP_STORE
        if let debugDelay { Thread.sleep(forTimeInterval: debugDelay) }
        #endif
        let refreshBackup = lastBackup.map { now().timeIntervalSince($0) >= Self.backupInterval } ?? true
        do {
            if try store.save(grid, refreshingBackup: refreshBackup, now: now()) { lastBackup = now() }
            return nil
        } catch {
            return error
        }
    }
}
