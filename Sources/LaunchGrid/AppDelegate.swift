import AppKit
import CryptoKit
import os
import SwiftUI
import UniformTypeIdentifiers
import LaunchGridCore

extension UTType {
    static let launchGridLayout = UTType(exportedAs: "com.sglavoie.launchgrid.layout", conformingTo: .json)
}

/// Finder can send several files in one open event, including before the first scan.
/// Each load (and its confirmation or import) finishes before the next one starts.
@MainActor
final class LayoutOpenQueue {
    private var pending: [URL] = []
    private var ready = false
    private var opening = false
    private let open: (URL, @escaping @MainActor () -> Void) -> Void
    private let onEmpty: () -> Void

    init(open: @escaping (URL, @escaping @MainActor () -> Void) -> Void,
         onEmpty: @escaping () -> Void) {
        self.open = open
        self.onEmpty = onEmpty
    }

    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending.append(contentsOf: urls)
        advance()
    }

    func becomeReady() {
        guard !ready else { return }
        ready = true
        advance()
    }

    private func advance() {
        guard ready, !opening else { return }
        guard !pending.isEmpty else { onEmpty(); return }
        opening = true
        let next = pending.removeFirst()
        open(next) { [weak self] in
            guard let self else { return }
            self.opening = false
            self.advance()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static let showNotification = Notification.Name("com.sglavoie.launchgrid.show")

    let prefs = Preferences()
    private(set) var state: AppState!
    private var overlay: OverlayController!
    /// The trackpad pinch and hot corner that open the grid, as set in Settings.
    private(set) var gestures: GestureWatcher!
    private var statusItem: NSStatusItem?
    /// The menu-bar icon on screen, for the debug scripts.
    var statusButtonScreenFrame: CGRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    /// The menu-bar icon's menu while VoiceOver runs, filled each time it opens.
    private lazy var voiceOverMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()
    private var voiceOverObservation: NSKeyValueObservation?
    /// Set by the debug scripts to act as if VoiceOver were on.
    var attachesStatusMenu = false
    private var watcher: FolderWatcher?
    /// The folders a watcher is being made for, while their real paths are read.
    private var watcherPending: [String]?
    private var rescanDebounce: Task<Void, Never>?
    private var periodicRescan: Timer?
    private var windows: [String: NSWindow] = [:]
    private lazy var layoutOpenQueue = LayoutOpenQueue(
        open: { [weak self] url, finished in
            guard let self else { finished(); return }
            self.openLayout(url, finished: finished)
        },
        onEmpty: { [weak self] in
            guard let self, !self.state.hasGridFile else { return }
            self.showFirstRun()
        }
    )

    /// Other running copies of LaunchGrid (same bundle ID), leaving out scratch runs.
    static var otherInstances: [NSRunningApplication] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated && !isScratch($0) }
    }

    /// Held for as long as this copy runs; the system lets it go when the process ends,
    /// crashed or not.
    enum InstanceLockResult: Equatable {
        case acquired
        case held
        case unavailable(Int32)
    }

    nonisolated(unsafe) private static var instanceLocks: [Int32] = []

    /// Takes the lock beside the layout that only one copy can hold, so two started at the
    /// same moment (the login item and a click) can't both miss the other in `otherInstances`
    /// and both answer the shortcut and save. A per-user lock also covers a data folder that
    /// cannot hold a lock file; every copy takes it, so a permission change cannot split them.
    static func acquireInstanceLock(in folder: URL = storeURL.deletingLastPathComponent(),
                                    fallbackDirectory: URL = FileManager.default.temporaryDirectory) -> InstanceLockResult {
        let path = folder.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let fallback = fallbackDirectory.appendingPathComponent("LaunchGrid-\(digest).lock")
        let fallbackFD = open(fallback.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fallbackFD >= 0 else { return .unavailable(errno) }
        guard flock(fallbackFD, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fallbackFD)
            return code == EWOULDBLOCK ? .held : .unavailable(code)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appendingPathComponent(".instance.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        // A read-only data folder is still usable for loading and exporting its layout.
        // The fallback lock keeps same-user copies from writing it concurrently.
        guard fd >= 0 else {
            NSLog("LaunchGrid: could not open the layout lock at \(folder.path): \(String(cString: strerror(errno))); using the per-user lock")
            instanceLocks.append(fallbackFD)
            return .acquired
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            close(fallbackFD)
            return code == EWOULDBLOCK ? .held : .unavailable(code)
        }
        instanceLocks.append(contentsOf: [fallbackFD, fd])
        return .acquired
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

    /// The layout: in a scratch run's own folder, or in Application Support.
    nonisolated static let storeURL = ProcessInfo.processInfo.environment["LAUNCHGRID_DATA_DIR"]
        .map { URL(fileURLWithPath: $0).appendingPathComponent("grid.json") } ?? GridStore.defaultURL

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState(prefs: prefs, store: GridStore(url: Self.storeURL))
        #if !APP_STORE
        // For the debug scripts: the first scan hangs this many seconds, as on a stalled volume.
        if let hang = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_SCAN_HANG"].flatMap(Double.init) {
            let scanner = state.scanner
            let first = OSAllocatedUnfairLock(initialState: true)
            state.scanner = { roots in
                if first.withLock({ let was = $0; $0 = false; return was }) { Thread.sleep(forTimeInterval: hang) }
                return scanner(roots)
            }
        }
        #endif
        #if !APP_STORE
        // For the debug scripts: how long a scan may hang before what waits for it goes ahead.
        if let s = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_SCAN_TIMEOUT"].flatMap(Double.init) {
            state.scanTimeout = .seconds(s)
        }
        #endif
        // Only the sandboxed build keeps bookmarks, so only it needs telling which apps are in use.
        if Sandbox.isActive {
            state.onAppPathsInUse = { [prefs, weak state = state as AppState?] in
                FileAccess.forgetUnused(notIn: $0, actionsInUse: state?.actionPathsInUse ?? [], prefs: prefs)
            }
            FileAccess.pathsInUse = { [weak state = state as AppState?] in state?.pathsInUse ?? [] }
            FileAccess.actionPathsInUse = { [weak state = state as AppState?] in state?.actionPathsInUse ?? [] }
        }
        FileAccess.onBookmarkFailure = { [weak self] url in
            self?.showError(String(localized: "LaunchGrid can't keep access to “\(url.lastPathComponent)”"),
                            String(localized: "LaunchGrid couldn't confirm lasting access. If this item becomes unavailable, choose it again."))
        }
        overlay = OverlayController(state: state)
        gestures = GestureWatcher(prefs: prefs, overlay: overlay)
        gestures.apply()
        state.onHide = { [weak self] in self?.overlay.hide() }
        state.onHideForLaunch = { [weak self] in
            // Long enough to see the opened tile zoom (`OpenMotion`); none of it with Reduce Motion.
            let zoom = !Motion.reduced
            self?.overlay.hide(deactivate: false, duration: zoom ? 0.2 : 0.12)
        }
        state.onLaunchedBehind = { [weak self] in self?.overlay.openedBehind($0) }
        state.onError = { [weak self] title, detail in self?.showError(title, detail) }
        state.onSaveFailure = { [weak self] title, detail in self?.showSaveFailure(title, detail) }
        state.onOpenSettings = { [weak self] in self?.showSettings() }
        state.onAddMissing = { [weak self] in self?.showAddMissing() }
        state.onScanFoldersMoved = { [weak self] in
            self?.startWatching(onlyIfChanged: true)
            self?.state.rescan()
        }
        state.onEditAction = { [weak self] action, pageID in self?.showActionEditor(action, pageID: pageID) }
        state.onConfirmRunAgain = { [weak self] action in self?.confirmRunAgain(action) ?? false }
        state.onShowLastOutput = { [weak self] action in self?.showLastOutput(action) }
        state.actionRunner.terminalApp = { [prefs] in prefs.terminalApp }

        #if !APP_STORE
        if let scenario = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_UI_TEST"] {
            guard Preferences.isScratch,
                  ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_DEFAULTS"]?.hasPrefix("com.sglavoie.launchgrid.uitest.") == true else {
                FileHandle.standardError.write(Data("UI tests require a scratch layout and a dedicated uitest settings domain.\n".utf8))
                exit(1)
            }
            buildMainMenu()
            applyDockPolicy()
            DebugUITest.run(scenario, state: state, overlay: overlay, delegate: self)
            return
        }
        #endif
        // Before the first scan, so it sees the folders and apps the bookmarks reach. Resolved
        // off the main thread: one to a volume that has stopped answering could hang the launch.
        // The grid follows moved apps in the same main-actor turn their bookmarks move in: a
        // save finishing in between would see the new paths unused and forget them.
        let restored = Task { [state] in state.followMovedApps(await FileAccess.restoreInBackground(prefs: prefs)) }
        buildMainMenu()
        applyDockPolicy()
        applyMenuBarIcon()
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            Task { @MainActor in self?.applyMenuBarIcon() }
        }
        // The grid comes out of where the pointer is.
        HotkeyService.shared.onTrigger = { [weak self] in self?.overlay.toggle(from: NSEvent.mouseLocation) }
        SettingsPaneCatalog.load()
        if !applyHotkey() {
            // After launch finishes, so the alert doesn't hold up the first scan.
            DispatchQueue.main.async { self.warnHotkeyFailed() }
        }
        if let notice = state.recoveryNotice {
            state.recoveryNotice = nil
            DispatchQueue.main.async { self.showRecoveryNotice(notice.title, notice.message, file: notice.file) }
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
                    _ = Task { [weak self] in
                        guard let prefs = self?.prefs else { return }
                        // Access to what was on a volume that went is let go, so it is taken up
                        // again (and followed to a new name) when the volume returns.
                        FileAccess.releaseUnmounted(mounted: await Disk.run { Volume.mountedNames() })
                        let moves = await FileAccess.restoreInBackground(prefs: prefs)
                        self?.state.followMovedApps(moves)
                        self?.startWatching(onlyIfChanged: true)
                        self?.state.rescan()
                    }
                }
            }
        }
        // The dots under running apps.
        state.refreshRunningApps()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.state.refreshRunningApps() }
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

        // Icons first drawn as placeholders that have now come: the tiles ask again.
        IconProvider.shared.onRedrawn = { [weak self] in
            Task { @MainActor in self?.state.iconGeneration += 1 }
        }
        IconProvider.shared.prewarm(state.grid.allApps.map(\.path))
        Task { [self] in
            await restored.value
            state.rescan { [weak self] in
                guard let self else { return }
                self.overlay.prewarm()
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
                self.layoutOpenQueue.becomeReady()
                if CommandLine.arguments.contains("--show") { self.overlay.show() }
            }
            startWatching()
        }
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
        layoutOpenQueue.enqueue(urls)
    }

    #if !APP_STORE
    /// The debug `open` step: as Finder opening a file, without the launch-time queue, which
    /// debug runs never make ready.
    func debugOpen(_ url: URL) { openLayout(url) }
    #endif

    /// A completed layout may have no apps but still contain pages, titles or grid size
    /// choices worth keeping. Welcome-screen exclusions precede the first layout.
    static func shouldConfirmReplacingLayout(_ state: AppState) -> Bool { state.hasGridFile }

    /// Loads a layout file, from Finder or the Load Grid File panel, asking before it replaces
    /// a grid that has apps on it. `done` gets what happened, for Settings to show.
    /// `finished` runs once it's over, whether the layout loaded or not.
    private func openLayout(_ url: URL, done: (@MainActor (String) -> Void)? = nil,
                            finished: (@MainActor () -> Void)? = nil) {
        overlay.hide(deactivate: false)
        NSApp.activate()
        Task {
            var handedOn = false
            defer { if !handedOn { finished?() } }
            // Read first, off the main thread (a file on a stalled volume mustn't hang the app):
            // a file that can't be loaded shouldn't ask to replace anything.
            guard let layout = await readLayout(at: url) else { return }
            switch layout {
            case .database:
                // Asks once the database is read, and only when apps in it were found.
                handedOn = true
                importDatabase(url, from: url.lastPathComponent, done: done, finished: finished)
            case .grid(let read, let skipped):
                let name = url.deletingPathExtension().lastPathComponent
                // Nothing in the file runs while it loads; its actions wait for a look in the editor.
                guard let grid = reviewActions(in: read, name: name) else { return }
                // Said before replacing anything, as an unreadable saved layout is.
                let leftOut = skipped > 0 ? String(localized: "\(skipped) entries in “\(name)” could not be read and will be left out.") : nil
                if Self.shouldConfirmReplacingLayout(state) {
                    // A slow read may have let the grid open again meanwhile.
                    overlay.hide(deactivate: false)
                    NSApp.activate()
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Replace your layout with “\(name)”?")
                    alert.informativeText = [leftOut, String(localized: "Your current pages and folders will be replaced. ⌘Z in the grid undoes it.")]
                        .compactMap { $0 }.joined(separator: "\n\n")
                    alert.addButton(withTitle: String(localized: "Replace"))
                    alert.addButton(withTitle: String(localized: "Cancel"))
                    #if !APP_STORE
                    if let preset = DebugScript.replaceAnswer {
                        guard preset else { return }
                    } else {
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                    }
                    #else
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    #endif
                } else if let leftOut {
                    showError(String(localized: "Some of “\(name)” couldn't be read"), leftOut)
                }
                state.replaceGrid(AppState.keepingExclusions(state.grid.removedBundleIDs, in: grid, installed: state.selectableApps))
                let message = skipped > 0
                    ? String(localized: "Loaded \(url.lastPathComponent); left out \(skipped) unreadable entries")
                    : String(localized: "Loaded \(url.lastPathComponent)")
                state.showToast(message)
                done?(message)
                closeFirstRunIfDone()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The last changes would be lost on the way out: say so, so they can be kept open.
        guard let state else { return .terminateNow }
        // Only this quit came from a signal: one cancelled below leaves a later ⌘Q asking again.
        let fromSignal = quittingOnSignal
        quittingOnSignal = false
        // An action editor with changes asks first, as its close button does; a signal (a script
        // quitting the app) doesn't wait for an answer.
        if !fromSignal, let open = state.actionEditor, open.hasChanges, windows["actionEditor"] != nil,
           !confirmDiscardEditor(open) {
            bringForward("actionEditor")
            return .terminateCancel
        }
        if state.saveNow(reportingFailure: false) {
            // A failed backup refresh is separate from saving the current layout. Make the
            // warning visible even when this was the only save made before quitting, unless a
            // script is waiting for the app to quit.
            state.reportLastBackupFailure(forceAlert: true, logOnly: fromSignal)
            return .terminateNow
        }
        // Saving again on the way out would fail again, and tell it a second time.
        overlay.hide(deactivate: false, saving: false)
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
        // Commands and scripts still running aren't left behind on their own.
        state?.stopAllRuns()
        state?.saveNow(reportingFailure: false)
    }

    /// Hide LaunchGrid in the menu bar (Window mode leaves it in view): the grid hides as it
    /// does itself, so its search, open folder and edit mode don't come back with it.
    func applicationWillHide(_ notification: Notification) {
        overlay?.hide(deactivate: false)
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

    func warnHotkeyFailed() {
        guard prefs.hotkeyWarningDismissed != prefs.hotkeyID else { return }
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
        // Not Now is remembered for this shortcut, so it isn't asked at every login while
        // another app keeps it; Settings still shows the problem.
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again for this shortcut")
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { prefs.hotkeyWarningDismissed = prefs.hotkeyID }
        if answer == .alertFirstButtonReturn { showSettings() }
    }

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(prefs.showInDock ? .regular : .accessory)
    }

    func applyMenuBarIcon() {
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
            // The menu is otherwise only a right-click away, out of reach of VoiceOver and the keyboard.
            item.button?.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: String(localized: "Show Menu")) { [weak self] in
                    self?.showStatusMenu()
                    return true
                },
            ])
            statusItem = item
        }
        // With VoiceOver, pressing the icon (or VoiceOver's own show-menu command) opens the
        // menu, whose first action shows the grid.
        statusItem?.menu = NSWorkspace.shared.isVoiceOverEnabled || attachesStatusMenu ? voiceOverMenu : nil
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
            showStatusMenu()
        } else {
            // Out of the icon itself.
            let origin = sender.window.map { w in
                let f = w.convertToScreen(sender.convert(sender.bounds, to: nil))
                return CGPoint(x: f.midX, y: f.midY)
            }
            overlay.toggle(from: origin)
        }
    }

    /// Opens the menu-bar icon's menu below it.
    private func showStatusMenu() {
        guard let statusItem, statusItem.menu == nil else {
            statusItem?.button?.performClick(nil)
            return
        }
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === voiceOverMenu else { return }
        menu.removeAllItems()
        for item in makeMenu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let title = version.map { "LaunchGrid \($0)" } ?? "LaunchGrid"
        let about = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Show LaunchGrid"), action: #selector(showOverlay), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: String(localized: "Add Missing Apps…"), action: #selector(showAddMissing), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Choose Apps…"), action: #selector(showChooseApps), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Sort Everything…"), action: #selector(sortEverything), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Sort Everything by Colour…"), action: #selector(sortEverythingByColour), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "New Action…"), action: #selector(newAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Save Grid File…"), action: #selector(saveGridFileFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Load Grid File…"), action: #selector(loadGridFile as () -> Void), keyEquivalent: "").target = self
        let importMenu = NSMenu()
        let appGrid = importMenu.addItem(withTitle: String(localized: "From AppGrid…"), action: #selector(importAppGrid as () -> Void), keyEquivalent: "")
        appGrid.target = self
        appGrid.isEnabled = LaunchpadImporter.appGridDatabaseURL != nil
        let launchpad = importMenu.addItem(withTitle: String(localized: "From Launchpad…"), action: #selector(importLaunchpad as () -> Void), keyEquivalent: "")
        launchpad.target = self
        launchpad.isEnabled = LaunchpadImporter.launchpadDatabaseURL != nil
        importMenu.autoenablesItems = false
        let importItem = menu.addItem(withTitle: String(localized: "Import"), action: nil, keyEquivalent: "")
        menu.setSubmenu(importMenu, for: importItem)
        menu.addItem(withTitle: String(localized: "Rebuild from Scratch…"), action: #selector(confirmRebuild), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Keyboard Shortcuts"), action: #selector(showShortcuts), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "LaunchGrid Support"), action: #selector(openSupport), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Privacy Policy"), action: #selector(openPrivacyPolicy), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit LaunchGrid"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// The Dock icon's menu: the menu-bar icon's, as either can be the only one shown. The Dock
    /// adds its own Quit.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = makeMenu()
        while let last = menu.items.last, last.isSeparatorItem || last.action == #selector(NSApplication.terminate(_:)) {
            menu.removeItem(last)
        }
        for item in menu.items { item.keyEquivalent = "" }
        return menu
    }

    /// Watches the scan folders, including any not created yet; `onlyIfChanged` keeps the
    /// current watcher when that set is the same.
    private func startWatching(onlyIfChanged: Bool = false) {
        let roots = prefs.scanRoots.map(\.path)
        if onlyIfChanged, (watcherPending ?? watcher?.paths) == roots { return }
        watcherPending = roots
        // Where the folders' symlinks lead is read off the main thread: on a volume that has
        // stopped answering, that waits.
        Task { [weak self] in
            let real = await Disk.run { FolderWatcher.resolve(roots) }
            // A later call (the folders changed again meanwhile) makes its own.
            guard let self, self.watcherPending == roots else { return }
            self.watcherPending = nil
            self.watcher = FolderWatcher(paths: roots, realPaths: real) { [weak self] in
                // An install produces bursts of events; scan once things settle.
                self?.rescanDebounce?.cancel()
                self?.rescanDebounce = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    self?.state.rescan()
                }
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
                // The first layout (the welcome window) fits the display; a rebuild keeps the size.
                guard let self else { return }
                self.state.build(style: style, fitToDisplay: !self.state.hasGridFile)
                self.closeFirstRunIfDone()
            },
            importAppGrid: { [weak self] done in self?.importAppGrid(done: done) },
            importLaunchpad: { [weak self] done in self?.importLaunchpad(done: done) },
            loadFile: { [weak self] done in self?.loadGridFile(done: done) },
            saveFile: { [weak self] done in self?.saveGridFile(done: done) },
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
            },
            gesturesChanged: { [weak self] in self?.gestures.apply() },
            pinchUnavailable: { [weak self] in self?.gestures.pinchUnavailable ?? false },
            requestPinchAccess: { [weak self] in self?.gestures.requestPinchAccess() },
            showShortcuts: { [weak self] in self?.showShortcuts() }
        )
    }

    private func present<V: View>(_ key: String, title: String, resizable: Bool = false, @ViewBuilder content: (@escaping () -> Void) -> V) {
        if bringForward(key) { return }
        let close: () -> Void = { [weak self] in self?.windows[key]?.close() }
        let root = content(close)
            .motionSettings()
            .environment(state)
            .environment(\.libraryActions, libraryActions)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .resizable] : [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(key)
        window.delegate = self
        center(window)
        windows[key] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Centres `window` as `center()` does, on the display with the pointer (where the grid
    /// opens) rather than the main one.
    private func center(_ window: NSWindow) {
        window.center()
        let mouse = NSEvent.mouseLocation
        guard let target = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let current = window.screen ?? NSScreen.main, target != current else { return }
        let (from, to) = (current.visibleFrame, target.visibleFrame)
        let size = window.frame.size
        // The same place relative to the display, kept on it when it's smaller.
        let x = to.minX + (to.width - size.width) * ((window.frame.minX - from.minX) / max(from.width - size.width, 1))
        let y = to.minY + (to.height - size.height) * ((window.frame.minY - from.minY) / max(from.height - size.height, 1))
        // On it at every edge; a window taller than the display keeps its title bar in sight.
        window.setFrameOrigin(NSPoint(x: max(to.minX, min(x, to.maxX - size.width)),
                                      y: min(max(to.minY, y), to.maxY - size.height)))
    }

    /// Brings the open window for `key` to the front, over the grid. False when none is open.
    @discardableResult
    private func bringForward(_ key: String) -> Bool {
        guard let window = windows[key] else { return false }
        overlay.hide(deactivate: false)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// The close button and ⌘W ask before an action editor with changes goes; Cancel and Save
    /// close it directly.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.identifier?.rawValue == "actionEditor", let open = state.actionEditor, open.hasChanges else { return true }
        return confirmDiscardEditor(open)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let key = window.identifier?.rawValue else { return }
        windows[key] = nil
        if key == "actionEditor" { state.actionEditor = nil }
        if key == "firstRun" && !state.hasGridFile {
            // Closed without choosing: start with the category layout, once the apps are found.
            state.buildWhenScanned(style: .byCategory)
        }
        // Without a Dock icon, nothing of ours is left to type into: hand focus back to the
        // app before, as hiding the grid does. Next turn, once the window is gone.
        DispatchQueue.main.async { [self] in
            // The About panel counts; the grid's own panel is checked by `isVisible`.
            let others = NSApp.windows.contains { $0.isVisible && $0.level == .normal && !($0 is OverlayPanel) }
            if !state.prefs.showInDock, !overlay.isVisible, !others, NSApp.isActive { NSApp.hide(nil) }
        }
    }

    @objc func showOverlay() { overlay.show() }

    /// The grid, with its Keyboard Shortcuts panel up (the menu-bar and Dock menus, Settings).
    @objc func showShortcuts() {
        guard state.hasGridFile else { return showFirstRun() }
        overlay.show()
        state.showingShortcuts = true
    }

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
        // Before the first layout nothing is missing yet: apps are chosen in the welcome window.
        guard state.hasGridFile else { return showFirstRun() }
        present("addMissing", title: String(localized: "Add Missing Apps"), resizable: true) { close in AddMissingAppsView(close: close) }
    }

    func closeActionEditor() { windows["actionEditor"]?.close() }

    /// From the menu-bar or Dock menu: a new action for the page the grid shows.
    @objc func newAction() { state.newAction() }

    /// Opens the action editor on `action`, or on a new action for the page with `pageID`. One
    /// editor at a time. Asking again for the one that's open brings it forward as it is: after
    /// Test, the action's own app is in front, and New Action… is the way back. Opening a
    /// different one asks first when the open one has changes.
    func showActionEditor(_ action: Action?, pageID: UUID?) {
        if let open = state.actionEditor, windows["actionEditor"] != nil {
            if open.edits(action) {
                bringForward("actionEditor")
                return
            }
            if open.hasChanges, !confirmDiscardEditor(open) {
                bringForward("actionEditor")
                return
            }
        }
        windows["actionEditor"]?.close()
        let model = ActionEditorModel(action: action, pageID: pageID, others: state.grid.allActions)
        state.actionEditor = model
        present("actionEditor", title: action == nil ? String(localized: "New Action") : String(localized: "Edit Action")) { close in
            ActionEditor(model: model, close: close)
        }
    }

    /// Asked before another action's editor replaces one with changes.
    private func confirmDiscardEditor(_ model: ActionEditorModel) -> Bool {
        #if !APP_STORE
        if let answer = DebugScript.discardEditorAnswer { return answer }
        #endif
        overlay.hide(deactivate: false)
        NSApp.activate()
        let alert = NSAlert()
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.messageText = model.isNew
            ? String(localized: "Discard the new action?")
            : String(localized: "Discard your changes to “\(name.isEmpty ? model.original?.name ?? "" : name)”?")
        alert.informativeText = String(localized: "The action editor is open with changes that aren't saved.")
        alert.addButton(withTitle: String(localized: "Keep Editing"))
        alert.addButton(withTitle: String(localized: "Discard"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Asked when an action still running is run again: over the grid, which stays up.
    func confirmRunAgain(_ action: Action) -> Bool {
        #if !APP_STORE
        if let answer = DebugScript.runAgainAnswer { return answer }
        #endif
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(action.name)” is still running")
        alert.informativeText = String(localized: "Run another copy of it at the same time?")
        alert.addButton(withTitle: String(localized: "Run Another Copy"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return overlay.runAlertOverGrid(alert) == .alertFirstButtonReturn
    }

    /// What an action's last background run printed, in its own window.
    func showLastOutput(_ action: Action) {
        guard let result = state.lastRun[action.id] else { return }
        windows["lastOutput"]?.close()
        present("lastOutput", title: String(localized: "Last Output of \(action.name)"), resizable: true) { close in
            LastOutputView(name: action.name, result: result, close: close)
        }
    }

    func closeLastOutput() { windows["lastOutput"]?.close() }

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
        alert.messageText = String(localized: "Sort everything by name?")
        alert.informativeText = state.sortEverythingDetail
        alert.addButton(withTitle: String(localized: "Sort Everything"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.sortEverything()
    }

    @objc func sortEverythingByColour() {
        overlay.hide(deactivate: false)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Sort everything by colour?")
        alert.informativeText = String(localized: "Apps and folders run through the colours of their icons, red to purple, with grey icons last, and fill each page before the next. Folders keep their apps; page titles are cleared. ⌘Z in the grid undoes it.")
        alert.addButton(withTitle: String(localized: "Sort by Colour"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.sortEverythingByColour()
    }

    @objc func confirmRebuild() {
        guard state.hasScanned else {
            return showError(String(localized: "LaunchGrid is still looking for your apps"),
                             String(localized: "Rebuild once it has found them, in a moment."))
        }
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

    #if !APP_STORE
    /// For the debug scripts: imports `url` as Settings' Import buttons do, asking first.
    func debugImport(_ url: URL, from source: String) {
        importDatabase(url, from: source) { print("imported: \($0)"); fflush(stdout) }
    }
    #endif

    @objc func importAppGrid() { importAppGrid(done: nil) }

    @objc func importLaunchpad() { importLaunchpad(done: nil) }

    /// `done` gets what happened, for Settings to show beside its buttons.
    func importAppGrid(done: (@MainActor (String) -> Void)?) {
        guard let url = LaunchpadImporter.appGridDatabaseURL else { return }
        importDatabase(url, from: "AppGrid", done: done)
    }

    func importLaunchpad(done: (@MainActor (String) -> Void)?) {
        guard let url = LaunchpadImporter.launchpadDatabaseURL else { return }
        importDatabase(url, from: "Launchpad", done: done)
    }

    /// Database imports need access to the containing folder, which covers a write-ahead log
    /// that may exist but be invisible when an open panel granted only the database file.
    /// The panel opens on that folder, so allowing it is one click.
    private func readDatabase(_ url: URL, from source: String, rows: Int, columns: Int,
                              installed: [String]) async -> Result<LaunchpadImporter.Result, Error>? {
        let folder = url.deletingLastPathComponent()
        var scopedFolder: URL?
        defer { scopedFolder?.stopAccessingSecurityScopedResource() }
        if Sandbox.isActive, !(await Disk.run { Self.canListDirectory(folder) }) {
            overlay.hide(deactivate: false)
            NSApp.activate()
            let panel = NSOpenPanel()
            panel.message = String(localized: "To import your \(source) layout, allow LaunchGrid to read this folder.")
            panel.prompt = String(localized: "Allow")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = folder
            guard panel.runModal() == .OK, let picked = panel.url else { return nil }
            // Consume the grant attached to the selected URL before using path-based file
            // APIs, and hold it until the background copy has read the database and its WAL.
            if picked.startAccessingSecurityScopedResource() { scopedFolder = picked }
        }
        if Sandbox.isActive {
            let readable = await Disk.run {
                Self.canListDirectory(folder) && FileManager.default.isReadableFile(atPath: url.path)
            }
            guard readable else {
                showError(String(localized: "Could not import from \(source)"), String(localized: "Choose the folder that holds the \(source) database: \(folder.path)"))
                return nil
            }
        }
        return await Disk.run {
            Result {
                try LaunchpadImporter.importDatabase(at: url, rows: rows, columns: columns, installed: installed,
                                                     keeps: LaunchpadImporter.isLastingCopy) { id in
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
                }
            }
        }
    }

    /// Actually listing the folder checks sandbox access. A file-only grant can make the
    /// database readable while `fileExists` reports a sibling WAL as absent.
    nonisolated private static func canListDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// Asks before replacing a grid that has apps on it, as loading a grid file does, once the
    /// database is read: there may be nothing in it to import.
    private func importDatabase(_ url: URL, from source: String,
                                done: (@MainActor (String) -> Void)? = nil,
                                finished: (@MainActor () -> Void)? = nil) {
        let rows = state.grid.rows, columns = state.grid.columns
        let installed = state.installed.map(\.path)
        Task {
            defer { finished?() }
            // Reading the database and asking Launch Services about every app can take a while.
            guard let outcome = await readDatabase(url, from: source, rows: rows, columns: columns,
                                                  installed: installed) else { return }
            switch outcome {
            case .failure(let error):
                showError(String(localized: "Could not import from \(source)"), error.localizedDescription)
            case .success(let result):
                guard result.imported > 0 else {
                    showError(String(localized: "Nothing to import"), String(localized: "No apps in the \(source) layout could be found on this Mac."))
                    return
                }
                if Self.shouldConfirmReplacingLayout(state) {
                    overlay.hide(deactivate: false)
                    NSApp.activate()
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Replace your layout with the one from \(source)?")
                    alert.informativeText = String(localized: "Your current pages and folders will be replaced by the \(result.imported) apps found in the \(source) layout. ⌘Z in the grid undoes it.")
                    alert.addButton(withTitle: String(localized: "Replace"))
                    alert.addButton(withTitle: String(localized: "Cancel"))
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                state.replaceGrid(AppState.keepingExclusions(state.grid.removedBundleIDs, in: result.grid, installed: state.selectableApps),
                                  keepingActions: true)
                // Whole sentences, so a translation can order them its own way.
                let (n, skipped, twice) = (result.imported, result.skipped.count, result.duplicates.count)
                var message = switch (skipped > 0, twice > 0) {
                case (false, false): String(localized: "Imported \(n) apps from \(source)")
                case (true, false): String(localized: "Imported \(n) apps from \(source); skipped \(skipped) not installed")
                case (false, true): String(localized: "Imported \(n) apps from \(source); skipped \(twice) listed twice")
                case (true, true): String(localized: "Imported \(n) apps from \(source); skipped \(skipped) not installed and \(twice) listed twice")
                }
                // Entries of a damaged database whose app record is missing.
                if result.unreadable > 0 { message += String(localized: "; left out \(result.unreadable) unreadable entries") }
                state.showToast(message)
                done?(message)
                closeFirstRunIfDone()
            }
        }
    }

    /// From the menu bar there's nothing in view to confirm the save in; the grid says so next time it opens.
    @objc func saveGridFileFromMenu() {
        saveGridFile { [weak self] url in self?.state.showToast(String(localized: "Saved \(url.lastPathComponent)")) }
    }

    /// Saves the layout to a file the person picks; `done` gets where, unless cancelled or failed.
    func saveGridFile(done: @escaping @MainActor (URL) -> Void) {
        overlay.hide(deactivate: false)
        NSApp.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.launchGridLayout]
        panel.nameFieldStringValue = String(localized: "LaunchGrid Layout") + ".launchgrid"
        // A grid file gets shared: commands stay out of it unless asked for.
        var include: NSButton?
        if state.grid.hasCommands {
            let box = NSButton(checkboxWithTitle: String(localized: "Include commands and scripts"), target: nil, action: nil)
            box.state = .off
            box.setAccessibilityHelp(String(localized: "When off, commands and scripts are saved as placeholders with their names and icons."))
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: box.fittingSize.width + 40, height: box.fittingSize.height + 16))
            box.frame.origin = NSPoint(x: 20, y: 8)
            holder.addSubview(box)
            panel.accessoryView = holder
            include = box
        }
        #if !APP_STORE
        if let preset = DebugScript.includeCommandsAnswer { include?.state = preset ? .on : .off }
        #endif
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let grid = include == nil || include?.state == .on ? state.grid : state.grid.removingCommands()
        Task {
            // Off the main thread: a stalled network or USB volume mustn't hang the app.
            let written = await Disk.run { Result { try GridStore.encode(grid).write(to: url, options: .atomic) } }
            switch written {
            case .success: done(url)
            case .failure(let error): showError(String(localized: "Could not save the grid file"), error.localizedDescription)
            }
        }
    }

    /// The layout a grid file someone opened goes in as: every action in it needs review
    /// before it runs. One with commands, scripts or links to other apps is shown first, each
    /// in full, to keep for review or leave out. Nil when they cancel loading.
    private func reviewActions(in grid: Grid, name: String) -> Grid? {
        guard grid.needsActionReview else { return grid.applyingReview(.keepForReview) }
        let entries = grid.actionReview
        overlay.hide(deactivate: false)
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "“\(name)” contains commands, links to other apps or files that run")
        alert.informativeText = String(localized: "Nothing in it has run. Actions you keep don't run until you've checked them in the editor. Remove Them leaves out the commands, scripts, links to other apps and files that run something, listed first.")
        alert.accessoryView = Self.reviewList(entries)
        alert.addButton(withTitle: String(localized: "Keep for Review"))
        alert.addButton(withTitle: String(localized: "Remove Them"))
        let cancel = alert.addButton(withTitle: String(localized: "Cancel Loading"))
        cancel.keyEquivalent = "\u{1b}"
        let answer: NSApplication.ModalResponse
        #if !APP_STORE
        if let preset = DebugScript.reviewAnswer {
            print("review: \(entries.map { "\($0.isRunnableCode ? "!" : "-")\($0.action.name)=\($0.detail)" })")
            fflush(stdout)
            answer = preset
        } else {
            answer = alert.runModal()
        }
        #else
        answer = alert.runModal()
        #endif
        switch answer {
        case .alertFirstButtonReturn: return grid.applyingReview(.keepForReview)
        case .alertSecondButtonReturn: return grid.applyingReview(.removeRunnable)
        default: return nil
        }
    }

    /// Each action's name and what it does in full, the commands, scripts and app links first.
    private static func reviewList(_ entries: [ActionReviewEntry]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let width: CGFloat = 380
        func add(_ heading: String, _ group: [ActionReviewEntry]) {
            guard !group.isEmpty else { return }
            let title = NSTextField(labelWithString: heading)
            title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            title.textColor = .secondaryLabelColor
            stack.addArrangedSubview(title)
            for entry in group {
                let name = NSTextField(labelWithString: entry.name)
                name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
                let detail = NSTextField(wrappingLabelWithString: entry.detail)
                detail.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                detail.isSelectable = true
                detail.preferredMaxLayoutWidth = width - 16
                detail.setAccessibilityLabel(String(localized: "\(entry.name): \(entry.detail)"))
                stack.addArrangedSubview(name)
                stack.addArrangedSubview(detail)
                stack.setCustomSpacing(2, after: name)
            }
        }
        add(String(localized: "Commands, scripts and links to other apps"), entries.filter(\.isRunnableCode))
        add(String(localized: "Also kept for review"), entries.filter { !$0.isRunnableCode })
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalToConstant: width - 4),
        ])
        document.layoutSubtreeIfNeeded()
        scroll.frame.size.height = min(260, document.fittingSize.height + 4)
        return scroll
    }

    /// Scroll content laid out from the top.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    @objc func loadGridFile() {
        loadGridFile(done: nil)
    }

    /// `done` gets what happened, for Settings to show beside its buttons.
    func loadGridFile(done: (@MainActor (String) -> Void)?) {
        overlay.hide(deactivate: false)
        NSApp.activate()
        let panel = NSOpenPanel()
        // Layouts and previous-save `.bak` files, plus SQLite databases for the importer:
        // `.agrid` files and copies of a Launchpad or AppGrid database. Their live,
        // extension-less `db` files are imported from the Import menu instead.
        panel.allowedContentTypes = [.launchGridLayout, .json]
            + ["bak", "agrid", "db", "sqlite", "sqlite3"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openLayout(url, done: done)
    }

    /// What a file opened as a layout holds.
    private enum OpenedLayout {
        /// With how many of its entries couldn't be read and are left out.
        case grid(Grid, skipped: Int)
        /// A Launchpad or AppGrid database (or an `.agrid` file), for the importer.
        case database
    }

    /// Reads and checks a layout file; nil, after saying why, when it can't be loaded.
    private func readLayout(at url: URL) async -> OpenedLayout? {
        let outcome = await Disk.run {
            Result { () throws -> OpenedLayout in
                let data = try Data(contentsOf: url)
                if data.prefix(16) == Data("SQLite format 3\0".utf8) { return .database }
                let (grid, skipped) = try GridStore.decodeCountingSkipped(data)
                return .grid(grid, skipped: skipped)
            }
        }
        switch outcome {
        case .success(let layout): return layout
        case .failure(let error):
            showError(String(localized: "Could not load the grid file"), error.localizedDescription)
            return nil
        }
    }

    private func closeFirstRunIfDone() {
        if state.hasGridFile { windows["firstRun"]?.close() }
    }

    private func showRecoveryNotice(_ title: String, _ message: String, file: URL) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Show in Finder"))
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }

    /// A failed save, with what can be done about it while LaunchGrid runs: keep a copy of
    /// the layout elsewhere, or look at the folder it couldn't be saved in.
    private func showSaveFailure(_ title: String, _ detail: String) {
        overlay?.hide(deactivate: false)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Save Layout Elsewhere…"))
        alert.addButton(withTitle: String(localized: "Show Data Folder"))
        switch alert.runModal() {
        case .alertSecondButtonReturn: saveGridFileFromMenu()
        case .alertThirdButtonReturn: state.showDataFolder()
        default: break
        }
    }

    private func showError(_ title: String, _ detail: String) {
        // After slow work the grid may be up again: the alert would open behind it.
        overlay?.hide(deactivate: false)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
