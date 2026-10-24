import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LaunchGridCore

extension UTType {
    static let launchGridLayout = UTType(exportedAs: "com.sglavoie.launchgrid.layout", conformingTo: .json)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let showNotification = Notification.Name("com.sglavoie.launchgrid.show")

    let prefs = Preferences()
    private(set) var state: AppState!
    private var overlay: OverlayController!
    private var statusItem: NSStatusItem?
    private var watcher: FolderWatcher?
    private var rescanDebounce: Task<Void, Never>?
    private var periodicRescan: Timer?
    private var windows: [String: NSWindow] = [:]
    /// Layout files opened before the first scan finished (e.g. the double-click that launched us).
    private var pendingOpen: URL?
    private var catalogReady = false

    /// Other running copies of LaunchGrid (same bundle ID), leaving out scratch runs.
    static var otherInstances: [NSRunningApplication] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated && !isScratch($0) }
    }

    private static func isScratch(_ app: NSRunningApplication) -> Bool {
        guard let marker = try? String(contentsOf: scratchMarker(for: app.processIdentifier), encoding: .utf8)
        else { return false }
        // A marker naming another start was left by a crashed run whose pid got reused.
        return isScratchMarker(marker, startedAt: processStart(app.processIdentifier))
    }

    /// A scratch run leaves a marker named after its pid so other copies can tell it apart. It
    /// holds the run's start time, which tells it from a stale one without reading the file's
    /// dates (a required-reason API).
    static func scratchMarker(for pid: pid_t) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LaunchGrid-scratch-\(pid)")
    }

    static func writeScratchMarker() {
        let pid = getpid()
        FileManager.default.createFile(atPath: scratchMarker(for: pid).path,
                                       contents: Data(scratchMarkerContents(startedAt: processStart(pid)).utf8))
    }

    /// When the process with `pid` started, from the kernel. Not `NSRunningApplication.launchDate`,
    /// which is nil for a binary run directly, as a scratch run is.
    nonisolated static func processStart(_ pid: pid_t) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }

    nonisolated static func scratchMarkerContents(startedAt start: Double?) -> String {
        start.map { String($0) } ?? ""
    }

    /// Whether `marker` was left by the process that started at `start`; one without a time to
    /// compare counts.
    nonisolated static func isScratchMarker(_ marker: String, startedAt start: Double?) -> Bool {
        guard let start, let written = Double(marker.trimmingCharacters(in: .whitespacesAndNewlines)) else { return true }
        return abs(written - start) < 0.001
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let storeURL = ProcessInfo.processInfo.environment["LAUNCHGRID_DATA_DIR"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("grid.json") } ?? GridStore.defaultURL
        state = AppState(prefs: prefs, store: GridStore(url: storeURL))
        // Before the first scan, so it sees the folders and apps the bookmarks reach.
        state.followMovedApps(FileAccess.restore(prefs: prefs))
        // Only the sandboxed build keeps bookmarks, so only it needs telling which apps are in use.
        if Sandbox.isActive { state.onAppPathsInUse = { FileAccess.forgetApps(notIn: $0) } }
        FileAccess.onBookmarkFailure = { [weak self] url in
            self?.showError(String(localized: "LaunchGrid can't keep access to “\(url.lastPathComponent)”"),
                            String(localized: "It can be used until LaunchGrid quits. After that, choose it again."))
        }
        overlay = OverlayController(state: state)
        state.onHide = { [weak self] in self?.overlay.hide() }
        state.onHideForLaunch = { [weak self] in self?.overlay.hide(deactivate: false) }
        state.onError = { [weak self] title, detail in self?.showError(title, detail) }
        state.onOpenSettings = { [weak self] in self?.showSettings() }
        state.onAddMissing = { [weak self] in self?.showAddMissing() }

        buildMainMenu()
        applyDockPolicy()
        applyMenuBarIcon()
        HotkeyService.shared.onTrigger = { [weak self] in self?.overlay.toggle() }
        if !applyHotkey() {
            // After launch finishes, so the alert doesn't hold up the first scan.
            DispatchQueue.main.async { self.warnHotkeyFailed() }
        }
        if let notice = state.recoveryNotice {
            state.recoveryNotice = nil
            DispatchQueue.main.async { self.showRecoveryNotice(notice.message, file: notice.file) }
        }

        // The hand-over from a second launch is for the installed copy, not a scratch one.
        if !Preferences.isScratch {
            DistributedNotificationCenter.default().addObserver(forName: Self.showNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.overlay.show() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.rescan() }
        }
        // A scan folder on an external volume only exists (and can only be watched) while it's mounted.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { self.state.followMovedApps(FileAccess.restore(prefs: self.prefs)) }
                    self?.startWatching(onlyIfChanged: true)
                    self?.state.rescan()
                }
            }
        }
        // A scratch copy hands the shortcut over while another LaunchGrid runs, and takes it back after.
        if Preferences.isScratch {
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard app?.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
                    MainActor.assumeIsolated { _ = self?.applyHotkey() }
                }
            }
        }

        IconProvider.shared.prewarm(state.grid.allApps.map(\.path))
        state.rescan { [weak self] in
            guard let self else { return }
            self.catalogReady = true
            #if !APP_STORE
            if let script = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_SCRIPT"] {
                // A script rebuilds and edits the layout: only against a scratch one.
                if Preferences.isScratch {
                    DebugScript.run(script, state: self.state, overlay: self.overlay, delegate: self)
                    return
                }
                FileHandle.standardError.write(Data("LaunchGrid: ignoring LAUNCHGRID_DEBUG_SCRIPT, which needs LAUNCHGRID_DATA_DIR (a scratch layout)\n".utf8))
            }
            #endif
            if let url = self.pendingOpen {
                // Loading needs the catalog, so a file that launched us waits for the first scan.
                self.pendingOpen = nil
                self.openLayout(url)
            }
            if !self.state.hasGridFile { self.showFirstRun() }
            if CommandLine.arguments.contains("--show") { self.overlay.show() }
        }
        startWatching()
        // Slow fallback in case FSEvents misses something (e.g. network volumes).
        periodicRescan = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startWatching(onlyIfChanged: true)
                self?.state.rescan()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        overlay?.toggle()
        return false
    }

    /// A layout file opened from Finder. Arrives before applicationDidFinishLaunching when the
    /// double-click is what launched us.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        guard catalogReady else {
            pendingOpen = url
            return
        }
        openLayout(url)
    }

    private func openLayout(_ url: URL) {
        overlay.hide(deactivate: false)
        NSApp.activate()
        // Read first: a file that can't be loaded shouldn't ask to replace anything.
        guard let layout = readLayout(at: url) else { return }
        if !state.grid.allApps.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "Replace your layout with “\(url.deletingPathExtension().lastPathComponent)”?")
            alert.informativeText = String(localized: "Your current pages and folders will be replaced. ⌘Z in the grid undoes it.")
            alert.addButton(withTitle: String(localized: "Replace"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        load(layout, from: url)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The last changes would be lost on the way out: say so, so they can be kept open.
        guard let state, !state.saveNow(reportingFailure: false) else { return .terminateNow }
        overlay.hide(deactivate: false)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Your latest layout changes couldn't be saved")
        alert.informativeText = String(localized: "If you quit now, they'll be lost. Keep LaunchGrid open to try again once the problem is fixed, or save the layout elsewhere from Settings › Library.\n\n\(state.lastSaveError?.localizedDescription ?? "")")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Don't Quit"))
        alert.addButton(withTitle: String(localized: "Quit Anyway"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.saveNow(reportingFailure: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Integration

    /// Registers the global shortcut; false when macOS refused it. With a `fallback`, a refused
    /// shortcut is put back to that one in the preferences, so the next launch doesn't start
    /// without a working shortcut.
    @discardableResult
    private func applyHotkey(fallback: (keyCode: UInt32, modifiers: UInt32)? = nil) -> Bool {
        // Carbon lets a second process register the same combo, so a scratch copy would fight
        // the installed one for it. Leave it to the installed copy while that one runs.
        if Preferences.isScratch && !Self.otherInstances.isEmpty {
            HotkeyService.shared.unregister()
            state.hotkeyProblem = String(localized: "This is a scratch copy: the shortcut stays with the LaunchGrid that's already running.")
            return true
        }
        guard prefs.hotkeyEnabled else {
            HotkeyService.shared.unregister()
            state.hotkeyProblem = nil
            return true
        }
        return Self.registerHotkey(prefs: prefs, state: state, fallback: fallback,
                                   register: { HotkeyService.shared.register(keyCode: $0, modifiers: $1) },
                                   activeCombo: HotkeyService.shared.activeCombo)
    }

    /// The registering half of `applyHotkey`, with the hotkey service passed in for tests.
    static func registerHotkey(prefs: Preferences, state: AppState, fallback: (keyCode: UInt32, modifiers: UInt32)?,
                               register: (UInt32, UInt32) -> Bool,
                               activeCombo: @autoclosure () -> (keyCode: UInt32, modifiers: UInt32)?) -> Bool {
        let ok = register(prefs.hotkeyKeyCode, prefs.hotkeyModifiers)
        if ok {
            state.hotkeyProblem = nil
        } else if let fallback, (fallback.keyCode, fallback.modifiers) != (prefs.hotkeyKeyCode, prefs.hotkeyModifiers),
                  register(fallback.keyCode, fallback.modifiers) {
            let refused = KeyCombo.describe(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
            let kept = KeyCombo.describe(keyCode: fallback.keyCode, modifiers: fallback.modifiers)
            prefs.hotkeyKeyCode = fallback.keyCode
            prefs.hotkeyModifiers = fallback.modifiers
            state.hotkeyProblem = String(localized: "\(refused) couldn't be registered (macOS or another app may reserve it), so LaunchGrid kept \(kept). Pick another one.")
        } else {
            // A failed change keeps the previous shortcut registered.
            if let active = activeCombo() {
                let previous = KeyCombo.describe(keyCode: active.keyCode, modifiers: active.modifiers)
                state.hotkeyProblem = String(localized: "This shortcut couldn't be registered (macOS or another app may reserve it), so it won't open LaunchGrid. \(previous) still opens it. Pick another one.")
            } else {
                state.hotkeyProblem = String(localized: "This shortcut couldn't be registered (macOS or another app may reserve it), so it won't open LaunchGrid. Pick another one.")
            }
        }
        return ok
    }

    private func warnHotkeyFailed() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "LaunchGrid's shortcut couldn't be registered")
        let shortcut = KeyCombo.describe(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
        // Only the icons that are on: the Dock icon is off by default.
        alert.informativeText = switch (prefs.showInMenuBar, prefs.showInDock) {
        case (true, true): String(localized: "\(shortcut) couldn't be registered as a global shortcut; it may be reserved by macOS or another app. Open LaunchGrid from the menu bar or Dock icon, or choose a different shortcut.")
        case (false, true): String(localized: "\(shortcut) couldn't be registered as a global shortcut; it may be reserved by macOS or another app. Open LaunchGrid from its Dock icon, or choose a different shortcut.")
        default: String(localized: "\(shortcut) couldn't be registered as a global shortcut; it may be reserved by macOS or another app. Open LaunchGrid from its menu bar icon, or choose a different shortcut.")
        }
        alert.addButton(withTitle: String(localized: "Choose Shortcut…"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        if alert.runModal() == .alertFirstButtonReturn { showSettings() }
    }

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(prefs.showInDock ? .regular : .accessory)
    }

    private func applyMenuBarIcon() {
        guard prefs.showInMenuBar else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        }
        statusItem?.button?.image = switch prefs.menuBarIconStyle {
        case .monochrome: NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "LaunchGrid")
        case .colour: Self.colourMenuBarIcon
        }
    }

    /// The app logo (see scripts/make-icon.swift) redrawn at menu-bar size, so it stays crisp at any scale.
    private static let colourMenuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let body = rect.insetBy(dx: 0.5, dy: 0.5)
            let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
            NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.20, blue: 0.42, alpha: 1),
                                NSColor(srgbRed: 0.36, green: 0.22, blue: 0.62, alpha: 1)])!.draw(in: shape, angle: -60)
            let colors: [NSColor] = [
                .systemPink, .systemOrange, .systemYellow,
                .systemGreen, .systemTeal, .systemBlue,
                .systemIndigo, .systemPurple, .white,
            ]
            let tile = body.width * 0.206, gap = body.width * 0.063
            let origin = (body.width - tile * 3 - gap * 2) / 2
            for i in 0..<9 {
                let c = i % 3, r = 2 - i / 3
                let tileRect = NSRect(x: body.minX + origin + CGFloat(c) * (tile + gap),
                                      y: body.minY + origin + CGFloat(r) * (tile + gap), width: tile, height: tile)
                colors[i].setFill()
                NSBezierPath(roundedRect: tileRect, xRadius: tile * 0.26, yRadius: tile * 0.26).fill()
            }
            return true
        }
        image.accessibilityDescription = "LaunchGrid"
        return image
    }()

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            guard let statusItem else { return }
            statusItem.menu = makeMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            overlay.toggle()
        }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Show LaunchGrid"), action: #selector(showOverlay), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: String(localized: "Add Missing Apps…"), action: #selector(showAddMissing), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Choose Apps…"), action: #selector(showChooseApps), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Sort Everything"), action: #selector(sortEverything), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Save Grid File…"), action: #selector(saveGridFileFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Load Grid File…"), action: #selector(loadGridFile), keyEquivalent: "").target = self
        let importMenu = NSMenu()
        let appGrid = importMenu.addItem(withTitle: String(localized: "From AppGrid"), action: #selector(importAppGrid), keyEquivalent: "")
        appGrid.target = self
        appGrid.isEnabled = LaunchpadImporter.appGridDatabaseURL != nil
        let launchpad = importMenu.addItem(withTitle: String(localized: "From Launchpad"), action: #selector(importLaunchpad), keyEquivalent: "")
        launchpad.target = self
        launchpad.isEnabled = LaunchpadImporter.launchpadDatabaseURL != nil
        importMenu.autoenablesItems = false
        let importItem = menu.addItem(withTitle: String(localized: "Import"), action: nil, keyEquivalent: "")
        menu.setSubmenu(importMenu, for: importItem)
        menu.addItem(withTitle: String(localized: "Rebuild from Scratch…"), action: #selector(confirmRebuild), keyEquivalent: "").target = self
        menu.addItem(.separator())
        // Without the Dock icon (the default) there's no app menu, so About is here too.
        menu.addItem(withTitle: String(localized: "About LaunchGrid"), action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "LaunchGrid Support"), action: #selector(openSupport), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Privacy Policy"), action: #selector(openPrivacyPolicy), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit LaunchGrid"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// Watches the scan folders, including any not created yet; `onlyIfChanged` keeps the
    /// current watcher when that set is the same.
    private func startWatching(onlyIfChanged: Bool = false) {
        let roots = prefs.scanRoots.map(\.path)
        if onlyIfChanged, let watcher, watcher.paths == roots { return }
        watcher = FolderWatcher(paths: roots) { [weak self] in
            // An install produces bursts of events; scan once things settle.
            self?.rescanDebounce?.cancel()
            self?.rescanDebounce = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.state.rescan()
            }
        }
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: String(localized: "LaunchGrid"), action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About LaunchGrid"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "LaunchGrid Support"), action: #selector(openSupport), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: String(localized: "Privacy Policy"), action: #selector(openPrivacyPolicy), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide LaunchGrid"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "Quit LaunchGrid"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.setSubmenu(appMenu, for: appItem)

        let editItem = main.addItem(withTitle: String(localized: "Edit"), action: nil, keyEquivalent: "")
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.setSubmenu(edit, for: editItem)

        let windowItem = main.addItem(withTitle: String(localized: "Window"), action: nil, keyEquivalent: "")
        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.setSubmenu(window, for: windowItem)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    // MARK: Windows

    var libraryActions: LibraryActions {
        LibraryActions(
            rebuild: { [weak self] style in
                self?.state.build(style: style)
                self?.closeFirstRunIfDone()
            },
            importAppGrid: { [weak self] in self?.importAppGrid() },
            importLaunchpad: { [weak self] in self?.importLaunchpad() },
            loadFile: { [weak self] in self?.loadGridFile() },
            saveFile: { [weak self] in self?.saveGridFile() },
            addMissing: { [weak self] in self?.showAddMissing() },
            chooseApps: { [weak self] in self?.showChooseApps() },
            hotkeyChanged: { [weak self] fallback in self?.applyHotkey(fallback: fallback) },
            dockChanged: { [weak self] in
                self?.applyDockPolicy()
                NSApp.activate()
            },
            menuBarChanged: { [weak self] in self?.applyMenuBarIcon() },
            windowModeChanged: { [weak self] in self?.overlay.modeChanged() },
            foldersChanged: { [weak self] in
                self?.startWatching()
                self?.state.rescan()
            }
        )
    }

    private func present<V: View>(_ key: String, title: String, resizable: Bool = false, @ViewBuilder content: (@escaping () -> Void) -> V) {
        overlay.hide(deactivate: false)
        if let existing = windows[key] {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let close: () -> Void = { [weak self] in self?.windows[key]?.close() }
        let root = content(close)
            .environment(state)
            .environment(\.libraryActions, libraryActions)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .resizable] : [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(key)
        window.delegate = self
        window.center()
        windows[key] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let key = window.identifier?.rawValue else { return }
        windows[key] = nil
        if key == "firstRun" && !state.hasGridFile {
            // Closed without choosing: start with the category layout.
            state.build(style: .byCategory)
        }
    }

    @objc func showOverlay() { overlay.show() }

    // The App Store asks for both pages to be reachable from inside the app.
    static let website = URL(string: "https://launchgrid.sglavoie.com/")!
    @objc func showAbout() {
        overlay.hide(deactivate: false)
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc func openSupport() { NSWorkspace.shared.open(Self.website.appendingPathComponent("support/")) }
    @objc func openPrivacyPolicy() { NSWorkspace.shared.open(Self.website.appendingPathComponent("privacy/")) }

    @objc func showSettings() {
        let actions = libraryActions
        present("settings", title: String(localized: "LaunchGrid Settings")) { _ in SettingsView(actions: actions) }
    }

    @objc func showAddMissing() {
        present("addMissing", title: String(localized: "Add Missing Apps"), resizable: true) { close in AddMissingAppsView(close: close) }
    }

    @objc func showChooseApps() {
        present("chooseApps", title: String(localized: "Choose Apps"), resizable: true) { close in ChooseAppsView(close: close) }
    }

    func showFirstRun() {
        let actions = libraryActions
        present("firstRun", title: String(localized: "Welcome")) { close in FirstRunView(actions: actions, close: close) }
    }

    /// From the menu bar the grid is hidden, so the change and its undo aren't in view: confirm first.
    @objc func sortEverything() {
        overlay.hide(deactivate: false)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Sort everything alphabetically?")
        alert.informativeText = String(localized: "Every page is re-flowed and page titles are cleared. Folders stay intact. ⌘Z in the grid undoes it.")
        alert.addButton(withTitle: String(localized: "Sort"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.sortEverything()
    }

    @objc func confirmRebuild() {
        overlay.hide(deactivate: false)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Rebuild the grid from scratch?")
        alert.informativeText = String(localized: "Folders, page titles and your custom order will be replaced. ⌘Z in the grid undoes it.")
        alert.addButton(withTitle: String(localized: "By Category"))
        alert.addButton(withTitle: String(localized: "Alphabetically"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: state.build(style: .byCategory)
        case .alertSecondButtonReturn: state.build(style: .alphabetical)
        default: return
        }
        closeFirstRunIfDone()
    }

    // MARK: Import / export

    @objc func importAppGrid() {
        guard let url = LaunchpadImporter.appGridDatabaseURL, allowReading(url, from: "AppGrid") else { return }
        importDatabase(url, from: "AppGrid")
    }

    @objc func importLaunchpad() {
        guard let url = LaunchpadImporter.launchpadDatabaseURL, allowReading(url, from: "Launchpad") else { return }
        importDatabase(url, from: "Launchpad")
    }

    /// Inside the sandbox, a database outside it can only be read once the person picks its
    /// folder (which also covers its write-ahead log). The panel opens on that folder, so
    /// allowing it is one click.
    private func allowReading(_ url: URL, from source: String) -> Bool {
        guard Sandbox.isActive, !FileManager.default.isReadableFile(atPath: url.path) else { return true }
        overlay.hide(deactivate: false)
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.message = String(localized: "To import your \(source) layout, allow LaunchGrid to read this folder.")
        panel.prompt = String(localized: "Allow")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return false }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            showError(String(localized: "Could not import from \(source)"), String(localized: "Choose the folder that holds the \(source) database: \(url.deletingLastPathComponent().path)"))
            return false
        }
        return true
    }

    private func importDatabase(_ url: URL, from source: String) {
        let rows = state.grid.rows, columns = state.grid.columns
        let installed = state.installed.map(\.path)
        Task {
            // Reading the database and asking Launch Services about every app can take a while.
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    try LaunchpadImporter.importDatabase(at: url, rows: rows, columns: columns, installed: installed) { id in
                        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
                    }
                }
            }.value
            switch outcome {
            case .failure(let error):
                showError(String(localized: "Could not import from \(source)"), error.localizedDescription)
            case .success(let result):
                guard result.imported > 0 else {
                    showError(String(localized: "Nothing to import"), String(localized: "No apps in the \(source) layout could be found on this Mac."))
                    return
                }
                state.replaceGrid(AppState.keepingExclusions(state.grid.removedBundleIDs, in: result.grid))
                // Whole sentences, so a translation can order them its own way.
                let (n, skipped, twice) = (result.imported, result.skipped.count, result.duplicates.count)
                let message = switch (skipped > 0, twice > 0) {
                case (false, false): String(localized: "Imported \(n) apps from \(source)")
                case (true, false): String(localized: "Imported \(n) apps from \(source); skipped \(skipped) not installed")
                case (false, true): String(localized: "Imported \(n) apps from \(source); skipped \(twice) listed twice")
                case (true, true): String(localized: "Imported \(n) apps from \(source); skipped \(skipped) not installed and \(twice) listed twice")
                }
                state.showToast(message)
                closeFirstRunIfDone()
            }
        }
    }

    /// From the menu bar there's nothing in view to confirm the save in; the grid says so next time it opens.
    @objc func saveGridFileFromMenu() {
        if let url = saveGridFile() { state.showToast(String(localized: "Saved \(url.lastPathComponent)")) }
    }

    /// Saves the layout to a file the person picks; returns where, or nil if cancelled or failed.
    @discardableResult
    func saveGridFile() -> URL? {
        overlay.hide(deactivate: false)
        NSApp.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.launchGridLayout]
        panel.nameFieldStringValue = "LaunchGrid Layout.launchgrid"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try GridStore.encode(state.grid).write(to: url, options: .atomic)
            return url
        } catch {
            showError(String(localized: "Could not save the grid file"), error.localizedDescription)
            return nil
        }
    }

    @objc func loadGridFile() {
        overlay.hide(deactivate: false)
        NSApp.activate()
        let panel = NSOpenPanel()
        // Layouts, plus SQLite databases for the importer: `.agrid` files and copies of a
        // Launchpad or AppGrid database. Their live, extension-less `db` files are imported
        // from the Import menu instead.
        panel.allowedContentTypes = [.launchGridLayout, .json]
            + ["agrid", "db", "sqlite", "sqlite3"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let layout = readLayout(at: url) else { return }
        load(layout, from: url)
    }

    /// What a file opened as a layout holds.
    private enum OpenedLayout {
        case grid(Grid)
        /// A Launchpad or AppGrid database (or an `.agrid` file), for the importer.
        case database
    }

    /// Reads and checks a layout file; nil, after saying why, when it can't be loaded.
    private func readLayout(at url: URL) -> OpenedLayout? {
        do {
            let data = try Data(contentsOf: url)
            if data.prefix(16) == Data("SQLite format 3\0".utf8) { return .database }
            return .grid(try GridStore.decode(data))
        } catch {
            showError(String(localized: "Could not load the grid file"), error.localizedDescription)
            return nil
        }
    }

    private func load(_ layout: OpenedLayout, from url: URL) {
        switch layout {
        case .database:
            importDatabase(url, from: url.lastPathComponent)
        case .grid(let grid):
            state.replaceGrid(AppState.keepingExclusions(state.grid.removedBundleIDs, in: grid))
            state.showToast(String(localized: "Loaded \(url.lastPathComponent)"))
            closeFirstRunIfDone()
        }
    }

    private func closeFirstRunIfDone() {
        if state.hasGridFile { windows["firstRun"]?.close() }
    }

    private func showRecoveryNotice(_ message: String, file: URL) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Your layout was restored from the previous save")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Show in Finder"))
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }

    private func showError(_ title: String, _ detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
