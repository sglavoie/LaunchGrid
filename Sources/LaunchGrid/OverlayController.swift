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
    /// Whether the trackpad gesture under way goes up and down, taken from its first movement
    /// so a slightly slanted swipe doesn't switch axis halfway.
    private var scrollIsVertical: Bool?
    /// When the last mouse-wheel event came, to tell one burst of them from the next.
    private var lastWheelEvent = Date.distantPast
    /// Bumped by every show and hide, so a fade-out that was overtaken doesn't order the panel out.
    private var visibilityGeneration = 0
    /// The last app opened behind the grid while it stayed up ("Hide after opening an app"
    /// off), brought forward when the grid hides.
    var launchedBehind: NSRunningApplication?
    /// A window frame waiting to be saved once a move stops.
    private var frameSaveTask: Task<Void, Never>?

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
        // The panel joins every Space, so it follows a switch unless asked to hide.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, self.state.prefs.hideOnSpaceChange else { return }
                self.hide(deactivate: false)
            }
        }
        installMonitors()
        textInput.onInsert = { [weak self] in self?.insertIntoSearch($0) }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        // An alert or a file panel is waiting for an answer: over it, the grid would take no
        // clicks and hide the question. Bring that forward instead.
        if let modal = NSApp.modalWindow {
            NSApp.activate()
            modal.makeKeyAndOrderFront(nil)
            return
        }
        // Before the first layout the grid is empty: the welcome window is where to choose one.
        if !state.hasGridFile, let welcome = NSApp.windows.first(where: { $0.identifier?.rawValue == "firstRun" && $0.isVisible }) {
            NSApp.activate()
            welcome.makeKeyAndOrderFront(nil)
            return
        }
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
        launchedBehind = nil
        state.didShow()
    }

    /// - Parameter saving: false when the caller has just saved (quitting), so a failure
    ///   isn't reported twice.
    func hide(deactivate: Bool = true, saving: Bool = true) {
        guard let panel, panel.isVisible else { return }
        // While it's still visible, which saving the frame checks.
        if frameSaveTask != nil { saveWindowFrame() }
        textInput.discardComposition()
        state.isShown = false
        // Written off the main thread, so the fade doesn't wait for the disk. A failure is told
        // once the panel is gone, whichever ends first: an alert would open behind it.
        let progress = HideProgress()
        if saving {
            state.saveInBackground(reportingFailure: false) { [weak self] saved in
                progress.saved = saved
                if !saved && progress.gone { self?.state.reportLastSaveFailure() }
            }
        }
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
                progress.gone = true
                if progress.saved == false { self.state.reportLastSaveFailure() }
                // Hand focus back to the previous app unless another of our windows is up, or
                // to the last app opened behind the grid while it stayed up.
                let others = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.level == .normal && !($0 is NSPanel) }
                if deactivate, !others, let app = self.launchedBehind {
                    Launcher.bringForward(app)
                } else if deactivate && NSApp.isActive && !others {
                    NSApp.hide(nil)
                }
                self.launchedBehind = nil
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
        let root = GridRootView().environment(state)
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

    /// Set while `placePanel` moves the panel, so the frame it fits to the screen isn't saved
    /// over the person's own (a lower resolution for a while would shrink it for good).
    private var placing = false

    private func placePanel() {
        // After a display change the remembered screen may be gone (or a new object for the
        // same display); match it by ID and fall back to the main screen.
        let id = screen?.displayID
        screen = NSScreen.screens.first { $0.displayID == id } ?? NSScreen.main
        guard let panel, let screen else { return }
        placing = true
        defer { placing = false }
        showBackground(for: screen)
        switch state.prefs.windowMode {
        case .fullScreen:
            panel.setFrame(screen.frame, display: true)
        case .behindDock:
            panel.setFrame(screen.visibleFrame, display: true)
        case .window:
            let v = screen.visibleFrame
            if var r = savedFrame(for: screen) {
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

    /// Points the background (blurred desktop or wallpaper) at `screen`. Only the background
    /// reads it, so nothing else is redrawn, and nothing at all on a show on the same display.
    private func showBackground(for screen: NSScreen) {
        if state.screenID != screen.displayID { state.screenID = screen.displayID }
    }

    // MARK: NSWindowDelegate

    // Saved once a resize or move comes to rest, not at each of its many steps.
    // Not for `placePanel`'s own moves: the save would run once `placing` is over.
    func windowDidResize(_ notification: Notification) {
        if panel?.inLiveResize != true, !placing { scheduleFrameSave() }
    }
    func windowDidEndLiveResize(_ notification: Notification) { saveWindowFrame() }
    func windowDidMove(_ notification: Notification) {
        if !placing { scheduleFrameSave() }
    }

    private func scheduleFrameSave() {
        frameSaveTask?.cancel()
        frameSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveWindowFrame()
        }
    }

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
        frameSaveTask?.cancel()
        frameSaveTask = nil
        guard !placing, state.prefs.windowMode == .window, let panel, panel.isVisible, let screen = panel.screen else { return }
        var frames = state.prefs.windowFrames
        frames[screen.frameKey] = Self.savedFrame(panel.frame, on: screen.frame)
        Self.prune(&frames)
        if frames != state.prefs.windowFrames { state.prefs.windowFrames = frames }
    }

    /// Marks a frame saved from its display's origin, so it still lands on that display after
    /// the displays are arranged differently. Earlier ones are in global coordinates.
    static let relativePrefix = "rel:"

    /// The frame saved for a display, in global coordinates. One saved under the old
    /// name-and-number key, which changed whenever the display reconnected, moves to the
    /// stable key the first time.
    private func savedFrame(for screen: NSScreen) -> NSRect? {
        var frames = state.prefs.windowFrames
        var saved = frames[screen.frameKey]
        if saved == nil, let old = frames.removeValue(forKey: screen.legacyFrameKey) {
            frames[screen.frameKey] = old
            state.prefs.windowFrames = frames
            saved = old
        }
        return saved.map { Self.frame(saved: $0, on: screen.frame) }
    }

    /// `frame` as saved for the display at `display`: from the display's origin.
    static func savedFrame(_ frame: NSRect, on display: NSRect) -> String {
        relativePrefix + NSStringFromRect(frame.offsetBy(dx: -display.minX, dy: -display.minY))
    }

    /// A saved frame in global coordinates, for the display now at `display`.
    static func frame(saved: String, on display: NSRect) -> NSRect {
        guard saved.hasPrefix(relativePrefix) else { return NSRectFromString(saved) }
        return NSRectFromString(String(saved.dropFirst(relativePrefix.count))).offsetBy(dx: display.minX, dy: display.minY)
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
            if cmd, let digit = Int(Self.shortcutKey(event)), (1...9).contains(digit) {
                state.dragGoToPage(digit - 1)
            }
            return nil
        }

        switch code {
        case kVK_Escape:
            if state.drag.active { state.cancelDrag() }
            else if !state.query.isEmpty { state.endSearch() }
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
                // Edit mode opens a focused folder, as a click does, to arrange it; Return again
                // renames it. Otherwise it renames the focused app, else the open folder.
                if let id = focusedID, state.openFolder == nil, let item = state.grid.item(id), item.folder != nil {
                    state.activate(item)
                } else if let id = focusedID ?? state.openFolderID {
                    state.beginRename(id)
                }
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
                // The open folder's slot, in case removing its last app takes the folder too.
                let folderSlot = state.openFolderID.flatMap { f in state.currentItems.firstIndex { $0.id == f } }
                state.remove([id])
                // Stay on the item that took its place: in the folder, or where the folder was.
                if let folderSlot, state.openFolder == nil { state.focusIndex = folderSlot }
                let count = focusableCount
                state.focusIndex = count > 0 ? state.focusIndex.map { min($0, count - 1) } : nil
            }
            return nil
        case kVK_Tab:
            state.flipPage(mods.contains(.shift) ? -1 : 1)
            return nil
        case kVK_PageUp, kVK_PageDown:
            state.flipPage(code == kVK_PageUp ? -1 : 1)
            return nil
        case kVK_Home, kVK_End:
            // The first or last page (of the open folder), or in the search either end of it.
            let home = code == kVK_Home
            if !state.query.isEmpty {
                editSearch { home ? $0.moveToStart() : $0.moveToEnd() }
            } else {
                let pages = state.openFolder.map { FolderLayout.pageCount(apps: $0.apps.count, grid: state.grid) }
                    ?? state.grid.pages.count
                state.flipPage(home ? -pages : pages)
            }
            return nil
        default:
            break
        }

        if cmd {
            let key = Self.shortcutKey(event)
            switch key {
            case "z": mods.contains(.shift) ? state.redo() : state.undo()
            case "e": state.editing.toggle()
            // Search results hide the page; selecting it unseen would let ⌫ remove it.
            case "a": if state.query.isEmpty { selectAll() }
            case "f": if !state.query.isEmpty { state.endSearch() }
            case "g": state.groupSelection()
            case "n": state.newPage() // which clears the search and closes the folder first
            case ",": state.onOpenSettings()
            // ⌘H would hide the app around the grid, leaving its search, folder and edit mode
            // as they were; hide the grid itself. The panel can't be minimised: ⌘M would beep.
            case "w", "h": hide()
            case "m": break
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
            switch Self.shortcutKey(event) {
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
    /// for `AppState.endSearch()`.
    private static let topRowDigits: [Int: String] = [
        kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
        kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]

    /// The key a ⌘ or ⌃ shortcut names, lowercased, as menus read it. A layout without Latin
    /// letters (Russian, Greek) names its keys by the Latin layout the person also uses, and
    /// the top row's keys are its digits wherever they are, so ⌘1 works where that key types
    /// "&" (French).
    static func shortcutKey(_ event: NSEvent) -> String {
        if let digit = topRowDigits[Int(event.keyCode)] { return digit }
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard !typed.unicodeScalars.allSatisfy(\.isASCII) else { return typed }
        return latinKey(event.keyCode) ?? typed
    }

    /// What `keyCode` types, unshifted, on the current ASCII-capable layout.
    private static func latinKey(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).lowercased()
    }

    private func insertIntoSearch(_ text: String) {
        guard !text.isEmpty else { return }
        if state.query.isEmpty {
            state.folderBeforeSearch = state.openFolderID.map { ($0, state.folderPage) }
            state.openFolderID = nil
        }
        state.searchLine.insert(text)
    }

    /// Edits the search at its caret; emptying it ends the search.
    private func editSearch(_ edit: (inout TextLine) -> Void) {
        var line = state.searchLine
        edit(&line)
        if line.text.isEmpty { state.endSearch() } else { state.searchLine = line }
    }

    /// Clears the search from the keyboard, back to the folder it was started in, if still there.
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
        let paging = state.openFolder == nil
        if paging && (next < 0 || next >= count) && (code == kVK_LeftArrow || code == kVK_RightArrow) {
            let before = state.query.isEmpty ? state.currentPage : state.searchPage
            state.flipPage(code == kVK_LeftArrow ? -1 : 1)
            let after = state.query.isEmpty ? state.currentPage : state.searchPage
            if after != before {
                let count = state.query.isEmpty ? state.currentItems.count : state.searchResults.count
                state.focusIndex = code == kVK_LeftArrow ? max(0, count - 1) : 0
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
            let c = state.iconCenter(i - state.folderPage * FolderLayout.perPage(state.grid), inFolder: true)
            let f = state.drag.folderGridFrame
            center = CGPoint(x: f.minX + c.x, y: f.minY + c.y)
        } else {
            guard let found = state.currentItems[safe: i] else { return }
            item = found
            let c = state.iconCenter(i, inFolder: false), f = state.drag.pagerFrame
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
        // Root coordinates start below the title bar in Window mode, and run from the top left;
        // the hosting view's may not.
        let origin = state.drag.rootOrigin
        let point = CGPoint(x: point.x + origin.x, y: point.y + origin.y)
        let local = host.isFlipped ? point : NSPoint(x: point.x, y: host.bounds.height - point.y)
        MenuEntry.nsMenu(entries).popUp(positioning: nil, at: local, in: host)
    }

    private func activateFocused() {
        if !state.query.isEmpty {
            let results = state.searchResults
            if let app = results[safe: state.focusIndex ?? 0] { state.activateResult(app) }
            return
        }
        guard let i = state.focusIndex else { return }
        if let f = state.openFolder {
            if let app = f.apps[safe: i] { state.launch(app) }
        } else if let item = state.currentItems[safe: i] {
            state.activate(item)
        }
    }

    /// Like ⌘-click, without entering edit mode: clicks still open apps.
    private func selectAll() {
        if let f = state.openFolder {
            state.selection = Set(f.apps.map(\.id))
        } else {
            state.selection = Set(state.currentItems.map(\.id))
        }
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        // A swipe that ends where it's no longer followed (a search typed, a rename or a drag
        // begun meanwhile) would leave the page part-way: it goes back.
        let ending = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        // The rename card edits the page it opened on: don't turn pages behind it.
        guard let panel, event.window === panel, isVisible, !state.drag.active, state.textEdit == nil else {
            if ending, event.window === panel { settleSwipe() }
            return event
        }
        let searching = !state.query.isEmpty
        // If a search began during a swipe of the grid, finish that gesture without
        // carrying its accumulated movement into the search results.
        if searching && (state.swipeOffset != 0 || state.folderSwipeOffset != 0) {
            settleSwipe()
            return nil
        }
        let width = max(state.drag.pagerFrame.width, 1)
        if !event.phase.isEmpty || !event.momentumPhase.isEmpty {
            // Trackpad: the pager follows the fingers, then snaps.
            if !event.momentumPhase.isEmpty { return nil }
            if event.phase.contains(.began) {
                scrollAccumulator = 0
                scrollIsVertical = nil
            }
            // Up and down turns pages too, as the mouse wheel does: down for the next one.
            if scrollIsVertical == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                scrollIsVertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
            }
            scrollAccumulator += scrollIsVertical == true ? event.scrollingDeltaY : event.scrollingDeltaX
            let inFolder = !searching && state.openFolder != nil
            if inFolder {
                state.folderSwipeOffset = state.swipeOffset(for: scrollAccumulator, width: max(state.drag.folderGridFrame.width, 1))
            } else if !searching {
                state.swipeOffset = state.swipeOffset(for: scrollAccumulator, width: width)
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                let threshold = min(120, (inFolder ? max(state.drag.folderGridFrame.width, 1) : width) * 0.12)
                let flip = event.phase.contains(.cancelled) ? 0
                    : scrollAccumulator < -threshold ? 1 : scrollAccumulator > threshold ? -1 : 0
                if inFolder && flip != 0 {
                    // The folder shows one page at a time: the new one comes in where it is.
                    state.folderSwipeOffset = 0
                    state.flipPage(flip)
                    // A folder opened mid-swipe: the page behind it goes back too.
                    settleSwipe()
                } else {
                    withAnimation(AppState.pageAnimation) {
                        if flip != 0 { state.flipPage(flip) }
                        state.swipeOffset = 0
                        state.folderSwipeOffset = 0
                    }
                }
                scrollAccumulator = 0
            }
            return nil
        }
        // Mouse wheel: one page per burst of notches, the first after a pause, so a wheel left
        // spinning freely turns one page, not one every so often while it spins.
        let delta = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        let now = Date()
        defer { lastWheelEvent = now }
        guard abs(delta) > 0.5, now.timeIntervalSince(lastWheelEvent) > Self.wheelPause else { return nil }
        state.flipPage(delta < 0 ? 1 : -1)
        return nil
    }

    /// A pause in mouse-wheel events this long ends a burst.
    static let wheelPause: TimeInterval = 0.25

    /// Puts a part-way swipe back, page and folder.
    private func settleSwipe() {
        scrollAccumulator = 0
        guard state.swipeOffset != 0 || state.folderSwipeOffset != 0 else { return }
        withAnimation(AppState.pageAnimation) {
            state.swipeOffset = 0
            state.folderSwipeOffset = 0
        }
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
    /// The search field's frame in the hosting view (from its top left), for the candidate window.
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

/// How a hide is going, for telling a failed save once both the save and the fade are done.
@MainActor private final class HideProgress {
    var saved: Bool?
    var gone = false
}
