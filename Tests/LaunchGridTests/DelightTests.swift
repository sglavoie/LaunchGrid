import AppKit
import Foundation
import Testing
@testable import LaunchGrid
@testable import LaunchGridCore

/// System Settings panes in search, suggestions for the time of day, names that grow with
/// their icons and the live Calendar and Clock icons.
@MainActor @Suite(.tempDir) struct DelightTests {
    @Test func settingsPanesComeAfterTheGrid() {
        let state = makeState(["Blueprint", "Notes"])
        state.query = "blue"
        let titles = state.allSearchResults.map(\.title)
        #expect(titles.first == "Blueprint")
        #expect(titles.contains("Bluetooth"))
        #expect(titles.firstIndex(of: "Bluetooth")! > titles.firstIndex(of: "Blueprint")!)
        // Turned off, only the grid's.
        state.prefs.searchSettingsPanes = false
        #expect(state.allSearchResults.map(\.title) == ["Blueprint"])
    }

    @Test func aPaneOpenedMostRanksFirstAmongPanes() {
        let state = makeState(["Notes"])
        state.query = "di"
        let before = state.allSearchResults.map(\.title)
        #expect(before.contains("Displays"))
        let dictation = SettingsPane.all.first { $0.name == "Keyboard" }!
        for _ in 0..<3 { state.recordUse(.action(dictation.action)) }
        // "di" finds Keyboard through "Dictation"; opened often, it comes first of the panes.
        let after = state.allSearchResults.map(\.title)
        #expect(after.first == "Keyboard")
    }

    @Test func aPaneCanOnlyBeOpenedFromItsMenu() {
        let state = makeState(["Notes"])
        let pane = SettingsPane.all.first { $0.name == "Sound" }!
        let entries = MenuEntry.item(.action(pane.action), state: state)
        #expect(entries.map(\.title) == ["Open"])
    }

    @Test func suggestionsFollowTheTimeOfDayWhenTurnedOn() {
        let state = makeState(["Mail", "Music", "Notes"])
        let mail = state.grid.allApps.first { $0.name == "Mail" }!
        for _ in 0..<3 { state.recordUse(.app(mail)) }
        state.refreshSuggestions()
        #expect(state.suggestions.isEmpty, "off by default")
        state.prefs.showSuggestions = true
        state.refreshSuggestions()
        #expect(state.suggestions.map(\.title) == ["Mail"])
        // At the other end of the day, nothing yet.
        state.refreshSuggestions(at: Date().addingTimeInterval(12 * 3600))
        #expect(state.suggestions.isEmpty)
        // An app gone from the layout isn't suggested.
        state.refreshSuggestions()
        state.remove([mail.id])
        state.refreshSuggestions()
        #expect(state.suggestions.isEmpty)
    }

    @Test func namesGrowWithTheirIcons() {
        #expect(GridLayout.labelFontSize(iconSize: 64) == 11)
        #expect(GridLayout.labelFontSize(iconSize: 120) > 13)
        #expect(GridLayout.labelFontSize(iconSize: 200) == 15)
        // A big cell gets a bigger icon than before, with room for its name.
        let big = GridLayout(size: CGSize(width: 2464, height: 1250), rows: 5, columns: 7)
        let icon = big.iconSize(scale: 1, labels: true)
        #expect(icon > 145)
        #expect(big.labelsFit(iconSize: icon))
        // A short cell still leaves its name room.
        let short = GridLayout(size: CGSize(width: 900, height: 300), rows: 5, columns: 7)
        let small = short.iconSize(scale: 1.4, labels: true)
        #expect(small + GridLayout.labelHeight(iconSize: small) <= short.cell.height + 0.001)
    }

    @Test func theFocusFitsItsCell() {
        let cell = CGSize(width: 120, height: 110)
        let size = FocusHalo.size(iconSize: 80, labels: true, cell: cell)
        #expect(size.width <= cell.width - 4)
        #expect(size.height <= cell.height)
        #expect(size.height > 80)
    }

    @Test func calendarAndClockAreLive() {
        #expect(LiveIcon.kind(for: "/System/Applications/Calendar.app") == .calendar)
        #expect(LiveIcon.kind(for: "/System/Applications/Clock.app") == .clock)
        #expect(LiveIcon.kind(for: "/System/Applications/Notes.app") == nil)
        // Another app with the same name isn't Apple's.
        #expect(LiveIcon.kind(for: "/tmp/nowhere/Calendar.app") == nil)
    }

    @Test func liveIconsFollowTheIconStyle() {
        #expect(LiveIcon.style(forTheme: "") == .light)
        #expect(LiveIcon.style(forTheme: "RegularLight") == .light)
        #expect(LiveIcon.style(forTheme: "RegularDark") == .dark)
        #expect(LiveIcon.style(forTheme: "ClearDark") == nil)
        #expect(LiveIcon.style(forTheme: "TintedLight") == nil)
    }
}
