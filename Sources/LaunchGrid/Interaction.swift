import AppKit
import Observation
import SwiftUI
import LaunchGridCore

/// Fixed rows × columns geometry. Hit-testing is plain arithmetic.
struct GridLayout {
    var size: CGSize
    var rows: Int
    var columns: Int

    var cell: CGSize {
        CGSize(width: size.width / CGFloat(max(columns, 1)), height: size.height / CGFloat(max(rows, 1)))
    }

    func center(_ index: Int) -> CGPoint {
        let c = index % columns, r = index / columns
        return CGPoint(x: (CGFloat(c) + 0.5) * cell.width, y: (CGFloat(r) + 0.5) * cell.height)
    }

    /// Cell under a point in local coordinates, clamped to the grid.
    func cellIndex(at p: CGPoint) -> Int? {
        guard p.y >= -cell.height * 0.5, p.y <= size.height + cell.height * 0.5 else { return nil }
        let c = min(max(Int(p.x / cell.width), 0), columns - 1)
        let r = min(max(Int(p.y / cell.height), 0), rows - 1)
        return r * columns + c
    }

    func iconSize(scale: Double) -> CGFloat {
        let fit = min(cell.width * 0.62, cell.height * 0.58)
        return max(24, min(fit * scale, min(cell.width, cell.height) * 0.9, 160))
    }
}

enum FolderLayout {
    static func columns(_ grid: Grid) -> Int { grid.columns }
    static func maxRows(_ grid: Grid) -> Int { max(1, grid.rows - 1) }
    static func perPage(_ grid: Grid) -> Int { columns(grid) * maxRows(grid) }

    static func pageCount(apps: Int, grid: Grid) -> Int {
        max(1, Int(ceil(Double(apps) / Double(perPage(grid)))))
    }

    static func rows(apps: Int, grid: Grid) -> Int {
        max(1, min(maxRows(grid), Int(ceil(Double(apps) / Double(columns(grid))))))
    }
}

/// Live state of an item drag (or a background swipe drag).
@MainActor @Observable
final class DragController {
    enum Source: Equatable { case page, folder(UUID) }

    var active = false
    var ids: [UUID] = []
    var primary: GridItem?
    var source: Source = .page
    /// Pointer location in the root coordinate space.
    var location: CGPoint = .zero
    /// Insertion index among the non-dragged items of the current page (or open folder).
    var gap: Int?
    /// Item the pointer has dwelt on long enough to merge with.
    var mergeTarget: UUID?

    /// A gap move waiting for the pointer to settle, so passing over icons doesn't shuffle them.
    @ObservationIgnored var pendingGap: Int?
    @ObservationIgnored var pendingGapSince = Date()
    @ObservationIgnored var candidate: UUID?
    @ObservationIgnored var candidateSince = Date()
    @ObservationIgnored var edgeSide = 0
    @ObservationIgnored var edgeSince = Date()
    @ObservationIgnored var decided = false
    @ObservationIgnored var panning = false
    @ObservationIgnored var timer: Timer?

    // Frames reported by views, in root coordinates.
    @ObservationIgnored var pagerFrame: CGRect = .zero
    @ObservationIgnored var folderPanelFrame: CGRect = .zero
    @ObservationIgnored var folderGridFrame: CGRect = .zero

    func isDragged(_ id: UUID) -> Bool { active && ids.contains(id) }

    func cancel() {
        timer?.invalidate()
        timer = nil
        active = false
        ids = []
        primary = nil
        gap = nil
        pendingGap = nil
        mergeTarget = nil
        candidate = nil
        decided = false
        panning = false
        edgeSide = 0
    }
}

private let debugDrag = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_DRAG"] != nil

extension AppState {
    static let mergeDwell: TimeInterval = 0.4
    static let edgeDwell: TimeInterval = 0.6
    static let reorderDwell: TimeInterval = 0.18

    var pageLayout: GridLayout {
        GridLayout(size: drag.pagerFrame.size, rows: grid.rows, columns: grid.columns)
    }

    var folderLayout: GridLayout {
        GridLayout(size: drag.folderGridFrame.size,
                   rows: FolderLayout.rows(apps: openFolder?.apps.count ?? 0, grid: grid),
                   columns: FolderLayout.columns(grid))
    }

    /// Items of a page as displayed during a drag: dragged ones removed.
    func remainingItems(page: Int) -> [GridItem] {
        guard grid.pages.indices.contains(page) else { return [] }
        let items = grid.pages[page].items
        return drag.active ? items.filter { !drag.ids.contains($0.id) } : items
    }

    func remainingFolderApps() -> [AppRef] {
        guard let f = openFolder else { return [] }
        return drag.active ? f.apps.filter { !drag.ids.contains($0.id) } : f.apps
    }

    /// Whether the pager shows an extra empty page to drop onto.
    var showsVirtualPage: Bool { drag.active && currentPage >= grid.pages.count }

    // MARK: Gesture entry points

    func dragChanged(start: CGPoint, location: CGPoint) {
        if debugDrag { NSLog("drag changed start=\(start) loc=\(location) active=\(drag.active) gap=\(String(describing: drag.gap)) cand=\(String(describing: drag.candidate)) merge=\(String(describing: drag.mergeTarget)) pager=\(drag.pagerFrame)") }
        if !drag.decided {
            drag.decided = true
            if !beginItemDrag(at: start) {
                drag.panning = query.isEmpty && openFolder == nil && drag.pagerFrame.contains(start)
            }
        }
        if drag.panning {
            swipeOffset = location.x - start.x
            return
        }
        guard drag.active else { return }
        drag.location = location
        updateTargets()
    }

    func dragEnded(start: CGPoint, location: CGPoint, predicted: CGPoint) {
        if debugDrag { NSLog("drag ended loc=\(location) active=\(drag.active) gap=\(String(describing: drag.gap)) merge=\(String(describing: drag.mergeTarget))") }
        defer { drag.cancel() }
        if drag.panning {
            let w = max(drag.pagerFrame.width, 1)
            let dx = location.x - start.x, flick = predicted.x - start.x
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                if dx < -w * 0.18 || flick < -w * 0.5 { currentPage = min(currentPage + 1, grid.pages.count - 1) }
                if dx > w * 0.18 || flick > w * 0.5 { currentPage = max(currentPage - 1, 0) }
                swipeOffset = 0
            }
            return
        }
        guard drag.active else { return }
        drop()
    }

    // MARK: Drag lifecycle

    private func beginItemDrag(at start: CGPoint) -> Bool {
        guard query.isEmpty, textEdit == nil else { return false }
        var hit: UUID?
        var source = DragController.Source.page
        if let folder = openFolder {
            let local = CGPoint(x: start.x - drag.folderGridFrame.minX, y: start.y - drag.folderGridFrame.minY)
            guard drag.folderGridFrame.contains(start), let cell = folderLayout.cellIndex(at: local) else { return false }
            let index = folderPage * FolderLayout.perPage(grid) + cell
            guard folder.apps.indices.contains(index) else { return false }
            hit = folder.apps[index].id
            source = .folder(folder.id)
        } else {
            let local = CGPoint(x: start.x - drag.pagerFrame.minX, y: start.y - drag.pagerFrame.minY)
            guard drag.pagerFrame.contains(start), let cell = pageLayout.cellIndex(at: local),
                  currentItems.indices.contains(cell) else { return false }
            // Only start on the icon itself; elsewhere a drag swipes pages.
            let center = pageLayout.center(cell)
            let reach = pageLayout.iconSize(scale: prefs.iconScale) * 0.75
            guard abs(local.x - center.x) < reach, abs(local.y - center.y) < reach * 1.2 else { return false }
            hit = currentItems[cell].id
        }
        guard let hit, let item = grid.item(hit) else { return false }
        let ids = targets(for: hit)
        drag.ids = ids
        drag.primary = item
        drag.source = source
        drag.location = start
        drag.edgeSide = 0
        drag.candidate = nil
        drag.mergeTarget = nil
        // The gap starts where the primary item was, among the remaining items.
        let siblings: [UUID] = openFolder.map { $0.apps.map(\.id) } ?? currentItems.map(\.id)
        let before = siblings.prefix { $0 != hit }.filter { !ids.contains($0) }.count
        drag.gap = before
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { drag.active = true }
        drag.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragTick() }
        }
        return true
    }

    private var mergeAllowed: Bool {
        // Folders cannot go inside folders.
        !drag.ids.contains { grid.item($0)?.folder != nil }
    }

    private func updateTargets() {
        let p = drag.location
        if case .folder = drag.source, openFolder != nil {
            if drag.folderPanelFrame.insetBy(dx: -12, dy: -12).contains(p) {
                updateFolderGap(p)
                return
            }
            // Dragged out of the folder: close it and continue on the page.
            closeFolder()
            drag.gap = nil
            drag.pendingGap = nil
        }
        updatePageTargets(p)
    }

    private func updateFolderGap(_ p: CGPoint) {
        let local = CGPoint(x: p.x - drag.folderGridFrame.minX, y: p.y - drag.folderGridFrame.minY)
        guard let cell = folderLayout.cellIndex(at: local) else { return }
        let index = min(folderPage * FolderLayout.perPage(grid) + cell, remainingFolderApps().count)
        if index != drag.gap {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag.gap = index }
        }
    }

    private func updatePageTargets(_ p: CGPoint) {
        let frame = drag.pagerFrame
        let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        let edge = min(70, frame.width * 0.06)
        let side = local.x < edge ? -1 : (local.x > frame.width - edge ? 1 : 0)
        if side != drag.edgeSide {
            drag.edgeSide = side
            drag.edgeSince = Date()
        }
        guard let cell = pageLayout.cellIndex(at: local) else { return }
        let remaining = remainingItems(page: currentPage)
        let gap = drag.gap ?? remaining.count
        // Which item is displayed in this cell, given the gap shifts later items right.
        var shown: GridItem?
        if cell != gap {
            let r = cell < gap ? cell : cell - 1
            if remaining.indices.contains(r) { shown = remaining[r] }
        }
        let center = pageLayout.center(cell)
        let radius = pageLayout.iconSize(scale: prefs.iconScale) * 0.42
        let nearCenter = hypot(local.x - center.x, local.y - center.y) < radius
        if let shown, nearCenter, mergeAllowed {
            drag.pendingGap = nil
            if drag.candidate != shown.id {
                drag.candidate = shown.id
                drag.candidateSince = Date()
                if drag.mergeTarget != nil { withAnimation(.easeOut(duration: 0.15)) { drag.mergeTarget = nil } }
            }
            return
        }
        drag.candidate = nil
        if drag.mergeTarget != nil { withAnimation(.easeOut(duration: 0.15)) { drag.mergeTarget = nil } }
        let newGap = min(cell, remaining.count)
        if newGap == drag.gap {
            drag.pendingGap = nil
        } else if newGap != drag.pendingGap {
            drag.pendingGap = newGap
            drag.pendingGapSince = Date()
        }
    }

    private func dragTick() {
        guard drag.active else { return }
        let now = Date()
        if let g = drag.pendingGap, now.timeIntervalSince(drag.pendingGapSince) > Self.reorderDwell {
            drag.pendingGap = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag.gap = g }
        }
        if let c = drag.candidate, drag.mergeTarget != c, now.timeIntervalSince(drag.candidateSince) > Self.mergeDwell {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { drag.mergeTarget = c }
        }
        if drag.edgeSide != 0, openFolder == nil, now.timeIntervalSince(drag.edgeSince) > Self.edgeDwell {
            drag.edgeSince = now
            let target = currentPage + drag.edgeSide
            // Past the last page there is one empty page to drop onto.
            let last = grid.pages.count - (remainingItems(page: grid.pages.count - 1).isEmpty ? 1 : 0)
            guard target >= 0, target <= last else { return }
            drag.candidate = nil
            drag.mergeTarget = nil
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                currentPage = target
                drag.gap = nil
                drag.pendingGap = nil
            }
        }
    }

    private func drop() {
        let ids = drag.ids
        let page = currentPage
        if let target = drag.mergeTarget, let targetItem = grid.item(target) {
            switch targetItem {
            case .folder(let f):
                apply { g in g.removingEmptiedPages { $0.addToFolder(ids, folder: f.id) } }
                showToast("Added to \(f.name)")
            case .app(let a):
                let apps = [a] + ids.compactMap { grid.item($0)?.app }
                let name = GridBuilder.folderName(for: apps.map { installedApp(for: $0) })
                apply { g in g.removingEmptiedPages { $0.group([target] + ids, name: name, anchor: target) } }
            }
        } else if case .folder(let fid) = drag.source, openFolderID == fid {
            let gap = drag.gap ?? remainingFolderApps().count
            apply { $0.addToFolder(ids, folder: fid, at: gap) }
        } else {
            // A drop right after moving counts, even if the pointer hadn't settled yet.
            let gap = drag.pendingGap ?? drag.gap ?? remainingItems(page: page).count
            apply { g in g.removingEmptiedPages { $0.move(ids, toPage: page, at: gap) } }
        }
        selection.removeAll()
        // The grid may have lost an emptied page; keep the view on a real page.
        currentPage = min(currentPage, grid.pages.count - 1)
    }
}
