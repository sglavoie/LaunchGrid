import Foundation

public struct ItemLocation: Equatable, Sendable {
    public var page: Int
    public var index: Int
    /// Set when the item is an app inside the folder at `(page, index)`.
    public var folderIndex: Int?

    public init(page: Int, index: Int, folderIndex: Int? = nil) {
        self.page = page
        self.index = index
        self.folderIndex = folderIndex
    }
}

public enum FolderPlacement: String, Codable, CaseIterable, Sendable {
    case first, last, mixed
}

extension Grid {
    // MARK: Lookup

    public func locate(_ id: UUID) -> ItemLocation? {
        for (p, page) in pages.enumerated() {
            for (i, item) in page.items.enumerated() {
                if item.id == id { return ItemLocation(page: p, index: i) }
                if case .folder(let f) = item, let fi = f.apps.firstIndex(where: { $0.id == id }) {
                    return ItemLocation(page: p, index: i, folderIndex: fi)
                }
            }
        }
        return nil
    }

    /// The item with `id`; an app inside a folder is returned as `.app`.
    public func item(_ id: UUID) -> GridItem? {
        guard let loc = locate(id) else { return nil }
        let top = pages[loc.page].items[loc.index]
        if let fi = loc.folderIndex, case .folder(let f) = top { return .app(f.apps[fi]) }
        return top
    }

    public func folder(_ id: UUID) -> Folder? {
        item(id)?.folder
    }

    /// All apps, in visual order, including those inside folders.
    public var allApps: [AppRef] {
        pages.flatMap { $0.items.flatMap(\.apps) }
    }

    public var appKeys: Set<String> {
        Set(allApps.map(\.key))
    }

    // MARK: Structural invariants

    /// Drops empty folders, spills overflowing pages and guarantees at least one page.
    public mutating func normalize() {
        for p in pages.indices {
            pages[p].items.removeAll { if case .folder(let f) = $0 { return f.apps.isEmpty } else { return false } }
        }
        if pages.isEmpty { pages = [Page()] }
        spill(from: 0)
    }

    /// Pushes items beyond page capacity onto the following page, creating pages as needed.
    public mutating func spill(from start: Int) {
        var p = max(0, start)
        while p < pages.count {
            if pages[p].items.count > capacity {
                let overflow = Array(pages[p].items[capacity...])
                pages[p].items.removeSubrange(capacity...)
                if p + 1 == pages.count { pages.append(Page()) }
                pages[p + 1].items.insert(contentsOf: overflow, at: 0)
            }
            p += 1
        }
    }

    /// Runs `body`, then deletes pages it emptied. Pages that were already empty
    /// (e.g. just created by the user) are kept.
    public mutating func removingEmptiedPages(_ body: (inout Grid) -> Void) {
        let filled = Set(pages.filter { !$0.items.isEmpty }.map(\.id))
        body(&self)
        pages.removeAll { filled.contains($0.id) && $0.items.isEmpty }
        if pages.isEmpty { pages = [Page()] }
    }

    public mutating func removeEmptyPages() {
        pages.removeAll { $0.items.isEmpty }
        if pages.isEmpty { pages = [Page()] }
    }

    // MARK: Moving

    /// Removes the given items (top-level or inside folders) and returns them in visual order.
    /// Folders lose emptied entries but are not deleted here; call `normalize()` afterwards.
    @discardableResult
    public mutating func detach(_ ids: [UUID]) -> [GridItem] {
        let wanted = Set(ids)
        var taken: [GridItem] = []
        for p in pages.indices {
            var kept: [GridItem] = []
            for item in pages[p].items {
                if wanted.contains(item.id) {
                    taken.append(item)
                    continue
                }
                if case .folder(var f) = item, f.apps.contains(where: { wanted.contains($0.id) }) {
                    taken.append(contentsOf: f.apps.filter { wanted.contains($0.id) }.map(GridItem.app))
                    f.apps.removeAll { wanted.contains($0.id) }
                    kept.append(.folder(f))
                    continue
                }
                kept.append(item)
            }
            pages[p].items = kept
        }
        return taken
    }

    /// Inserts items on a page, pushing overflow to later pages.
    public mutating func insert(_ items: [GridItem], page: Int, at index: Int) {
        guard !items.isEmpty else { return }
        spill(from: place(items, page: page, at: index))
    }

    /// Inserts items on a page without spilling; returns the page. A page past the end
    /// becomes one new page after the last, not a run of empty ones.
    private mutating func place(_ items: [GridItem], page: Int, at index: Int) -> Int {
        let page = min(max(0, page), pages.count)
        if page == pages.count { pages.append(Page()) }
        let i = min(max(0, index), pages[page].items.count)
        pages[page].items.insert(contentsOf: items, at: i)
        return page
    }

    /// Moves items to `index` on `page`. The index is relative to the page *after* the moved
    /// items have been taken out, which is what a live-reordering drag displays (a folder the
    /// move empties still counts, as it's still on screen).
    public mutating func move(_ ids: [UUID], toPage page: Int, at index: Int) {
        let items = detach(ids)
        // The displayed gap counts folders the move just emptied. Translate it to a slot
        // among the remaining items before reserving room on the destination page.
        let target = min(max(0, page), pages.count)
        func isEmptyFolder(_ item: GridItem) -> Bool { item.folder?.apps.isEmpty == true }
        let emptiedBefore = target < pages.count
            ? pages[target].items.prefix(max(0, index)).count(where: isEmptyFolder) : 0
        for p in pages.indices { pages[p].items.removeAll(where: isEmptyFolder) }
        // The moved items stay on the page asked for: on a full page, the items they
        // displace spill onward instead of them.
        if !items.isEmpty { _ = place(items, page: page, at: min(index - emptiedBefore, max(0, capacity - items.count))) }
        normalize()
    }

    /// Adds items after the last item of the grid, on the last page while it has room and then
    /// on new pages, as Launchpad adds newly installed apps. Gaps on earlier pages (a page
    /// arranged by hand, or one per category) stay as they are.
    public mutating func appendAtEnd(_ items: [GridItem]) {
        guard !items.isEmpty else { return }
        if pages.isEmpty { pages = [Page()] }
        let last = pages.count - 1
        let room = max(0, capacity - pages[last].items.count)
        pages[last].items.append(contentsOf: items.prefix(room))
        var remaining = items.dropFirst(room)
        while !remaining.isEmpty {
            pages.append(Page(items: Array(remaining.prefix(capacity))))
            remaining = remaining.dropFirst(capacity)
        }
    }

    /// Adds items at the end of the first page with room, or on a new page.
    public mutating func appendToFirstFree(_ items: [GridItem]) {
        var remaining = items[...]
        for p in pages.indices where !remaining.isEmpty {
            let room = capacity - pages[p].items.count
            guard room > 0 else { continue }
            let chunk = remaining.prefix(room)
            pages[p].items.append(contentsOf: chunk)
            remaining = remaining.dropFirst(chunk.count)
        }
        while !remaining.isEmpty {
            let chunk = remaining.prefix(capacity)
            pages.append(Page(items: Array(chunk)))
            remaining = remaining.dropFirst(chunk.count)
        }
    }

    // MARK: Removing

    /// Removes items; their bundle IDs (or paths) are remembered so scans don't re-add them.
    /// A copy sharing its bundle ID with another in `installed` or on the grid is remembered
    /// by path, so the other copy can stay.
    public mutating func remove(_ ids: [UUID], installed: [InstalledApp] = []) {
        let removed = detach(ids).flatMap(\.apps).map(InstalledApp.init)
        let copies = CopyIndex(installed + removed + allApps.map(InstalledApp.init))
        for app in removed { setExcluded(app, true, copies: copies) }
        normalize()
    }

    // MARK: Folders

    /// Groups items into a new folder placed where `anchor` (or the first item) was.
    /// Folders among the items are flattened, since folders cannot nest.
    @discardableResult
    public mutating func group(_ ids: [UUID], name: String, anchor: UUID? = nil) -> UUID? {
        guard let anchorID = anchor ?? ids.first, let loc = locate(anchorID) else { return nil }
        let target = loc.folderIndex == nil ? loc : ItemLocation(page: loc.page, index: loc.index)
        // Count items before the anchor on its page that will be detached, to keep its slot.
        let wanted = Set(ids)
        let shift = pages[target.page].items[..<target.index].filter { wanted.contains($0.id) }.count
        let taken = detach(ids)
        let apps = taken.flatMap(\.apps)
        guard !apps.isEmpty else { return nil }
        let folder = Folder(name: name, apps: apps)
        let index = min(target.index - shift, pages[target.page].items.count)
        pages[target.page].items.insert(.folder(folder), at: max(0, index))
        normalize()
        return folder.id
    }

    /// Adds items to an existing folder; folders among them are flattened into it.
    public mutating func addToFolder(_ ids: [UUID], folder folderID: UUID, at index: Int? = nil) {
        let moving = ids.filter { $0 != folderID }
        let apps = detach(moving).flatMap(\.apps)
        guard let loc = locate(folderID), loc.folderIndex == nil,
              case .folder(var f) = pages[loc.page].items[loc.index] else {
            // Folder vanished (or the ID isn't a folder); put the apps back somewhere visible.
            appendToFirstFree(apps.map(GridItem.app))
            normalize()
            return
        }
        let i = min(max(0, index ?? f.apps.count), f.apps.count)
        f.apps.insert(contentsOf: apps, at: i)
        pages[loc.page].items[loc.index] = .folder(f)
        normalize()
    }

    /// Replaces a folder by its apps, in place.
    public mutating func ungroup(_ folderID: UUID) {
        guard let loc = locate(folderID), loc.folderIndex == nil,
              case .folder(let f) = pages[loc.page].items[loc.index] else { return }
        pages[loc.page].items.replaceSubrange(loc.index...loc.index, with: f.apps.map(GridItem.app))
        spill(from: loc.page)
    }

    // MARK: Renaming

    public mutating func rename(_ id: UUID, to newName: String) {
        guard let loc = locate(id) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        func renamed(_ a: AppRef) -> AppRef {
            var a = a
            a.displayName = (trimmed.isEmpty || trimmed == a.name) ? nil : trimmed
            return a
        }
        switch pages[loc.page].items[loc.index] {
        case .app(let a):
            pages[loc.page].items[loc.index] = .app(renamed(a))
        case .folder(var f):
            if let fi = loc.folderIndex {
                f.apps[fi] = renamed(f.apps[fi])
            } else if !trimmed.isEmpty {
                f.name = trimmed
            }
            pages[loc.page].items[loc.index] = .folder(f)
        }
    }

    /// Points each app at its new place, `moves` mapping old paths to new; recently pruned ones
    /// and path-based exclusions too, so restoring a snapshot preserves those choices.
    public mutating func followMoves(_ moves: [String: String]) {
        guard !moves.isEmpty else { return }
        func moved(_ a: AppRef) -> AppRef {
            var a = a
            if let path = moves[a.path] { a.path = path }
            return a
        }
        for p in pages.indices {
            for i in pages[p].items.indices {
                switch pages[p].items[i] {
                case .app(let a):
                    pages[p].items[i] = .app(moved(a))
                case .folder(var f):
                    f.apps = f.apps.map(moved)
                    pages[p].items[i] = .folder(f)
                }
            }
        }
        for i in recentlyPruned.indices { recentlyPruned[i].app = moved(recentlyPruned[i].app) }
        removedBundleIDs = Set(removedBundleIDs.map { moves[$0] ?? $0 })
    }

    // MARK: Pages

    @discardableResult
    public mutating func addPage(after index: Int? = nil, title: String? = nil) -> Int {
        let at = min(max(0, (index ?? pages.count - 1) + 1), pages.count)
        pages.insert(Page(title: title), at: at)
        return at
    }

    /// Deletes a page; its items move to the end of the previous page (or, for the first
    /// page, to the start of the next one). What doesn't fit there goes on an untitled page in
    /// its place, unless the page after has room for it and no title it would end up under.
    public mutating func deletePage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        let items = pages.remove(at: index).items
        if pages.isEmpty {
            pages = [Page(items: items)]
            spill(from: 0)
            return
        }
        let target = max(0, index - 1)
        if index == 0 {
            pages[0].items.insert(contentsOf: items, at: 0)
        } else {
            pages[target].items.append(contentsOf: items)
        }
        guard pages[target].items.count > capacity else { return }
        let overflow = Array(pages[target].items[capacity...])
        pages[target].items.removeSubrange(capacity...)
        let next = target + 1
        if pages.indices.contains(next), pages[next].title == nil, pages[next].items.count + overflow.count <= capacity {
            pages[next].items.insert(contentsOf: overflow, at: 0)
        } else {
            pages.insert(Page(items: overflow), at: next)
            spill(from: next)
        }
    }

    public mutating func setPageTitle(_ index: Int, _ title: String?) {
        guard pages.indices.contains(index) else { return }
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        pages[index].title = (t?.isEmpty ?? true) ? nil : t
    }

    // MARK: Resizing

    /// Changes the grid size. When every page still fits, the pages stay as they are, so a
    /// layout built by category keeps its pages. Otherwise every item re-flows, in order, so
    /// each page is filled before the next one starts; an empty page stays where it was, between
    /// the items around it. Page `n` keeps the old page `n`'s ID, and takes the title of the page
    /// its first item came from, so a title stays with what it names.
    public mutating func resize(rows: Int, columns: Int) {
        let rows = max(1, rows), columns = max(1, columns)
        guard pages.contains(where: { $0.items.count > rows * columns }) else {
            self.rows = rows
            self.columns = columns
            return
        }
        // Before the new size spills items onto later pages.
        let titles = Dictionary(pages.flatMap { page in page.items.map { ($0.id, page.title) } },
                                uniquingKeysWith: { a, _ in a })
        self.rows = rows
        self.columns = columns
        // Drops empty folders; spilling now would fill the empty pages kept below.
        for p in pages.indices {
            pages[p].items.removeAll { if case .folder(let f) = $0 { return f.apps.isEmpty } else { return false } }
        }
        // Each run of pages between empty ones re-flows on its own, keeping its pages' IDs.
        var result: [Page] = []
        var run: [Page] = []
        func flush() {
            guard !run.isEmpty else { return }
            var part = self
            part.pages = run
            part.flow(run.flatMap(\.items))
            for p in part.pages.indices { part.pages[p].title = part.pages[p].items.first.flatMap { titles[$0.id] ?? nil } }
            result += part.pages
            run = []
        }
        for page in pages {
            if page.items.isEmpty {
                flush()
                result.append(page)
            } else {
                run.append(page)
            }
        }
        flush()
        pages = result
    }

    /// The grid as a resize would leave it, so the UI can warn before re-flowing.
    public func resized(rows: Int, columns: Int) -> Grid {
        var copy = self
        copy.resize(rows: rows, columns: columns)
        return copy
    }

    /// Number of pages a resize would produce.
    public func pageCountAfterResize(rows: Int, columns: Int) -> Int {
        resized(rows: rows, columns: columns).pages.count
    }

    /// Whether `other` (the grid resized, say) has any item on another page, or any page
    /// titled differently.
    public func pagesDiffer(from other: Grid) -> Bool {
        let layout = { (g: Grid) in g.pages.map { $0.items.map(\.id) } }
        return layout(other) != layout(self) || other.pages.map(\.title) != pages.map(\.title)
    }

    // MARK: Sorting

    static func sorted(_ items: [GridItem], folders: FolderPlacement) -> [GridItem] {
        let byTitle: (GridItem, GridItem) -> Bool = {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        switch folders {
        case .mixed:
            return items.sorted(by: byTitle)
        case .first, .last:
            let f = items.filter { $0.folder != nil }.sorted(by: byTitle)
            let a = items.filter { $0.folder == nil }.sorted(by: byTitle)
            return folders == .first ? f + a : a + f
        }
    }

    public mutating func sortPage(_ index: Int, folders: FolderPlacement = .first) {
        guard pages.indices.contains(index) else { return }
        pages[index].items = Grid.sorted(pages[index].items, folders: folders)
    }

    /// Sorts every top-level item and re-flows them across pages. Folders stay intact; page
    /// `n` keeps the old page `n`'s ID. Titles go: the pages no longer hold what they named.
    public mutating func sortEverything(folders: FolderPlacement = .first) {
        flow(Grid.sorted(pages.flatMap(\.items), folders: folders))
        for p in pages.indices { pages[p].title = nil }
    }

    /// Lays `items` out over full pages; page `n` keeps the old page `n`'s ID and title.
    private mutating func flow(_ items: [GridItem]) {
        let old = pages
        pages = stride(from: 0, to: max(items.count, 1), by: capacity).enumerated().map { n, start in
            let chunk = items.isEmpty ? [] : Array(items[start..<min(start + capacity, items.count)])
            return n < old.count ? Page(id: old[n].id, title: old[n].title, items: chunk) : Page(items: chunk)
        }
    }
}

