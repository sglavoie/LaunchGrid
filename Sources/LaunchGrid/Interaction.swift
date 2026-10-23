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
    /// From the pointer to the picked-up icon's centre, so the icon stays where it was grabbed.
    var grabOffset: CGSize = .zero
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
    @ObservationIgnored var gestureStart: CGPoint = .zero
    @ObservationIgnored var panning = false
    @ObservationIgnored var timer: Timer?
    /// Start of a gesture cancelled while still in progress (Esc, hiding). Its remaining
    /// events are ignored instead of starting a new drag.
    @ObservationIgnored var abandonedStart: CGPoint?

    // Frames reported by views, in root coordinates.
    @ObservationIgnored var pagerFrame: CGRect = .zero
    @ObservationIgnored var folderPanelFrame: CGRect = .zero
    @ObservationIgnored var folderGridFrame: CGRect = .zero
    @ObservationIgnored var menuButtonFrame: CGRect = .zero

    func isDragged(_ id: UUID) -> Bool { active && ids.contains(id) }

    /// Centre of the dragged icon. Drop targets are found under it rather than under the
    /// pointer, so what lands is what the icon covers.
    var iconCenter: CGPoint { CGPoint(x: location.x + grabOffset.width, y: location.y + grabOffset.height) }

    /// Cancels the drag; the rest of the gesture in progress, if any, is ignored.
    func cancel() {
        if decided { abandonedStart = gestureStart }
        reset()
    }

    /// Clears all drag state once a gesture has ended.
    func reset() {
        timer?.invalidate()
        timer = nil
        active = false
        ids = []
        primary = nil
        grabOffset = .zero
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

    /// Drag motion (lifts, gap shifts, merge highlights); none with Reduce Motion, so
    /// icons change place without sliding.
    static func dragMotion(_ animation: Animation) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
    }

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
        if let abandoned = drag.abandonedStart {
            if abandoned == start { return }
            drag.abandonedStart = nil // A new gesture: its end event never arrived.
        }
        if drag.decided && start != drag.gestureStart {
            // A new gesture while the last one is still decided: its end never arrived.
            // Drop what it left (a lifted item, a half swipe) and decide afresh.
            drag.reset()
            swipeOffset = 0
        }
        if !drag.decided {
            drag.decided = true
            drag.gestureStart = start
            if !beginItemDrag(at: start) {
                drag.panning = query.isEmpty && openFolder == nil && textEdit == nil && drag.pagerFrame.contains(start)
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
        if drag.abandonedStart != nil {
            drag.abandonedStart = nil
            return
        }
        defer { drag.reset() }
        if drag.panning {
            let w = max(drag.pagerFrame.width, 1)
            let dx = location.x - start.x, flick = predicted.x - start.x
            withAnimation(Self.pageAnimation) {
                // Through goToPage, which keeps keyboard focus on the new page.
                if dx < -w * 0.18 || flick < -w * 0.5 { goToPage(currentPage + 1) }
                if dx > w * 0.18 || flick > w * 0.5 { goToPage(currentPage - 1) }
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
        // Only start on the icon itself; elsewhere a drag swipes pages (or does nothing in a folder).
        let reach = pageLayout.iconSize(scale: prefs.iconScale) * 0.75
        func onIcon(_ local: CGPoint, _ center: CGPoint) -> Bool {
            abs(local.x - center.x) < reach && abs(local.y - center.y) < reach * 1.2
        }
        var center = CGPoint.zero
        if let folder = openFolder {
            let frame = drag.folderGridFrame
            let local = CGPoint(x: start.x - frame.minX, y: start.y - frame.minY)
            guard frame.contains(start), let cell = folderLayout.cellIndex(at: local) else { return false }
            let index = folderPage * FolderLayout.perPage(grid) + cell
            let c = folderLayout.center(cell)
            guard folder.apps.indices.contains(index), onIcon(local, c) else { return false }
            hit = folder.apps[index].id
            source = .folder(folder.id)
            center = CGPoint(x: frame.minX + c.x, y: frame.minY + c.y)
        } else {
            let frame = drag.pagerFrame
            let local = CGPoint(x: start.x - frame.minX, y: start.y - frame.minY)
            guard frame.contains(start), let cell = pageLayout.cellIndex(at: local),
                  currentItems.indices.contains(cell) else { return false }
            let c = pageLayout.center(cell)
            guard onIcon(local, c) else { return false }
            hit = currentItems[cell].id
            center = CGPoint(x: frame.minX + c.x, y: frame.minY + c.y)
        }
        guard let hit, let item = grid.item(hit) else { return false }
        let ids = targets(for: hit)
        drag.ids = ids
        drag.primary = item
        drag.source = source
        drag.location = start
        drag.grabOffset = CGSize(width: center.x - start.x, height: center.y - start.y)
        drag.edgeSide = 0
        drag.candidate = nil
        drag.mergeTarget = nil
        // The gap starts where the primary item was, among the remaining items.
        let siblings: [UUID] = openFolder.map { $0.apps.map(\.id) } ?? currentItems.map(\.id)
        let before = siblings.prefix { $0 != hit }.filter { !ids.contains($0) }.count
        drag.gap = before
        withAnimation(Self.dragMotion(.spring(response: 0.25, dampingFraction: 0.8))) { drag.active = true }
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
        let p = drag.iconCenter
        if case .folder = drag.source, openFolder != nil {
            if drag.folderPanelFrame.insetBy(dx: -12, dy: -12).contains(p) {
                updateFolderGap(p)
                return
            }
            // Dragged out of the folder: close it and continue on the page.
            closeFolder()
            drag.gap = nil
            drag.pendingGap = nil
            drag.edgeSide = 0
        }
        updatePageTargets(p)
    }

    private func updateFolderGap(_ p: CGPoint) {
        let frame = drag.folderGridFrame
        // Holding at the side of a folder with several pages flips its pages. The zone is
        // narrow and extends past the grid into the panel's margin.
        let edge = min(36, frame.width * 0.05)
        let side = p.x < frame.minX + edge ? -1 : (p.x > frame.maxX - edge ? 1 : 0)
        if side != drag.edgeSide {
            drag.edgeSide = side
            drag.edgeSince = Date()
        }
        let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        guard let cell = folderLayout.cellIndex(at: local) else { return }
        let index = min(folderPage * FolderLayout.perPage(grid) + cell, remainingFolderApps().count)
        if index != drag.gap {
            withAnimation(Self.dragMotion(.spring(response: 0.3, dampingFraction: 0.8))) { drag.gap = index }
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
        guard let cell = pageLayout.cellIndex(at: local) else {
            drag.candidate = nil
            if drag.mergeTarget != nil { withAnimation(.easeOut(duration: 0.15)) { drag.mergeTarget = nil } }
            return
        }
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
            withAnimation(Self.dragMotion(.spring(response: 0.3, dampingFraction: 0.8))) { drag.gap = g }
        }
        if let c = drag.candidate, drag.mergeTarget != c, now.timeIntervalSince(drag.candidateSince) > Self.mergeDwell {
            withAnimation(Self.dragMotion(.spring(response: 0.25, dampingFraction: 0.7))) { drag.mergeTarget = c }
        }
        guard drag.edgeSide != 0 else { return }
        // An icon in the edge column reaches into the edge zone: while the pointer rests on
        // one to merge, the edge dwell waits and starts over once it moves off.
        if drag.candidate != nil || drag.mergeTarget != nil {
            drag.edgeSince = now
            return
        }
        if let folder = openFolder {
            guard case .folder(folder.id) = drag.source, now.timeIntervalSince(drag.edgeSince) > Self.edgeDwell else { return }
            drag.edgeSince = now
            let pages = FolderLayout.pageCount(apps: folder.apps.count, grid: grid)
            let target = folderPage + drag.edgeSide
            guard target >= 0, target < pages else { return }
            withAnimation(Self.pageAnimation) { folderPage = target }
            // The gap follows the pointer onto the new page.
            drag.pendingGap = nil
            updateFolderGap(drag.iconCenter)
            return
        }
        if now.timeIntervalSince(drag.edgeSince) > Self.edgeDwell {
            drag.edgeSince = now
            let target = currentPage + drag.edgeSide
            // Past the last page there is one empty page to drop onto.
            let last = grid.pages.count - (remainingItems(page: grid.pages.count - 1).isEmpty ? 1 : 0)
            guard target >= 0, target <= last else { return }
            drag.candidate = nil
            drag.mergeTarget = nil
            withAnimation(Self.pageAnimation) {
                currentPage = target
                drag.gap = nil
                drag.pendingGap = nil
            }
        }
    }

    /// ⌘1…9 during a drag: show another page; the gap is found again there.
    func dragGoToPage(_ p: Int) {
        guard drag.active, openFolder == nil else { return }
        drag.candidate = nil
        drag.mergeTarget = nil
        drag.pendingGap = nil
        drag.gap = nil
        goToPage(p)
    }

    private func drop() {
        let ids = drag.ids
        let page = currentPage
        // Emptying the source page removes it, which shifts later pages; follow the target by ID.
        let pageID = grid.pages.indices.contains(page) ? grid.pages[page].id : nil
        if let target = drag.mergeTarget, let targetItem = grid.item(target) {
            switch targetItem {
            case .folder(let f):
                apply { g in g.removingEmptiedPages { $0.addToFolder(ids, folder: f.id) } }
                showToast(String(localized: "Added to \(f.name)"))
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
        // Stay on the page dropped onto. A drop on the extra empty page created a new one;
        // find it through the dropped item.
        if let pageID, let i = grid.pages.firstIndex(where: { $0.id == pageID }) {
            currentPage = i
        } else if let first = ids.first, let loc = grid.locate(first) {
            currentPage = loc.page
        }
        currentPage = min(currentPage, grid.pages.count - 1)
    }
}
