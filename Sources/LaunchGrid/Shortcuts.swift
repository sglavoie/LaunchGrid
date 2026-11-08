import AppKit
import SwiftUI
import LaunchGridCore

// Every key the grid takes, described once: the Keyboard Shortcuts panel lists them all by
// section, the strip ⌘ shows when held picks those for what's on screen, and the grid's menus
// show theirs beside the items they match. `OverlayController.keyDown` is what handles them.

/// One shortcut: its keys as they're drawn, what it does, and where the panel lists it.
struct KeyShortcut: Identifiable, Equatable {
    /// Where the panel lists it.
    enum Section: CaseIterable {
        case general, navigate, search, items, select, editLayout, drag

        var title: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .navigate: "Pages and Focus"
            case .search: "Search"
            case .items: "Items"
            case .select: "Selection"
            case .editLayout: "Edit Mode"
            case .drag: "Dragging"
            }
        }
    }

    /// What's on screen, which decides what the ⌘ strip shows: the first of these that holds.
    enum Context: CaseIterable {
        case drag, search, editing, selection, folder, grid

        @MainActor
        static func current(_ state: AppState) -> Context {
            if state.drag.active { return .drag }
            if !state.query.isEmpty { return .search }
            if state.editing { return .editing }
            if !state.selection.isEmpty { return .selection }
            if state.openFolder != nil { return .folder }
            return .grid
        }

        /// What the ⌘ strip shows here, by ID, in order: the shortcuts that do something now.
        /// Mid-drag only ⌘1–9 and Esc do anything, so it has no ⌘/.
        var strip: [String] {
            switch self {
            case .grid: ["goToPage", "turnPage", "edit", "showInFinder", "quickLook", "quitApp", "newPage", "selectAll", "undo", "itemMenu", "settings", "shortcuts"]
            case .folder: ["goToPage", "edit", "showInFinder", "quickLook", "quitApp", "undo", "itemMenu", "shortcuts"]
            case .search: ["openResult", "showInFinder", "quickLook", "clearSearch", "itemMenu", "shortcuts"]
            case .editing: ["moveItem", "rename", "removeItem", "toggleSelect", "group", "editAction", "newPage", "undo", "doneEditing", "shortcuts"]
            case .selection: ["group", "removeSelection", "toggleSelect", "selectAll", "clearSelection", "undo", "shortcuts"]
            case .drag: ["carry", "cancelDrag"]
            }
        }
    }

    /// Stable, for the strip, tests and menus to name it by.
    let id: String
    let keys: String
    let label: LocalizedStringKey
    let section: Section
    /// A shorter label for the ⌘ strip, when `label` is long.
    var short: LocalizedStringKey?
    /// False for a strip-only line the panel says another way.
    var inPanel = true

    var stripLabel: LocalizedStringKey { short ?? label }

    static func == (a: KeyShortcut, b: KeyShortcut) -> Bool { a.id == b.id }

    /// Every shortcut, in the order each section of the panel shows it, strip-only ones too.
    /// `hotkey` is the shortcut that shows and hides the grid, as set in Settings (nil: none).
    static func catalog(hotkey: String?) -> [KeyShortcut] {
        var list: [KeyShortcut] = []
        if let hotkey {
            list.append(KeyShortcut(id: "toggle", keys: hotkey, label: "Show or hide LaunchGrid", section: .general))
        }
        list += [
            KeyShortcut(id: "escape", keys: "esc", label: "Back out: clear the search, close the folder, leave edit mode, clear the selection, then hide", section: .general),
            KeyShortcut(id: "shortcuts", keys: "⌘/", label: "Keyboard shortcuts (this list)", section: .general, short: "All shortcuts"),
            KeyShortcut(id: "settings", keys: "⌘,", label: "Settings", section: .general),
            KeyShortcut(id: "undo", keys: "⌘Z", label: "Undo", section: .general),
            KeyShortcut(id: "redo", keys: "⇧⌘Z", label: "Redo", section: .general),
            KeyShortcut(id: "hide", keys: "⌘W", label: "Hide LaunchGrid", section: .general),
            KeyShortcut(id: "quitSelf", keys: "⌘Q", label: "Quit LaunchGrid", section: .general),

            KeyShortcut(id: "arrows", keys: "←→↑↓", label: "Move the focus; past a page’s end, turn the page", section: .navigate),
            KeyShortcut(id: "open", keys: "↩", label: "Open the focused item", section: .navigate),
            KeyShortcut(id: "goToPage", keys: "⌘1–9", label: "Go to that page", section: .navigate, short: "Go to page"),
            KeyShortcut(id: "turnPage", keys: "⌘← ⌘→", label: "Previous or next page", section: .navigate, short: "Turn page"),
            KeyShortcut(id: "tab", keys: "⇥ ⇧⇥", label: "Next or previous page", section: .navigate),
            KeyShortcut(id: "pageUpDown", keys: "⇞ ⇟", label: "Previous or next page (Page Up, Page Down)", section: .navigate),
            KeyShortcut(id: "homeEnd", keys: "↖ ↘", label: "First or last page (Home, End)", section: .navigate),
            KeyShortcut(id: "newPage", keys: "⌘N", label: "New page after this one", section: .navigate, short: "New page"),

            KeyShortcut(id: "type", keys: "A–Z", label: "Just type to search", section: .search),
            KeyShortcut(id: "openFirst", keys: "↩", label: "Open the focused result, or the first", section: .search),
            KeyShortcut(id: "openResult", keys: "⌘1–9", label: "Open the result with that number", section: .search, short: "Open result"),
            KeyShortcut(id: "clearSearch", keys: "⌘F", label: "Clear the search and start again", section: .search, short: "Clear search"),
            KeyShortcut(id: "paste", keys: "⌘V", label: "Paste into the search", section: .search),
            KeyShortcut(id: "caret", keys: "⌥← ⌥→", label: "Move by word (⌘← ⌘→ to either end)", section: .search),
            KeyShortcut(id: "deleteWord", keys: "⌥⌫", label: "Delete a word (⌘⌫ to the start)", section: .search),
            KeyShortcut(id: "emacs", keys: "⌃A ⌃E", label: "Text-field keys: ⌃A ⌃E ⌃B ⌃F ⌃H ⌃D ⌃W ⌃U ⌃K", section: .search),

            KeyShortcut(id: "showInFinder", keys: "⌘↩", label: "Show in Finder", section: .items),
            KeyShortcut(id: "quickLook", keys: "⌘Y", label: "Quick Look", section: .items),
            KeyShortcut(id: "quitApp", keys: "⌘⌫", label: "Quit the focused app, when it’s running", section: .items, short: "Quit app"),
            KeyShortcut(id: "editAction", keys: "⌘I", label: "Edit the focused action", section: .items, short: "Edit action"),
            KeyShortcut(id: "itemMenu", keys: "⌃↩", label: "The focused item’s menu", section: .items, short: "Item menu"),
            KeyShortcut(id: "pageMenu", keys: "⇧⌃↩", label: "The ⋯ menu", section: .items),

            KeyShortcut(id: "toggleSelect", keys: "Space", label: "Select or deselect the focused item", section: .select, short: "Select"),
            KeyShortcut(id: "selectAll", keys: "⌘A", label: "Select everything on the page", section: .select, short: "Select all"),
            KeyShortcut(id: "clickSelect", keys: "⌘-click", label: "Add to the selection (⇧-click selects a run)", section: .select),
            KeyShortcut(id: "group", keys: "⌘G", label: "Group the selection into a folder", section: .select, short: "Group"),
            KeyShortcut(id: "removeSelection", keys: "⌫", label: "Remove the selection from the grid", section: .select, short: "Remove"),
            KeyShortcut(id: "clearSelection", keys: "esc", label: "Clear the selection", section: .select, short: "Deselect all"),

            KeyShortcut(id: "edit", keys: "⌘E", label: "Edit the layout, or finish editing", section: .editLayout, short: "Edit layout"),
            KeyShortcut(id: "doneEditing", keys: "⌘E", label: "Done editing", section: .editLayout, short: "Done", inPanel: false),
            KeyShortcut(id: "moveItem", keys: "⌥ ←→↑↓", label: "Move the focused item (and the selection), onto the next page past the end", section: .editLayout, short: "Move item"),
            KeyShortcut(id: "rename", keys: "↩", label: "Rename the focused app or action; open a folder, then rename it", section: .editLayout, short: "Rename"),
            KeyShortcut(id: "removeItem", keys: "⌫", label: "Remove the focused item", section: .editLayout, short: "Remove"),

            KeyShortcut(id: "carry", keys: "⌘1–9", label: "Carry what’s dragged to that page", section: .drag, short: "Move to page"),
            KeyShortcut(id: "cancelDrag", keys: "esc", label: "Cancel the drag", section: .drag, short: "Cancel drag"),
            KeyShortcut(id: "dragOut", keys: "⌥-drag", label: "Drag a tile off the grid, onto the Dock, a Finder window or another app", section: .drag),
        ]
        return list
    }

    /// The panel's list.
    static func panel(hotkey: String?) -> [KeyShortcut] { catalog(hotkey: hotkey).filter(\.inPanel) }

    /// What the ⌘ strip shows in `context`.
    static func strip(_ context: Context) -> [KeyShortcut] {
        let byID = Dictionary(catalog(hotkey: nil).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return context.strip.compactMap { byID[$0] }
    }
}


/// The key equivalent a grid menu item shows for what it does: only shown (the key handler
/// does the work, and closed menus aren't asked).
struct MenuKey {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    static let edit = MenuKey(key: "e", modifiers: .command)
    static let undo = MenuKey(key: "z", modifiers: .command)
    static let redo = MenuKey(key: "z", modifiers: [.command, .shift])
    static let newPage = MenuKey(key: "n", modifiers: .command)
    static let settings = MenuKey(key: ",", modifiers: .command)
    static let shortcuts = MenuKey(key: "/", modifiers: .command)
    static let showInFinder = MenuKey(key: "\r", modifiers: .command)
    static let quickLook = MenuKey(key: "y", modifiers: .command)
    static let quitApp = MenuKey(key: "\u{8}", modifiers: .command)
    static let editAction = MenuKey(key: "i", modifiers: .command)
    static let group = MenuKey(key: "g", modifiers: .command)
    static let remove = MenuKey(key: "\u{8}", modifiers: [])
    static let select = MenuKey(key: " ", modifiers: [])

    /// As a menu draws it: "⇧⌘Z", "⌘↩", "⌫".
    var description: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case "\r": s += "↩"
        case "\u{8}": s += "⌫"
        case " ": s += "Space"
        default: s += key.uppercased()
        }
        return s
    }

    /// The same for a SwiftUI menu.
    var swiftUI: KeyboardShortcut {
        var mods: EventModifiers = []
        if modifiers.contains(.command) { mods.insert(.command) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.option) { mods.insert(.option) }
        if modifiers.contains(.control) { mods.insert(.control) }
        let k: KeyEquivalent = switch key {
        case "\r": .return
        case "\u{8}": .delete
        case " ": .space
        default: KeyEquivalent(Character(key))
        }
        return KeyboardShortcut(k, modifiers: mods)
    }
}

/// Every shortcut, by section, over the grid: ⌘/, the ⋯ menu, a search for "shortcuts", or
/// the menu-bar and Dock menus. Esc, ⌘/ or a click outside closes it.
struct ShortcutsPanel: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let prefs = state.prefs
        let hotkey = prefs.hotkeyEnabled ? KeyCombo.describe(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers) : nil
        let all = KeyShortcut.panel(hotkey: hotkey)
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "keyboard")
                    .font(.system(size: 17, weight: .medium))
                Text("Keyboard Shortcuts")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    state.showingShortcuts = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.14), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close (esc)")
                .accessibilityLabel("Close")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 12)

            // Scrolls only when it doesn't fit, as in a small window.
            ViewThatFits(in: .vertical) {
                sections(all)
                ScrollView { sections(all) }
                    .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: 1180)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .padding(40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard Shortcuts")
    }

    private func sections(_ all: [KeyShortcut]) -> some View {
        ShortcutColumns(spacing: 28) {
            ForEach(KeyShortcut.Section.allCases, id: \.self) { section in
                VStack(alignment: .leading, spacing: 7) {
                    Text(section.title)
                        .font(.system(size: 12, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(contrast == .increased ? 0.9 : 0.55))
                        .padding(.leading, 94)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(all.filter { $0.section == section }) { ShortcutRow(shortcut: $0) }
                }
            }
        }
        .padding(.horizontal, 22).padding(.bottom, 20)
    }
}

/// A shortcut's keys in a cap, and what it does beside them.
private struct ShortcutRow: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let shortcut: KeyShortcut

    var body: some View {
        let high = contrast == .increased
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: shortcut.keys)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.white.opacity(high ? 0.3 : 0.16), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(high ? 0.5 : 0.18), lineWidth: 0.5))
                .fixedSize()
                .frame(minWidth: 84, alignment: .trailing)
            Text(shortcut.label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(high ? 1 : 0.88))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// The panel's sections in as many columns as fit (one to three), each section whole in one
/// column, the columns about as tall as each other.
private struct ShortcutColumns: Layout {
    var spacing: CGFloat
    static let minColumn: CGFloat = 300

    private func columns(_ subviews: Subviews, width: CGFloat) -> (count: Int, width: CGFloat, assignment: [[Int]]) {
        let count = max(1, min(3, Int((width + spacing) / (Self.minColumn + spacing))))
        let colWidth = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: colWidth, height: nil)).height }
        // In order, starting the next column once this one holds its share.
        let total = heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0))
        let share = total / CGFloat(count)
        var assignment: [[Int]] = [[]]
        var filled: CGFloat = 0
        for (i, h) in heights.enumerated() {
            if !assignment[assignment.count - 1].isEmpty, assignment.count < count, filled + h / 2 > share {
                assignment.append([])
                filled = 0
            }
            assignment[assignment.count - 1].append(i)
            filled += h + spacing
        }
        return (count, colWidth, assignment)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (Self.minColumn * 3 + spacing * 2)
        let (_, colWidth, assignment) = columns(subviews, width: width)
        let proposal = ProposedViewSize(width: colWidth, height: nil)
        var tallest: CGFloat = 0
        for column in assignment {
            var height: CGFloat = spacing * CGFloat(max(column.count - 1, 0))
            for i in column { height += subviews[i].sizeThatFits(proposal).height }
            tallest = max(tallest, height)
        }
        return CGSize(width: width, height: tallest)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, colWidth, assignment) = columns(subviews, width: bounds.width)
        for (c, column) in assignment.enumerated() {
            var y = bounds.minY
            let x = bounds.minX + CGFloat(c) * (colWidth + spacing)
            for i in column {
                let size = subviews[i].sizeThatFits(ProposedViewSize(width: colWidth, height: nil))
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: colWidth, height: size.height))
                y += size.height + spacing
            }
        }
    }
}
