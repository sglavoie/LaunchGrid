import Foundation
import Testing
@testable import LaunchGridCore

@Suite struct SearchActionTests {
    let github = Action(name: "Search GitHub", keywords: ["gh"], kind: .openURL(template: "https://github.com/search?q={query}"))
    let home = Action(name: "GitHub Home", keywords: ["ghh"], kind: .openURL(template: "https://github.com"))

    func names(_ items: [GridItem], _ query: String) -> [String] {
        Search.results(in: items, query: query).map(\.title)
    }

    @Test func anExactKeywordBeatsAnExactName() {
        let items: [GridItem] = [.app(app("gh")), .app(app("GHex")), .action(github)]
        #expect(names(items, "gh") == ["Search GitHub", "gh", "GHex"])
        #expect(names(items, "GH") == ["Search GitHub", "gh", "GHex"], "case-insensitive")
        let cafe = Action(name: "Order", keywords: ["café"], kind: .openURL(template: "https://example.com"))
        #expect(names([.app(app("Cafe")), .action(cafe)], "cafe") == ["Order", "Cafe"], "diacritic-insensitive")
    }

    @Test func aKeywordAndArgumentCarryTheArgument() throws {
        let items: [GridItem] = [.app(app("gh launchgrid")), .action(home), .action(github)]
        let first = try #require(Search.results(in: items, query: "gh LaunchGrid").first)
        #expect(first.id == github.id)
        #expect(first.argument == "LaunchGrid", "keeps its case")
        #expect(Search.results(in: items, query: "  gh   launch grid  ").first?.argument == "launch grid", "trimmed")
        #expect(Search.results(in: items, query: "gh").first?.argument == nil)
        #expect(Search.results(in: items, query: "gh ").first?.argument == nil)
    }

    /// A Shortcut with no input of its own takes what's typed after its keyword as its input;
    /// one with a fixed input doesn't take an argument.
    @Test func aShortcutWithNoInputTakesTheArgument() {
        let log = Action(name: "Log", keywords: ["lg"], kind: .shortcut(name: "Log", input: nil))
        let fixed = Action(name: "Fixed", keywords: ["fx"], kind: .shortcut(name: "Fixed", input: "clipboard"))
        let match = Search.results(in: [.action(log)], query: "lg Buy milk").first
        #expect(match?.id == log.id && match?.argument == "Buy milk")
        #expect(Search.results(in: [.action(fixed)], query: "fx Buy milk").first?.argument == nil)
    }

    @Test func aKeywordWithASpaceTakesAnArgumentToo() {
        let wiki = Action(name: "Wiki", keywords: ["w en"], kind: .openURL(template: "https://en.wikipedia.org/wiki/{query}"))
        let match = Search.results(in: [.action(wiki)], query: "w en Swift").first
        #expect(match?.id == wiki.id && match?.argument == "Swift")
    }

    /// The editor asks for $LAUNCHGRID_QUERY where {query} can't go (a here-document): such a
    /// command still gets what's typed after its keyword.
    @Test func aCommandReadingTheVariableCarriesTheArgument() {
        let note = Action(name: "Note", keywords: ["n"],
                          kind: .shell(command: "cat >> ~/notes.txt <<EOF\n$LAUNCHGRID_QUERY\nEOF", runMode: .background, workingDirectory: nil, timeoutSeconds: nil))
        let match = Search.results(in: [.action(note)], query: "n buy milk").first
        #expect(match?.id == note.id && match?.argument == "buy milk")
    }

    @Test func anActionWithoutQueryTakesNoArgument() {
        // "ghh launchgrid" isn't a keyword match: GitHub Home has no {query}. It falls back to
        // scoring names and keywords, which neither matches.
        let items: [GridItem] = [.action(home), .action(github)]
        #expect(Search.results(in: items, query: "ghh launchgrid").isEmpty)
        let found = Search.results(in: items, query: "github home")
        #expect(found.map(\.id) == [home.id] && found[0].argument == nil)
    }

    @Test func eachKindSaysWhetherItTakesAnArgument() {
        #expect(ActionKind.openURL(template: "x://{query}").takesArgument)
        #expect(!ActionKind.openURL(template: "x://").takesArgument)
        #expect(ActionKind.shell(command: "echo {query}", runMode: .background, workingDirectory: nil, timeoutSeconds: nil).takesArgument)
        #expect(!ActionKind.shell(command: "echo", runMode: .terminal, workingDirectory: "{query}", timeoutSeconds: nil).takesArgument)
        // Where the editor asks for $LAUNCHGRID_QUERY instead of {query}, it still takes one.
        #expect(ActionKind.shell(command: "cat <<EOF\n$LAUNCHGRID_QUERY\nEOF", runMode: .background, workingDirectory: nil, timeoutSeconds: nil).takesArgument)
        #expect(ActionKind.shell(command: "echo ${LAUNCHGRID_QUERY:-none}", runMode: .terminal, workingDirectory: nil, timeoutSeconds: nil).takesArgument)
        #expect(ActionKind.userScript(fileName: "a.sh", arguments: ["-q", "{query}"], runMode: .background).takesArgument)
        #expect(!ActionKind.userScript(fileName: "{query}.sh", arguments: [], runMode: .background).takesArgument)
        #expect(ActionKind.shortcut(name: "S", input: "{query}").takesArgument)
        #expect(!ActionKind.shortcut(name: "{query}", input: "fixed").takesArgument)
        #expect(ActionKind.shortcut(name: "S", input: nil).takesArgument, "what's typed is its input")
        #expect(!ActionKind.openFile(path: "/{query}", appPath: nil).takesArgument)
        let shell = Action(name: "Grep", keywords: ["g"], kind: .shell(command: "grep {query}", runMode: .terminal, workingDirectory: nil, timeoutSeconds: nil))
        #expect(Search.results(in: [.action(shell)], query: "g foo").first?.argument == "foo")
    }

    @Test func aKeywordPrefixIsScoredLikeAName() {
        let docs = Action(name: "Docs", keywords: ["swiftdocs"], kind: .openURL(template: "https://swift.org"))
        let items: [GridItem] = [.app(app("Swiftly")), .action(docs)]
        #expect(names(items, "swiftd") == ["Docs"])
        #expect(Set(names(items, "swift")) == ["Docs", "Swiftly"])
        #expect(names(items, "doc") == ["Docs"], "by name too")
    }

    @Test func searchOnlyActionsAreFound() {
        var grid = Grid(rows: 2, columns: 2, pages: [Page(items: [.app(app("Notes")), .action(home)])])
        grid.hiddenActions = [github]
        let found = Search.results(in: grid.allSearchItems, query: "gh")
        #expect(found.map(\.id) == [github.id, home.id])
        #expect(Search.results(in: grid.allSearchItems, query: "gh x").first?.id == github.id)
    }

    @Test func foldersAreNotMatchedButTheirAppsAre() {
        let folder = Folder(name: "Notes Folder", apps: [app("Notes")])
        #expect(names([.folder(folder)], "notes").isEmpty)
        #expect(names(Grid(rows: 2, columns: 2, pages: [Page(items: [.folder(folder)])]).allSearchItems, "notes") == ["Notes"])
    }

    @Test func appsRankAsTheyDidAlone() {
        let apps = ["Notes", "Keynote", "Notion", "Sonoma Notes", "Final Cut Pro", "GarageBand", "Wi-Fi Explorer", "WiFiman"].map { app($0) }
        for query in ["no", "fcp", "wifi", "gb", "e", "zzz"] {
            #expect(names(apps.map(GridItem.app), query) == Search.results(in: apps, query: query).map(\.title))
            #expect(Search.results(in: apps.map(GridItem.app), query: query).allSatisfy { $0.argument == nil })
        }
    }

    @Test func tiesAreBrokenByTitle() {
        let b = Action(name: "B", keywords: ["x"], kind: .openURL(template: "a"))
        let a = Action(name: "A", keywords: ["x"], kind: .openURL(template: "a"))
        #expect(names([.action(b), .action(a)], "x") == ["A", "B"])
    }
}
