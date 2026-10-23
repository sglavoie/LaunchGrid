import AppKit
import Carbon.HIToolbox
import SwiftUI
import LaunchGridCore

struct SettingsView: View {
    @Environment(AppState.self) private var state
    let actions: LibraryActions

    var body: some View {
        @Bindable var state = state
        TabView(selection: $state.settingsTab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("General")
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintbrush") }.tag("Appearance")
            LayoutSettings().tabItem { Label("Layout", systemImage: "square.grid.3x3") }.tag("Layout")
            LibrarySettings(actions: actions).tabItem { Label("Library", systemImage: "books.vertical") }.tag("Library")
        }
        .frame(width: 580, height: state.settingsHeight)
    }
}

/// Library operations implemented by the app delegate (they need panels and alerts).
struct LibraryActions: @unchecked Sendable {
    var rebuild: (BuildStyle) -> Void
    var importAppGrid: () -> Void
    var importLaunchpad: () -> Void
    var loadFile: () -> Void
    /// Where the layout was saved; nil when cancelled or failed (already reported).
    var saveFile: () -> URL?
    var addMissing: () -> Void
    var chooseApps: () -> Void
    /// Applies the shortcut in the preferences. A recorded one that macOS refuses is replaced
    /// by `fallback`, the shortcut from before recording, so a working one is what gets saved.
    var hotkeyChanged: (_ fallback: (keyCode: UInt32, modifiers: UInt32)?) -> Void
    var dockChanged: () -> Void
    var menuBarChanged: () -> Void
    var windowModeChanged: () -> Void
    var foldersChanged: () -> Void
}

struct GeneralSettings: View {
    @Environment(AppState.self) private var state
    @Environment(\.libraryActions) private var actions
    @State private var loginEnabled = LoginItem.isRequested
    @State private var loginStatus = LoginItem.statusDescription
    @State private var loginError: String?

    var body: some View {
        @Bindable var prefs = state.prefs
        Form {
            Section("Shortcut") {
                HotkeyRecorder()
                Toggle("Enable global shortcut", isOn: $prefs.hotkeyEnabled)
                    .onChange(of: prefs.hotkeyEnabled) { actions?.hotkeyChanged(nil) }
            }
            Section("Startup & Visibility") {
                // The toggle shows what the system reports, so a failed change springs back.
                Toggle("Open at login", isOn: Binding(get: { loginEnabled }, set: { on in
                    do { try LoginItem.set(on); loginError = nil } catch { loginError = error.localizedDescription }
                    loginEnabled = LoginItem.isRequested
                    loginStatus = LoginItem.statusDescription
                }))
                LabeledContent("Login item status", value: loginStatus)
                if let loginError { Text(loginError).foregroundStyle(.red).font(.caption) }
                Toggle("Show in Dock", isOn: $prefs.showInDock)
                    .disabled(prefs.showInDock && !prefs.showInMenuBar)
                    .onChange(of: prefs.showInDock) { actions?.dockChanged() }
                Toggle("Show in menu bar", isOn: $prefs.showInMenuBar)
                    .disabled(prefs.showInMenuBar && !prefs.showInDock)
                    .onChange(of: prefs.showInMenuBar) { actions?.menuBarChanged() }
                Picker("Menu bar icon", selection: $prefs.menuBarIconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!prefs.showInMenuBar)
                .onChange(of: prefs.menuBarIconStyle) { actions?.menuBarChanged() }
                Text("At least one of the Dock icon and the menu bar icon stays on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Toggle("Add newly installed apps automatically", isOn: $prefs.autoAddApps)
                Toggle("Hide after opening an app", isOn: $prefs.hideAfterLaunch)
                Toggle("Hide when clicking an empty area", isOn: $prefs.hideOnEmptyClick)
            }
        }
        .formStyle(.grouped)
        // The login item can change in System Settings while this window stays open.
        .onAppear(perform: refreshLoginItem)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLoginItem() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshLoginItem() }
    }

    private func refreshLoginItem() {
        loginEnabled = LoginItem.isRequested
        loginStatus = LoginItem.statusDescription
    }
}

struct HotkeyRecorder: View {
    @Environment(AppState.self) private var state
    @Environment(\.libraryActions) private var actions
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?
    /// The window recording started in; recording stops when it loses key status.
    @State private var window: NSWindow?
    @State private var timeout: Task<Void, Never>?
    /// The shortcut from before recording, to go back to if macOS refuses the new one.
    @State private var previous: (keyCode: UInt32, modifiers: UInt32)?

    var body: some View {
        let prefs = state.prefs
        LabeledContent("Show / hide LaunchGrid") {
            HStack {
                Button(recording ? "Press a shortcut…" : KeyCombo.describe(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)) {
                    recording ? stop() : start()
                }
                .frame(minWidth: 140)
            }
        }
        // Closing Settings mid-recording must not leave the monitor up and the shortcut off.
        .onDisappear { if recording { stop() } }
        // Switching away mid-recording would leave the shortcut unregistered until Settings
        // came back; so would walking away.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if recording, note.object as? NSWindow === window { stop() }
        }
        if let conflict = KeyCombo.conflict(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers) {
            let system = KeyCombo.conflictIsSystemSetting(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
            Label(!system ? "Also used for \(conflict). Pick another shortcut to keep it working."
                  : KeyCombo.readsSystemShortcuts
                  ? "Also used by macOS for \(conflict). Turn that shortcut off in System Settings › Keyboard › Keyboard Shortcuts, or pick another."
                  : "macOS uses this for \(conflict) unless that shortcut is off in System Settings › Keyboard › Keyboard Shortcuts. If it's on, turn it off or pick another.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        if let problem = state.hotkeyProblem, !recording {
            Label(problem, systemImage: "exclamationmark.octagon")
                .font(.caption).foregroundStyle(.red)
        }
        if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
    }

    private func start() {
        recording = true
        previous = (state.prefs.hotkeyKeyCode, state.prefs.hotkeyModifiers)
        hint = String(localized: "Include ⌘, ⌥ or ⌃ (⇧ can be added), or use a function key. Esc cancels.")
        HotkeyService.shared.unregister()
        window = NSApp.keyWindow
        timeout = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled, recording { stop() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            let mods = KeyCombo.carbonModifiers(event.modifierFlags)
            if code == 53 && mods == 0 { // Esc
                stop()
                return nil
            }
            // Shift alone would steal ordinary typing, e.g. ⇧A for a capital A.
            let chord = UInt32(cmdKey | optionKey | controlKey)
            guard mods & chord != 0 || KeyCombo.functionKeys[code] != nil else { return nil }
            state.prefs.hotkeyKeyCode = UInt32(code)
            state.prefs.hotkeyModifiers = mods
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        hint = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window = nil
        timeout?.cancel()
        timeout = nil
        actions?.hotkeyChanged(previous)
        previous = nil
    }
}

struct AppearanceSettings: View {
    @Environment(AppState.self) private var state
    @Environment(\.libraryActions) private var actions

    var body: some View {
        @Bindable var prefs = state.prefs
        Form {
            Section("Window") {
                Picker("Mode", selection: $prefs.windowMode) {
                    ForEach(WindowMode.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: prefs.windowMode) { actions?.windowModeChanged() }
                if prefs.windowMode == .window {
                    Text("The window's size and position are remembered for each display.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Background") {
                Picker("Style", selection: $prefs.background) {
                    ForEach(BackgroundStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                if prefs.background == .glass, ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 {
                    Text("Liquid Glass needs macOS 26; a blur is used instead.").font(.caption).foregroundStyle(.secondary)
                }
                if prefs.background == .solid {
                    ColorPicker("Colour", selection: Binding(
                        get: { Color(nsColor: prefs.solidColor) },
                        set: { prefs.solidColor = NSColor($0) }
                    ), supportsOpacity: false)
                    // Under 3:1 contrast with white, the grid's text colour.
                    if prefs.solidColor.luminance > 0.3 {
                        Text("App names and the search field are white, so they're hard to read on a light colour.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if prefs.background == .image {
                    LabeledContent("Image") {
                        HStack {
                            Text(prefs.customImagePath.map { ($0 as NSString).lastPathComponent } ?? String(localized: "None"))
                                .foregroundStyle(.secondary)
                            Button("Choose…") { chooseImage() }
                        }
                    }
                }
                if prefs.background == .wallpaper || prefs.background == .image {
                    // Whole steps: each radius is blurred and cached separately.
                    ValueSlider(title: "Blur", value: $prefs.blurRadius, range: 0...60, step: 1,
                                valueText: String(localized: "\(Int(prefs.blurRadius)) pt"))
                }
                ValueSlider(title: prefs.background == .solid ? "Transparency" : "Dimming",
                            value: $prefs.backgroundOpacity, range: 0...0.9, valueText: percent(prefs.backgroundOpacity))
            }
            Section("Icons") {
                ValueSlider(title: "Icon size", value: $prefs.iconScale, range: 0.6...1.4, valueText: percent(prefs.iconScale))
                Toggle("Show app names", isOn: $prefs.showLabels)
            }
        }
        .formStyle(.grouped)
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if let old = state.prefs.customImagePath { FileAccess.forget(old) }
            FileAccess.remember(url)
            state.prefs.customImagePath = url.path
        }
    }
}

/// A slider with its value beside it, which VoiceOver reads too.
struct ValueSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let valueText: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Group {
                    if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
                }
                .accessibilityLabel(Text(title))
                .accessibilityValue(valueText)
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct LayoutSettings: View {
    @Environment(AppState.self) private var state
    @State private var rows = 5
    @State private var columns = 7
    @State private var confirm = false

    var body: some View {
        @Bindable var prefs = state.prefs
        let grid = state.grid
        let after = grid.pageCountAfterResize(rows: rows, columns: columns)
        Form {
            Section("Grid size") {
                // Widened to take in the grid's own size, which a loaded file can set anywhere in
                // 1...50: a step from outside the usual range would snap it into that range.
                Stepper("Rows: \(rows)", value: $rows, in: min(2, grid.rows)...max(12, grid.rows))
                Stepper("Columns: \(columns)", value: $columns, in: min(3, grid.columns)...max(16, grid.columns))
                if rows != grid.rows || columns != grid.columns {
                    Group {
                        if after != grid.pages.count { Text("Items re-flow to fill each page in order: \(grid.pages.count) → \(after) pages.") }
                        else { Text("Items re-flow to fill each page in order.") }
                    }
                        .font(.caption).foregroundStyle(after != grid.pages.count ? .orange : .secondary)
                    HStack {
                        Spacer()
                        Button("Revert") { rows = grid.rows; columns = grid.columns }
                        Button("Apply") {
                            if after != grid.pages.count { confirm = true } else { apply() }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            Section("Sorting") {
                Picker("Folders when sorting", selection: $prefs.folderPlacement) {
                    Text("First").tag(FolderPlacement.first)
                    Text("Last").tag(FolderPlacement.last)
                    Text("Mixed with apps").tag(FolderPlacement.mixed)
                }
                HStack {
                    Spacer()
                    Button("Sort Everything") { state.sortEverything() }
                }
                Text("Sort Everything re-flows every page and clears page titles. ⌘Z in the grid undoes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { rows = grid.rows; columns = grid.columns }
        // Undo, a load or an import can resize the grid while this tab is open.
        .onChange(of: [grid.rows, grid.columns]) { rows = state.grid.rows; columns = state.grid.columns }
        .confirmationDialog("Re-flow the grid?", isPresented: $confirm) {
            Button("Resize to \(rows) × \(columns)") { apply() }
        } message: {
            Text("Items move between pages, and titles of pages past the last one are dropped. You can undo this from the grid with ⌘Z.")
        }
    }

    private func apply() {
        state.resize(rows: rows, columns: columns)
    }
}

struct LibrarySettings: View {
    @Environment(AppState.self) private var state
    let actions: LibraryActions
    @State private var confirmRebuild: BuildStyle?
    /// Feedback for Rescan Now and Regenerate Icons.
    @State private var libraryStatus: String?
    /// The grid file last saved from here, to confirm it and show it in Finder.
    @State private var savedFile: URL?

    var body: some View {
        @Bindable var prefs = state.prefs
        Form {
            Section("Apps") {
                LabeledContent("On the grid") { Text("\(state.grid.allApps.count) apps, \(state.grid.pages.count) pages") }
                LabeledContent("Installed") { Text("\(state.installed.count) apps found") }
                LabeledContent("Excluded") { Text("\(state.excludedApps.count) apps") }
                HStack {
                    Button("Choose Apps…") { actions.chooseApps() }
                    Button("Add Missing Apps…") { actions.addMissing() }
                }
                HStack {
                    Button("Rescan Now") {
                        libraryStatus = String(localized: "Rescanning…")
                        state.rescan { libraryStatus = String(localized: "Found \(state.installed.count) apps") }
                    }
                    Button("Regenerate Icons") {
                        libraryStatus = String(localized: "Regenerating icons…")
                        state.regenerateIcons { libraryStatus = String(localized: "Icons regenerated") }
                    }
                    if let libraryStatus {
                        Text(libraryStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .task(id: libraryStatus) {
                    // A result stays a few seconds; work in progress until it calls back.
                    guard let status = libraryStatus, !status.hasSuffix("…") else { return }
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { libraryStatus = nil }
                }
                Text("Excluded apps stay off the grid and aren't added back by scans or rebuilds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rebuild") {
                HStack {
                    Button("Rebuild by Category…") { confirmRebuild = .byCategory }
                    Button("Rebuild Alphabetically…") { confirmRebuild = .alphabetical }
                }
                Text("Lays out every installed app that isn't excluded from scratch, the same as the choices on the welcome screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Extra folders to scan") {
                ForEach(prefs.extraFolders, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            prefs.extraFolders.removeAll { $0 == path }
                            FileAccess.forget(path)
                            actions.foldersChanged()
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url, !prefs.extraFolders.contains(url.path) {
                        FileAccess.remember(url)
                        prefs.extraFolders.append(url.path)
                        actions.foldersChanged()
                    }
                }
            }
            Section("Grid file") {
                HStack {
                    Button("Save Grid File…") { if let url = actions.saveFile() { savedFile = url } }
                    Button("Load Grid File…") { actions.loadFile() }
                }
                if let savedFile {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text("Saved \(savedFile.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedFile]) }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                }
                HStack {
                    Button("Import from AppGrid") { actions.importAppGrid() }
                        .disabled(LaunchpadImporter.appGridDatabaseURL == nil)
                    Button("Import from Launchpad") { actions.importLaunchpad() }
                        .disabled(LaunchpadImporter.launchpadDatabaseURL == nil)
                }
                Button("Show Data Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([state.store.url])
                }
                Text("Loading or importing replaces the current layout; ⌘Z in the grid undoes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Rebuild the grid from scratch?", isPresented: Binding(
            get: { confirmRebuild != nil }, set: { if !$0 { confirmRebuild = nil } }
        ), presenting: confirmRebuild) { style in
            Button("Rebuild", role: .destructive) { actions.rebuild(style) }
        } message: { _ in
            Text("Folders, page titles and your custom order will be replaced. You can undo this from the grid with ⌘Z.")
        }
    }
}

private struct LibraryActionsKey: EnvironmentKey {
    static let defaultValue: LibraryActions? = nil
}

extension EnvironmentValues {
    var libraryActions: LibraryActions? {
        get { self[LibraryActionsKey.self] }
        set { self[LibraryActionsKey.self] = newValue }
    }
}

// MARK: - Add missing apps

struct AddMissingAppsView: View {
    @Environment(AppState.self) private var state
    var close: () -> Void
    @State private var chosen: Set<String> = []
    @State private var filter = ""

    var body: some View {
        let all = state.missingApps
        let missing = all.filter { filter.isEmpty || Search.score($0.name, query: filter) != nil }
        // Picks survive filtering; apps that stopped being missing (e.g. a rescan) don't count.
        let picked = all.filter { chosen.contains($0.path) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Missing Apps").font(.title2.weight(.semibold))
            Text("Installed apps that are not on the grid, including ones you removed.")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
            List(missing, id: \.path) { app in
                Toggle(isOn: Binding(
                    get: { chosen.contains(app.path) },
                    set: { if $0 { chosen.insert(app.path) } else { chosen.remove(app.path) } }
                )) {
                    HStack {
                        AppIcon(path: app.path, size: 24)
                        Text(app.name)
                        Spacer()
                        Text(app.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
            }
            .frame(minHeight: 280)
            .overlay {
                Group {
                    if state.installed.isEmpty { Text("Looking for installed apps…") }
                    else if all.isEmpty { Text("Every installed app is on the grid.") }
                    else if missing.isEmpty { Text("No missing apps match “\(filter)”.") }
                }
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("Select All") { chosen.formUnion(missing.map(\.path)) }.disabled(missing.isEmpty)
                Button("Browse for App…") { browse(adding: picked) }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Add \(picked.count)") {
                    state.addApps(picked)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    /// Adds apps from anywhere on disk, along with those already ticked in the list.
    private func browse(adding picked: [InstalledApp]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let browsed = panel.urls.compactMap { AppScanner.read(appAt: $0) }
        // Apps outside the scan folders are read again at each scan.
        for app in browsed { FileAccess.remember(URL(fileURLWithPath: app.path)) }
        guard !browsed.isEmpty else { return }
        let apps = picked + browsed.filter { app in !picked.contains { $0.path == app.path } }
        state.addApps(apps)
        close()
    }
}

// MARK: - Choose apps

/// Includes or excludes apps in bulk. Changes are kept as overrides of what the grid holds,
/// so a rescan while the window is open doesn't turn into unintended exclusions.
struct ChooseAppsView: View {
    @Environment(AppState.self) private var state
    var close: () -> Void
    @State private var changes: [String: Bool] = [:]
    @State private var filter = ""

    var body: some View {
        let all = state.selectableApps
        let initial = state.includedPaths
        let shown = all.filter { filter.isEmpty || Search.score($0.name, query: filter) != nil }
        let isOn = { (app: InstalledApp) in changes[app.path] ?? initial.contains(app.path) }
        let include = all.filter { changes[$0.path] == true && !initial.contains($0.path) }
        let exclude = all.filter { changes[$0.path] == false && initial.contains($0.path) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Apps").font(.title2.weight(.semibold))
            Text(state.hasGridFile
                 ? "Unchecked apps leave the grid and aren't added back by scans or rebuilds."
                 : "Unchecked apps are left out of your grid and aren't added later by scans. You can change this in Settings › Library.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
            List(shown, id: \.path) { app in
                Toggle(isOn: Binding(get: { isOn(app) }, set: { changes[app.path] = $0 })) {
                    HStack {
                        AppIcon(path: app.path, size: 24)
                        Text(app.name)
                        Spacer()
                        Text(app.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
            }
            .frame(minHeight: 280)
            .overlay {
                Group {
                    if all.isEmpty { Text("Looking for installed apps…") }
                    else if shown.isEmpty { Text("No apps match “\(filter)”.") }
                }
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("Include All") { for app in shown { changes[app.path] = true } }.disabled(shown.isEmpty)
                Button("Exclude All") { for app in shown { changes[app.path] = false } }.disabled(shown.isEmpty)
                Text("\(all.filter(isOn).count) of \(all.count) included")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    state.chooseApps(include: include, exclude: exclude)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(include.isEmpty && exclude.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 520)
    }
}

// MARK: - First run

struct FirstRunView: View {
    @Environment(AppState.self) private var state
    let actions: LibraryActions
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text("Welcome to LaunchGrid").font(.title.weight(.semibold))
                    Text("Choose how to set up your grid. You can change it later in Settings › Library.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let problem = state.loadProblem {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(problem.message)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([problem.backup]) }
                            .buttonStyle(.link)
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            appsChoice
            option("Build by category", "One page per kind of app — Productivity, Developer Tools, Creativity…",
                   "square.grid.3x3.square", requiresScan: true) { actions.rebuild(.byCategory) }
            option("Build alphabetically", "All apps in name order.", "textformat.abc", requiresScan: true) {
                actions.rebuild(.alphabetical)
            }
            if LaunchpadImporter.appGridDatabaseURL != nil {
                option("Import from AppGrid", "Bring over your AppGrid pages and folders.", "square.and.arrow.down") {
                    actions.importAppGrid()
                }
            }
            if LaunchpadImporter.launchpadDatabaseURL != nil {
                option("Import from Launchpad", "Use the layout of the old macOS Launchpad.", "square.and.arrow.down.on.square") {
                    actions.importLaunchpad()
                }
            }
            option("Load a grid file…", "A file saved from LaunchGrid, or an AppGrid .agrid file.", "doc") { actions.loadFile() }
            Divider()
            Text("Open LaunchGrid with **\(KeyCombo.describe(keyCode: state.prefs.hotkeyKeyCode, modifiers: state.prefs.hotkeyModifiers))**, the menu bar icon, or the Dock icon.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 520)
    }

    /// Which apps the build (or an import's new-app scan) brings in.
    private var appsChoice: some View {
        let total = state.selectableApps.count
        let included = state.includedPaths.count
        return HStack(spacing: 12) {
            Image(systemName: "checklist").font(.title2).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apps to include").font(.headline)
                Text(total == 0 ? "Looking for installed apps…"
                     : included == total ? "All \(total) installed apps." : "\(included) of \(total) installed apps.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") { actions.chooseApps() }
                .disabled(state.installed.isEmpty)
        }
        .padding(12)
    }

    /// - Parameter requiresScan: unavailable until the first scan has found the installed apps.
    private func option(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ icon: String, requiresScan: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button {
            action()
            if state.hasGridFile { close() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(requiresScan && state.installed.isEmpty)
    }
}
