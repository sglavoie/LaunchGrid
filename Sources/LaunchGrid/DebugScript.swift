#if !APP_STORE
import AppKit
import Carbon
import LaunchGridCore

/// Development aid: `LAUNCHGRID_DEBUG_SCRIPT="build;show;snap:grid;quit"` drives the UI and
/// writes PNG snapshots of our windows into `LAUNCHGRID_DEBUG_DIR` (default: the temp folder).
@MainActor
enum DebugScript {
    /// The menu the "menus" step closes once it has printed it, and the item it then chooses.
    private static weak var trackedMenu: NSMenu?
    private static var menuChoice: String?
    private static var watchingMenus = false
    /// Where a held drag ("hold", "fhold", "panhold") is, for "release".
    private static var heldAt: (point: CGPoint, window: NSWindow)?

    static func run(_ script: String, state: AppState, overlay: OverlayController, delegate: AppDelegate) {
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let dir = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_DIR"] ?? NSTemporaryDirectory()
        Task {
            for step in steps {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let arg = parts.count > 1 ? parts[1] : ""
                switch parts[0] {
                case "build": state.build(style: arg == "alpha" ? .alphabetical : .byCategory)
                case "only":
                    // Before "build": exclude every app whose name or bundle ID isn't listed, e.g. "only:Maps,com.apple.Notes".
                    let keep = Set(arg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                    let apps = state.selectableApps
                    let kept = apps.filter { keep.contains($0.name) || keep.contains($0.bundleID ?? "") }
                    state.chooseApps(include: kept, exclude: apps.filter { !kept.contains($0) })
                    print("only: kept \(kept.count) of \(apps.count), missing \(keep.subtracting(kept.flatMap { [$0.name, $0.bundleID ?? ""] }).sorted())")
                    fflush(stdout)
                case "size":
                    // Rows x columns, e.g. "size:5x7".
                    let n = arg.split(separator: "x").compactMap { Int($0) }
                    if n.count == 2 { state.resize(rows: n[0], columns: n[1]) }
                case "mark":
                    // Prints the wall-clock time, so a screen recording can be cut at this step.
                    print("mark: \(arg) \(String(format: "%.3f", Date().timeIntervalSince1970))")
                    fflush(stdout)
                case "show": overlay.show()
                case "hide": overlay.hide()
                case "page": state.goToPage(Int(arg) ?? 0)
                case "search": state.query = arg
                case "type":
                    // Inserts at the search's caret, character by character, as typing does.
                    for ch in arg { state.searchLine.insert(String(ch)) }
                case "edit": state.editing = true
                case "select": for i in (arg.split(separator: ",").compactMap { Int($0) }) where state.currentItems.indices.contains(i) {
                    state.selection.insert(state.currentItems[i].id)
                }
                case "fselect": for i in (arg.split(separator: ",").compactMap { Int($0) }) {
                    if let app = state.openFolder?.apps[safe: i] { state.selection.insert(app.id) }
                }
                case "group": state.groupSelection()
                case "folder":
                    if let f = state.grid.pages.flatMap(\.items).compactMap(\.folder).first { state.openFolder(f.id) }
                case "focus": state.focusIndex = Int(arg) ?? 0
                case "rename": if let item = state.currentItems.first { state.beginRename(item.id) }
                case "settings": delegate.showSettings()
                case "tab": state.settingsTab = arg
                case "settingsheight": state.settingsHeight = Double(arg).map { CGFloat($0) }
                case "hotkeyclear":
                    // Hides why the shortcut isn't registered, e.g. a scratch copy beside the installed one.
                    state.hotkeyProblem = nil
                case "appearance": NSApp.appearance = arg.isEmpty ? nil : NSAppearance(named: arg == "dark" ? .darkAqua : .aqua)
                case "shoot":
                    // Asks whoever reads stdout to screenshot the window titled like the first part, as
                    // `screencapture -l` does with permission we lack, and waits for the file:
                    // "shoot:LaunchGrid Settings,general" prints "shoot: <window number> general".
                    let n = arg.split(separator: ",", maxSplits: 1).map(String.init)
                    guard n.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.title == n[0] }) else { break }
                    let path = URL(fileURLWithPath: dir).appendingPathComponent("\(n[1]).png").path
                    try? FileManager.default.removeItem(atPath: path)
                    print("shoot: \(window.windowNumber) \(n[1])")
                    fflush(stdout)
                    var waited = 0
                    while !FileManager.default.fileExists(atPath: path) && waited < 100 {
                        try? await Task.sleep(for: .milliseconds(100))
                        waited += 1
                    }
                case "windowsize":
                    // Window mode: resizes the grid's window to "w,h" points, centred on its screen.
                    let n = arg.split(separator: ",").compactMap { Double($0) }
                    guard n.count == 2, let window = overlay.window, let v = window.screen?.visibleFrame else { break }
                    window.setFrame(NSRect(x: v.midX - n[0] / 2, y: v.midY - n[1] / 2, width: n[0], height: n[1]), display: true)
                case "shootframe":
                    // Like shoot, for the grid's window inset by N points (past its rounded corners and
                    // close button): "shootframe:grid,36" prints "shootrect: x,y,w,h grid", in points
                    // from the main screen's top left as `screencapture -R` takes them.
                    let n = arg.split(separator: ",", maxSplits: 1).map(String.init)
                    guard n.count == 2, let inset = Double(n[1]), let window = overlay.window,
                          let top = NSScreen.screens.first?.frame.maxY else { break }
                    let r = window.frame.insetBy(dx: inset, dy: inset)
                    let path = URL(fileURLWithPath: dir).appendingPathComponent("\(n[0]).png").path
                    try? FileManager.default.removeItem(atPath: path)
                    print("shootrect: \(Int(r.minX)),\(Int(top - r.maxY)),\(Int(r.width)),\(Int(r.height)) \(n[0])")
                    fflush(stdout)
                    var waited = 0
                    while !FileManager.default.fileExists(atPath: path) && waited < 100 {
                        try? await Task.sleep(for: .milliseconds(100))
                        waited += 1
                    }
                case "open":
                    // As if Finder opened the file. Async, so the script goes on while an alert is up.
                    let url = URL(fileURLWithPath: arg)
                    DispatchQueue.main.async { delegate.application(NSApp, open: [url]) }
                case "alert":
                    // Prints the texts of the modal window up (an alert), then presses the button titled `arg`, if any.
                    guard let window = NSApp.modalWindow, let view = window.contentView else {
                        print("alert: none")
                        fflush(stdout)
                        break
                    }
                    @MainActor func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                    let views = all(view)
                    let texts = views.compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
                    let buttons = views.compactMap { $0 as? NSButton }
                    print("alert: \(texts) buttons=\(buttons.map(\.title).filter { !$0.isEmpty })")
                    fflush(stdout)
                    if !arg.isEmpty { buttons.first { $0.title == arg }?.performClick(nil) }
                case "wkeys":
                    // Types `text` into the window titled `title`: "wkeys:title,text"; "\r" is Return.
                    let n = arg.split(separator: ",", maxSplits: 1).map(String.init)
                    guard n.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.title == n[0] }) else { break }
                    for ch in n[1].replacingOccurrences(of: "\\r", with: "\r") {
                        let s = String(ch)
                        let code: UInt16 = s == "\r" ? UInt16(kVK_Return) : 0
                        for type in [NSEvent.EventType.keyDown, .keyUp] {
                            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, characters: s,
                                                        charactersIgnoringModifiers: s, isARepeat: false, keyCode: code) {
                                NSApp.postEvent(e, atStart: false)
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                case "menusave":
                    // The menu bar's Save Grid File…, async so the script goes on while the panel is up.
                    DispatchQueue.main.async { delegate.saveGridFileFromMenu() }
                case "results":
                    // The search's matches, best first, and where each app lives.
                    print("results: \(state.allSearchResults.map { "\($0.title) \($0.path)" })")
                    fflush(stdout)
                case "toast":
                    print("toast: \(state.toast ?? "-")")
                    fflush(stdout)
                case "problem":
                    print("problem: \(state.hotkeyProblem ?? "-")")
                    fflush(stdout)
                case "missing": delegate.showAddMissing()
                case "choose": delegate.showChooseApps()
                case "welcome": delegate.showFirstRun()
                case "undo": state.undo()
                case "bg":
                    // "bg:wallpaper", or "bg:/path/to/picture" for a custom image.
                    if arg.hasPrefix("/") {
                        state.prefs.customImagePath = arg
                        state.prefs.background = .image
                    } else if let style = BackgroundStyle(rawValue: arg) {
                        state.prefs.background = style
                    }
                case "blur": state.prefs.blurRadius = Double(arg) ?? 0
                case "blursweep":
                    // "blursweep:10-30": one radius every 30 ms, as dragging the slider does.
                    let ends = arg.split(separator: "-").compactMap { Int($0) }
                    guard ends.count == 2, ends[0] <= ends[1] else { break }
                    for r in ends[0]...ends[1] {
                        state.prefs.blurRadius = Double(r)
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                case "space":
                    // As if the Space changed.
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
                case "renders":
                    print("renders: blurs=\(ImageBlurCache.shared.renders) wallpaperLookups=\(BackgroundView.wallpaperLookups)")
                    fflush(stdout)
                case "keys":
                    // Comma-separated virtual key codes or literal characters, each optionally after
                    // modifiers, e.g. "keys:n,o,125,opt+51,ctrl+a,36".
                    guard let window = overlay.window else { break }
                    let modifierNames: [String: NSEvent.ModifierFlags] = ["cmd": .command, "opt": .option, "ctrl": .control, "shift": .shift]
                    for var token in arg.split(separator: ",").map(String.init) {
                        var flags: NSEvent.ModifierFlags = []
                        while let plus = token.firstIndex(of: "+"), plus != token.startIndex,
                              let flag = modifierNames[String(token[..<plus])] {
                            flags.insert(flag)
                            token = String(token[token.index(after: plus)...])
                        }
                        let code = UInt16(token).flatMap { token.count > 1 ? $0 : nil }
                        let chars = code == nil ? token : ""
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code ?? 0)
                        if let event { NSApp.postEvent(event, atStart: false) }
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                case "menus":
                    // Prints each menu that opens, then closes it, so keyboard menus can be checked;
                    // "menus:Select" also chooses the item with that title.
                    menuChoice = arg.isEmpty ? nil : arg
                    if watchingMenus { break }
                    watchingMenus = true
                    NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                        // Menus post this on the main thread.
                        nonisolated(unsafe) let menu = note.object as? NSMenu
                        MainActor.assumeIsolated { trackedMenu = menu }
                        // Menu tracking runs the loop in its own mode, which the common modes include.
                        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
                            MainActor.assumeIsolated {
                                guard let menu = trackedMenu else { return }
                                print("menu: \(menu.items.map { $0.isEnabled ? $0.title : "(\($0.title))" }.filter { !$0.isEmpty })")
                                fflush(stdout)
                                menu.cancelTracking()
                                if let choice = menuChoice, let i = menu.items.firstIndex(where: { $0.title == choice }) {
                                    menu.performActionForItem(at: i)
                                }
                            }
                        }
                        RunLoop.main.add(timer, forMode: .common)
                    }
                case "state":
                    print("state: page=\(state.currentPage) query='\(state.searchLine.beforeCaret)|\(state.searchLine.afterCaret)' focus=\(String(describing: state.focusIndex)) folder=\(state.openFolder?.name ?? "-") folderPage=\(state.folderPage) shown=\(state.isShown) editing=\(state.editing) pages=\(state.grid.pages.count) selected=\(state.selection.count) dragging=\(state.drag.active) swipe=\(Int(state.swipeOffset))")
                    if state.openFolder != nil { print("folderframe: \(state.drag.folderGridFrame) pager=\(state.drag.pagerFrame)") }
                    if let f = state.openFolder { print("folder: \(f.apps.count) apps, first \(f.apps.prefix(3).map(\.title)), last \(f.apps.suffix(3).map(\.title))") }
                    fflush(stdout)
                case "wclick":
                    // Clicks at x,y (points from the top left) in the window titled `title`: "wclick:title,x,y".
                    let n = arg.split(separator: ",").map(String.init)
                    guard n.count == 3, let x = Double(n[1]), let y = Double(n[2]),
                          let window = NSApp.windows.first(where: { $0.isVisible && $0.title == n[0] }) else { break }
                    let p = NSPoint(x: x, y: (window.contentView?.bounds.height ?? 0) - y)
                    window.makeKeyAndOrderFront(nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                      pressure: type == .leftMouseUp ? 0 : 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                case "movescreen":
                    // Moves the overlay window onto screen N (Window mode), as dragging it there would.
                    let screens = NSScreen.screens
                    guard let window = overlay.window, let i = Int(arg), screens.indices.contains(i) else { break }
                    let v = screens[i].visibleFrame, size = window.frame.size
                    window.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2))
                    try? await Task.sleep(for: .milliseconds(500))
                    print("movescreen: window on \(window.screen?.displayID ?? 0), background for \(overlay.screen?.displayID ?? 0), of \(screens.map(\.displayID))")
                    fflush(stdout)
                case "panel":
                    let w = overlay.window
                    print("panel: visible=\(w?.isVisible == true) alpha=\(w?.alphaValue ?? -1) key=\(w?.isKeyWindow == true) shown=\(state.isShown)")
                    fflush(stdout)
                case "toggle":
                    // Hide and show again at once, inside the fade-out.
                    overlay.hide()
                    overlay.show()
                case "hotkeyfire":
                    // Delivers a Carbon hot-key event for our hotkey, as macOS does when it's pressed.
                    var event: EventRef?
                    CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &event)
                    if let event {
                        var id = EventHotKeyID(signature: OSType(0x4C47_5244), id: 1)
                        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                          MemoryLayout<EventHotKeyID>.size, &id)
                        print("hotkeyfire: \(SendEventToEventTarget(event, GetApplicationEventTarget()))")
                        ReleaseEvent(event)
                    }
                    fflush(stdout)
                case "hotkeyhold":
                    // Takes "keyCode,modifiers" under another ID, so registering it as our hotkey fails.
                    let n = arg.split(separator: ",").compactMap { UInt32($0) }
                    guard n.count == 2 else { break }
                    var ref: EventHotKeyRef?
                    let status = RegisterEventHotKey(n[0], n[1], EventHotKeyID(signature: OSType(0x484F_4C44), id: 9),
                                                     GetApplicationEventTarget(), 0, &ref)
                    print("hotkeyhold: \(status)")
                    fflush(stdout)
                case "hotkey":
                    // Register "keyCode,modifiers" directly, bypassing the scratch-copy guard.
                    let n = arg.split(separator: ",").compactMap { UInt32($0) }
                    guard n.count == 2 else { break }
                    let ok = HotkeyService.shared.register(keyCode: n[0], modifiers: n[1])
                    print("hotkey: registered=\(ok) active=\(String(describing: HotkeyService.shared.activeCombo))")
                    fflush(stdout)
                case "hotkeyblock":
                    // Takes "keyCode,modifiers" in a hotkey of its own, so registering it again is refused.
                    let n = arg.split(separator: ",").compactMap { UInt32($0) }
                    guard n.count == 2 else { break }
                    var ref: EventHotKeyRef?
                    let status = RegisterEventHotKey(n[0], n[1], EventHotKeyID(signature: OSType(0x4C47_4442), id: 9),
                                                     GetApplicationEventTarget(), 0, &ref)
                    print("hotkey: blocked \(arg) status=\(status)")
                    fflush(stdout)
                case "hotkeyrecord":
                    // As if the Settings recorder caught "keyCode,modifiers": the same path, minus
                    // the scratch-copy guard.
                    let n = arg.split(separator: ",").compactMap { UInt32($0) }
                    guard n.count == 2 else { break }
                    let prefs = state.prefs
                    let previous = (keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
                    HotkeyService.shared.register(keyCode: previous.keyCode, modifiers: previous.modifiers)
                    prefs.hotkeyKeyCode = n[0]
                    prefs.hotkeyModifiers = n[1]
                    let ok = AppDelegate.registerHotkey(prefs: prefs, state: state, fallback: previous,
                                                        register: { HotkeyService.shared.register(keyCode: $0, modifiers: $1) },
                                                        activeCombo: HotkeyService.shared.activeCombo)
                    print("hotkey: recorded=\(arg) ok=\(ok) saved=\(prefs.hotkeyKeyCode),\(prefs.hotkeyModifiers) active=\(String(describing: HotkeyService.shared.activeCombo)) problem=\(state.hotkeyProblem ?? "-")")
                    fflush(stdout)
                case "press", "click", "fpress":
                    // Long-press (or click) item N on the current page, or in the open folder.
                    guard let window = overlay.window else { break }
                    let folder = parts[0] == "fpress"
                    let c = (folder ? state.folderLayout : state.pageLayout).center(Int(arg) ?? 0)
                    let o = folder ? state.drag.folderGridFrame.origin : state.drag.pagerFrame.origin
                    let h = window.contentView?.bounds.height ?? 0
                    let p = NSPoint(x: o.x + c.x, y: h - (o.y + c.y))
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                      pressure: type == .leftMouseUp ? 0 : 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                        if type == .leftMouseDown { try? await Task.sleep(for: .seconds(parts[0] == "click" ? 0.05 : 1)) }
                    }
                case "drag", "merge", "edge", "fdrag", "fedge", "finside", "edgehide", "hold", "fhold", "panhold":
                    // An optional third number grabs the icon that many points right of its centre.
                    let n = arg.split(separator: ",").compactMap { Int($0) }
                    guard let window = overlay.window, let from = n.first else { break }
                    await simulateDrag(parts[0], from: from, to: n.count > 1 ? n[1] : 0, grab: CGFloat(n.count > 2 ? n[2] : 0),
                                       state: state, window: window, overlay: overlay, snapDir: dir)
                case "titles": print("titles:", state.grid.pages.map { "\($0.title ?? "-") #\($0.items.count) \($0.items.first?.title ?? "")" }); fflush(stdout)
                case "sortall": state.sortEverything()
                case "windows":
                    print("windows: \(NSApp.windows.filter(\.isVisible).map { "\($0.title.isEmpty ? "(untitled)" : $0.title) \(Int($0.frame.width))x\(Int($0.frame.height))" })")
                    fflush(stdout)
                case "statusmenu": print("statusmenu: \(delegate.makeMenu().items.map(\.title).filter { !$0.isEmpty })"); fflush(stdout)
                case "rebuildaction": delegate.libraryActions.rebuild(arg == "alpha" ? .alphabetical : .byCategory)
                case "about": delegate.showAbout()
                case "frames": print("frames: \(state.prefs.windowFrames.count) saved, \(state.prefs.windowFrames)"); fflush(stdout)
                case "framesfill":
                    // Saved frames for N displays that aren't connected, as years of docks and projectors leave.
                    for i in 0..<(Int(arg) ?? 0) { state.prefs.windowFrames["display-FAKE-\(i)"] = "{{0, 0}, {800, 600}}" }
                case "framesave":
                    // Saves "w,h" as the Window-mode frame for every connected display, as if resized there.
                    let n = arg.split(separator: ",").compactMap { Double($0) }
                    guard n.count == 2 else { break }
                    for s in NSScreen.screens { state.prefs.windowFrames[s.frameKey] = NSStringFromRect(NSRect(x: s.visibleFrame.minX, y: s.visibleFrame.minY, width: n[0], height: n[1])) }
                case "fakeinstall":
                    // As if a scan found a newly installed app "Name" (nothing is put on disk).
                    let app = InstalledApp(bundleID: "com.example.fake.\(arg.lowercased())", path: "/Applications/\(arg).app", name: arg)
                    state.catalogScanned(state.installed + [app])
                case "regenicons":
                    state.regenerateIcons { print("regenicons: done"); fflush(stdout) }
                case "movetopage":
                    // Moves the first item of the current page to page N (0-based), as Move to Page does.
                    if let first = state.currentItems.first, let p = Int(arg) { state.moveToPage([first.id], page: p) }
                case "release":
                    // Releases a held drag where it is.
                    guard let (p, window) = heldAt else { break }
                    heldAt = nil
                    let h = window.contentView?.bounds.height ?? 0
                    if let e = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: p.x, y: h - p.y), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
                        NSApp.postEvent(e, atStart: false)
                    }
                case "extrafolder":
                    // Adds a scan folder without the open panel, as Settings › Library does.
                    state.prefs.extraFolders.append(arg)
                    delegate.libraryActions.foldersChanged()
                case "mode":
                    // "mode:window" (or fullScreen, behindDock), as Settings changes it.
                    if let mode = WindowMode(rawValue: arg) {
                        state.prefs.windowMode = mode
                        overlay.modeChanged()
                    }
                case "screenchange":
                    // As if a display was added, removed or changed resolution.
                    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
                case "pages": print("pages(\(state.currentPage)):", state.grid.pages.map { $0.items.prefix(5).map(\.title) + ["#\($0.items.count)"] }); fflush(stdout)
                case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
                case "snap": snapshot(name: arg.isEmpty ? "snap" : arg, dir: dir)
                case "dump": print(String(data: (try? GridStore.encode(state.grid)) ?? Data(), encoding: .utf8) ?? "")
                case "quit": NSApp.terminate(nil)
                default: NSLog("LaunchGrid debug: unknown step \(step)")
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Sends real mouse events through the panel so the SwiftUI gesture path is exercised.
    /// drag: drop item `from` into the gap at slot `to`; merge: dwell on item `to`'s centre;
    /// edge: dwell at the right edge to flip a page, then drop at slot `to`.
    /// fedge: like fdrag, dwelling at the open folder's right edge to flip its page first.
    /// finside: drag open-folder app `from` to the gap at folder slot `to`, staying inside it.
    /// hold / fhold: like drag / fdrag, without releasing ("release" does).
    /// panhold: swipe the page from beside item `from` by `to` points, without releasing.
    /// edgehide: dwell at the right edge until the page flips, then hide without releasing.
    static func simulateDrag(_ kind: String, from: Int, to: Int, grab: CGFloat = 0, state: AppState, window: NSWindow,
                             overlay: OverlayController, snapDir: String) async {
        let layout = state.pageLayout
        let origin = state.drag.pagerFrame.origin
        func rootPoint(_ index: Int, dx: CGFloat = 0) -> CGPoint {
            let c = layout.center(index)
            return CGPoint(x: origin.x + c.x + dx, y: origin.y + c.y)
        }
        func send(_ type: NSEvent.EventType, _ p: CGPoint) {
            let h = window.contentView?.bounds.height ?? 0
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: h - p.y), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            if let event { NSApp.postEvent(event, atStart: false) }
        }
        func glide(_ a: CGPoint, _ b: CGPoint, steps: Int = 12) async {
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                send(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        var start = rootPoint(from, dx: grab)
        if kind == "panhold" {
            // Between two icons, where a drag swipes the page rather than lifting an icon.
            start = rootPoint(from, dx: layout.cell.width / 2)
        }
        if kind == "fdrag" || kind == "fedge" || kind == "finside" || kind == "fhold" {
            let f = state.drag.folderGridFrame
            let fl = state.folderLayout
            let c = fl.center(from)
            start = CGPoint(x: f.minX + c.x, y: f.minY + c.y)
        }
        NSLog("LaunchGrid debug: active=\(NSApp.isActive) key=\(window.isKeyWindow) start=\(start)")
        send(.leftMouseDown, start)
        try? await Task.sleep(for: .milliseconds(50))
        var end: CGPoint
        switch kind {
        case "merge":
            end = rootPoint(to)
            await glide(start, end)
            for _ in 0..<8 { send(.leftMouseDragged, end); try? await Task.sleep(for: .milliseconds(100)) }
        case "edge":
            let frame = state.drag.pagerFrame
            let edge = CGPoint(x: frame.maxX - 10, y: frame.midY)
            await glide(start, edge)
            for _ in 0..<9 { send(.leftMouseDragged, edge); try? await Task.sleep(for: .milliseconds(100)) }
            end = rootPoint(to, dx: -layout.cell.width * 0.4)
            await glide(edge, end)
        case "fedge":
            let f = state.drag.folderGridFrame
            let edge = CGPoint(x: f.maxX - 10, y: f.midY)
            await glide(start, edge)
            for _ in 0..<12 { send(.leftMouseDragged, edge); try? await Task.sleep(for: .milliseconds(100)) }
            let c = state.folderLayout.center(to)
            end = CGPoint(x: f.minX + c.x - state.folderLayout.cell.width * 0.4, y: f.minY + c.y)
            await glide(edge, end)
        case "hold", "fhold":
            end = rootPoint(to, dx: -layout.cell.width * 0.4)
            await glide(start, end)
            for _ in 0..<5 { send(.leftMouseDragged, end); try? await Task.sleep(for: .milliseconds(100)) }
            heldAt = (end, window)
            return
        case "panhold":
            end = CGPoint(x: start.x + CGFloat(to), y: start.y)
            await glide(start, end)
            heldAt = (end, window)
            return
        case "finside":
            let f = state.drag.folderGridFrame
            let c = state.folderLayout.center(to)
            end = CGPoint(x: f.minX + c.x - state.folderLayout.cell.width * 0.4, y: f.minY + c.y)
            await glide(start, end)
            for _ in 0..<5 { send(.leftMouseDragged, end); try? await Task.sleep(for: .milliseconds(100)) }
        case "edgehide":
            let frame = state.drag.pagerFrame
            let edge = CGPoint(x: frame.maxX - 10, y: frame.midY)
            await glide(start, edge)
            for _ in 0..<12 { send(.leftMouseDragged, edge); try? await Task.sleep(for: .milliseconds(100)) }
            print("before hide: page=\(state.currentPage) pages=\(state.grid.pages.count) dragging=\(state.drag.active)")
            fflush(stdout)
            overlay.hide()
            return
        default:
            end = rootPoint(to, dx: -layout.cell.width * 0.4 + grab)
            await glide(start, end)
            if grab != 0 { snapshot(name: "middrag", dir: snapDir) }
        }
        try? await Task.sleep(for: .milliseconds(150))
        send(.leftMouseUp, end)
    }

    static func snapshot(name: String, dir: String) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView, view.bounds.width > 0,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(i).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            NSLog("LaunchGrid debug: wrote \(url.path)")
        }
    }
}
#endif
