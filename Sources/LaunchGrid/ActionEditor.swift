import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LaunchGridCore

/// What the action editor holds while it's open: the fields of one action, new or existing,
/// unsaved until `save`. Kept apart from the view so the debug scripts and tests can fill it.
@MainActor @Observable
final class ActionEditorModel {
    enum KindChoice: String, CaseIterable, Identifiable {
        case link, file, shortcut, command, script
        var id: Self { self }

        var title: String {
            switch self {
            case .link: String(localized: "Link")
            case .file: String(localized: "File")
            case .shortcut: String(localized: "Shortcut")
            case .command: String(localized: "Command")
            case .script: String(localized: "Script")
            }
        }

        /// A sandboxed build can't run commands; one already in the layout keeps its own.
        var isAvailable: Bool { self != .command || ActionRunner.commandsAvailable }

        init(_ kind: ActionKind) {
            self = switch kind {
            case .openURL: .link
            case .openFile: .file
            case .shortcut: .shortcut
            case .shell: .command
            case .userScript: .script
            }
        }
    }

    enum IconChoice: String, CaseIterable, Identifiable {
        case automatic, symbol, emoji, image
        var id: Self { self }

        var title: String {
            switch self {
            case .automatic: String(localized: "Automatic")
            case .symbol: String(localized: "Symbol")
            case .emoji: String(localized: "Emoji")
            case .image: String(localized: "Image")
            }
        }
    }

    /// The symbols offered for an icon.
    static let symbols = [
        "star", "heart", "bolt", "flame", "sparkles", "lightbulb", "globe", "link",
        "magnifyingglass", "safari", "doc", "doc.text", "folder", "book", "bookmark", "tray",
        "envelope", "paperplane", "bubble.left", "phone", "calendar", "clock", "timer", "music.note",
        "play.circle", "camera", "photo", "film", "mic", "terminal",
        "chevron.left.forwardslash.chevron.right", "hammer", "gearshape", "cpu", "network", "cloud",
        "house", "cart", "map", "square.stack.3d.up",
    ]

    /// The action being edited; nil for a new one.
    let original: Action?
    /// The page a new action goes to.
    let pageID: UUID?
    /// The ID the saved action gets: the original's, or a new one kept across Test and Save.
    let id: UUID
    var name = ""
    /// Comma-separated, as typed.
    var keywordsText = ""
    var kind: KindChoice = .link
    var template = ""
    var filePath = ""
    /// The app to open the file with; nil for its default app.
    var appPath: String?
    var shortcutName = ""
    var shortcutInput = ""
    var command = ""
    var runMode: RunMode = .background
    /// Empty for the home folder.
    var workingDirectory = ""
    var timeout = CodeJob.defaultTimeout
    var scriptName = ""
    /// One argument per line, as typed.
    var argumentsText = ""
    /// The scripts in the Application Scripts folder, for the picker.
    var scripts: [String] = []
    /// Where the scripts are; tests point it elsewhere.
    var scriptsDirectory = ActionRunner.applicationScriptsDirectory
    var iconChoice: IconChoice = .automatic
    var symbol = "star"
    var emoji = "" { didSet { if emoji.count > 1 { emoji = String(emoji.suffix(1)) } } }
    var imagePath: String?
    var showsOnGrid = true
    /// What Test hands the action as the text typed after its keyword.
    var testArgument = ""
    /// What the last Test did, to show and read out.
    var testResult: String?
    var testFailed = false
    /// The person's Shortcuts, for the picker (the downloadable build only).
    var shortcuts: [String] = []

    /// Every other action's keywords, to warn about one used twice.
    private let otherKeywords: [String: String]

    init(action: Action?, pageID: UUID?, others: [Action]) {
        original = action
        self.pageID = pageID
        id = action?.id ?? UUID()
        var keywords: [String: String] = [:]
        for other in others where other.id != action?.id {
            for k in other.keywords where keywords[k] == nil { keywords[k] = other.name }
        }
        otherKeywords = keywords
        guard let action else { return }
        name = action.name
        keywordsText = action.keywords.joined(separator: ", ")
        kind = KindChoice(action.kind)
        showsOnGrid = action.showsOnGrid
        switch action.kind {
        case .openURL(let t): template = t
        case .openFile(let path, let app): (filePath, appPath) = (path, app)
        case .shortcut(let n, let input): (shortcutName, shortcutInput) = (n, input ?? "")
        case .shell(let c, let mode, let directory, let seconds):
            (command, runMode, workingDirectory) = (c, mode, directory ?? "")
            timeout = CodeJob.timeout(seconds)
        case .userScript(let file, let arguments, let mode):
            (scriptName, runMode) = (file, mode)
            argumentsText = arguments.joined(separator: "\n")
        }
        switch action.icon {
        case action.kind.defaultIcon: iconChoice = .automatic
        case .symbol(let s): (iconChoice, symbol) = (.symbol, s)
        case .emoji(let e): (iconChoice, emoji) = (.emoji, e)
        case .image(let path): (iconChoice, imagePath) = (.image, path)
        }
    }

    var isNew: Bool { original == nil }

    /// It came from a grid file and hasn't run yet: the editor says to check it, and saving it
    /// (which the draft does, without the flag) lets it run.
    var needsReview: Bool { original?.needsReview ?? false }

    /// The keywords as saved: split at commas, trimmed and lowercased, without blanks.
    var keywords: [String] {
        keywordsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// The script's arguments: one per line, blank lines left out.
    var arguments: [String] {
        argumentsText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The kind as filled in; nil for a command in the sandboxed build, unless the action
    /// already was one (it keeps it).
    var actionKind: ActionKind? {
        switch kind {
        case .link: return .openURL(template: template.trimmingCharacters(in: .whitespacesAndNewlines))
        case .file: return .openFile(path: filePath, appPath: appPath)
        case .shortcut: return .shortcut(name: shortcutName.trimmingCharacters(in: .whitespaces),
                                         input: shortcutInput.isEmpty ? nil : shortcutInput)
        case .command:
            guard kind.isAvailable else { return original.map(\.kind).flatMap { KindChoice($0) == kind ? $0 : nil } }
            return .shell(command: command, runMode: runMode,
                          workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
                          timeoutSeconds: timeout == CodeJob.defaultTimeout ? nil : CodeJob.timeout(timeout))
        case .script:
            return .userScript(fileName: scriptName, arguments: arguments, runMode: runMode)
        }
    }

    /// Whether the run mode can be In Terminal: the sandboxed build can't open a terminal.
    var terminalAvailable: Bool { !Sandbox.isActive }

    var icon: ActionIcon? {
        switch iconChoice {
        case .automatic: nil
        case .symbol: .symbol(symbol)
        case .emoji: emoji.isEmpty ? nil : .emoji(emoji)
        case .image: imagePath.map { .image(path: $0) }
        }
    }

    /// The action as the editor has it.
    var draft: Action? {
        guard let actionKind else { return nil }
        return Action(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), keywords: keywords,
                      icon: icon, kind: actionKind, showsOnGrid: showsOnGrid)
    }

    /// What's wrong with the kind's own fields, which also keeps Test from running.
    var kindError: String? {
        switch kind {
        case .link:
            let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return String(localized: "Enter a link.") }
            let sample = t.replacingOccurrences(of: ActionKind.argumentPlaceholder, with: "test")
            guard let url = URL(string: sample, encodingInvalidCharacters: false), url.scheme?.isEmpty == false else {
                return String(localized: "This isn't a valid link. Include its scheme, as in https://")
            }
            return nil
        case .file:
            return filePath.isEmpty ? String(localized: "Choose a file or folder.") : nil
        case .shortcut:
            return shortcutName.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Enter the name of a Shortcut.") : nil
        case .command:
            // One already in the layout can still be renamed and given keywords.
            guard kind.isAvailable else { return actionKind == nil ? ActionRunner.Failure.commandsUnavailable.message : nil }
            if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "Enter a command.") }
            do { _ = try ActionRunner.substitutingArgument(in: command) } catch { return error.localizedDescription }
            return nil
        case .script:
            if scriptName.isEmpty { return String(localized: "Choose a script.") }
            if runMode == .terminal && !terminalAvailable { return ActionRunner.Failure.terminalUnavailable.message }
            return nil
        }
    }

    /// What keeps the action from being saved.
    var errors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append(String(localized: "Enter a name.")) }
        if let kindError { errors.append(kindError) }
        let spaced = keywordsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains(where: \.isWhitespace) }
        if !spaced.isEmpty {
            errors.append(String(localized: "Keywords can't contain spaces: \(spaced.map { "“\($0)”" }.formatted(.list(type: .and)))"))
        }
        return errors
    }

    /// Worth knowing, but no reason not to save: a keyword another action has too. Search lists
    /// both.
    var warnings: [String] {
        var warnings = keywords.compactMap { k in
            otherKeywords[k].map { String(localized: "“\(k)” is also a keyword of \($0).") }
        }
        // It may be put in the folder later: the tile says so meanwhile.
        if kind == .script, !scriptName.isEmpty, scriptsLoaded, !scripts.contains(scriptName) {
            warnings.append(ActionRunner.Failure.scriptNotFound(scriptName).message)
        }
        return warnings
    }

    /// Whether `scripts` was read yet.
    var scriptsLoaded = false

    /// Reads the Application Scripts folder off the main thread, for the picker.
    func loadScripts() async {
        let dir = scriptsDirectory
        scripts = await Disk.run { ActionRunner.scripts(in: dir) }
        scriptsLoaded = true
    }

    /// Creates the Application Scripts folder when it's missing and shows it in Finder.
    func openScriptsFolder() {
        let dir = scriptsDirectory
        // The sandboxed build may only ask for it to be made, not make it itself.
        _ = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.open(dir)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([dir.deletingLastPathComponent()])
        }
    }

    func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { workingDirectory = url.path }
    }

    var canSave: Bool { errors.isEmpty && draft != nil }

    /// Saves as one undo step. Returns false, changing nothing, while something is wrong.
    @discardableResult
    func save(to state: AppState) -> Bool {
        guard canSave, let draft else { return false }
        state.saveAction(draft, pageID: isNew ? pageID : nil)
        return true
    }

    /// Runs the action as filled in, with the test argument when it takes one.
    func test(with state: AppState) async {
        guard kindError == nil, let draft else { return }
        let argument = draft.kind.takesArgument && !testArgument.isEmpty ? testArgument : nil
        testResult = nil
        if let error = await state.test(draft, argument: argument) {
            (testResult, testFailed) = (String(localized: "Could not run it: \(error.localizedDescription)"), true)
        } else {
            (testResult, testFailed) = (String(localized: "Ran \(draft.name.isEmpty ? String(localized: "the action") : draft.name)"), false)
        }
    }

    // MARK: Choosing files

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url, FileAccess.rememberForAction(url) { filePath = url.path }
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url, FileAccess.rememberForAction(url) { appPath = url.path }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url, FileAccess.rememberForAction(url) {
            imagePath = url.path
            iconChoice = .image
        }
    }

    /// Reads the person's Shortcuts off the main thread. The sandbox can't run `shortcuts`, so
    /// that build has a plain text field only.
    func loadShortcuts() async {
        #if !APP_STORE
        let names = await Task.detached { Self.listShortcuts() }.value
        shortcuts = names
        #endif
    }

    #if !APP_STORE
    nonisolated static func listShortcuts() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    #endif

    // MARK: Debug scripts

    /// Sets a field by name, for the debug scripts and UI scenarios: SwiftUI's fields have no
    /// names to reach them by over Accessibility on the test Mac. Returns false for an unknown
    /// field or value.
    @discardableResult
    func fill(_ field: String, _ value: String) -> Bool {
        switch field {
        case "name": name = value
        case "keywords": keywordsText = value
        case "kind": guard let k = KindChoice(rawValue: value) else { return false }; kind = k
        case "template": template = value
        case "file": filePath = value
        case "app": appPath = value.isEmpty ? nil : value
        case "shortcut": shortcutName = value
        case "input": shortcutInput = value
        case "command": command = value
        case "runmode": guard let m = RunMode(rawValue: value) else { return false }; runMode = m
        case "workdir": workingDirectory = value
        case "timeout": guard let t = Int(value) else { return false }; timeout = t
        case "script": scriptName = value
        // "\n" between arguments: a debug script's step can't hold a newline.
        case "arguments": argumentsText = value.replacingOccurrences(of: "\\n", with: "\n")
        case "showongrid": guard let b = Bool(value) else { return false }; showsOnGrid = b
        case "argument": testArgument = value
        case "symbol": (iconChoice, symbol) = (.symbol, value)
        case "emoji": (iconChoice, emoji) = (.emoji, value)
        case "image": (iconChoice, imagePath) = (.image, value)
        case "icon": guard let c = IconChoice(rawValue: value) else { return false }; iconChoice = c
        default: return false
        }
        return true
    }
}

/// Creates or edits one action, in its own window like Settings, so the grid's keyboard
/// handling stays out of its fields.
struct ActionEditor: View {
    @Environment(AppState.self) private var state
    @Bindable var model: ActionEditorModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if model.needsReview {
                    Section {
                        Label {
                            Text("This action came from a grid file. Check what it does before running it.")
                        } icon: {
                            Image(systemName: "exclamationmark.shield").foregroundStyle(.yellow)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                    TextField("Name", text: $model.name)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Keywords", text: $model.keywordsText, prompt: Text("gh, github"))
                            .accessibilityHint(Text("Separate keywords with commas. Typing one in search finds this action first."))
                        KeywordTokens(keywords: model.keywords)
                    }
                    Toggle("Show on grid", isOn: $model.showsOnGrid)
                        .accessibilityHint(Text("When off, the action is found only by searching."))
                }
                Section("Icon") { iconFields }
                Section {
                    Picker("Kind", selection: $model.kind) {
                        ForEach(ActionEditorModel.KindChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    kindFields
                }
                if let draft = model.draft, model.kindError == nil {
                    Section("Test") { testFields(draft) }
                }
                let errors = model.errors, warnings = model.warnings
                if !errors.isEmpty || !warnings.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) { WarningCaption(Text($0)) }
                        ForEach(warnings, id: \.self) { message in
                            Label { Text(message) } icon: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                                .font(.caption)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button(model.isNew ? "Add Action" : "Save") {
                    if model.save(to: state) { close() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
            }
            .padding(12)
        }
        .frame(width: 520)
        .frame(minHeight: 520, idealHeight: 640)
        .task { await model.loadShortcuts() }
        .task { await model.loadScripts() }
    }

    @ViewBuilder private var iconFields: some View {
        Picker("Icon", selection: $model.iconChoice) {
            ForEach(ActionEditorModel.IconChoice.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        switch model.iconChoice {
        case .automatic:
            Text("The kind's own symbol.").font(.caption).foregroundStyle(.secondary)
        case .symbol:
            LazyVGrid(columns: Array(repeating: SwiftUI.GridItem(.fixed(34), spacing: 6), count: 10), spacing: 6) {
                ForEach(ActionEditorModel.symbols, id: \.self) { name in
                    let chosen = model.symbol == name
                    Button { model.symbol = name } label: {
                        Image(systemName: name)
                            .font(.system(size: 15))
                            .frame(width: 32, height: 28)
                            .background(chosen ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(chosen ? Color.accentColor : .clear))
                    }
                    .buttonStyle(.plain)
                    .help(name)
                    .accessibilityLabel(Text(Self.spoken(name)))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        case .emoji:
            TextField("Emoji", text: $model.emoji, prompt: Text("🚀"))
                .accessibilityHint(Text("Type or paste one emoji. Press Control-Command-Space for the emoji picker."))
        case .image:
            HStack {
                Text(model.imagePath.map { FileManager.default.displayName(atPath: $0) } ?? String(localized: "No image chosen"))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(model.imagePath == nil ? .secondary : .primary)
                Spacer()
                Button("Choose Image…") { model.chooseImage() }
            }
        }
    }

    @ViewBuilder private var kindFields: some View {
        switch model.kind {
        case .link:
            TextField("Link", text: $model.template, prompt: Text("https://github.com/search?q={query}"))
            Text("Use {query} for what you type after a keyword.")
                .font(.caption).foregroundStyle(.secondary)
        case .file:
            LabeledContent("File") {
                HStack {
                    Text(model.filePath.isEmpty ? String(localized: "None") : FileManager.default.displayName(atPath: model.filePath))
                        .lineLimit(1).truncationMode(.middle)
                        .help(model.filePath)
                    Button("Choose…") { model.chooseFile() }
                }
            }
            LabeledContent("Open with") {
                HStack {
                    Text(model.appPath.map { FileManager.default.displayName(atPath: $0) } ?? String(localized: "Default app"))
                        .lineLimit(1)
                    Button("Choose…") { model.chooseApp() }
                        .accessibilityLabel(Text("Choose app to open with"))
                    if model.appPath != nil {
                        Button("Use Default") { model.appPath = nil }
                    }
                }
            }
        case .shortcut:
            HStack {
                TextField("Shortcut", text: $model.shortcutName, prompt: Text("Name of the Shortcut"))
                #if !APP_STORE
                if !model.shortcuts.isEmpty {
                    Menu {
                        ForEach(model.shortcuts, id: \.self) { name in Button(name) { model.shortcutName = name } }
                    } label: { Text("Choose") }
                    .fixedSize()
                    .accessibilityLabel(Text("Choose a Shortcut"))
                }
                #endif
            }
            TextField("Input", text: $model.shortcutInput, prompt: Text("Optional"))
            Text("Use {query} in the input for what you type after a keyword.")
                .font(.caption).foregroundStyle(.secondary)
        case .command:
            if model.kind.isAvailable {
                commandFields
            } else {
                if let kind = model.actionKind {
                    // Made in the downloadable build: shown as it is, kept on saving.
                    Text(Self.describe(kind)).font(.callout.monospaced()).textSelection(.enabled)
                }
                Text("Commands run only in the version of LaunchGrid from its website. Use a script in the Application Scripts folder, or a Shortcut, instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .script:
            scriptFields
        }
    }

    @ViewBuilder private var commandFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Command").font(.callout)
            TextEditor(text: $model.command)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .frame(minHeight: 64, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                .accessibilityLabel(Text("Command"))
                .accessibilityHint(Text("Run by zsh as a login shell. {query} becomes what you type after a keyword, as text the shell never runs."))
            Text("Runs with zsh -l. {query} becomes what you type after a keyword, as text the shell never runs, even inside quotes; it's also in $LAUNCHGRID_QUERY.")
                .font(.caption).foregroundStyle(.secondary)
        }
        runModeField
        LabeledContent("Working folder") {
            HStack {
                Text(model.workingDirectory.isEmpty ? String(localized: "Home folder") : FileManager.default.displayName(atPath: model.workingDirectory))
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.workingDirectory)
                Button("Choose…") { model.chooseWorkingDirectory() }
                    .accessibilityLabel(Text("Choose working folder"))
                if !model.workingDirectory.isEmpty {
                    Button("Use Home") { model.workingDirectory = "" }
                }
            }
        }
        if model.runMode == .background { timeoutField }
    }

    @ViewBuilder private var scriptFields: some View {
        LabeledContent("Script") {
            HStack {
                Picker("Script", selection: $model.scriptName) {
                    if model.scriptName.isEmpty { Text("Choose…").tag("") }
                    if !model.scriptName.isEmpty && !model.scripts.contains(model.scriptName) {
                        Text(model.scriptName).tag(model.scriptName)
                    }
                    ForEach(model.scripts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Button {
                    Task { await model.loadScripts() }
                } label: { Image(systemName: "arrow.clockwise") }
                .help(String(localized: "Look for scripts again"))
                .accessibilityLabel(Text("Look for scripts again"))
            }
        }
        HStack {
            Text("Scripts go in ~/Library/Application Scripts/com.sglavoie.launchgrid.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Open Scripts Folder") { model.openScriptsFolder() }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Arguments").font(.callout)
            TextEditor(text: $model.argumentsText)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .frame(minHeight: 44, maxHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                .accessibilityLabel(Text("Arguments"))
                .accessibilityHint(Text("One per line. {query} becomes what you type after a keyword."))
            Text("One per line. {query} becomes what you type after a keyword.")
                .font(.caption).foregroundStyle(.secondary)
        }
        runModeField
        // Scripts stop after the default timeout: the layout keeps no timeout for them.
    }

    @ViewBuilder private var runModeField: some View {
        Picker("Run", selection: $model.runMode) {
            Text("In the background").tag(RunMode.background)
            Text("In a terminal").tag(RunMode.terminal)
        }
        if model.runMode == .terminal && !model.terminalAvailable {
            Text("This version of LaunchGrid can't open scripts in a terminal. Run it in the background instead.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var timeoutField: some View {
        let timeoutText = String(localized: "\(model.timeout) s")
        Stepper(value: $model.timeout, in: 1...CodeJob.maximumTimeout, step: 10) {
            LabeledContent("Stop after", value: timeoutText)
        }
        .accessibilityLabel(Text("Stop after"))
        .accessibilityValue(Text("\(model.timeout) seconds"))
    }

    @ViewBuilder private func testFields(_ draft: Action) -> some View {
        if draft.kind.takesArgument {
            TextField("Argument", text: $model.testArgument, prompt: Text("Replaces {query}"))
        }
        HStack {
            Button("Test") { Task { await model.test(with: state) } }
                .accessibilityHint(Text("Runs the action as it is here, without saving it."))
            if let result = model.testResult {
                Label { Text(result) } icon: {
                    Image(systemName: model.testFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.testFailed ? .orange : .green)
                }
                .font(.caption)
            }
        }
        .announcing(model.testResult)
    }

    /// A symbol's name read as words ("doc.text" as "doc text").
    static func spoken(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: " ")
    }

    static func describe(_ kind: ActionKind) -> String {
        switch kind {
        case .shell(let command, _, _, _): command
        case .userScript(let file, let arguments, _): ([file] + arguments).joined(separator: " ")
        default: ""
        }
    }
}

/// The keywords as tokens, as search will match them.
struct KeywordTokens: View {
    let keywords: [String]

    var body: some View {
        if !keywords.isEmpty {
            HStack(spacing: 4) {
                ForEach(keywords, id: \.self) { k in
                    Text(k)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Keywords: \(keywords.formatted(.list(type: .and)))"))
        }
    }
}

/// What an action's last background run printed (the last 4 KB of each output) and how it
/// ended, from the tile's Show Last Output….
struct LastOutputView: View {
    let name: String
    let result: RunResult
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(status)
            } icon: {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.succeeded ? .green : .orange)
            }
            .font(.headline)
            .accessibilityElement(children: .combine)
            OutputBox(title: String(localized: "Output"), text: result.output)
            OutputBox(title: String(localized: "Errors"), text: result.errorOutput)
            HStack {
                Text("Only the last 4 KB of each is kept.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 460)
    }

    private var status: String {
        let time = result.endedAt.formatted(date: .omitted, time: .standard)
        return switch result.ending {
        case .exited(0): String(localized: "\(name) finished at \(time)")
        case .stopped: String(localized: "\(name) was stopped at \(time)")
        default: String(localized: "\(name) failed at \(time): \(result.summary)")
        }
    }

    private struct OutputBox: View {
        let title: String
        let text: String

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                ScrollView {
                    Text(verbatim: text.isEmpty ? String(localized: "(none)") : text)
                        .font(.callout.monospaced())
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .accessibilityLabel(Text(title))
            }
        }
    }
}
