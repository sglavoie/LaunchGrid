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
        let page = max(0, page)
        while page >= pages.count { pages.append(Page()) }
        let i = min(max(0, index), pages[page].items.count)
        pages[page].items.insert(contentsOf: items, at: i)
        spill(from: page)
    }

    /// Moves items to `index` on `page`. The index is relative to the page *after* the moved
    /// items have been taken out, which is what a live-reordering drag displays.
    public mutating func move(_ ids: [UUID], toPage page: Int, at index: Int) {
        let items = detach(ids)
        insert(items, page: page, at: index)
        normalize()
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

    // MARK: Pages

    @discardableResult
    public mutating func addPage(after index: Int? = nil, title: String? = nil) -> Int {
        let at = min(max(0, (index ?? pages.count - 1) + 1), pages.count)
        pages.insert(Page(title: title), at: at)
        return at
    }

    /// Deletes a page; its items move to the end of the previous page (or, for the first
    /// page, to the start of the next one).
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
        spill(from: target)
    }

    public mutating func setPageTitle(_ index: Int, _ title: String?) {
        guard pages.indices.contains(index) else { return }
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        pages[index].title = (t?.isEmpty ?? true) ? nil : t
    }

    // MARK: Resizing

    /// Changes the grid size and re-flows every item, in order, so each page is filled
    /// before the next one starts. Page `n` keeps the old page `n`'s ID and title.
    public mutating func resize(rows: Int, columns: Int) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        normalize()
        flow(pages.flatMap(\.items))
    }

    /// Number of pages a resize would produce, so the UI can warn before re-flowing.
    public func pageCountAfterResize(rows: Int, columns: Int) -> Int {
        var copy = self
        copy.resize(rows: rows, columns: columns)
        return copy.pages.count
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
    /// `n` keeps the old page `n`'s ID and title.
    public mutating func sortEverything(folders: FolderPlacement = .first) {
        flow(Grid.sorted(pages.flatMap(\.items), folders: folders))
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
