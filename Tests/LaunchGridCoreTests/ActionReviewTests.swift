import AppKit
import Foundation
import Testing
@testable import LaunchGridCore

@Suite struct ActionReviewTests {
    let web = Action(name: "Docs", kind: .openURL(template: "https://example.com/docs"))
    let deepLink = Action(name: "Vault", kind: .openURL(template: "obsidian://open?vault=Notes"))
    let file = Action(name: "Notes", kind: .openFile(path: "/Users/x/notes.txt", appPath: nil))
    let shortcut = Action(name: "GIF", kind: .shortcut(name: "Make GIF", input: nil))
    let shell = Action(name: "Wipe", keywords: ["wipe"], icon: .emoji("💣"),
                       kind: .shell(command: "rm -rf ~/secret-marker", runMode: .terminal, workingDirectory: "/private/marker-dir", timeoutSeconds: 30))
    let script = Action(name: "Deploy", kind: .userScript(fileName: "deploy-marker.sh", arguments: ["--token=marker-token"], runMode: .background),
                        showsOnGrid: false)

    var grid: Grid {
        Grid(rows: 3, columns: 4, pages: [Page(items: [
            .app(AppRef(bundleID: "com.test.A", path: "/Applications/A.app", name: "A")),
            .action(web), .action(deepLink), .action(file), .action(shortcut), .action(shell),
        ])], hiddenActions: [script])
    }

    @Test func commandsScriptsAndAppLinksAreWhatAsks() {
        #expect(grid.actionReview.map(\.action.name) == ["Docs", "Vault", "Notes", "GIF", "Wipe", "Deploy"])
        #expect(grid.actionReview.filter(\.isRunnableCode).map(\.action.name) == ["Vault", "Wipe", "Deploy"])
        #expect(grid.needsActionReview)
        #expect(!Grid(rows: 3, columns: 4, pages: [Page(items: [.action(web), .action(file), .action(shortcut)])]).needsActionReview)
        #expect(!ActionKind.openURL(template: " HTTPS://example.com").isRunnableCode)
        #expect(ActionKind.openURL(template: "file:///Applications/Calculator.app").isRunnableCode)
        #expect(ActionKind.openURL(template: "httpx://example.com").isRunnableCode)
    }

    /// Opening some files runs something: an app, a Terminal command, an executable, or any
    /// file opened with a terminal. Those ask too, and Remove Them leaves them out.
    @Test func filesThatRunSomethingWhenOpenedAsk() throws {
        for path in ["/Users/x/Notes.command", "/Users/x/Tool.APP", "/Users/x/setup.pkg", "/Users/x/run.tool",
                     "/Users/x/Profile.terminal", "/Users/x/link.webloc", "/Users/x/x.jar"] {
            #expect(ActionKind.openFile(path: path, appPath: nil).isRunnableCode, "\(path)")
        }
        #expect(ActionKind.openFile(path: "/Users/x/notes.txt", appPath: "/System/Applications/Utilities/Terminal.app").isRunnableCode)
        #expect(ActionKind.openFile(path: "/Users/x/notes.txt", appPath: "/Applications/iTerm.app").isRunnableCode)
        #expect(!ActionKind.openFile(path: "/Users/x/notes.txt", appPath: "/System/Applications/TextEdit.app").isRunnableCode)
        #expect(ActionKind.openFile(path: "/Users/x/Readme", appPath: nil).isRunnableCode, "missing, of no known kind")
        #expect(ActionKind.openFile(path: "/Users/x/Sunset.saver", appPath: nil).isRunnableCode)

        // An executable without an extension opens in Terminal; a plain file doesn't.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("tool"), plain = dir.appendingPathComponent("README")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try Data("hi".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        #expect(ActionKind.openFile(path: tool.path, appPath: nil).isRunnableCode)
        #expect(!ActionKind.openFile(path: plain.path, appPath: nil).isRunnableCode)
        #expect(!ActionKind.openFile(path: dir.path, appPath: nil).isRunnableCode, "a folder is searchable, not run")

        // Scripts, whose default app may run them, and links to them, whatever they're named.
        for path in ["/Users/x/setup.sh", "/Users/x/a.pl", "/Users/x/b.py", "/Users/x/c.applescript", "/Users/x/d.zsh"] {
            #expect(ActionKind.openFile(path: path, appPath: nil).isRunnableCode, "\(path)")
        }
        let shScript = dir.appendingPathComponent("run.sh"), disguised = dir.appendingPathComponent("notes.txt")
        try Data("#!/bin/sh\n".utf8).write(to: shScript)
        try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: tool)
        #expect(ActionKind.openFile(path: disguised.path, appPath: nil).isRunnableCode, "a link to an executable")
        let linkedPlain = dir.appendingPathComponent("plain-link.txt")
        try FileManager.default.createSymbolicLink(at: linkedPlain, withDestinationURL: plain)
        #expect(!ActionKind.openFile(path: linkedPlain.path, appPath: nil).isRunnableCode, "a link to a plain file")

        // A Finder alias opens what it points to, though it has no extension of its own.
        let app = dir.appendingPathComponent("Payload.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let alias = dir.appendingPathComponent("Invoice"), plainAlias = dir.appendingPathComponent("Letter")
        try URL.writeBookmarkData(try app.bookmarkData(options: .suitableForBookmarkFile), to: alias)
        try URL.writeBookmarkData(try plain.bookmarkData(options: .suitableForBookmarkFile), to: plainAlias)
        #expect(ActionKind.openFile(path: alias.path, appPath: nil).isRunnableCode, "an alias to an app")
        #expect(!ActionKind.openFile(path: plainAlias.path, appPath: nil).isRunnableCode, "an alias to a plain file")

        // Any app other than the file's own is launched, whatever the file, and may run it.
        for app in ["/Users/x/Downloads/Payload.app", "/Applications/Python 3.13/Python Launcher.app"] {
            #expect(ActionKind.openFile(path: "/etc/hosts", appPath: app).isRunnableCode, "\(app)")
            #expect(ActionKind.openFile(path: plain.path, appPath: app).isRunnableCode, "\(app)")
        }
        // Terminal itself, through a link with another name.
        let viewer = dir.appendingPathComponent("Viewer.app")
        try FileManager.default.createSymbolicLink(at: viewer, withDestinationURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        #expect(ActionKind.openFile(path: plain.path, appPath: viewer.path).isRunnableCode, "a link to Terminal")
        let text = dir.appendingPathComponent("notes.txt.plain.txt")
        try Data("hi".utf8).write(to: text)
        if let own = NSWorkspace.shared.urlForApplication(toOpen: text) {
            #expect(!ActionKind.openFile(path: text.path, appPath: own.path).isRunnableCode, "its own app: \(own.path)")
        }

        let script = Action(name: "Script", kind: .openFile(path: "/Users/x/Notes.command", appPath: nil))
        let shared = Grid(rows: 3, columns: 4, pages: [Page(items: [.action(file), .action(script)])])
        #expect(shared.needsActionReview)
        #expect(shared.applyingReview(.removeRunnable).allActions.map(\.name) == ["Notes"])
    }

    @Test func theListShowsEachInFull() {
        let details = Dictionary(uniqueKeysWithValues: grid.actionReview.map { ($0.action.name, $0.detail) })
        #expect(details["Wipe"] == "rm -rf ~/secret-marker\n(in /private/marker-dir)")
        #expect(details["Deploy"] == "Script deploy-marker.sh\n--token=marker-token")
        #expect(details["Vault"] == "obsidian://open?vault=Notes")
    }

    @Test func keepingMarksEveryActionForReview() {
        let kept = grid.applyingReview(.keepForReview)
        #expect(kept.allActions.count == 6 && kept.allActions.allSatisfy { $0.needsReview })
        #expect(kept.allApps.map(\.name) == ["A"])
    }

    @Test func removingLeavesOutTheRunnableOnesAndKeepsTheRestForReview() {
        let kept = grid.applyingReview(.removeRunnable)
        #expect(kept.allActions.map(\.name) == ["Docs", "Notes", "GIF"])
        #expect(kept.allActions.allSatisfy { $0.needsReview })
        #expect(kept.hiddenActions.isEmpty && kept.allApps.map(\.name) == ["A"])
    }

    /// A page that held only commands goes with them, rather than loading blank.
    @Test func removingDropsThePagesItEmpties() {
        let a = GridItem.app(AppRef(bundleID: "com.test.A", path: "/Applications/A.app", name: "A"))
        let b = GridItem.app(AppRef(bundleID: "com.test.B", path: "/Applications/B.app", name: "B"))
        let shared = Grid(rows: 3, columns: 4, pages: [Page(items: [a]), Page(items: [.action(shell)]), Page(), Page(items: [b])])
        let kept = shared.applyingReview(.removeRunnable)
        #expect(kept.pages.map(\.items.count) == [1, 0, 1], "the emptied page goes; one already empty stays")
        #expect(kept.allApps.map(\.name) == ["A", "B"])
    }

    @Test func needsReviewIsWrittenOnlyWhenSetAndSurvivesTheAppsOwnLayout() throws {
        let plain = String(decoding: try GridStore.encode(grid), as: UTF8.self)
        #expect(!plain.contains("needsReview"))
        let flagged = try GridStore.encode(grid.applyingReview(.keepForReview))
        #expect(String(decoding: flagged, as: UTF8.self).contains("\"needsReview\" : true"))
        #expect(try GridStore.decode(flagged).allActions.allSatisfy { $0.needsReview })
    }

    @Test func theAppsOwnLayoutAndItsBackupNeverSetIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GridStore(url: dir.appendingPathComponent("grid.json"))
        try store.save(grid)
        try store.save(grid) // the first save becomes the backup
        #expect(try store.load().allActions.allSatisfy { !$0.needsReview })
        #expect(try store.load().allActions.count == 6)
        #expect(try store.loadBackup().allActions.allSatisfy { !$0.needsReview })
    }

    @Test func savingWithoutCommandsWritesNoneOfTheirText() throws {
        let data = try GridStore.encode(grid.removingCommands())
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["rm -rf", "secret-marker", "marker-dir", "deploy-marker", "marker-token"] {
            #expect(data.range(of: Data(secret.utf8)) == nil, "\(secret) left out")
        }
        let read = try GridStore.decode(data)
        let wipe = try #require(read.allActions.first { $0.name == "Wipe" })
        #expect(wipe.kind == .shell(command: "", runMode: .terminal, workingDirectory: nil, timeoutSeconds: nil))
        #expect(wipe.needsReview && wipe.icon == .emoji("💣") && wipe.keywords == ["wipe"])
        let deploy = try #require(read.hiddenActions.first)
        #expect(deploy.kind == .userScript(fileName: "", arguments: [], runMode: .background) && deploy.needsReview)
        #expect(read.locateAction(wipe.id) == grid.locateAction(shell.id), "the layout keeps its shape")
        // Links, files and Shortcuts are written as they are.
        #expect(text.contains("obsidian:\\/\\/open?vault=Notes") || text.contains("obsidian://open?vault=Notes"))
        #expect(!read.allActions.first { $0.name == "Docs" }!.needsReview)

        let full = try GridStore.encode(grid)
        #expect(full.range(of: Data("secret-marker".utf8)) != nil && full.range(of: Data("marker-token".utf8)) != nil)
        #expect(grid.hasCommands && !grid.removingCommands().allActions.isEmpty)
        #expect(!Grid(rows: 3, columns: 4, pages: [Page(items: [.action(web)])]).hasCommands)
    }

    /// A direction override or a zero-width space would make a command read differently from
    /// what runs: the review names them. Joiners inside an emoji stay, as do line breaks.
    @Test func hiddenCharactersAreNamed() {
        let reversed = ActionKind.shell(command: "echo ok #\u{202E}gnp.x/ ; rm -rf ~", runMode: .background,
                                        workingDirectory: nil, timeoutSeconds: nil)
        #expect(reversed.reviewDescription == "echo ok #⟨U+202E⟩gnp.x/ ; rm -rf ~")
        #expect(ActionKind.revealingHidden("a\u{200B}b\nc\td") == "a⟨U+200B⟩b\nc\td")
        #expect(ActionKind.revealingHidden("👨\u{200D}👩\u{200D}👧") == "👨\u{200D}👩\u{200D}👧")
        #expect(ActionKind.revealingHidden("a\u{200D}b") == "a⟨U+200D⟩b")
        #expect(ActionKind.hiddenCharacters(in: "x\u{2066}y\u{2066}\u{E000}") == ["U+2066", "U+E000"])
        let entry = ActionReviewEntry(action: Action(name: "Safe\u{202E}", kind: reversed), isRunnableCode: true)
        #expect(entry.name == "Safe⟨U+202E⟩")
    }
}
