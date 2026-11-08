import AppKit
import SwiftUI
import LaunchGridCore

// Files dragged onto the grid open with the app they're dropped on; a tile ⌥-dragged off the
// grid goes where it's dropped (the Dock, a Finder window, another app).

/// Files being dragged over the grid, from Finder or another app.
struct FileDrag: Equatable {
    var urls: [URL]
    /// The apps (by path) that say they open every one of them: their tiles light up, the
    /// rest dim.
    var openers: Set<String>
    /// The tile under the pointer, if any.
    var target: UUID?
}

extension AppState {
    /// How long a dragged file rests on a folder before it opens, or at a page's edge before
    /// the page turns, as when dragging a tile.
    static let springDwell: TimeInterval = 0.6

    /// Files began to be dragged over the grid.
    func beginFileDrag(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // Off the main thread would be nicer, but Launch Services answers this from memory.
        let sets = urls.map { url in Set(NSWorkspace.shared.urlsForApplications(toOpen: url).map(\.path)) }
        let openers = sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) }
        fileDrag = FileDrag(urls: urls, openers: openers, target: nil)
        peekFolderID = nil
        fileDwell = nil
    }

    /// Whether the files being dragged can be dropped on `app`.
    func canOpenDraggedFiles(with app: AppRef) -> Bool {
        fileDrag?.openers.contains(app.path) ?? false
    }

    /// The dragged files moved to `p`, in root coordinates. Returns whether a drop there would
    /// open them. Resting on a folder opens it; outside an open folder, closes it; at a page's
    /// side, turns the page.
    @discardableResult
    func fileDragMoved(to p: CGPoint) -> Bool {
        guard var drag = fileDrag else { return false }
        let hit = fileDropItem(at: p)
        drag.target = hit?.id
        if drag != fileDrag { fileDrag = drag }
        // What a rest here would do, and since when it has rested there.
        let spring: FileDwell.Spot? = {
            if let hit, case .folder(let f) = hit, openFolderID == nil { return .folder(f.id) }
            if openFolderID != nil, !self.drag.folderPanelFrame.contains(p) { return .outsideFolder }
            guard openFolderID == nil, query.isEmpty else { return nil }
            let frame = self.drag.pagerFrame
            let edge = min(60, frame.width * 0.05)
            if p.x < frame.minX + edge, currentPage > 0 { return .edge(-1) }
            if p.x > frame.maxX - edge, currentPage < grid.pages.count - 1 { return .edge(1) }
            return nil
        }()
        if fileDwell?.spot != spring { fileDwell = spring.map { FileDwell(spot: $0, since: Date()) } }
        if let dwell = fileDwell, Date().timeIntervalSince(dwell.since) >= Self.springDwell {
            switch dwell.spot {
            case .folder(let id): openFolder(id)
            case .outsideFolder: closeFolder()
            case .edge(let side): withAnimationIfShown { goToPage(currentPage + side) }
            }
            Haptics.perform(.generic)
            // Again after another rest, for the next page along.
            fileDwell = FileDwell(spot: dwell.spot, since: Date())
            if case .folder = dwell.spot { fileDwell = nil }
        }
        if case .app(let app) = hit { return canOpenDraggedFiles(with: app) }
        return false
    }

    /// The files were dropped at `p`. Returns whether they were opened.
    @discardableResult
    func dropFiles(at p: CGPoint) -> Bool {
        defer { endFileDrag() }
        guard let drag = fileDrag, case .app(let app)? = fileDropItem(at: p), canOpenDraggedFiles(with: app) else { return false }
        let urls = drag.urls
        recordUse(.app(app))
        noteTip(.dropFile)
        if isNew(app) { prefs.newAppPaths.remove(app.path) }
        let hides = prefs.hideAfterLaunch
        showOpening(app.id, hides: hides)
        if hides { onHideForLaunch() }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = hides
        NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: app.path), configuration: config) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, !Launcher.isUserCancel(error) else { return }
                let title = String(localized: "Could not open the files with \(app.title)")
                if self.isShown { self.showToast("\(title): \(error.localizedDescription)") } else { self.onError(title, error.localizedDescription) }
            }
        }
        return true
    }

    /// The files left the grid, or were dropped.
    func endFileDrag() {
        fileDrag = nil
        fileDwell = nil
    }

    /// The tile under `p` (root coordinates): on the page shown, or in the open folder.
    func fileDropItem(at p: CGPoint) -> GridItem? {
        guard query.isEmpty else {
            // Over search results: the result under the pointer.
            let frame = drag.pagerFrame
            let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
            guard frame.contains(p), let i = searchLayout.index(at: local) else { return nil }
            return searchResults[safe: i]?.item
        }
        if let folder = openFolder {
            let frame = drag.folderGridFrame
            let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
            guard frame.contains(p), let cell = folderLayout.cellIndex(at: local) else { return nil }
            return folder.items[safe: folderPage * FolderLayout.perPage(grid) + cell]?.gridItem
        }
        let frame = drag.pagerFrame
        let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        guard frame.contains(p), let cell = pageLayout.cellIndex(at: local) else { return nil }
        return currentItems[safe: cell]
    }
}

/// A rest during a file drag that does something once it's long enough.
struct FileDwell: Equatable {
    enum Spot: Equatable {
        case folder(UUID)
        case outsideFolder
        case edge(Int)
    }
    var spot: Spot
    var since: Date
}

/// A tile while files are dragged over the grid: an app that opens them stands out, lifting
/// under the pointer; anything else fades back.
struct FileDragLook: ViewModifier {
    let item: GridItem
    @Environment(AppState.self) private var state
    @Environment(\.reduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let drag = state.fileDrag
        let opens: Bool = if case .app(let app) = item { state.canOpenDraggedFiles(with: app) } else { false }
        let folder = item.folder != nil
        let targeted = drag?.target == item.id
        content
            .background {
                if targeted && opens {
                    RoundedRectangle(cornerRadius: 14)
                        .fill((item.hoverTint ?? .white).opacity(0.35))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.7), lineWidth: 2))
                        .transition(.opacity)
                }
            }
            .scaleEffect(drag != nil && targeted && (opens || folder) && !reduceMotion ? 1.12 : 1)
            // Folders stay as they are: the files can be taken into one.
            .opacity(drag == nil || opens || folder ? 1 : 0.3)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: targeted)
            .animation(.easeOut(duration: 0.2), value: drag == nil)
    }
}

/// The view under the grid's SwiftUI content that files are dropped on.
final class DropContainerView: NSView {
    weak var controller: OverlayController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Our own tile dragged out and back over the grid: not a file to open here.
        if sender.draggingSource is OverlayController { return [] }
        let urls = urls(sender)
        guard !urls.isEmpty, let controller else { return [] }
        return controller.fileDragEntered(urls, at: sender.draggingLocation) ? .copy : .generic
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let controller, sender.draggingSource as? OverlayController == nil else { return [] }
        return controller.fileDragMoved(to: sender.draggingLocation) ? .copy : .generic
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.fileDragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.dropFiles(at: sender.draggingLocation) ?? false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.fileDragExited()
    }
}
