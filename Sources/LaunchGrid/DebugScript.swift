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
    /// The pages `Pager` last drew, for "drawn".
    static var drawnPages: ClosedRange<Int>?
    /// The menu "menuhold" built, for "menurun".
    private static var heldMenu: [MenuEntry] = []

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
                case "renamesnap", "editsnap":
                    // "renamesnap:ms,name": opens (or, open, closes) the rename card and snaps ms later,
                    // within its transition; "editsnap:ms,name" turns edit mode on or off the same way.
                    let n = arg.split(separator: ",", maxSplits: 1).map(String.init)
                    guard n.count == 2, let ms = Int(n[0]) else { break }
                    if parts[0] == "editsnap" {
                        state.editing.toggle()
                    } else if state.textEdit != nil {
                        state.textEdit = nil
                    } else if let item = state.currentItems.first {
                        state.beginRename(item.id)
                    }
                    try? await Task.sleep(for: .milliseconds(ms))
                    snapshot(name: n[1], dir: dir)
                case "foldersnap":
                    // "foldersnap:ms,name": opens the first folder (or closes the one open) and snaps
                    // ms later, within its transition.
                    let n = arg.split(separator: ",", maxSplits: 1).map(String.init)
                    guard n.count == 2, let ms = Int(n[0]) else { break }
                    if state.openFolderID != nil {
                        state.closeFolder()
                    } else if let f = state.grid.pages.flatMap(\.items).compactMap(\.folder).first {
                        state.openFolder(f.id)
                    }
                    try? await Task.sleep(for: .milliseconds(ms))
                    snapshot(name: n[1], dir: dir)
                case "drawn":
                    // The pages the pager draws (the rest are blank stand-ins).
                    print("drawn: \(drawnPages.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "-") current=\(state.currentPage)")
                    fflush(stdout)
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
                case "loadfile":
                    // Load Grid File… (menu bar or Settings), its panel and any alert driven from outside.
                    DispatchQueue.main.async { delegate.loadGridFile(done: nil) }
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
                case "datafolder": state.showDataFolder() // as Settings › Library's button
                case "browseapp":
                    // Browse for App… (Settings › Library › Add Missing Apps), adding what is picked.
                    let picked = AppBrowser.pick()
                    state.addApps(picked)
                    print("browseapp: \(picked.map(\.path))")
                    fflush(stdout)
                case "bookmarks":
                    print("bookmarks: \((Preferences.appDefaults.dictionary(forKey: "bookmarks") ?? [:]).keys.sorted())")
                    fflush(stdout)
                case "undo": state.undo()
                case "redo": state.redo()
                case "deletepage": state.deleteCurrentPage()
                case "launch":
                    // Opens app N of the current page, as a click does.
                    if case .app(let a)? = state.currentItems[safe: Int(arg) ?? 0] { state.launch(a) }
                case "front":
                    // The app in front, and whether we are active or hidden.
                    print("front: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") active=\(NSApp.isActive) hidden=\(NSApp.isHidden)")
                    fflush(stdout)
                case "closewin":
                    // Closes the window titled `arg`, as its close button does.
                    NSApp.windows.first { $0.title == arg && $0.isVisible }?.performClose(nil)
                case "bg":
                    // "bg:wallpaper", or "bg:/path/to/picture" for a custom image.
                    if arg.hasPrefix("/") {
                        state.prefs.customImagePath = arg
                        state.prefs.background = .image
                    } else if let style = BackgroundStyle(rawValue: arg) {
                        state.prefs.background = style
                    }
                case "blur": state.prefs.blurRadius = Double(arg) ?? 0
                case "showsnap":
                    // "showsnap:ms,name[,/picture]": shows the overlay (with that custom picture, as if
                    // shown on another display with its own) and snaps it ms later, before the runner's pause.
                    let n = arg.split(separator: ",", maxSplits: 2).map(String.init)
                    guard n.count >= 2, let ms = Int(n[0]) else { break }
                    if n.count == 3 { state.prefs.customImagePath = n[2] }
                    overlay.show()
                    try? await Task.sleep(for: .milliseconds(ms))
                    snapshot(name: n[1], dir: dir)
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
                    print("renders: blurs=\(ImageBlurCache.shared.renders) evicted=\(ImageBlurCache.shared.evictions) heldMB=\(ImageBlurCache.shared.heldBytes >> 20) wallpaperLookups=\(BackgroundView.wallpaperLookups) itemMenus=\(MenuEntry.builds)")
                    fflush(stdout)
                case "keys":
                    // Comma-separated virtual key codes or literal characters, each optionally after
                    // modifiers, e.g. "keys:n,o,125,opt+51,ctrl+a,36". "char@code" sends both, as a
                    // layout does where that key types another letter: "cmd+я@6" is ⌘Z on Russian.
                    guard let window = overlay.window else { break }
                    let modifierNames: [String: NSEvent.ModifierFlags] = ["cmd": .command, "opt": .option, "ctrl": .control, "shift": .shift]
                    for var token in arg.split(separator: ",").map(String.init) {
                        var flags: NSEvent.ModifierFlags = []
                        while let plus = token.firstIndex(of: "+"), plus != token.startIndex,
                              let flag = modifierNames[String(token[..<plus])] {
                            flags.insert(flag)
                            token = String(token[token.index(after: plus)...])
                        }
                        var code = UInt16(token).flatMap { token.count > 1 ? $0 : nil }
                        var chars = code == nil ? token : ""
                        if let at = token.lastIndex(of: "@"), at != token.startIndex, let c = UInt16(token[token.index(after: at)...]) {
                            (chars, code) = (String(token[..<at]), c)
                        }
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
                    print("state: page=\(state.currentPage) query='\(state.searchLine.beforeCaret)|\(state.searchLine.afterCaret)' focus=\(String(describing: state.focusIndex)) folder=\(state.openFolder?.name ?? "-") folderPage=\(state.folderPage) shown=\(state.isShown) editing=\(state.editing) pages=\(state.grid.pages.count) selected=\(state.selection.count) dragging=\(state.drag.active) swipe=\(Int(state.swipeOffset)) fswipe=\(Int(state.folderSwipeOffset))")
                    if state.openFolder != nil { print("folderframe: \(state.drag.folderGridFrame) pager=\(state.drag.pagerFrame)") }
                    if let f = state.openFolder { print("folder: \(f.apps.count) apps, first \(f.apps.prefix(3).map(\.title)), last \(f.apps.suffix(3).map(\.title))") }
                    fflush(stdout)
                case "wclick":
                    // Clicks at x,y (points from the top left) in the window titled `title`: "wclick:title,x,y";
                    // "-" for the untitled overlay.
                    let n = arg.split(separator: ",").map(String.init)
                    guard n.count == 3, let x = Double(n[1]), let y = Double(n[2]),
                          let window = NSApp.windows.first(where: { $0.isVisible && $0.title == (n[0] == "-" ? "" : n[0]) }) else { break }
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
                    let (r, h) = (state.drag.rootOrigin, window.contentView?.bounds.height ?? 0)
                    let p = NSPoint(x: r.x + o.x + c.x, y: h - (r.y + o.y + c.y))
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                      pressure: type == .leftMouseUp ? 0 : 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                        if type == .leftMouseDown { try? await Task.sleep(for: .seconds(parts[0] == "click" ? 0.05 : 1)) }
                    }
                case "drag", "merge", "edge", "fdrag", "fedge", "finside", "edgehide", "edgehold", "hold", "fhold", "panhold":
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
                case "frames": print("frames: \(state.prefs.windowFrames.count) saved (\(Preferences.windowFrameWrites) writes), \(state.prefs.windowFrames)"); fflush(stdout)
                case "rootframes":
                    // Where root coordinates start in the overlay, and the frames menus and the
                    // candidate window are placed from.
                    print("rootframes: origin=\(state.drag.rootOrigin) menubutton=\(state.drag.menuButtonFrame) field=\(SearchComposition.shared.fieldFrame) window=\(overlay.window?.frame ?? .zero)")
                    fflush(stdout)
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
                    let (r, h) = (state.drag.rootOrigin, window.contentView?.bounds.height ?? 0)
                    if let e = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: r.x + p.x, y: h - (r.y + p.y)), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
                        NSApp.postEvent(e, atStart: false)
                    }
                case "pickfolder":
                    // Settings › Library's Add Folder…: the open panel, then the folder picked kept with its bookmark.
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url, !state.prefs.extraFolders.contains(url.path) {
                        FileAccess.remember(url)
                        state.prefs.extraFolders.append(url.path)
                        delegate.libraryActions.foldersChanged()
                    }
                    print("folders: \(state.prefs.extraFolders)")
                    fflush(stdout)
                case "folders":
                    print("folders: \(state.prefs.extraFolders)")
                    fflush(stdout)
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
                case "titleedit":
                    // Opens the rename card for the current page's title, as clicking the title does.
                    state.beginPageTitleEdit(state.currentPage)
                case "menuhold":
                    // Builds the first item's right-click menu now, for "menurun" to choose from later,
                    // as a menu left open while a rescan changes the pages.
                    if let first = state.currentItems.first { heldMenu = MenuEntry.item(first, state: state) }
                case "pagemenuhold":
                    // Builds the ⋯ menu (the background's right-click menu) for "menurun", as it is
                    // over search results or an open folder.
                    heldMenu = MenuEntry.page(state: state)
                case "menurun":
                    // Chooses the entry titled `arg` (in a submenu too) of the menu "menuhold" built.
                    func find(_ entries: [MenuEntry]) -> (@MainActor () -> Void)? {
                        for e in entries {
                            switch e.kind {
                            case .action(let run) where e.title == arg: return run
                            case .submenu(let sub): if let run = find(sub) { return run }
                            default: break
                            }
                        }
                        return nil
                    }
                    if let run = find(heldMenu) { run() } else { print("menurun: no \(arg)"); fflush(stdout) }
                case "pagetitle":
                    // Titles the current page, as the rename card does.
                    let p = state.currentPage
                    state.apply { $0.setPageTitle(p, arg) }
                case "foldername":
                    // Renames the open folder (or the first folder on the page).
                    if let id = state.openFolder?.id ?? state.currentItems.first(where: { $0.folder != nil })?.id {
                        state.apply { $0.rename(id, to: arg) }
                    }
                case "importdb":
                    // "importdb:/path/db": imports it as from AppGrid, asking before replacing; async,
                    // so the script goes on while the alert is up.
                    let url = URL(fileURLWithPath: arg)
                    DispatchQueue.main.async { delegate.debugImport(url, from: "AppGrid") }
                case "statusmenu-attach":
                    // "on": the menu-bar icon keeps its menu, as while VoiceOver runs.
                    delegate.attachesStatusMenu = arg == "on"
                    delegate.applyMenuBarIcon()
                case "rescan":
                    // A real scan, as Rescan Now does; the script waits for it.
                    await withCheckedContinuation { done in state.rescan { done.resume() } }
                    print("rescan: \(state.installed.count) apps")
                    fflush(stdout)
                case "apps":
                    // Every app on the grid whose name contains `arg`, with its path.
                    print("apps: \(state.grid.allApps.filter { $0.name.localizedCaseInsensitiveContains(arg) }.map(\.path))")
                    fflush(stdout)
                case "missingapps":
                    // Add Missing Apps' list, names containing `arg`.
                    print("missingapps: \(state.missingApps.map(\.path).filter { arg.isEmpty || $0.localizedCaseInsensitiveContains(arg) })")
                    fflush(stdout)
                case "setenv":
                    // "setenv:NAME=value" ("NAME=" unsets it), e.g. LAUNCHGRID_DEBUG_LOGIN_STATUS mid-run.
                    let kv = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    if kv.count == 2 { if kv[1].isEmpty { unsetenv(kv[0]) } else { setenv(kv[0], kv[1], 1) } }
                case "followmove":
                    // "followmove:/old/A.app>/new/A.app", as when a bookmark finds a moved app.
                    let n = arg.components(separatedBy: ">")
                    if n.count == 2 { state.followMovedApps([n[0]: n[1]]) }
                case "motion":
                    // Whether Reduce Motion turns the animations off, as the views ask it.
                    print("motion: reduce=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) drag=\(AppState.dragMotion(.default) != nil) page=\(AppState.pageAnimation != nil)")
                    fflush(stdout)
                case "volumes":
                    let listed = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes"))?.sorted()
                    print("volumes: \(Volume.mountedNames().map { $0.sorted() } ?? []) listing=\(listed.map { "\($0)" } ?? "denied")")
                    fflush(stdout)
                case "savedfile":
                    // What is on disk now, not in memory.
                    let saved = try? state.store.load()
                    print("savedfile: pages=\(saved.map { $0.pages.compactMap(\.title) }.map { "\($0)" } ?? "unreadable") apps=\(saved?.allApps.count ?? 0)")
                    fflush(stdout)
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
        let origin = state.drag.pagerFrame.origin, root = state.drag.rootOrigin
        func rootPoint(_ index: Int, dx: CGFloat = 0) -> CGPoint {
            let c = layout.center(index)
            return CGPoint(x: origin.x + c.x + dx, y: origin.y + c.y)
        }
        func send(_ type: NSEvent.EventType, _ p: CGPoint) {
            let h = window.contentView?.bounds.height ?? 0
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: root.x + p.x, y: h - (root.y + p.y)), modifierFlags: [],
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
            // Before the pointer settles the gap stays put, the move pending; after, it has moved.
            print("gap: \(String(describing: state.drag.gap)) pending=\(String(describing: state.drag.pendingGap))")
            for _ in 0..<5 { send(.leftMouseDragged, end); try? await Task.sleep(for: .milliseconds(100)) }
            print("gap: \(String(describing: state.drag.gap)) pending=\(String(describing: state.drag.pendingGap))")
            fflush(stdout)
        case "edgehold":
            // Flips to the next page at the edge and stays held there, for "release" or Esc.
            let frame = state.drag.pagerFrame
            let edge = CGPoint(x: frame.maxX - 10, y: frame.midY)
            await glide(start, edge)
            for _ in 0..<12 { send(.leftMouseDragged, edge); try? await Task.sleep(for: .milliseconds(100)) }
            heldAt = (edge, window)
            return
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
