import Foundation

public struct ItemLocation: Equatable, Sendable {
    public var page: Int
    public var index: Int
    /// Set when the item is an app or action inside the folder at `(page, index)`: its
    /// position among the folder's members.
    public var folderIndex: Int?

    public init(page: Int, index: Int, folderIndex: Int? = nil) {
        self.page = page
        self.index = index
        self.folderIndex = folderIndex
    }
}

/// Where an action is: on a page like any other item, or search-only in `Grid.hiddenActions`.
public enum ActionLocation: Equatable, Sendable {
    case page(ItemLocation)
    case hidden(index: Int)
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
                if case .folder(let f) = item, let fi = f.items.firstIndex(where: { $0.id == id }) {
                    return ItemLocation(page: p, index: i, folderIndex: fi)
                }
            }
        }
        return nil
    }

    /// Where the action with `id` is, also when it is search-only. `locate(_:)` only finds
    /// items on a page, so its callers can index `pages` with whatever it returns. One in a
    /// folder is on a page, with `folderIndex` set.
    public func locateAction(_ id: UUID) -> ActionLocation? {
        if let loc = locate(id) {
            return item(at: loc)?.action != nil ? .page(loc) : nil
        }
        return hiddenActions.firstIndex { $0.id == id }.map { .hidden(index: $0) }
    }

    /// The item with `id`; an app or action inside a folder is returned as `.app` or
    /// `.action`, a search-only action as `.action`.
    public func item(_ id: UUID) -> GridItem? {
        guard let loc = locate(id) else { return hiddenActions.first { $0.id == id }.map(GridItem.action) }
        return item(at: loc)
    }

    /// The item at `loc`, a folder member as itself.
    public func item(at loc: ItemLocation) -> GridItem? {
        guard pages.indices.contains(loc.page), pages[loc.page].items.indices.contains(loc.index) else { return nil }
        let top = pages[loc.page].items[loc.index]
        guard let fi = loc.folderIndex else { return top }
        guard case .folder(let f) = top, f.items.indices.contains(fi) else { return nil }
        return f.items[fi].gridItem
    }

    /// The folder holding the item with `id`, if it is in one.
    public func folder(containing id: UUID) -> Folder? {
        guard let loc = locate(id), loc.folderIndex != nil else { return nil }
        return pages[loc.page].items[loc.index].folder
    }

    public func folder(_ id: UUID) -> Folder? {
        item(id)?.folder
    }

    /// All apps, in visual order, including those inside folders.
    public var allApps: [AppRef] {
        pages.flatMap { $0.items.flatMap(\.apps) }
    }

    /// All actions: those on pages (folders too) in visual order, then the search-only ones.
    public var allActions: [Action] {
        pages.flatMap { $0.items.flatMap { item in item.folder?.actions ?? item.action.map { [$0] } ?? [] } } + hiddenActions
    }

    /// Everything search can find: apps and actions (folder contents too), in visual order,
    /// then the search-only actions. Folders themselves are left out.
    public var allSearchItems: [GridItem] {
        pages.flatMap { page in
            page.items.flatMap { item -> [GridItem] in
                if case .folder(let f) = item { return f.items.map(\.gridItem) }
                return [item]
            }
        } + hiddenActions.map(GridItem.action)
    }

    public var appKeys: Set<String> {
        Set(allApps.map(\.key))
    }

    // MARK: Structural invariants

    /// Drops empty folders (no apps and no actions), spills overflowing pages and guarantees
    /// at least one page.
    public mutating func normalize() {
        for p in pages.indices {
            pages[p].items.removeAll { if case .folder(let f) = $0 { return f.items.isEmpty } else { return false } }
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
                if case .folder(var f) = item, f.items.contains(where: { wanted.contains($0.id) }) {
                    taken.append(contentsOf: f.items.filter { wanted.contains($0.id) }.map(\.gridItem))
                    f.items.removeAll { wanted.contains($0.id) }
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
        func isEmptyFolder(_ item: GridItem) -> Bool { item.folder?.items.isEmpty == true }
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
    /// Actions are simply dropped, search-only ones too; they never touch the exclusions.
    public mutating func remove(_ ids: [UUID], installed: [InstalledApp] = []) {
        let taken = detach(ids)
        let folders = Set(taken.compactMap(\.folder).map(\.id))
        let wanted = Set(ids)
        hiddenActions.removeAll { wanted.contains($0.id) }
        // A folder's temporarily missing apps leave with it, or the next scan would restore
        // them outside the removed folder. Keep the other records as known copies too:
        // removing a visible copy must not exclude its sibling while that one is updating.
        let forgotten = recentlyPruned.filter {
            wanted.contains($0.app.id) || $0.folderID.map(folders.contains) == true
        }
        let removed = (taken.flatMap(\.apps) + forgotten.map(\.app)).map(InstalledApp.init)
        let copies = CopyIndex(installed + removed + (allApps + recentlyPruned.map(\.app)).map(InstalledApp.init))
        let forgottenIDs = Set(forgotten.map(\.app.id))
        recentlyPruned.removeAll { forgottenIDs.contains($0.app.id) }
        for app in removed { setExcluded(app, true, copies: copies) }
        normalize()
    }

    // MARK: Folders

    /// Groups items (apps, actions, folders) into a new folder placed where `anchor` (or the
    /// first item) was. Folders among the items are flattened, since folders cannot nest.
    /// Search-only actions have no slot and stay where they are.
    @discardableResult
    public mutating func group(_ ids: [UUID], name: String, anchor: UUID? = nil) -> UUID? {
        let ids = onPages(ids)
        let anchor = anchor.flatMap { locate($0) == nil ? nil : $0 }
        guard let anchorID = anchor ?? ids.first, let loc = locate(anchorID) else { return nil }
        let target = loc.folderIndex == nil ? loc : ItemLocation(page: loc.page, index: loc.index)
        // Count items before the anchor on its page that will be detached, to keep its slot.
        let wanted = Set(ids)
        let shift = pages[target.page].items[..<target.index].filter { wanted.contains($0.id) }.count
        let taken = detach(ids)
        let members = taken.flatMap(\.members)
        guard !members.isEmpty else { return nil }
        let folder = Folder(name: name, items: members)
        let index = min(target.index - shift, pages[target.page].items.count)
        pages[target.page].items.insert(.folder(folder), at: max(0, index))
        normalize()
        movePrunedContents(of: taken, to: folder.id, at: 0)
        return folder.id
    }

    /// Adds items (apps, actions, folders) to an existing folder at member position `index`;
    /// folders among them are flattened into it. Search-only actions stay where they are.
    public mutating func addToFolder(_ ids: [UUID], folder folderID: UUID, at index: Int? = nil) {
        let moving = onPages(ids).filter { $0 != folderID }
        let taken = detach(moving)
        let members = taken.flatMap(\.members)
        guard let loc = locate(folderID), loc.folderIndex == nil,
              case .folder(var f) = pages[loc.page].items[loc.index] else {
            // Folder vanished (or the ID isn't a folder); put the items back somewhere visible.
            appendToFirstFree(members.map(\.gridItem))
            normalize()
            return
        }
        let i = min(max(0, index ?? f.items.count), f.items.count)
        f.items.insert(contentsOf: members, at: i)
        pages[loc.page].items[loc.index] = .folder(f)
        normalize()
        movePrunedContents(of: taken, to: folderID, at: i)
    }

    /// The IDs of items on a page (folder members too): search-only actions have no slot.
    private func onPages(_ ids: [UUID]) -> [UUID] {
        ids.filter { locate($0) != nil }
    }

    /// Flattening a folder also moves the apps an updater temporarily took out of it.
    /// Their remembered neighbours follow them, preserving their order when they return;
    /// removing the destination folder meanwhile must exclude them with its visible apps.
    private mutating func movePrunedContents(of items: [GridItem], to folderID: UUID, at index: Int) {
        guard !recentlyPruned.isEmpty, let loc = locate(folderID),
              let destination = folder(folderID) else { return }
        var offset = index
        for item in items {
            defer { offset += item.members.count }
            guard let source = item.folder else { continue }
            let prefix = destination.itemIDs.prefix(offset)
            for k in recentlyPruned.indices where recentlyPruned[k].folderID == source.id {
                var entry = recentlyPruned[k]
                let slot = min(max(0, entry.folderIndex ?? source.items.count), source.items.count)
                entry.folderBefore = prefix + (entry.folderBefore ?? Array(source.itemIDs.prefix(slot)))
                entry.folderIndex = offset + slot
                entry.folderID = folderID
                entry.folderName = destination.name
                entry.folderEmptied = false
                entry.pageID = pages[loc.page].id
                entry.index = loc.index
                entry.before = pages[loc.page].items.prefix(loc.index).map(\.id)
                entry.pageEmptied = false
                entry.pageIndex = nil
                entry.pageTitle = nil
                entry.pageBefore = nil
                recentlyPruned[k] = entry
            }
        }
    }

    /// Replaces a folder by its apps and actions, in place.
    public mutating func ungroup(_ folderID: UUID) {
        guard let loc = locate(folderID), loc.folderIndex == nil,
              case .folder(let f) = pages[loc.page].items[loc.index] else { return }
        pages[loc.page].items.replaceSubrange(loc.index...loc.index, with: f.items.map(\.gridItem))
        spill(from: loc.page)
        // An updater may have taken some apps out before the folder was moved or
        // ungrouped. Their fallback slots now belong among its expanded contents;
        // their folder neighbours still tell them apart when those contents spill.
        for k in recentlyPruned.indices where recentlyPruned[k].folderID == folderID {
            var entry = recentlyPruned[k]
            let slot = min(max(0, Self.slot(after: entry.folderBefore,
                fallback: entry.folderIndex ?? f.items.count, in: f.itemIDs)), f.items.count)
            let absolute = loc.index + slot
            let page = min(loc.page + absolute / capacity, pages.count - 1)
            let index = min(absolute - (page - loc.page) * capacity, pages[page].items.count)
            entry.pageID = pages[page].id
            entry.index = index
            entry.before = pages[page].items.prefix(index).map(\.id)
            entry.folderBefore = entry.folderBefore ?? Array(f.itemIDs.prefix(slot))
            entry.folderEmptied = false
            entry.pageEmptied = false
            entry.pageIndex = nil
            entry.pageTitle = nil
            entry.pageBefore = nil
            recentlyPruned[k] = entry
        }
    }

    // MARK: Renaming

    public mutating func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .hidden(let k) = locateAction(id) {
            if !trimmed.isEmpty { hiddenActions[k].name = trimmed }
            return
        }
        guard let loc = locate(id) else { return }
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
                switch f.items[fi] {
                case .app(let a):
                    f.items[fi] = .app(renamed(a))
                case .action(var a):
                    guard !trimmed.isEmpty else { return }
                    a.name = trimmed
                    f.items[fi] = .action(a)
                }
            } else if !trimmed.isEmpty {
                f.name = trimmed
                // If the remaining apps also disappear during an update, the first one
                // back recreates the folder from its remembered name.
                for k in recentlyPruned.indices where recentlyPruned[k].folderID == f.id {
                    recentlyPruned[k].folderName = trimmed
                }
            }
            pages[loc.page].items[loc.index] = .folder(f)
        case .action(var a):
            guard !trimmed.isEmpty else { return }
            a.name = trimmed
            pages[loc.page].items[loc.index] = .action(a)
        }
    }

    /// Adds a new action: in the first free slot of page `page`, else (no such page, or it's
    /// full) the grid's first free slot; to `hiddenActions` when it's search-only. Nothing
    /// else moves.
    public mutating func addAction(_ action: Action, page: Int? = nil) {
        guard locateAction(action.id) == nil else { return updateAction(action) }
        guard action.showsOnGrid else { return hiddenActions.append(action) }
        if let page, pages.indices.contains(page), pages[page].items.count < capacity {
            pages[page].items.append(.action(action))
        } else {
            appendToFirstFree([.action(action)])
        }
    }

    /// Replaces the action with `action.id`. One whose `showsOnGrid` changed moves between
    /// its page and `hiddenActions`; one becoming visible goes to the first free slot. A page
    /// that hiding it empties is removed, as when removing it.
    public mutating func updateAction(_ action: Action) {
        switch locateAction(action.id) {
        case nil:
            return
        case .page(let loc) where action.showsOnGrid:
            if let fi = loc.folderIndex, case .folder(var f) = pages[loc.page].items[loc.index] {
                f.items[fi] = .action(action)
                pages[loc.page].items[loc.index] = .folder(f)
            } else {
                pages[loc.page].items[loc.index] = .action(action)
            }
        case .page:
            removingEmptiedPages {
                $0.detach([action.id])
                $0.hiddenActions.append(action)
                $0.normalize()
            }
        case .hidden(let k) where action.showsOnGrid:
            hiddenActions.remove(at: k)
            appendToFirstFree([.action(action)])
        case .hidden(let k):
            hiddenActions[k] = action
        }
    }

    /// Points each app at its new place, `moves` mapping old paths to new; recently pruned ones
    /// and path-based exclusions too, so restoring a snapshot preserves those choices.
    /// A bookmarked scan folder can move as a whole. Its descendants follow it, unless a
    /// more specific move names their destination. Every path follows the original map once.
    public mutating func followMoves(_ moves: [String: String]) {
        guard !moves.isEmpty else { return }
        let folders = moves.filter { $0.key.hasPrefix("/") }.map { old, new in
            (prefix: old.hasSuffix("/") ? old : old + "/", destination: new.hasSuffix("/") ? new : new + "/")
        }.sorted { $0.prefix.count > $1.prefix.count }
        func movedPath(_ path: String) -> String {
            if let exact = moves[path] { return exact }
            guard let folder = folders.first(where: { path.hasPrefix($0.prefix) }) else { return path }
            return folder.destination + path.dropFirst(folder.prefix.count)
        }
        func moved(_ a: AppRef) -> AppRef {
            var a = a
            a.path = movedPath(a.path)
            return a
        }
        // The file an action opens, the app it opens it with and its picture follow too:
        // their sandbox bookmarks moved with them.
        func moved(_ a: Action) -> Action {
            var a = a
            if case .openFile(let path, let appPath) = a.kind {
                a.kind = .openFile(path: movedPath(path), appPath: appPath.map(movedPath))
            }
            if case .image(let path) = a.icon { a.icon = .image(path: movedPath(path)) }
            return a
        }
        for p in pages.indices {
            for i in pages[p].items.indices {
                switch pages[p].items[i] {
                case .app(let a):
                    pages[p].items[i] = .app(moved(a))
                case .folder(var f):
                    f.items = f.items.map { member in
                        switch member {
                        case .app(let a): .app(moved(a))
                        case .action(let a): .action(moved(a))
                        }
                    }
                    pages[p].items[i] = .folder(f)
                case .action(let a):
                    pages[p].items[i] = .action(moved(a))
                }
            }
        }
        hiddenActions = hiddenActions.map(moved)
        for i in recentlyPruned.indices { recentlyPruned[i].app = moved(recentlyPruned[i].app) }
        removedBundleIDs = Set(removedBundleIDs.map(movedPath))
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
    /// A titled next page keeps its own items: those of the first page that don't fit stay
    /// on an untitled page before it.
    public mutating func deletePage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        let removed = pages.remove(at: index)
        let items = removed.items
        let target = max(0, index - 1)
        let start = index == 0 ? 0 : pages[target].items.count
        // Deleting the first page before a titled one: how many of its items stay on an
        // untitled page in its place, so the titled page's own items aren't pushed off it.
        var head = 0
        if index == 0, let next = pages.first, next.title != nil {
            head = max(0, items.count - max(0, capacity - next.items.count))
        }
        defer {
            // Apps temporarily absent during an update move with the page's visible
            // contents. Otherwise their deleted page ID sends them to the first free
            // slot anywhere in the grid when they return.
            let waiting = Set(recentlyPruned.flatMap { [$0.app.id] + ($0.folderID.map { [$0] } ?? []) })
            for k in recentlyPruned.indices where recentlyPruned[k].pageID == removed.id {
                let slot = min(max(0, Self.slot(after: recentlyPruned[k].before,
                    fallback: recentlyPruned[k].index, in: items.map(\.id))), items.count)
                let page: Int, at: Int
                if head > 0 {
                    // The untitled first page holds `items[..<head]`, the titled one the rest.
                    page = min(slot < head ? slot / capacity : (head + capacity - 1) / capacity, pages.count - 1)
                    at = slot < head ? min(slot - page * capacity, pages[page].items.count)
                                     : min(slot - head, pages[page].items.count)
                } else {
                    let absolute = start + slot
                    page = min(target + absolute / capacity, pages.count - 1)
                    at = min(absolute - (page - target) * capacity, pages[page].items.count)
                }
                recentlyPruned[k].pageID = pages[page].id
                recentlyPruned[k].index = at
                let prefix = pages[page].items.prefix(at).map(\.id)
                let neighbours = (recentlyPruned[k].before ?? []).filter {
                    prefix.contains($0) || waiting.contains($0)
                }
                recentlyPruned[k].before = prefix.filter { !neighbours.contains($0) } + neighbours
                recentlyPruned[k].pageEmptied = false
                recentlyPruned[k].pageIndex = nil
                recentlyPruned[k].pageTitle = nil
                recentlyPruned[k].pageBefore = nil
            }
        }
        if pages.isEmpty {
            pages = [Page(items: items)]
            spill(from: 0)
            return
        }
        if head > 0 {
            pages[0].items.insert(contentsOf: items[head...], at: 0)
            pages.insert(Page(items: Array(items[..<head])), at: 0)
            // Only a page holding more than fits (from an older, larger grid) spills here.
            if head > capacity {
                let overflow = Array(pages[0].items[capacity...])
                pages[0].items.removeSubrange(capacity...)
                for (n, chunk) in stride(from: 0, to: overflow.count, by: capacity).enumerated() {
                    pages.insert(Page(items: Array(overflow[chunk..<min(chunk + capacity, overflow.count)])), at: n + 1)
                }
            }
            return
        }
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

    /// The most rows or columns a grid file may have and still load.
    public static let maxDimension = 50

    /// Changes the grid size. When every page still fits, the pages stay as they are, so a
    /// layout built by category keeps its pages. Otherwise every item re-flows, in order, so
    /// each page is filled before the next one starts; an empty page stays where it was, between
    /// the items around it. Page `n` keeps the old page `n`'s ID, and takes the title of the page
    /// its first item came from, so a title stays with what it names.
    public mutating func resize(rows: Int, columns: Int) {
        // A size a saved file can't be loaded back with would set the whole layout aside.
        let rows = min(max(1, rows), Grid.maxDimension), columns = min(max(1, columns), Grid.maxDimension)
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
            pages[p].items.removeAll { if case .folder(let f) = $0 { return f.items.isEmpty } else { return false } }
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

    /// Actions sort by title among the apps; `folders` places only folders.
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

