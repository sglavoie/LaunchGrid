#if !APP_STORE
import AppKit
import LaunchGridCore

/// Assertions around the same event driver used for demos. Only AppDelegate's guarded
/// scratch branch starts this runner; it never starts scanners, watchers or a global hotkey.
@MainActor
enum DebugUITest {
    struct Scenario: Decodable {
        var name: String
        var fixture: Fixture
        var steps: [Step]
    }

    struct Fixture: Decodable {
        var rows: Int
        var columns: Int
        var pages: [[String]]
        var pageTitles: [String]
        var folders: [String: [String]]
        /// Actions in the layout's own JSON form. One that shows on the grid is placed where
        /// its name appears in `pages`; a search-only one goes to the grid's hidden actions.
        var actions: [Action]?
        /// Text files written, by name, into a `files` folder in the run's artifacts before the
        /// steps start; `${FILES}` anywhere in the scenario stands for that folder's path.
        var files: [String: String]?

        func grid() throws -> Grid {
            guard rows > 0, columns > 0, !pages.isEmpty, pageTitles.count == pages.count,
                  pages.allSatisfy({ $0.count <= rows * columns }),
                  folders.values.allSatisfy({ !$0.isEmpty }) else {
                throw Failure("Invalid fixture dimensions, titles or folders")
            }
            let items = pages.flatMap { $0 }
            let actions = actions ?? []
            let shown = Dictionary(uniqueKeysWithValues: actions.filter(\.showsOnGrid).map { ($0.name, $0) })
            let names = items + folders.values.flatMap { $0 } + actions.filter { !$0.showsOnGrid }.map(\.name)
            guard Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty }),
                  Set(folders.keys).isSubset(of: Set(items)), shown.count == actions.filter(\.showsOnGrid).count,
                  Set(shown.keys).isSubset(of: Set(items)), Set(shown.keys).isDisjoint(with: folders.keys) else {
                throw Failure("Fixture names must be unique and every folder and shown action must be on a page")
            }
            func app(_ name: String) -> AppRef {
                AppRef(bundleID: "com.example.uitest.\(name)", path: "/LaunchGridUITests/\(name).app", name: name)
            }
            var grid = Grid(rows: rows, columns: columns, pages: zip(pages, pageTitles).map { items, title in
                Page(title: title, items: items.map { name in
                    folders[name].map { .folder(Folder(name: name, apps: $0.map(app))) }
                        ?? shown[name].map(GridItem.action) ?? .app(app(name))
                })
            })
            grid.hiddenActions = actions.filter { !$0.showsOnGrid }
            return grid
        }
    }

    struct Step: Decodable {
        var run: String?
        var expect: [String: Value]?
    }

    /// JSON values retain their types: e.g. false cannot accidentally assert the number 0.
    enum Value: Codable, Equatable {
        case string(String), bool(Bool), int(Int), array([Value]), object([String: Value])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Int.self) { self = .int(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([Value].self) { self = .array(v) }
            else { self = .object(try c.decode([String: Value].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .int(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }

        static func strings(_ strings: [String]) -> Value { .array(strings.map(Value.string)) }
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    // Regression scenarios use this subset of the demo driver's commands.
    private static let commands: Set<String> = [
        "show", "hide", "keys", "click", "fpress", "press", "drag", "merge", "edge",
        "fdrag", "finside", "fhold", "hold", "release", "page", "folder", "focus",
        "edit", "select", "fselect", "search", "type", "group", "undo", "redo",
        "deletepage", "pagemenuhold", "menuhold", "menurun", "fakeinstall", "pagetitle",
        "movetopage", "titleedit", "autoadd", "windowsize", "addaction", "runaction",
        "neweditor", "editaction", "editorfill", "editorsave", "editorcancel",
    ]

    static func snapshot(_ state: AppState, overlay: OverlayController) -> [String: Value] {
        func name(_ id: UUID) -> String {
            state.grid.item(id)?.title ?? state.grid.allApps.first(where: { $0.id == id })?.title ?? id.uuidString
        }
        let focus: String
        if let i = state.focusIndex {
            if !state.query.isEmpty { focus = state.searchResults[safe: i]?.title ?? "<invalid:\(i)>" }
            else if let folder = state.openFolder { focus = folder.apps[safe: i]?.title ?? "<invalid:\(i)>" }
            else { focus = state.currentItems[safe: i]?.title ?? "<invalid:\(i)>" }
        } else { focus = "" }
        let editing: String
        switch state.textEdit?.target {
        case .item(let id): editing = "item:\(name(id))"
        case .pageTitle(let id): editing = "page:\(state.grid.pages.first { $0.id == id }?.title ?? "")"
        case nil: editing = ""
        }
        return [
            "pages": .array(state.grid.pages.map { .strings($0.items.map(\.title)) }),
            "pageTitles": .strings(state.grid.pages.map { $0.title ?? "" }),
            "folders": .object(Dictionary(uniqueKeysWithValues: state.grid.pages.flatMap(\.items).compactMap {
                $0.folder.map { ($0.name, Value.strings($0.apps.map(\.title))) }
            })),
            "apps": .strings(state.grid.allApps.map(\.title).sorted()),
            "selection": .strings(state.selection.map(name).sorted()),
            "focus": .string(focus), "currentPage": .int(state.currentPage),
            "folder": .string(state.openFolder?.name ?? ""), "query": .string(state.query),
            "editing": .bool(state.editing), "shown": .bool(state.isShown),
            "dragging": .bool(state.drag.active), "textEdit": .string(editing),
            "searchResults": .strings(state.allSearchResults.map(\.title)),
            // The argument each result carries, "" for none, in the same order.
            "searchArguments": .strings(state.allSearchResults.map { $0.argument ?? "" }),
            "toast": .string(state.toast ?? ""),
            // Every action's keywords by name, and the search-only ones' names.
            "actions": .object(Dictionary(state.grid.allActions.map { ($0.name, Value.strings($0.keywords)) }, uniquingKeysWith: { a, _ in a })),
            "hiddenActions": .strings(state.grid.hiddenActions.map(\.name)),
            // "" with no editor open, else "new" or "edit:<name>", and what keeps it from saving.
            "actionEditor": .string(state.actionEditor.map { $0.original.map { "edit:\($0.name)" } ?? "new" } ?? ""),
            "editorErrors": .strings(state.actionEditor?.errors ?? []),
            "editorWarnings": .strings(state.actionEditor?.warnings ?? []),
            "keyWindow": .bool(overlay.window?.isKeyWindow == true),
            "pagerReady": .bool(state.drag.pagerFrame.width > 0 && state.drag.pagerFrame.height > 0),
            "folderReady": .bool(state.openFolder != nil && state.drag.folderGridFrame.width > 0 && state.drag.folderGridFrame.height > 0),
        ]
    }

    private static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    static func run(_ path: String, state: AppState, overlay: OverlayController, delegate: AppDelegate) {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_DIR"]
                      ?? state.store.url.deletingLastPathComponent().path)
        Task {
            var stepNumber = 0
            var checkpoints = 0
            var expected: [String: Value] = [:]
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var data = try Data(contentsOf: URL(fileURLWithPath: path))
                try data.write(to: dir.appendingPathComponent("scenario.json"))
                let files = dir.appendingPathComponent("files")
                data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "${FILES}", with: files.path).utf8)
                let scenario = try JSONDecoder().decode(Scenario.self, from: data)
                if let fixtureFiles = scenario.fixture.files {
                    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
                    for (name, text) in fixtureFiles {
                        guard !name.contains("/"), !name.hasPrefix(".") else { throw Failure("Fixture file names must be plain: \(name)") }
                        try Data(text.utf8).write(to: files.appendingPathComponent(name))
                    }
                }
                guard !NSScreen.screens.isEmpty else {
                    throw Failure("UI tests need a logged-in graphical macOS session")
                }
                guard !scenario.steps.isEmpty, scenario.steps.contains(where: { $0.expect?.isEmpty == false }) else {
                    throw Failure("A scenario needs steps and at least one nonempty assertion")
                }
                // Validate everything before sending the first event. Typos must never pass silently.
                let fields = Set(snapshot(state, overlay: overlay).keys)
                for step in scenario.steps {
                    guard (step.run != nil) != (step.expect != nil) else {
                        throw Failure("Each step needs exactly one of run or expect")
                    }
                    if let run = step.run {
                        let command = String(run.prefix(while: { $0 != ":" }))
                        guard commands.contains(command), !run.contains(";") else {
                            throw Failure("Unsupported UI test command '\(run)'")
                        }
                    }
                    if let expect = step.expect {
                        guard !expect.isEmpty, Set(expect.keys).isSubset(of: fields) else {
                            throw Failure("Empty assertion or unknown fields: \(Set(expect.keys).subtracting(fields).sorted())")
                        }
                    }
                }
                let grid = try scenario.fixture.grid()
                state.prefs.hotkeyEnabled = false
                state.prefs.autoAddApps = false
                state.prefs.windowMode = .window
                state.prefs.background = .solid
                state.prefs.backgroundOpacity = 1
                state.prefs.hideOnSpaceChange = false
                state.catalogScanned(grid.allApps.map { InstalledApp(bundleID: $0.bundleID, path: $0.path, name: $0.name) }, disk: DiskState())
                state.replaceGrid(grid)
                print("UI TEST: \(scenario.name)")
                for (i, step) in scenario.steps.enumerated() {
                    stepNumber = i + 1
                    expected = step.expect ?? [:]
                    print("STEP \(stepNumber): \(step.run ?? "expect \(expected.keys.sorted())")")
                    fflush(stdout)
                    if let command = step.run {
                        let error = await withCheckedContinuation { continuation in
                            DebugScript.run(command, state: state, overlay: overlay, delegate: delegate, strict: true) {
                                continuation.resume(returning: $0)
                            }
                        }
                        if let error { throw Failure(error) }
                    } else {
                        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                        var matches = 0
                        repeat {
                            let actual = snapshot(state, overlay: overlay)
                            matches = expected.allSatisfy { actual[$0.key] == $0.value } ? matches + 1 : 0
                            if matches >= 2 { break }
                            try await Task.sleep(for: .milliseconds(50))
                        } while ContinuousClock.now < deadline
                        guard matches >= 2 else { throw Failure("State did not match within 3 seconds") }
                        checkpoints += 1
                    }
                }
                try json(snapshot(state, overlay: overlay)).write(to: dir.appendingPathComponent("state.json"))
                try GridStore.encode(state.grid).write(to: dir.appendingPathComponent("grid.json"))
                try json(["status": Value.string("passed"), "checkpoints": .int(checkpoints), "steps": .int(stepNumber)])
                    .write(to: dir.appendingPathComponent("result.json"))
                print("PASS: \(scenario.name) (\(checkpoints) checkpoints)")
                fflush(stdout)
                exit(0)
            } catch {
                let actual = snapshot(state, overlay: overlay)
                let report: [String: Value] = [
                    "status": .string("failed"), "step": .int(stepNumber),
                    "message": .string(String(describing: error)), "expected": .object(expected), "actual": .object(actual),
                ]
                try? json(report).write(to: dir.appendingPathComponent("result.json"))
                try? json(actual).write(to: dir.appendingPathComponent("state.json"))
                try? GridStore.encode(state.grid).write(to: dir.appendingPathComponent("grid.json"))
                DebugScript.snapshot(name: "failure", dir: dir.path, includingHidden: true)
                FileHandle.standardError.write(Data("FAIL at step \(stepNumber): \(error)\nArtifacts: \(dir.path)\n".utf8))
                exit(1)
            }
        }
    }
}
#endif
