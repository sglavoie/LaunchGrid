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
        didSet { scheduleSave() }
    }
    private(set) var installed: [InstalledApp] = []
    @ObservationIgnored private(set) var installedByPath: [String: InstalledApp] = [:]
    private(set) var hasGridFile: Bool
    /// Set when the saved layout could not be loaded at launch and was moved aside.
    private(set) var loadProblem: (message: String, backup: URL)?

    @ObservationIgnored private var undoStack: [Grid] = []
    @ObservationIgnored private var redoStack: [Grid] = []
    private(set) var canUndo = false
    private(set) var canRedo = false
    static let undoLimit = 50

    // MARK: UI state

    var currentPage = 0
    var openFolderID: UUID?
    var folderPage = 0
    var query = "" { didSet { if query != oldValue { focusIndex = query.isEmpty ? nil : 0 } } }
    var editing = false { didSet { if !editing { selection.removeAll() } } }
    var selection: Set<UUID> = []
    /// Keyboard focus: index on the current page, folder or search results.
    var focusIndex: Int?
    var textEdit: TextEditRequest?
    var toast: String?
    /// Horizontal offset of the pager while a trackpad swipe is in progress.
    var swipeOffset: CGFloat = 0
    var isShown = false
    /// Why the global shortcut could not be registered, shown in Settings.
    var hotkeyProblem: String?
    let drag = DragController()

    // MARK: Hooks wired by the app delegate

    @ObservationIgnored var onHide: () -> Void = {}
    /// Hides without handing focus back, so the app being launched can take it.
    @ObservationIgnored var onHideForLaunch: () -> Void = {}
    @ObservationIgnored var onError: (_ title: String, _ detail: String) -> Void = { _, _ in }
    @ObservationIgnored var onOpenSettings: () -> Void = {}
    @ObservationIgnored var onAddMissing: () -> Void = {}

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var rescanQueued = false

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
                try? FileManager.default.moveItem(at: store.url, to: backup)
                NSLog("LaunchGrid: could not load grid (\(error)); moved to \(backup.path)")
                let message = newer
                    ? "Your saved layout was made by a newer version of LaunchGrid. It was kept as \(backup.lastPathComponent)."
                    : "Your saved layout could not be read, so it was set aside as \(backup.lastPathComponent)."
                loadProblem = (message, backup)
            }
        }
        hasGridFile = loaded != nil
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
        if grid.allApps.isEmpty {
            // Nothing worth undoing back to (first run).
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

    func saveNow() {
        saveTask?.cancel()
        guard hasGridFile || !grid.allApps.isEmpty else { return }
        do {
            try store.save(grid)
            hasGridFile = true
        } catch {
            NSLog("LaunchGrid: save failed: \(error)")
        }
    }

    // MARK: Catalog

    /// Rescans the application folders off the main thread, then reconciles.
    func rescan(completion: (@MainActor () -> Void)? = nil) {
        if scanning {
            rescanQueued = true
            return
        }
        scanning = true
        let roots = prefs.scanRoots
        Task {
            let started = Date()
            let apps = await Task.detached(priority: .utility) { AppScanner.scan(roots: roots) }.value
            NSLog("LaunchGrid: scanned \(apps.count) apps in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            self.scanning = false
            self.catalogScanned(apps)
            completion?()
            if self.rescanQueued {
                self.rescanQueued = false
                self.rescan()
            }
        }
    }

    /// Takes in a finished scan.
    func catalogScanned(_ apps: [InstalledApp]) {
        installed = apps
        installedByPath = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        if hasGridFile { reconcile() }
    }

    /// Whether a scan could have seen an app at `path`. Absence says nothing about apps on
    /// an unmounted volume or under a scan folder that is currently missing.
    private func isReachable(_ path: String, missingRoots: [String]) -> Bool {
        if missingRoots.contains(where: { path.hasPrefix($0 + "/") }) { return false }
        let parts = (path as NSString).pathComponents
        if parts.count > 2, parts[0] == "/", parts[1] == "Volumes" {
            return FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
        }
        return true
    }

    /// Merges the catalog into the grid. Not an undo step: it mirrors the disk.
    func reconcile() {
        guard !installed.isEmpty else { return }
        // Apps added from outside the scanned folders stay as long as they exist on disk.
        let keys = Set(installed.map(\.key))
        let extra = grid.allApps
            .filter { !keys.contains($0.key) && installedByPath[$0.path] == nil && FileManager.default.fileExists(atPath: $0.path) }
            .compactMap { AppScanner.read(appAt: URL(fileURLWithPath: $0.path)) }
        var g = grid
        let missingRoots = prefs.scanRoots.map(\.path).filter { !FileManager.default.fileExists(atPath: $0) }
        let report = Reconciler.reconcile(&g, installed: installed + extra, autoAdd: prefs.autoAddApps,
                                          isReachable: { self.isReachable($0, missingRoots: missingRoots) })
        guard g != grid else { return }
        if !report.isEmpty {
            NSLog("LaunchGrid: reconcile added \(report.added), removed \(report.removed), moved \(report.moved)")
        }
        grid = g
        afterChange()
        if !report.added.isEmpty {
            IconProvider.shared.prewarm(g.allApps.map(\.path))
        }
    }

    var missingApps: [InstalledApp] { Reconciler.missingApps(in: grid, installed: installed) }

    func addApps(_ apps: [InstalledApp]) {
        apply { Reconciler.add(apps, to: &$0) }
        showToast(apps.count == 1 ? "Added \(apps[0].name)" : "Added \(apps.count) apps")
    }

    func installedApp(for ref: AppRef) -> InstalledApp? {
        installedByPath[ref.path]
    }

    func build(style: BuildStyle) {
        replaceGrid(GridBuilder.build(from: installed, style: style, rows: grid.rows, columns: grid.columns))
    }

    // MARK: Derived

    var searchResults: [AppRef] {
        Array(Search.results(in: grid.allApps, query: query).prefix(grid.capacity))
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
                if path != app.path { rememberPath(path, of: app.id) }
            } catch {
                if isShown {
                    showToast("Could not open \(app.title): \(error.localizedDescription)")
                } else {
                    onError("Could not open \(app.title)", error.localizedDescription)
                }
            }
        }
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

    func closeFolder() {
        withAnimationIfShown { openFolderID = nil }
        focusIndex = nil
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
        } else {
            goToPage(currentPage + delta)
        }
    }

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Shift-click: select the range on the current page from the last selected item.
    func extendSelection(to id: UUID) {
        let ids = (openFolder?.apps.map(\.id)) ?? currentItems.map(\.id)
        guard let end = ids.firstIndex(of: id) else { return }
        let anchor = ids.lastIndex { selection.contains($0) } ?? end
        for i in min(anchor, end)...max(anchor, end) { selection.insert(ids[i]) }
    }

    /// The items an action on `id` applies to: the selection if `id` is part of it.
    func targets(for id: UUID) -> [UUID] {
        selection.contains(id) ? orderedSelection : [id]
    }

    var orderedSelection: [UUID] {
        grid.pages.flatMap { $0.items.flatMap { [$0.id] + $0.apps.map(\.id) } }.filter { selection.contains($0) }
    }

    func remove(_ ids: [UUID]) {
        let count = ids.count
        apply { g in g.removingEmptiedPages { $0.remove(ids) } }
        selection.subtract(ids)
        showToast(count == 1 ? "Removed — ⌘Z to undo" : "Removed \(count) items — ⌘Z to undo")
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
        apply { $0.sortEverything(folders: prefs.folderPlacement) }
        goToPage(0)
    }

    func beginRename(_ id: UUID) {
        guard let item = grid.item(id) else { return }
        textEdit = TextEditRequest(target: .item(id), title: item.folder == nil ? "Rename App" : "Rename Folder", text: item.title)
    }

    func beginPageTitleEdit(_ page: Int) {
        guard grid.pages.indices.contains(page) else { return }
        textEdit = TextEditRequest(target: .pageTitle(page), title: "Page Title", text: grid.pages[page].title ?? "")
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

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Resets transient state when the overlay closes.
    func didHide() {
        query = ""
        openFolderID = nil
        editing = false
        focusIndex = nil
        textEdit = nil
        drag.cancel()
        swipeOffset = 0
    }

    private func withAnimationIfShown(_ body: () -> Void) {
        if isShown {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86), body)
        } else {
            body()
        }
    }
}
