import AppKit
import Carbon.HIToolbox
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
    private var monitors: [Any] = []
    private var screen: NSScreen?
    private var scrollAccumulator: CGFloat = 0
    private var lastWheelFlip = Date.distantPast
    private var swipeFlipped = false

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
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        state.didShow()
    }

    func hide(deactivate: Bool = true) {
        guard let panel, panel.isVisible else { return }
        state.isShown = false
        state.saveNow()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.state.isShown else { return }
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
        p.contentView = host
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
        if let host = panel.contentView as? NSHostingView<AnyView> {
            host.rootView = AnyView(GridRootView().environment(state).environment(\.screenID, screen.displayID))
        }
        switch state.prefs.windowMode {
        case .fullScreen:
            panel.setFrame(screen.frame, display: true)
        case .behindDock:
            panel.setFrame(screen.visibleFrame, display: true)
        case .window:
            if let saved = savedFrame(for: screen) {
                let r = NSRectFromString(saved)
                if screen.visibleFrame.intersects(r) {
                    panel.setFrame(r, display: true)
                    return
                }
            }
            let v = screen.visibleFrame
            let size = NSSize(width: v.width * 0.7, height: v.height * 0.75)
            panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height),
                           display: true)
        }
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) { saveWindowFrame() }
    func windowDidMove(_ notification: Notification) { saveWindowFrame() }

    /// Clicking another app, or our own Settings, takes key status away: hide like Launchpad.
    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, state.textEdit == nil else { return }
        hide(deactivate: false)
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
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        let cmd = mods.contains(.command)

        switch code {
        case kVK_Escape:
            if state.drag.active { state.cancelDrag() }
            else if !state.query.isEmpty { state.query = "" }
            else if state.openFolder != nil { state.closeFolder(restoringFocus: true) }
            else if state.editing { state.editing = false }
            else if !state.selection.isEmpty { state.selection.removeAll() }
            else { hide() }
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if state.editing && state.query.isEmpty {
                // Edit mode renames: the focused item, else the open folder.
                if let id = focusedID ?? state.openFolderID { state.beginRename(id) }
            } else {
                activateFocused()
            }
            return nil
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            if cmd && (code == kVK_LeftArrow || code == kVK_RightArrow) {
                state.flipPage(code == kVK_LeftArrow ? -1 : 1)
            } else {
                moveFocus(code)
            }
            return nil
        case kVK_Delete, kVK_ForwardDelete:
            if !state.query.isEmpty {
                if cmd { state.query = "" } else { state.query.removeLast() }
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
            state.flipPage(mods.contains(.shift) ? -1 : 1)
            return nil
        default:
            break
        }

        if cmd {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch key {
            case "z": mods.contains(.shift) ? state.redo() : state.undo()
            case "e": state.editing.toggle()
            case "a": selectAll()
            case "f": state.query = ""
            case "g": state.groupSelection()
            case "n": state.newPage()
            case ",": state.onOpenSettings()
            case "w": hide()
            case "q": NSApp.terminate(nil)
            case "v":
                if let s = NSPasteboard.general.string(forType: .string) {
                    state.query += s.replacingOccurrences(of: "\n", with: " ")
                }
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                state.query = ""
                state.goToPage(Int(key)! - 1)
            default:
                return event
            }
            return nil
        }

        if mods.contains(.control) { return event }
        if let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .privateUse }) {
            if state.query.isEmpty && chars == " " {
                // Space selects (or deselects) the focused item.
                if !event.isARepeat, let id = focusedID { state.toggleSelection(id) }
                return nil
            }
            state.openFolderID = nil
            state.query += chars
            return nil
        }
        return nil
    }

    /// The item with keyboard focus on the page or in the open folder (not search results).
    private var focusedID: UUID? {
        guard state.query.isEmpty, let i = state.focusIndex else { return nil }
        if let f = state.openFolder { return f.apps[safe: i]?.id }
        return state.currentItems[safe: i]?.id
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
            if event.phase.contains(.began) {
                scrollAccumulator = 0
                swipeFlipped = false
            }
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
