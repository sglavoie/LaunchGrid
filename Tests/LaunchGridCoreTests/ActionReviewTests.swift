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
}
