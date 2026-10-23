import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import LaunchGridCore

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the overlay window: showing, hiding, placement, keyboard and scroll input.
@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private let state: AppState
    private var panel: OverlayPanel?
    private var panelMode: WindowMode?
    private var host: NSHostingView<AnyView>?
    /// First responder while the panel is up, so input methods compose into the search.
    private let textInput = SearchInputView()
    private var monitors: [Any] = []
    /// The display the panel and its background belong to.
    private(set) var screen: NSScreen?
    private var scrollAccumulator: CGFloat = 0
    private var lastWheelFlip = Date.distantPast
    /// Bumped by every show and hide, so a fade-out that was overtaken doesn't order the panel out.
    private var visibilityGeneration = 0
    /// The folder (and its page) that was open when typing started a search; Esc returns to it.
    private var folderBeforeSearch: (id: UUID, page: Int)?

    var isVisible: Bool { panel?.isVisible == true && state.isShown }
    var window: NSWindow? { panel }

    init(state: AppState) {
        self.state = state
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isVisible == true { self?.hide() } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placePanel() }
        }
        installMonitors()
        textInput.onInsert = { [weak self] in self?.insertIntoSearch($0) }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let panel = makePanelIfNeeded()
        placePanel()
        state.focusIndex = nil
        visibilityGeneration += 1
        // A fade-out still running would otherwise carry on to 0 after this; replace it.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textInput)
        state.didShow()
    }

    func hide(deactivate: Bool = true) {
        guard let panel, panel.isVisible else { return }
        textInput.discardComposition()
        state.isShown = false
        state.saveNow()
        visibilityGeneration += 1
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == generation, !self.state.isShown else { return }
                panel.orderOut(nil)
                self.state.didHide()
                // Hand focus back to the previous app unless another of our windows is up.
                let others = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.level == .normal && !($0 is NSPanel) }
                if deactivate && NSApp.isActive && !others { NSApp.hide(nil) }
            }
        })
    }

    /// Recreates the panel if the window mode changed.
    func modeChanged() {
        let wasVisible = isVisible
        panel?.orderOut(nil)
        panel = nil
        if wasVisible { show() }
    }

    private func makePanelIfNeeded() -> OverlayPanel {
        let mode = state.prefs.windowMode
        if let panel, panelMode == mode { return panel }
        panel?.orderOut(nil)
        // Non-activating: the panel takes keyboard focus without activating the app, the way
        // launchers do. Activation from a hotkey isn't guaranteed under cooperative activation.
        let style: NSWindow.StyleMask = mode == .window
            ? [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]
            : [.borderless, .fullSizeContentView, .nonactivatingPanel]
        let p = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: style,
                             backing: .buffered, defer: false)
        p.isFloatingPanel = mode != .window
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = false
        p.isOpaque = false
        // The SwiftUI content is always dark; menus and visual-effect views follow the window.
        p.appearance = NSAppearance(named: .darkAqua)
        p.backgroundColor = .clear
        p.hasShadow = mode == .window
        p.isReleasedWhenClosed = false
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.level = switch mode {
        case .fullScreen: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        case .behindDock: .floating
        case .window: .floating
        }
        p.minSize = NSSize(width: 480, height: 360)
        p.delegate = self
        let root = GridRootView()
            .environment(state)
            .environment(\.screenID, screen?.displayID ?? 0)
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        // The text input view sits beside the SwiftUI content, out of sight.
        let container = NSView()
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.addSubview(textInput)
        p.contentView = container
        self.host = host
        if mode == .window {
            p.contentView?.wantsLayer = true
            p.contentView?.layer?.cornerRadius = 12
            p.contentView?.layer?.masksToBounds = true
        }
        panel = p
        panelMode = mode
        return p
    }

    private func placePanel() {
        // After a display change the remembered screen may be gone (or a new object for the
        // same display); match it by ID and fall back to the main screen.
        let id = screen?.displayID
        screen = NSScreen.screens.first { $0.displayID == id } ?? NSScreen.main
        guard let panel, let screen else { return }
        showBackground(for: screen)
        switch state.prefs.windowMode {
        case .fullScreen:
            panel.setFrame(screen.frame, display: true)
        case .behindDock:
            panel.setFrame(screen.visibleFrame, display: true)
        case .window:
            let v = screen.visibleFrame
            if let saved = savedFrame(for: screen) {
                var r = NSRectFromString(saved)
                if v.intersects(r) {
                    // Pulled fully onto the screen (the Dock or a resolution may have changed
                    // since), no smaller than the minimum size.
                    r.size.width = max(panel.minSize.width, min(r.width, v.width))
                    r.size.height = max(panel.minSize.height, min(r.height, v.height))
                    r.origin.x = max(v.minX, min(r.minX, v.maxX - r.width))
                    r.origin.y = max(v.minY, min(r.minY, v.maxY - r.height))
                    panel.setFrame(r, display: true)
                    return
                }
            }
            let size = NSSize(width: v.width * 0.7, height: v.height * 0.75)
            panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height),
                           display: true)
        }
    }

    /// Points the background (blurred desktop or wallpaper) at `screen`.
    private func showBackground(for screen: NSScreen) {
        if let host {
            host.rootView = AnyView(GridRootView().environment(state).environment(\.screenID, screen.displayID))
        }
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) { saveWindowFrame() }
    func windowDidMove(_ notification: Notification) { saveWindowFrame() }

    /// A window dragged to another display takes that display's background with it.
    func windowDidChangeScreen(_ notification: Notification) {
        guard let current = panel?.screen, current.displayID != screen?.displayID else { return }
        screen = current
        showBackground(for: current)
    }

    /// Clicking another app, or our own Settings, takes key status away: hide like Launchpad.
    /// A rename in progress is cancelled, unless the panel was only briefly not key.
    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        guard state.textEdit != nil else {
            hide(deactivate: false)
            return
        }
        DispatchQueue.main.async { [self] in
            guard isVisible, panel?.isKeyWindow == false else { return }
            state.textEdit = nil
            hide(deactivate: false)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    private func saveWindowFrame() {
        guard state.prefs.windowMode == .window, let panel, panel.isVisible, let screen = panel.screen else { return }
        var frames = state.prefs.windowFrames
        frames[screen.frameKey] = NSStringFromRect(panel.frame)
        Self.prune(&frames)
        if frames != state.prefs.windowFrames { state.prefs.windowFrames = frames }
    }

    /// The frame saved for a display. One saved under the old name-and-number key, which
    /// changed whenever the display reconnected, moves to the stable key the first time.
    private func savedFrame(for screen: NSScreen) -> String? {
        var frames = state.prefs.windowFrames
        if let saved = frames[screen.frameKey] { return saved }
        guard let old = frames.removeValue(forKey: screen.legacyFrameKey) else { return nil }
        frames[screen.frameKey] = old
        state.prefs.windowFrames = frames
        return old
    }

    static let maxSavedFrames = 12

    /// Old-format keys of connected displays are superseded. Past the cap, keys of displays
    /// not connected now go, old-format ones first.
    private static func prune(_ frames: inout [String: String]) {
        let screens = NSScreen.screens
        for s in screens where s.frameKey != s.legacyFrameKey && frames[s.frameKey] != nil { frames[s.legacyFrameKey] = nil }
        guard frames.count > maxSavedFrames else { return }
        let connected = Set(screens.map(\.frameKey))
        let stale = frames.keys.filter { !connected.contains($0) }
            .sorted { !NSScreen.isStableFrameKey($0) && NSScreen.isStableFrameKey($1) }
        for key in stale.prefix(frames.count - maxSavedFrames) { frames[key] = nil }
    }

    // MARK: Input

    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) == nil }
            return consumed ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleScroll(event) == nil }
            return consumed ? nil : event
        } as Any)
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window === panel, isVisible else { return event }
        // Let the inline text editor have its keys.
        if state.textEdit != nil {
            if Int(event.keyCode) == kVK_Escape { state.textEdit = nil; return nil }
            return event
        }
        // While an input method composes, it has every key (Return commits, Esc cancels).
        if textInput.hasMarkedText(), textInput.handle(event) { return nil }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        let cmd = mods.contains(.command)
        // Mid-drag, only Esc (cancel) and ⌘1…9 (carry the items to a page) do anything.
        if state.drag.active && code != kVK_Escape {
            if cmd, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
                state.dragGoToPage(digit - 1)
            }
            return nil
        }

        switch code {
        case kVK_Escape:
            if state.drag.active { state.cancelDrag() }
            else if !state.query.isEmpty { endSearch() }
            else if state.openFolder != nil { state.closeFolder(restoringFocus: true) }
            else if state.editing { state.editing = false }
            else if !state.selection.isEmpty { state.selection.removeAll() }
            else { hide() }
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mods == .control {
                showFocusedMenu()
            } else if mods == [.control, .shift] {
                showPageMenu()
            } else if state.editing && state.query.isEmpty {
                // Edit mode renames: the focused item, else the open folder.
                if let id = focusedID ?? state.openFolderID { state.beginRename(id) }
            } else {
                activateFocused()
            }
            return nil
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            let horizontal = code == kVK_LeftArrow || code == kVK_RightArrow
            if horizontal && !state.query.isEmpty && (cmd || mods.contains(.option)) {
                // In the search, ⌥←/→ move the caret by word and ⌘←/→ to either end.
                let left = code == kVK_LeftArrow
                editSearch {
                    if cmd { left ? $0.moveToStart() : $0.moveToEnd() }
                    else { left ? $0.moveWordLeft() : $0.moveWordRight() }
                }
            } else if cmd && horizontal {
                state.flipPage(code == kVK_LeftArrow ? -1 : 1)
            } else if mods.contains(.option) && state.editing && state.query.isEmpty && state.focusIndex != nil {
                moveFocusedItem(code)
            } else {
                moveFocus(code)
            }
            return nil
        case kVK_Delete, kVK_ForwardDelete:
            if !state.query.isEmpty {
                let back = code == kVK_Delete
                editSearch {
                    if cmd { back ? $0.deleteToStart() : $0.deleteToEnd() }
                    else if mods.contains(.option) { back ? $0.deleteWordBackward() : $0.deleteWordForward() }
                    else { back ? $0.deleteBackward() : $0.deleteForward() }
                }
            } else if event.isARepeat {
                // Holding ⌫ only edits the search; removing is one press at a time.
            } else if !state.selection.isEmpty {
                state.remove(state.orderedSelection)
            } else if state.editing, let id = focusedID {
                state.remove([id])
                // Stay on the item that took its place (the folder may have gone with it).
                let count = focusableCount
                state.focusIndex = count > 0 ? state.focusIndex.map { min($0, count - 1) } : nil
            }
            return nil
        case kVK_Tab:
            // Pages are hidden behind search results; don't turn them unseen.
            if state.query.isEmpty { state.flipPage(mods.contains(.shift) ? -1 : 1) }
            return nil
        default:
            break
        }

        if cmd {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch key {
            case "z": mods.contains(.shift) ? state.redo() : state.undo()
            case "e": state.editing.toggle()
            // Search results hide the page; selecting it unseen would let ⌫ remove it.
            case "a": if state.query.isEmpty { selectAll() }
            case "f": state.query = ""
            case "g": state.groupSelection()
            case "n": state.newPage()
            case ",": state.onOpenSettings()
            case "w": hide()
            case "q": NSApp.terminate(nil)
            case "v":
                if let s = NSPasteboard.general.string(forType: .string) {
                    insertIntoSearch(TextLine.singleLine(s))
                }
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                state.query = ""
                if state.openFolder != nil { state.closeFolder() }
                state.goToPage(Int(key)! - 1)
            default:
                return event
            }
            return nil
        }

        if mods.contains(.control) {
            guard !state.query.isEmpty else { return event }
            // The Emacs keys every macOS text field takes.
            switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
            case "a": editSearch { $0.moveToStart() }
            case "e": editSearch { $0.moveToEnd() }
            case "b": editSearch { $0.moveLeft() }
            case "f": editSearch { $0.moveRight() }
            case "h": editSearch { $0.deleteBackward() }
            case "d": editSearch { $0.deleteForward() }
            case "w": editSearch { $0.deleteWordBackward() }
            case "u": editSearch { $0.deleteToStart() }
            case "k": editSearch { $0.deleteToEnd() }
            default: return event
            }
            return nil
        }
        if state.query.isEmpty && event.characters == " " {
            // Space selects (or deselects) the focused item.
            if !event.isARepeat, let id = focusedID { state.toggleSelection(id) }
            return nil
        }
        // Text goes through the input context, so dead keys and input methods compose;
        // what it commits arrives in `insertIntoSearch`.
        if panel.firstResponder !== textInput { panel.makeFirstResponder(textInput) }
        textInput.handle(event)
        return nil
    }

    /// The item with keyboard focus on the page or in the open folder (not search results).
    private var focusedID: UUID? {
        guard state.query.isEmpty, let i = state.focusIndex else { return nil }
        if let f = state.openFolder { return f.apps[safe: i]?.id }
        return state.currentItems[safe: i]?.id
    }

    /// Types into the search at its caret. Starting one closes an open folder, remembering it
    /// for `endSearch()`.
    private func insertIntoSearch(_ text: String) {
        guard !text.isEmpty else { return }
        if state.query.isEmpty {
            folderBeforeSearch = state.openFolderID.map { ($0, state.folderPage) }
            state.openFolderID = nil
        }
        state.searchLine.insert(text)
    }

    /// Edits the search at its caret; emptying it ends the search.
    private func editSearch(_ edit: (inout TextLine) -> Void) {
        var line = state.searchLine
        edit(&line)
        if line.text.isEmpty { endSearch() } else { state.searchLine = line }
    }

    /// Clears the search from the keyboard, back to the folder it was started in, if still there.
    private func endSearch() {
        state.query = ""
        guard let folder = folderBeforeSearch else { return }
        folderBeforeSearch = nil
        guard state.grid.folder(folder.id) != nil else { return }
        state.openFolder(folder.id)
        let pages = FolderLayout.pageCount(apps: state.openFolder?.apps.count ?? 0, grid: state.grid)
        state.folderPage = min(folder.page, pages - 1)
    }

    private var focusableCount: Int {
        if !state.query.isEmpty { return state.searchResults.count }
        if let f = state.openFolder { return f.apps.count }
        return state.currentItems.count
    }

    private func moveFocus(_ code: Int) {
        let count = focusableCount
        let cols = state.grid.columns
        guard count > 0 else {
            // Pages are hidden behind search results, even when there are none.
            guard state.query.isEmpty else { return }
            if code == kVK_LeftArrow { state.flipPage(-1) }
            if code == kVK_RightArrow { state.flipPage(1) }
            return
        }
        guard let i = state.focusIndex else {
            // First arrow press: ←/→ flip pages, ↑/↓ start focusing.
            switch code {
            case kVK_LeftArrow where state.query.isEmpty && state.openFolder == nil: state.flipPage(-1)
            case kVK_RightArrow where state.query.isEmpty && state.openFolder == nil: state.flipPage(1)
            default: state.focusIndex = 0
            }
            if state.openFolder != nil {
                // Start on the folder page being shown.
                state.focusIndex = min(state.folderPage * FolderLayout.perPage(state.grid), count - 1)
            }
            return
        }
        var next = i
        switch code {
        case kVK_LeftArrow: next = i - 1
        case kVK_RightArrow: next = i + 1
        case kVK_UpArrow: next = i - cols
        case kVK_DownArrow: next = i + cols
        default: break
        }
        let paging = state.query.isEmpty && state.openFolder == nil
        if paging && (next < 0 || next >= count) && (code == kVK_LeftArrow || code == kVK_RightArrow) {
            let before = state.currentPage
            state.flipPage(code == kVK_LeftArrow ? -1 : 1)
            if state.currentPage != before {
                state.focusIndex = code == kVK_LeftArrow ? max(0, state.currentItems.count - 1) : 0
            }
            return
        }
        if code == kVK_UpArrow || code == kVK_DownArrow {
            // Past the top or bottom row, stay put. ↓ from a row above a short last row
            // lands on the last item.
            if next < 0 || (next >= count && i / cols == (count - 1) / cols) { return }
        }
        state.focusIndex = max(0, min(next, count - 1))
        if state.openFolder != nil, let f = state.focusIndex {
            // Keep the focused app on screen in a folder with several pages.
            let page = f / FolderLayout.perPage(state.grid)
            if page != state.folderPage { state.flipPage(page - state.folderPage) }
        }
    }

    /// ⌥ + arrow in edit mode: moves the focused item one slot, together with the rest of the
    /// selection when it's part of one. ←/→ past either end of a page carry it onto the
    /// neighbouring page (a new one after the last); in an open folder it stays in the folder.
    private func moveFocusedItem(_ code: Int) {
        guard let i = state.focusIndex, let id = focusedID else { return }
        let folder = state.openFolder
        let pool = folder?.apps.map(\.id) ?? state.currentItems.map(\.id)
        // Selected items elsewhere stay put: only the ones here move, in their order.
        let ids = state.targets(for: id).filter(pool.contains)
        let lead = ids.firstIndex(of: id) ?? 0
        let rest = pool.count - ids.count
        let cols = state.grid.columns
        let horizontal = code == kVK_LeftArrow || code == kVK_RightArrow
        let step = switch code {
        case kVK_LeftArrow: -1
        case kVK_RightArrow: 1
        case kVK_UpArrow: -cols
        default: cols
        }
        // Where the moved items start among the others, so the focused one lands a step on.
        var at = i - lead + step
        // ↓ from a row above a short last row goes to the end, as plain ↓ moves focus there.
        if code == kVK_DownArrow, at > rest, i / cols < (pool.count - 1) / cols { at = rest }
        if let folder {
            guard at >= 0, at <= rest else { return }
            state.apply { $0.addToFolder(ids, folder: folder.id, at: at) }
        } else if at >= 0, at <= rest {
            let page = state.currentPage
            state.apply { $0.move(ids, toPage: page, at: at) }
        } else if horizontal {
            let page = state.currentPage + step
            // Nothing before the first page; a new page after the last only if one is left behind.
            guard page >= 0, page < state.grid.pages.count || rest > 0 else { return }
            state.apply { g in
                if page >= g.pages.count { g.addPage() }
                let end = g.pages[page].items.count
                g.removingEmptiedPages { $0.move(ids, toPage: page, at: step < 0 ? end : 0) }
            }
        } else {
            return // past the top or bottom row
        }
        // Follow the focused item wherever it went, spills and emptied pages included.
        guard let loc = state.grid.locate(id) else { return }
        if let fi = loc.folderIndex {
            state.focusIndex = fi
            let page = fi / FolderLayout.perPage(state.grid)
            if page != state.folderPage { state.flipPage(page - state.folderPage) }
        } else {
            state.goToPage(loc.page)
            state.focusIndex = loc.index
        }
    }

    /// ⌃Return: the focused item's context menu, as a right-click on it would show; with
    /// nothing focused, the page menu.
    private func showFocusedMenu() {
        guard let i = state.focusIndex else { return showPageMenu() }
        let item: GridItem
        let center: CGPoint
        if !state.query.isEmpty {
            guard let app = state.searchResults[safe: i] else { return }
            item = .app(app)
            let c = state.pageLayout.center(i), f = state.drag.pagerFrame
            center = CGPoint(x: f.minX + c.x, y: f.minY + c.y)
        } else if let folder = state.openFolder {
            guard let app = folder.apps[safe: i] else { return }
            item = .app(app)
            let c = state.folderLayout.center(i - state.folderPage * FolderLayout.perPage(state.grid))
            let f = state.drag.folderGridFrame
            center = CGPoint(x: f.minX + c.x, y: f.minY + c.y)
        } else {
            guard let found = state.currentItems[safe: i] else { return }
            item = found
            let c = state.pageLayout.center(i), f = state.drag.pagerFrame
            center = CGPoint(x: f.minX + c.x, y: f.minY + c.y)
        }
        popUp(MenuEntry.item(item, state: state), at: center)
    }

    /// ⇧⌃Return: the ⋯ menu, under its button.
    func showPageMenu() {
        let b = state.drag.menuButtonFrame
        popUp(MenuEntry.page(state: state), at: CGPoint(x: b.minX, y: b.maxY + 4))
    }

    /// Shows a menu at `point`, in root coordinates.
    private func popUp(_ entries: [MenuEntry], at point: CGPoint) {
        guard let host else { return }
        // Root coordinates run from the top left; the hosting view's may not.
        let local = host.isFlipped ? point : NSPoint(x: point.x, y: host.bounds.height - point.y)
        MenuEntry.nsMenu(entries).popUp(positioning: nil, at: local, in: host)
    }

    private func activateFocused() {
        if !state.query.isEmpty {
            let results = state.searchResults
            if let app = results[safe: state.focusIndex ?? 0] { state.launch(app) }
            return
        }
        guard let i = state.focusIndex else { return }
        if let f = state.openFolder {
            if let app = f.apps[safe: i] { state.launch(app) }
        } else if let item = state.currentItems[safe: i] {
            state.activate(item)
        }
    }

    private func selectAll() {
        state.editing = true
        if let f = state.openFolder {
            state.selection = Set(f.apps.map(\.id))
        } else {
            state.selection = Set(state.currentItems.map(\.id))
        }
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window === panel, isVisible, !state.drag.active else { return event }
        guard state.query.isEmpty else { return nil }
        let width = max(state.drag.pagerFrame.width, 1)
        if !event.phase.isEmpty || !event.momentumPhase.isEmpty {
            // Trackpad: the pager follows the fingers, then snaps.
            if !event.momentumPhase.isEmpty { return nil }
            if event.phase.contains(.began) { scrollAccumulator = 0 }
            let dx = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : 0
            scrollAccumulator += dx
            if state.openFolder == nil {
                state.swipeOffset = max(-width * 0.6, min(width * 0.6, scrollAccumulator))
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                let threshold = min(120, width * 0.12)
                withAnimation(AppState.pageAnimation) {
                    if scrollAccumulator < -threshold { state.flipPage(1) }
                    else if scrollAccumulator > threshold { state.flipPage(-1) }
                    state.swipeOffset = 0
                }
                scrollAccumulator = 0
            }
            return nil
        }
        // Mouse wheel: one page per notch burst.
        let delta = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        guard abs(delta) > 0.5, Date().timeIntervalSince(lastWheelFlip) > 0.35 else { return nil }
        lastWheelFlip = Date()
        state.flipPage(delta < 0 ? 1 : -1)
        return nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Holds what an input method is composing in the search, for the search field to show.
@MainActor @Observable
final class SearchComposition {
    static let shared = SearchComposition()
    var marked = ""
    /// The search field's frame in the overlay's root coordinates, for the candidate window.
    @ObservationIgnored var fieldFrame: CGRect = .zero
}

/// An invisible text input client for the search. Keys reach it from the overlay's key
/// monitor through `handle(_:)`, so dead keys and input methods (CJK) compose: marked text
/// is shown in the search field and committed text goes to `onInsert`. Its document is only
/// the marked text, since the search keeps its own text and caret.
@MainActor
final class SearchInputView: NSView, @preconcurrency NSTextInputClient {
    var onInsert: (String) -> Void = { _ in }
    private var markedSelection = NSRange(location: 0, length: 0)
    private var composition: SearchComposition { .shared }

    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    /// Interprets a key as text, through the input context. Returns whether it took the key.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        if let context = inputContext, context.handleEvent(event) { return true }
        return false
    }

    /// Drops a composition in progress, without inserting it.
    func discardComposition() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        composition.marked = ""
    }

    private static func plain(_ string: Any) -> String {
        (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        composition.marked = ""
        let text = Self.plain(string)
        // Function keys and other control characters aren't text.
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .privateUse
        }) else { return }
        onInsert(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        composition.marked = Self.plain(string)
        markedSelection = selectedRange
    }

    func unmarkText() {
        let text = composition.marked
        composition.marked = ""
        if !text.isEmpty { onInsert(text) }
    }

    func hasMarkedText() -> Bool { !composition.marked.isEmpty }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: (composition.marked as NSString).length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let text = composition.marked as NSString
        let r = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard r.length > 0 else { return nil }
        actualRange?.pointee = r
        return NSAttributedString(string: text.substring(with: r))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Below the search field, where the candidate window belongs.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window, let content = window.contentView else { return .zero }
        let f = composition.fieldFrame
        let bottomLeft = content.isFlipped ? NSPoint(x: f.minX, y: f.maxY) : NSPoint(x: f.minX, y: content.bounds.height - f.maxY)
        let inWindow = content.convert(bottomLeft, to: nil)
        return window.convertToScreen(NSRect(x: inWindow.x, y: inWindow.y, width: f.width, height: f.height))
    }

    /// Editing commands (arrows, Return) are the key monitor's; nothing to do here.
    override func doCommand(by selector: Selector) {}
}
