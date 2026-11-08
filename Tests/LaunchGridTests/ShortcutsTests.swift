import AppKit
import Foundation
import Testing
@testable import LaunchGrid
@testable import LaunchGridCore

/// The shortcut catalog behind the Keyboard Shortcuts panel, the ⌘ strip and the grid's menus,
/// and the ways to the panel.
@MainActor @Suite(.tempDir) struct ShortcutsTests {
    @Test func theCatalogHasEverythingTheStripAndPanelName() {
        let catalog = KeyShortcut.catalog(hotkey: "⌥Space")
        let ids = catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        // Every ID a strip names is in the catalog, once.
        for context in KeyShortcut.Context.allCases {
            #expect(Set(context.strip).isSubset(of: Set(ids)), "\(context)")
            #expect(Set(context.strip).count == context.strip.count, "\(context)")
            #expect(KeyShortcut.strip(context).map(\.id) == context.strip)
            // Every strip but a drag's (where only ⌘1–9 and Esc work) leads to the rest.
            #expect((context.strip.last == "shortcuts") == (context != .drag), "\(context)")
        }
        // Each section of the panel has something in it, the shortcut set in Settings first.
        let panel = KeyShortcut.panel(hotkey: "⌥Space")
        for section in KeyShortcut.Section.allCases {
            #expect(panel.contains { $0.section == section }, "\(section)")
        }
        #expect(panel.first?.keys == "⌥Space")
        #expect(!KeyShortcut.panel(hotkey: nil).contains { $0.id == "toggle" })
        // Strip-only lines stay out of the panel.
        #expect(!panel.contains { $0.id == "doneEditing" })
    }

    @Test func menusShowTheSameKeysAsThePanel() {
        let byID = Dictionary(uniqueKeysWithValues: KeyShortcut.catalog(hotkey: nil).map { ($0.id, $0.keys) })
        let pairs: [(MenuKey, String)] = [
            (.edit, "edit"), (.undo, "undo"), (.redo, "redo"), (.newPage, "newPage"), (.settings, "settings"),
            (.shortcuts, "shortcuts"), (.showInFinder, "showInFinder"), (.quickLook, "quickLook"),
            (.quitApp, "quitApp"), (.editAction, "editAction"), (.group, "group"), (.remove, "removeItem"),
            (.select, "toggleSelect"),
        ]
        for (key, id) in pairs { #expect(key.description == byID[id], "\(id)") }
    }

    @Test func theStripFollowsWhatsOnScreen() {
        let state = makeState(["A", "B"])
        #expect(KeyShortcut.Context.current(state) == .grid)
        state.selection = [state.grid.pages[0].items[0].id]
        #expect(KeyShortcut.Context.current(state) == .selection)
        state.editing = true
        #expect(KeyShortcut.Context.current(state) == .editing)
        state.query = "a"
        #expect(KeyShortcut.Context.current(state) == .search)
    }

    @Test func theGridsMenusShowTheirKeys() {
        let state = makeState(["A"])
        func keys(_ entries: [MenuEntry]) -> [String: String] {
            Dictionary(entries.compactMap { e in e.key.map { (e.title, $0.description) } }, uniquingKeysWith: { a, _ in a })
        }
        let page = keys(MenuEntry.page(state: state))
        #expect(page["Edit Layout"] == "⌘E" && page["Undo"] == "⌘Z" && page["Redo"] == "⇧⌘Z")
        #expect(page["Keyboard Shortcuts"] == "⌘/" && page["Settings…"] == "⌘," && page["New Page"] == "⌘N")
        let item = keys(MenuEntry.item(state.grid.pages[0].items[0], state: state))
        #expect(item["Show in Finder"] == "⌘↩" && item["Quick Look"] == "⌘Y" && item["Select"] == "Space")
        // ⌫ removes only in edit mode or a selection.
        #expect(item["Remove from Grid"] == nil)
        state.editing = true
        #expect(keys(MenuEntry.item(state.grid.pages[0].items[0], state: state))["Remove from Grid"] == "⌫")
        // Choosing it from the ⋯ menu opens the panel.
        if case .action(let run) = MenuEntry.page(state: state).first(where: { $0.title == "Keyboard Shortcuts" })?.kind { run() }
        #expect(state.showingShortcuts)
    }

    @Test func searchFindsTheKeyboardShortcutsPanel() {
        #expect(AppCommand.matches("shortcuts") == [.keyboardShortcuts])
        #expect(AppCommand.matches("keyboard sh") == [.keyboardShortcuts])
        #expect(AppCommand.matches("hotk") == [.keyboardShortcuts])
        // Not for a letter or two, nor a letter here and there.
        #expect(AppCommand.matches("ke").isEmpty && AppCommand.matches("kbd").isEmpty && AppCommand.matches("safari").isEmpty)

        let state = makeState(["Shortcuts", "Safari"])
        state.prefs.searchSettingsPanes = false
        state.query = "shortcuts"
        // After what's in the grid: Apple's Shortcuts app keeps its place.
        #expect(state.allSearchResults.map(\.title) == ["Shortcuts", "Keyboard Shortcuts"])
        let match = state.allSearchResults[1]
        #expect(MenuEntry.item(match.item, state: state).map(\.title) == ["Open"])
        state.activateResult(match)
        #expect(state.showingShortcuts)
        // The search stays, for Esc to come back to.
        #expect(state.query == "shortcuts")
        // Not a layout item: nothing was added, and hiding closes the panel.
        #expect(state.grid.allSearchItems.count == 2)
        state.didHide()
        #expect(!state.showingShortcuts)
    }

    @Test func openingThePanelPutsTheStripAway() {
        let state = makeState(["A"])
        state.commandHeld = true
        state.showingShortcuts = true
        #expect(!state.commandHeld)
        #expect(state.prefs.tipsSeen.contains("allShortcuts"))
    }
}
