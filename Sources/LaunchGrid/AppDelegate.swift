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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let storeURL = ProcessInfo.processInfo.environment["LAUNCHGRID_DATA_DIR"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("grid.json") } ?? GridStore.defaultURL
        state = AppState(prefs: prefs, store: GridStore(url: storeURL))
        overlay = OverlayController(state: state)
        state.onHide = { [weak self] in self?.overlay.hide() }
        state.onOpenSettings = { [weak self] in self?.showSettings() }
        state.onAddMissing = { [weak self] in self?.showAddMissing() }

        buildMainMenu()
        applyDockPolicy()
        applyMenuBarIcon()
        HotkeyService.shared.onTrigger = { [weak self] in self?.overlay.toggle() }
        if !applyHotkey() {
            // After launch finishes, so the alert doesn't hold up the first scan.
            DispatchQueue.main.async { self.warnHotkeyTaken() }
        }

        DistributedNotificationCenter.default().addObserver(forName: Self.showNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlay.show() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.rescan() }
        }

        IconProvider.shared.prewarm(state.grid.allApps.map(\.path))
        state.rescan { [weak self] in
            guard let self else { return }
            if let script = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_SCRIPT"] {
                DebugScript.run(script, state: self.state, overlay: self.overlay, delegate: self)
                return
            }
            if !self.state.hasGridFile { self.showFirstRun() }
            if CommandLine.arguments.contains("--show") { self.overlay.show() }
        }
        startWatching()
        // Slow fallback in case FSEvents misses something (e.g. network volumes).
        periodicRescan = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.rescan() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        overlay.toggle()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Integration

    /// Registers the global shortcut; false when another app already holds it.
    @discardableResult
    private func applyHotkey() -> Bool {
        guard prefs.hotkeyEnabled else {
            HotkeyService.shared.unregister()
            state.hotkeyProblem = nil
            return true
        }
        let ok = HotkeyService.shared.register(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
        state.hotkeyProblem = ok ? nil : "Another app is using this shortcut, so it won't open LaunchGrid. Pick another one."
        return ok
    }

    private func warnHotkeyTaken() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "LaunchGrid's shortcut is taken"
        alert.informativeText = "\(KeyCombo.describe(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)) is already used by another app. "
            + "Open LaunchGrid from the menu bar or Dock icon, or choose a different shortcut."
        alert.addButton(withTitle: "Choose Shortcut…")
        alert.addButton(withTitle: "Not Now")
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
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "LaunchGrid")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

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

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show LaunchGrid", action: #selector(showOverlay), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Add Missing Apps…", action: #selector(showAddMissing), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Sort Everything", action: #selector(sortEverything), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Save Grid File…", action: #selector(saveGridFile), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Load Grid File…", action: #selector(loadGridFile), keyEquivalent: "").target = self
        let importMenu = NSMenu()
        let appGrid = importMenu.addItem(withTitle: "From AppGrid", action: #selector(importAppGrid), keyEquivalent: "")
        appGrid.target = self
        appGrid.isEnabled = LaunchpadImporter.appGridDatabaseURL != nil
        let launchpad = importMenu.addItem(withTitle: "From Launchpad", action: #selector(importLaunchpad), keyEquivalent: "")
        launchpad.target = self
        launchpad.isEnabled = LaunchpadImporter.launchpadDatabaseURL != nil
        importMenu.autoenablesItems = false
        let importItem = menu.addItem(withTitle: "Import", action: nil, keyEquivalent: "")
        menu.setSubmenu(importMenu, for: importItem)
        menu.addItem(withTitle: "Rebuild from Scratch…", action: #selector(confirmRebuild), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LaunchGrid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func startWatching() {
        watcher = FolderWatcher(paths: prefs.scanRoots.map(\.path)) { [weak self] in
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
        let appItem = main.addItem(withTitle: "LaunchGrid", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LaunchGrid", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide LaunchGrid", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit LaunchGrid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.setSubmenu(appMenu, for: appItem)

        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.setSubmenu(edit, for: editItem)

        let windowItem = main.addItem(withTitle: "Window", action: nil, keyEquivalent: "")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.setSubmenu(window, for: windowItem)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    // MARK: Windows

    private var libraryActions: LibraryActions {
        LibraryActions(
            rebuild: { [weak self] style in self?.state.build(style: style) },
            importAppGrid: { [weak self] in self?.importAppGrid() },
            importLaunchpad: { [weak self] in self?.importLaunchpad() },
            loadFile: { [weak self] in self?.loadGridFile() },
            saveFile: { [weak self] in self?.saveGridFile() },
            addMissing: { [weak self] in self?.showAddMissing() },
            hotkeyChanged: { [weak self] in self?.applyHotkey() },
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

    @objc func showSettings() {
        let actions = libraryActions
        present("settings", title: "LaunchGrid Settings") { _ in SettingsView(actions: actions) }
    }

    @objc func showAddMissing() {
        present("addMissing", title: "Add Missing Apps", resizable: true) { close in AddMissingAppsView(close: close) }
    }

    private func showFirstRun() {
        let actions = libraryActions
        present("firstRun", title: "Welcome") { close in FirstRunView(actions: actions, close: close) }
    }

    @objc func sortEverything() { state.sortEverything() }

    @objc func confirmRebuild() {
        overlay.hide(deactivate: false)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Rebuild the grid from scratch?"
        alert.informativeText = "Folders, page titles and your custom order will be replaced. ⌘Z in the grid undoes it."
        alert.addButton(withTitle: "By Category")
        alert.addButton(withTitle: "Alphabetically")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: state.build(style: .byCategory)
        case .alertSecondButtonReturn: state.build(style: .alphabetical)
        default: break
        }
    }

    // MARK: Import / export

    @objc func importAppGrid() {
        guard let url = LaunchpadImporter.appGridDatabaseURL else { return }
        importDatabase(url, from: "AppGrid")
    }

    @objc func importLaunchpad() {
        guard let url = LaunchpadImporter.launchpadDatabaseURL else { return }
        importDatabase(url, from: "Launchpad")
    }

    private func importDatabase(_ url: URL, from source: String) {
        do {
            let result = try LaunchpadImporter.importDatabase(at: url, rows: state.grid.rows, columns: state.grid.columns) { id in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
            }
            guard result.imported > 0 else {
                showError("Nothing to import", "No apps in the \(source) layout could be found on this Mac.")
                return
            }
            state.replaceGrid(result.grid)
            var message = "Imported \(result.imported) apps from \(source)"
            if !result.skipped.isEmpty { message += "; skipped \(result.skipped.count) not installed" }
            state.showToast(message)
            closeFirstRunIfDone()
        } catch {
            showError("Could not import from \(source)", error.localizedDescription)
        }
    }

    @objc func saveGridFile() {
        overlay.hide(deactivate: false)
        NSApp.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.launchGridLayout]
        panel.nameFieldStringValue = "LaunchGrid Layout.appgrid"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try GridStore.encode(state.grid).write(to: url, options: .atomic)
        } catch {
            showError("Could not save the grid file", error.localizedDescription)
        }
    }

    @objc func loadGridFile() {
        overlay.hide(deactivate: false)
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.launchGridLayout, .json, UTType(filenameExtension: "agrid") ?? .data, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            if data.prefix(16) == Data("SQLite format 3\0".utf8) {
                importDatabase(url, from: url.lastPathComponent)
                return
            }
            state.replaceGrid(try GridStore.decode(data))
            state.showToast("Loaded \(url.lastPathComponent)")
            closeFirstRunIfDone()
        } catch {
            showError("Could not load the grid file", error.localizedDescription)
        }
    }

    private func closeFirstRunIfDone() {
        if state.hasGridFile { windows["firstRun"]?.close() }
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
