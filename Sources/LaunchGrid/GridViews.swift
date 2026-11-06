import AppKit
import SwiftUI
import LaunchGridCore

/// Root of the overlay: background, search, pager, page dots, folder and drag layers.
struct GridRootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var size: CGSize = .zero

    var body: some View {
        // A folder or the rename card is modal: VoiceOver stays out of what's beneath it.
        let folderModal = state.openFolder != nil
        let editModal = state.textEdit != nil
        ZStack {
            BackgroundView()
                .contentShape(Rectangle())
                .onTapGesture { backgroundClicked() }
                .contextMenu { BackgroundMenu() }
                .accessibilityHidden(folderModal || editModal)

            VStack(spacing: 0) {
                TopBar()
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                PageTitle()
                    .frame(height: 28)
                if state.query.isEmpty {
                    Pager()
                } else {
                    SearchResultsView()
                }
                PageDots()
                    .frame(height: 44)
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 48)
            .accessibilityHidden(folderModal || editModal)

            ZStack {
                if let folder = state.openFolder {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { state.closeFolder() }
                        .transition(.opacity)
                        .accessibilityHidden(true)
                    FolderPanel(folder: folder)
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isModal)
                        .accessibilityHidden(editModal)
                        .transition(reduceMotion ? .opacity : folderTransition(folder))
                }
            }
            // Opening and closing animate from here, not through `withAnimation`: called right
            // after another change (grouping makes the folder, then opens it), `withAnimation`
            // brought the view up to date first and the opening then sometimes never showed,
            // leaving a folder open that nobody could see.
            // With Reduce Motion, a short fade, as for the rename card.
            .animation(state.isShown ? AppState.pageAnimation ?? .easeOut(duration: 0.15) : nil, value: state.openFolderID)

            DragLayer()
            LandingLayer()

            ZStack {
                if let edit = state.textEdit {
                    TextEditCard(request: edit)
                        // A new request (another rename) starts over with its own text.
                        .id(edit.id)
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isModal)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                }
            }
            // `textEdit` changes outside any animation. With Reduce Motion, a short fade.
            .animation(state.isShown ? AppState.pageAnimation ?? .easeOut(duration: 0.15) : nil, value: state.textEdit?.id)

            // Only its Undo button takes clicks; the rest goes to the grid beneath.
            ToastLayer()
                .allowsHitTesting(state.toastUndoable)
        }
        .coordinateSpace(name: "root")
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: {
            state.drag.rootOrigin = $0
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("root"))
                .onChanged { state.dragChanged(start: $0.startLocation, location: $0.location) }
                .onEnded { state.dragEnded(start: $0.startLocation, location: $0.location, predicted: $0.predictedEndLocation) }
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        // The tiles themselves settle in and drift out (`AppearMotion`); the whole fades. Hiding to
        // open an item, the window's own fade does it, so the opened tile's zoom stays in view.
        .opacity(state.isShown || state.launchingID != nil ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: state.isShown)
        .environment(\.colorScheme, .dark)
    }

    /// The open folder grows out of its tile and shrinks back into it: from the tile's place and
    /// size to the middle. Where the tile isn't on the page shown, it grows from the middle.
    private func folderTransition(_ folder: Folder) -> AnyTransition {
        let frame = state.drag.pagerFrame
        guard size != .zero, frame != .zero,
              let i = state.currentItems.firstIndex(where: { $0.id == folder.id }) else {
            return .scale(scale: 0.85).combined(with: .opacity)
        }
        let c = state.iconCenter(i, inFolder: false)
        let tile = CGPoint(x: frame.minX + c.x, y: frame.minY + c.y)
        let panel = state.drag.folderPanelFrame.width > 0 ? state.drag.folderPanelFrame.width : size.width * 0.6
        let offset = CGSize(width: tile.x - size.width / 2, height: tile.y - size.height / 2)
        return .folderZoom(offset: offset, startScale: min(0.5, state.pageIconSize / max(panel, 1)))
    }

    /// Steps back one level, in Esc's order: search, edit mode, then the selection.
    private func backgroundClicked() {
        if state.textEdit != nil { return }
        if !state.query.isEmpty {
            state.endSearch()
        } else if state.editing {
            state.editing = false
        } else if !state.selection.isEmpty {
            state.selection.removeAll()
        } else if state.prefs.hideOnEmptyClick {
            state.onHide()
        }
    }
}

/// The toast, animated on its own so grid changes made alongside it don't animate too.
/// It fades in place with Reduce Motion.
struct ToastLayer: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// "Removed Safari — ⌘Z to undo" as "Removed Safari", beside its Undo button.
    static func withoutUndoHint(_ text: String) -> String {
        let hint = String(localized: "— ⌘Z to undo")
        guard let r = text.range(of: hint, options: .backwards) else { return text }
        return text[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack {
            Spacer()
            if let toast = state.toast {
                HStack(spacing: 12) {
                    Text(state.toastUndoable ? Self.withoutUndoHint(toast) : toast)
                        .font(.callout.weight(.medium))
                    if state.toastUndoable {
                        Button {
                            state.undo()
                            state.toast = nil
                            state.toastUndoable = false
                        } label: {
                            HStack(spacing: 4) {
                                Text("Undo")
                                Text(verbatim: "⌘Z").foregroundStyle(.secondary)
                            }
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.white.opacity(0.16), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Undo")
                    }
                }
                .padding(.leading, 16).padding(.trailing, state.toastUndoable ? 6 : 16).padding(.vertical, state.toastUndoable ? 5 : 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 80)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 0.78), value: state.toast)
        // VoiceOver doesn't see a toast appear; "Removed — ⌘Z to undo" is worth hearing.
        .onChange(of: state.toast) { _, toast in
            if let toast { AccessibilityNotification.Announcement(toast).post() }
        }
        // Nor the grid opening: the app isn't made active, so nothing else tells it.
        .onChange(of: state.showCount) {
            guard let page = pageDescription else { return }
            AccessibilityNotification.Announcement(String(localized: "LaunchGrid, \(page)")).post()
        }
        // Nor a page flip with nothing focused (Tab, a swipe), nor edit mode turning on or off.
        // With an item focused, VoiceOver moves to it, which says enough; during a drag, edge
        // flips would announce every page passed.
        .onChange(of: state.currentPage) {
            guard state.isShown, state.focusIndex == nil, !state.drag.active, let page = pageDescription else { return }
            AccessibilityNotification.Announcement(page).post()
        }
        .onChange(of: state.editing) { _, editing in
            guard state.isShown else { return }
            AccessibilityNotification.Announcement(editing ? String(localized: "Editing layout") : String(localized: "Done editing")).post()
        }
    }

    /// "Page 2 of 3", with its title if it has one.
    private var pageDescription: String? {
        let page = state.currentPage
        guard state.grid.pages.indices.contains(page) else { return nil }
        let count = state.grid.pages.count
        return state.grid.pages[page].title.map { String(localized: "Page \(page + 1) of \(count), \($0)") }
            ?? String(localized: "Page \(page + 1) of \(count)")
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TopBarLayout {
            SearchField()
            HStack {
                // A selection made with ⌘-click or ⇧-click outside edit mode gets the same actions.
                // Search results hide the selection: its actions wait until they're cleared.
                // With part of it on other pages, the count says what they act on.
                let count = state.selection.count
                let counted = state.selectionOutOfView > 0
                if state.selectionActionable && count > 1 && state.canGroup(state.orderedSelection) {
                    Button(counted ? "Group \(count)" : "Group") { state.groupSelection() }
                        .buttonStyle(PillButtonStyle())
                }
                if state.selectionActionable {
                    Button(counted ? "Remove \(count)" : "Remove") { state.remove(state.orderedSelection) }
                        .buttonStyle(PillButtonStyle())
                        .help(counted ? String(localized: "Some of the selected items are on other pages") : "")
                }
                if state.editing {
                    Button("Done") { state.editing = false }
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
                Menu {
                    BackgroundMenu()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .modifier(Legible())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: {
                    state.drag.menuButtonFrame = $0
                }
            }
            .fixedSize()
        }
    }
}

/// The search field centred and the buttons at the trailing edge. In a narrow window the
/// field moves left of the buttons, then narrows, rather than going under them.
struct TopBarLayout: Layout {
    var gap: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(gap, +)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (field, buttons) = (subviews[0], subviews[1])
        let b = buttons.sizeThatFits(.unspecified)
        buttons.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(b))
        let room = bounds.width - b.width - (b.width > 0 ? gap : 0)
        let ideal = field.sizeThatFits(.unspecified).width
        let f = field.sizeThatFits(ProposedViewSize(width: max(0, min(ideal, room)), height: nil))
        // Centred while that clears the buttons, else just left of them, never past the start.
        let x = max(bounds.minX, min(bounds.midX - f.width / 2, bounds.minX + room - f.width))
        field.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(f))
    }
}

struct SearchField: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    @AccessibilityFocusState private var voiceOverFocus: Bool

    var body: some View {
        let high = contrast == .increased
        let marked = SearchComposition.shared.marked
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(high ? 0.85 : 0.6))
            if state.query.isEmpty && marked.isEmpty {
                Text("Search")
                    .foregroundStyle(.white.opacity(high ? 0.75 : 0.45))
            } else {
                let line = state.searchLine
                // The caret floats over the join, so moving it doesn't push the text apart.
                // What an input method is still composing sits at the caret, underlined.
                // Too long to fit, the start gives way first: what was just typed stays in view.
                HStack(spacing: 0) {
                    Text(line.beforeCaret)
                        .truncationMode(.head)
                        .layoutPriority(1)
                    Text(marked).underline()
                        .overlay(alignment: .trailing) { Caret().offset(x: 1.5) }
                        .layoutPriority(2)
                    Text(line.afterCaret)
                }
                .foregroundStyle(.white)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        // Narrower only when a small window leaves no room beside the buttons (`TopBarLayout`).
        .frame(minWidth: 120, idealWidth: 240, maxWidth: 240, minHeight: 28, maxHeight: 28)
        // Dark under the light fill, so the white text reads over a light background too.
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .background(.black.opacity(high ? 0.55 : 0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(high ? 0.5 : 0.12)))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            SearchComposition.shared.fieldFrame = $0
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isSearchField)
        .accessibilityLabel("Search, type to filter apps")
        .accessibilityValue(state.query)
        // Where VoiceOver starts when the grid opens, as typing goes there.
        .accessibilityFocused($voiceOverFocus)
        .onChange(of: state.showCount) { voiceOverFocus = true }
    }
}

/// White text over the background: a shadow, and with Increase Contrast a dark backing, so it
/// reads over a light wallpaper or picture too.
struct Legible: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let high = contrast == .increased
        // A tight shadow outlines each letter; a wider, fainter one darkens around the text.
        content
            .shadow(color: .black.opacity(high ? 0.9 : 0.6), radius: 1, y: 0.5)
            .shadow(color: .black.opacity(high ? 0.6 : 0.35), radius: 3)
            .padding(.horizontal, high ? 4 : 0)
            .background {
                if high { Capsule().fill(.black.opacity(0.6)) }
            }
    }
}

struct Caret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Rectangle().fill(.white).frame(width: 1.5, height: 16).opacity(on ? 1 : 0)
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, prominent: prominent)
    }

    /// A view, so it can read the contrast setting.
    private struct Pill: View {
        @Environment(\.colorSchemeContrast) private var contrast
        let configuration: Configuration
        let prominent: Bool

        var body: some View {
            let high = contrast == .increased
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 5)
                .foregroundStyle(.white)
                .background(prominent ? Color.accentColor : .white.opacity(high ? 0.32 : 0.18), in: Capsule())
                // Dark under the light fill, so the button shows over a light background too.
                .background(prominent ? Color.clear : .black.opacity(high ? 0.5 : 0.25), in: Capsule())
                .overlay { if high { Capsule().strokeBorder(.white.opacity(0.6)) } }
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

struct PageTitle: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let page = state.currentPage
        let title = state.query.isEmpty && state.grid.pages.indices.contains(page) ? state.grid.pages[page].title : nil
        let high = contrast == .increased
        Group {
            if let title {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(high ? 1 : 0.9))
                    .modifier(Legible())
                    // One line: a second would spill over the search field or the icons.
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits([.isHeader, .isButton])
                    .accessibilityHint("Renames the page")
            } else if state.editing && state.query.isEmpty && state.grid.pages.indices.contains(page) {
                Text("Add Page Title")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(high ? 0.75 : 0.5))
                    .modifier(Legible())
                    .accessibilityAddTraits(.isButton)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { state.beginPageTitleEdit(page) }
        .accessibilityAction { state.beginPageTitleEdit(page) }
        .id(page)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: page)
    }
}

// MARK: - Pager

struct Pager: View {
    @Environment(AppState.self) private var state
    /// The page shown before the last change, kept until its slide has finished.
    @State private var settledPage: Int?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let count = state.grid.pages.count + (state.showsVirtualPage ? 1 : 0)
            // Only pages near the current one are rendered, plus, while a jump (⌘5, a page
            // dot) slides, every page it passes over, so it never slides across blank pages.
            // From the page before the latest change only: flips in a row (a drag held at the
            // edge, Tab held down) don't keep every page passed on the way drawn.
            let from = settledPage ?? state.currentPage
            let drawn = (min(from, state.currentPage) - 1)...(max(from, state.currentPage) + 1)
            #if !APP_STORE
            let _ = DebugScript.drawnPages = drawn
            #endif
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { p in
                    Group {
                        if drawn.contains(p) {
                            PageView(page: p, size: geo.size)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: w, height: geo.size.height)
                    // Neighbours peek into the side margins; only the page shown takes clicks
                    // and VoiceOver. (Drags find their targets on the current page by arithmetic.)
                    .allowsHitTesting(p == state.currentPage)
                    .accessibilityHidden(p != state.currentPage)
                }
            }
            .offset(x: -CGFloat(state.currentPage) * w + state.swipeOffset)
            .frame(width: w, alignment: .leading)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: {
                state.drag.pagerFrame = $0
                if state.drag.pagerSize != $0.size { state.drag.pagerSize = $0.size }
            }
        }
        .clippedSideways()
        // Pages run left to right in every language, as the swipes and arrow keys do.
        .environment(\.layoutDirection, .leftToRight)
        .onChange(of: state.currentPage) { old, _ in settledPage = old }
        .task(id: state.currentPage) {
            // Longer than the page spring takes to come to rest.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            settledPage = nil
        }
    }
}

struct PageView: View {
    @Environment(AppState.self) private var state
    let page: Int
    let size: CGSize

    /// Display entries: items, plus a placeholder for the drop gap on the current page.
    private var entries: [(id: UUID, item: GridItem?)] {
        var list: [(id: UUID, item: GridItem?)] = state.remainingItems(page: page).map { ($0.id, $0) }
        if state.drag.active, page == state.currentPage, state.openFolder == nil,
           let gap = state.drag.gap {
            list.insert((Self.gapID, nil), at: min(gap, list.count))
        }
        return list
    }

    static let gapID = UUID()

    @AccessibilityFocusState private var voiceOverFocus: UUID?

    var body: some View {
        let layout = GridLayout(size: size, rows: state.grid.rows, columns: state.grid.columns)
        let icon = layout.iconSize(scale: state.prefs.iconScale, labels: state.prefs.showLabels)
        // Read here once, not in every cell: a cell's body then reruns only when its own
        // focus, selection or merge highlight changes, not on every arrow key.
        let entries = entries
        // By ID: `focusIndex` counts the page's items, but during a drag the cells leave out the
        // dragged ones and hold a gap, so their positions no longer match it.
        let focus = page == state.currentPage && state.openFolder == nil
            ? state.focusIndex.flatMap { state.grid.pages[safe: page]?.items[safe: $0]?.id } : nil
        let selection = state.selection
        let mergeTarget = state.drag.mergeTarget
        let editing = state.editing
        let current = page == state.currentPage
        let hovers = current && !state.drag.active && state.openFolderID == nil && state.textEdit == nil
        // Kept empty: the open folder's tile (the panel grew out of it), and tiles a dropped icon
        // is still gliding into.
        let hidden = (state.landing?.hides ?? []).union(state.openFolderID.map { [$0] } ?? [])
        let columns = state.grid.columns, rows = state.grid.rows
        ZStack(alignment: .topLeading) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if let item = entry.item {
                    let dx = Double(index % columns) - Double(columns - 1) / 2
                    let dy = Double(index / columns) - Double(rows - 1) / 2
                    ItemCell(item: item, iconSize: icon, selected: selection.contains(item.id), focused: focus == item.id,
                             mergeTarget: mergeTarget == item.id, editing: editing, hovers: hovers)
                        .modifier(AppearMotion(distance: hypot(dx, dy), order: index, current: current))
                        .opacity(hidden.contains(item.id) ? 0 : 1)
                        .accessibilityFocused($voiceOverFocus, equals: item.id)
                        .frame(width: layout.cell.width, height: layout.cell.height)
                        .position(layout.center(index))
                        // Removed, a tile shrinks away as the rest close up.
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.gridLabelsFit, layout.labelsFit(iconSize: icon))
        .environment(\.gridJiggles, page == state.currentPage)
        // VoiceOver follows the keyboard focus, also onto a page drawn afresh with focus on it
        // (⌘4, End, a page dot further away, a search result revealed).
        .onChange(of: focus, initial: true) { _, id in
            if let id { voiceOverFocus = id }
        }
        // And the keyboard focus follows VoiceOver, so ⌫, Return or Space act on the item it
        // reads out, not on one the focus ring was left on.
        .onChange(of: voiceOverFocus) { _, id in
            guard let id, page == state.currentPage, state.openFolder == nil, !state.drag.active,
                  let i = entries.firstIndex(where: { $0.id == id }), i != state.focusIndex else { return }
            state.focusIndex = i
        }
    }
}

/// An item on a page, with its interactions.
struct ItemCell: View {
    @Environment(AppState.self) private var state
    let item: GridItem
    let iconSize: CGFloat
    let selected: Bool
    let focused: Bool
    let mergeTarget: Bool
    let editing: Bool
    /// Whether it reacts to the pointer over it: not during a drag or behind a folder.
    var hovers = true
    /// Set while a long press that entered edit mode is held: its release is not a tap.
    @State private var swallowTap = false

    var body: some View {
        ItemView(
            item: item,
            iconSize: iconSize,
            selected: selected,
            focused: focused,
            mergeTarget: mergeTarget,
            editing: editing,
            onDelete: { state.remove([item.id]) }
        )
        .modifier(TileMotion(enabled: hovers, cornerRadius: 14))
        .modifier(OpenMotion(id: item.id))
        .onTapGesture { tapped() }
        .modifier(ItemAccessibilityActions(id: item.id, selected: selected, isFolder: item.folder != nil, open: { state.activate(item) }))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.7).onEnded { _ in
                guard !state.drag.active, !state.editing else { return }
                swallowTap = true
                withAnimation(AppState.dragMotion(.default)) { state.editing = true }
                Task {
                    while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(50)) }
                    // Leave time for the release's tap to arrive and be swallowed.
                    try? await Task.sleep(for: .milliseconds(150))
                    swallowTap = false
                }
            }
        )
        .contextMenu { ItemMenu(item: item) }
    }

    private func tapped() {
        if swallowTap {
            swallowTap = false
            return
        }
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            state.toggleSelection(item.id)
        } else if mods.contains(.shift) {
            state.extendSelection(to: item.id)
        } else if state.editing {
            // Edit mode never launches: a click selects, or opens a folder to arrange it.
            // With a selection out of view only (on other pages), a click opens it too.
            let selectionShown = state.selection.count > state.selectionOutOfView
            if item.folder != nil && !selectionShown { state.activate(item) } else { state.toggleSelection(item.id) }
        } else {
            state.activate(item)
        }
    }
}

struct ItemView: View {
    @Environment(AppState.self) private var state
    @Environment(\.gridLabelsFit) private var labelsFit
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let item: GridItem
    let iconSize: CGFloat
    var selected = false
    var focused = false
    var mergeTarget = false
    var editing = false
    /// The argument a search result for an action carries, shown under its name.
    var argument: String?
    /// The search typed, whose letters show in bold in a result's name.
    var query: String?
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                icon
                    .frame(width: iconSize, height: iconSize)
                    .background {
                        if mergeTarget && item.folder == nil {
                            RoundedRectangle(cornerRadius: iconSize * 0.26)
                                .fill(.white.opacity(0.28))
                                .frame(width: iconSize * 1.25, height: iconSize * 1.25)
                        }
                    }
                    .scaleEffect(mergeTarget && !reduceMotion ? 1.12 : 1)
                    .overlay(alignment: .bottom) {
                        if case .app(let app) = item, state.prefs.showRunningIndicator, state.isRunning(app) {
                            RunningDot(size: iconSize).offset(y: 4.5)
                        }
                    }
                if editing, let onDelete {
                    // Smaller on small icons (a dense grid in a small window), so it doesn't hide them.
                    let badge = min(20, max(10, iconSize * 0.45))
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: badge / 2, weight: .bold))
                            .foregroundStyle(.black.opacity(contrast == .increased ? 1 : 0.75))
                            .frame(width: badge, height: badge)
                            .background(Circle().fill(.white.opacity(0.92)))
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -badge * 0.3, y: -badge * 0.3)
                    // Merged into the item below; its "Remove" action stands in for it.
                    .accessibilityHidden(true)
                }
            }
            .modifier(Jiggle(active: editing, seed: item.id.hashValue))
            if state.prefs.showLabels && labelsFit {
                (query.map { highlightedTitle(item.title, query: $0, contrast: contrast) } ?? Text(item.title))
                    .font(.system(size: max(11, min(13, iconSize * 0.14))))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: iconSize * 1.5)
                    .modifier(Legible())
                if let argument {
                    Text(verbatim: argument)
                        .font(.system(size: max(10, min(12, iconSize * 0.13))))
                        .foregroundStyle(.white.opacity(contrast == .increased ? 0.95 : 0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: iconSize * 1.5)
                        .modifier(Legible())
                        .padding(.top, -4)
                }
            }
        }
        .padding(6)
        .background {
            if selected || focused {
                let high = contrast == .increased
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white.opacity(selected ? 0.22 : high ? 0.24 : 0.14))
                    // Keyboard focus gets the stronger ring, with a dark edge so it shows on a
                    // light wallpaper too; Increase Contrast makes it bolder still.
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(focused ? (high ? 1 : 0.8) : 0.55), lineWidth: focused ? (high ? 3 : 2) : 1.5))
                    .overlay(RoundedRectangle(cornerRadius: 15).inset(by: -1)
                        .strokeBorder(.black.opacity(focused ? (high ? 0.7 : 0.35) : 0), lineWidth: 1))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // VoiceOver reads a folder's size after its name, and says an action is one.
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityLabel: Text {
        if item.folder != nil { return Text("Folder \(item.title)") }
        // "Search GitHub — launchgrid": what Return will run.
        if let argument { return Text(verbatim: "\(item.title) — \(argument)") }
        return Text(verbatim: item.title)
    }

    private var accessibilityValue: Text {
        switch item {
        case .folder(let f): f.sizeText
        case .action(let a):
            switch runStatus(a) {
            case .running: Text("Action, running")
            case .needsReview: Text("Action, needs review before it runs")
            case .failed: Text("Action, last run failed")
            case .unavailable: Text("Action, unavailable: \(state.unavailableReason(a) ?? "")")
            case nil: Text("Action")
            }
        case .app(let a): state.prefs.showRunningIndicator && state.isRunning(a) ? Text("Running") : Text(verbatim: "")
        }
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .app(let a): AppIcon(path: a.path, size: iconSize)
        case .folder(let f): FolderIcon(folder: f, size: iconSize, open: mergeTarget)
        case .action(let a):
            ActionTile(action: a, size: iconSize)
                .opacity(state.unavailableReason(a) == nil ? 1 : 0.45)
                .overlay(alignment: .bottomTrailing) { RunBadge(status: runStatus(a), size: iconSize) }
        }
    }

    private func runStatus(_ action: Action) -> RunBadge.Status? {
        if state.runningActions[action.id] != nil { return .running }
        if action.needsReview { return .needsReview }
        if state.unavailableReason(action) != nil { return .unavailable }
        if let last = state.lastRun[action.id], !last.succeeded, last.ending != .stopped { return .failed }
        return nil
    }
}

struct AppIcon: View {
    @Environment(AppState.self) private var state
    let path: String
    let size: CGFloat
    /// Kept here too, so an icon the cache has since let go of stays on screen.
    @State private var loaded: NSImage?

    var body: some View {
        let image = IconProvider.shared.cached(path) ?? loaded
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22).fill(.white.opacity(0.08))
                    .transition(.opacity)
            }
        }
        // An icon drawn while the grid was up fades in over its placeholder rather than pop in.
        // One already drawn shows at once: the value doesn't change.
        .animation(.easeOut(duration: 0.18), value: image != nil)
        .frame(width: size, height: size)
        .task(id: "\(path)|\(state.iconGeneration)") {
            // Returns at once from the cache.
            let image = await IconProvider.shared.icon(path)
            guard !Task.isCancelled else { return }
            if image !== loaded { loaded = image }
        }
    }
}

struct FolderIcon: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let folder: Folder
    let size: CGFloat
    var open = false

    var body: some View {
        let inner = size * 0.8
        let mini = (inner - size * 0.08 * 2) / 3
        let high = contrast == .increased
        ZStack {
            // With Increase Contrast, a stronger fill and an edge light and dark, so the tile
            // stands out on a light background as on a dark one.
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(.white.opacity(open ? (high ? 0.55 : 0.38) : (high ? 0.42 : 0.24)))
                .overlay {
                    if high {
                        RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(.black.opacity(0.6), lineWidth: 1)
                        RoundedRectangle(cornerRadius: size * 0.24).inset(by: 1).strokeBorder(.white.opacity(0.9), lineWidth: 1)
                    }
                }
                .frame(width: size * 0.92, height: size * 0.92)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(mini), spacing: size * 0.04), count: 3), spacing: size * 0.04) {
                ForEach(folder.items.prefix(9)) { member in
                    switch member {
                    case .app(let app): AppIcon(path: app.path, size: mini)
                    case .action(let action): ActionTile(action: action, size: mini)
                    }
                }
            }
            .frame(width: inner, height: inner)
        }
    }

    typealias GridItem = SwiftUI.GridItem
}

/// Gentle rotation wobble in edit mode: keyframes that repeat while `active`, upright
/// otherwise. Only the rotation is redrawn as they play, not the icon views, and
/// turning them off doesn't rebuild the icon (a repeating animation outlived later changes
/// to the angle, and rebuilding to drop it lost each icon's loaded image). Off with Reduce Motion.
struct Jiggle: ViewModifier {
    let active: Bool
    let seed: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.gridJiggles) private var jiggles

    func body(content: Content) -> some View {
        let on = active && jiggles && !reduceMotion
        // Slightly different periods keep neighbours out of step.
        let period = 0.15 + Double(abs(seed) % 7) * 0.008
        content.keyframeAnimator(initialValue: 0.0, repeating: on) { view, angle in
            // Stopped keyframes keep the angle they reached: upright once edit mode ends.
            view.rotationEffect(.degrees(on ? angle : 0))
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1.6, duration: period / 2)
                CubicKeyframe(-1.6, duration: period)
                CubicKeyframe(0, duration: period / 2)
            }
        }
    }
}

/// The dragged item following the pointer. Its own view, so pointer moves re-render only
/// this layer rather than the whole overlay.
struct DragLayer: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.drag.active, let item = state.drag.primary {
            DragGhost(item: item, count: state.drag.ids.count)
                .position(state.drag.iconCenter)
                .allowsHitTesting(false)
        }
    }
}

struct DragGhost: View {
    @Environment(AppState.self) private var state
    let item: GridItem
    let count: Int

    var body: some View {
        // The size of the icons it's among: a folder's stay at least 24 points in a small window,
        // where a page's can be smaller. Once out of the folder, it's the page's.
        let size = state.openFolder != nil ? state.folderIconSize : state.pageIconSize
        ZStack(alignment: .topTrailing) {
            Group {
                switch item {
                case .app(let a): AppIcon(path: a.path, size: size)
                case .folder(let f): FolderIcon(folder: f, size: size)
                case .action(let a): ActionTile(action: a, size: size)
                }
            }
            .scaleEffect(1.1)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(.red))
                    .offset(x: 8, y: -8)
            }
        }
        .opacity(0.92)
    }
}

// MARK: - Page dots

struct PageDots: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let count = state.query.isEmpty ? state.grid.pages.count + (state.showsVirtualPage ? 1 : 0) : 0
        // Where the pages are, in pages: follows a swipe as it goes, so the lit dot stretches
        // toward the page coming in and settles there.
        let width = max(state.drag.pagerSize.width, 1)
        let at = Double(state.currentPage) - Double(state.swipeOffset / width)
        let dim = contrast == .increased ? 0.6 : 0.35
        HStack(spacing: 10) {
            if count > 1 {
                ForEach(0..<count, id: \.self) { p in
                    let title = state.grid.pages.indices.contains(p) ? state.grid.pages[p].title : nil
                    let near = max(0, 1 - abs(Double(p) - at))
                    Capsule()
                        .fill(.white.opacity(dim + (0.95 - dim) * near))
                        .frame(width: 8 + 14 * near, height: 8)
                        // A dark edge, so the dots show on a light background too.
                        .overlay(Capsule().strokeBorder(.black.opacity(contrast == .increased ? 0.6 : 0.25), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 1.5)
                        .padding(4)
                        .contentShape(Capsule().inset(by: -4))
                        .onTapGesture { state.goToPage(p) }
                        .help(state.grid.pages.indices.contains(p) ? title.map { Text(verbatim: $0) } ?? Text("Page \(p + 1)") : Text("New page"))
                        .accessibilityLabel(state.grid.pages.indices.contains(p)
                                            ? title.map { Text("Page \(p + 1), \($0)") } ?? Text("Page \(p + 1)") : Text("New page"))
                        .accessibilityAddTraits(p == state.currentPage ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { state.goToPage(p) }
                }
            } else if !state.query.isEmpty && state.searchPageCount > 1 {
                Button {
                    state.flipPage(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(state.searchPage == 0)
                .accessibilityLabel(Text("Previous search results"))

                Text("Results \(state.searchPage + 1) of \(state.searchPageCount)")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(contrast == .increased ? 0.9 : 0.6))
                    .modifier(Legible())

                Button {
                    state.flipPage(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(state.searchPage == state.searchPageCount - 1)
                .accessibilityLabel(Text("Next search results"))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search results

struct SearchResultsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var voiceOverFocus: UUID?

    var body: some View {
        GeometryReader { geo in
            let layout = GridLayout(size: geo.size, rows: state.grid.rows, columns: state.grid.columns)
            let icon = layout.iconSize(scale: state.prefs.iconScale, labels: state.prefs.showLabels)
            let results = state.searchResults
            ZStack(alignment: .topLeading) {
                if results.isEmpty {
                    NoResultsView()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .transition(.opacity)
                }
                ForEach(Array(results.enumerated()), id: \.element.id) { i, match in
                    ItemView(item: match.item, iconSize: icon, focused: state.focusIndex == i, argument: match.argument,
                             query: match.argument == nil ? state.query : nil)
                        .modifier(TileMotion(enabled: true, cornerRadius: 14))
                        .modifier(OpenMotion(id: match.item.id))
                        .onTapGesture { state.activateResult(match) }
                        .accessibilityAction { state.activateResult(match) }
                        .accessibilityFocused($voiceOverFocus, equals: match.id)
                        .contextMenu { ItemMenu(item: match.item) }
                        .frame(width: layout.cell.width, height: layout.cell.height)
                        .position(layout.center(i))
                        // New matches grow in where they rank, dropped ones shrink away.
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
            }
            // Each keystroke re-ranks: results slide to their new places rather than jump.
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: results.map(\.id))
            .onChange(of: state.focusIndex) { _, i in
                if let i, results.indices.contains(i) { voiceOverFocus = results[i].id }
            }
            .onChange(of: state.searchPage) { _, _ in
                voiceOverFocus = state.focusIndex.flatMap { results.indices.contains($0) ? results[$0].id : nil }
            }
            .onChange(of: voiceOverFocus) { _, id in
                guard let id, let i = results.firstIndex(where: { $0.id == id }), i != state.focusIndex else { return }
                state.focusIndex = i
            }
            .environment(\.gridLabelsFit, layout.labelsFit(iconSize: icon))
        }
        // VoiceOver hears how many apps match once typing pauses, not on every keystroke.
        .task(id: state.query) {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, !state.query.isEmpty else { return }
            let count = state.allSearchResults.count
            let text = switch count {
            case 0: String(localized: "No results")
            case 1: String(localized: "1 result")
            default: String(localized: "\(count) results")
            }
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

/// Nothing matched: what can still be done with what was typed, the actions that take an
/// argument (Return runs the first), or how to make one.
struct NoResultsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let suggestions = state.noResultSuggestions
        VStack(spacing: 18) {
            Text("No Results")
                .font(.title2.weight(.medium))
                .foregroundStyle(.white.opacity(contrast == .increased ? 0.85 : 0.6))
                .modifier(Legible())
            if suggestions.isEmpty {
                VStack(spacing: 8) {
                    Text("An action with {query} in its link can search the web, or anything else, from here.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(contrast == .increased ? 0.85 : 0.6))
                        .modifier(Legible())
                        .frame(maxWidth: 420)
                    Button("New Action…") { state.newAction() }
                        .buttonStyle(PillButtonStyle())
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, action in
                        Button {
                            state.run(action, argument: state.query.trimmingCharacters(in: .whitespaces))
                        } label: {
                            HStack(spacing: 10) {
                                ActionTile(action: action, size: 26)
                                Text("Search “\(state.query)” with \(action.name)")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                if i == 0 {
                                    Image(systemName: "return")
                                        .foregroundStyle(.white.opacity(0.6))
                                        .accessibilityHidden(true)
                                }
                            }
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .frame(width: 380)
                            .background(.white.opacity(i == 0 ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .modifier(TileMotion(enabled: true, cornerRadius: 10))
                        .accessibilityHint(i == 0 ? Text("Return runs it") : Text(verbatim: ""))
                    }
                }
            }
        }
    }
}

extension View {
    /// Clipped at the sides only, where the pages beside it would show. Above and below, a
    /// tile's ✕ badge, its hover glow and its lift reach past the frame in a tight grid, and
    /// were cut off flat.
    func clippedSideways() -> some View {
        mask { Rectangle().padding(.vertical, -400) }
    }
}

extension EnvironmentValues {
    /// Whether app names fit under the icons of the grid around (`GridLayout.labelsFit`).
    @Entry var gridLabelsFit = true
    /// Off on pages out of view (or only peeking in at the sides): their icons keep still in edit mode.
    @Entry var gridJiggles = true
}

// MARK: - Folder

struct FolderPanel: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    let folder: Folder

    var body: some View {
        GeometryReader { geo in
            let grid = state.grid
            let pager = state.drag.pagerSize
            let cols = FolderLayout.columns(grid)
            let rows = FolderLayout.rows(apps: folder.items.count, grid: grid)
            let pages = FolderLayout.pageCount(apps: folder.items.count, grid: grid)
            // The page's cells, but never more than the overlay has room for once the panel's
            // padding, name and dots are around them (a small window with many rows).
            let room = CGSize(width: geo.size.width - 64, height: geo.size.height - (pages > 1 ? 150 : 125))
            let cellW = min(max(pager.width, 400), room.width) / CGFloat(grid.columns)
            let cellH = min(max(pager.height, 300) / CGFloat(grid.rows), max(room.height, 0) / CGFloat(rows))
            let gridSize = CGSize(width: max(cellW, 0) * CGFloat(cols), height: max(cellH, 0) * CGFloat(rows))
            VStack(spacing: 10) {
                Text(folder.name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: max(gridSize.width, 240))
                    .onTapGesture { state.beginRename(folder.id) }
                    .help("Click to rename")
                    .accessibilityAddTraits(.isButton)
                    // VoiceOver lands here when the folder opens (the panel is modal): with the
                    // count, it says how much is in it. An announcement at low priority went
                    // unspoken, and a value is read before the name.
                    .accessibilityLabel(Text(verbatim: "\(folder.name), ") + folder.sizeText)
                    .accessibilityHint("Renames the folder")
                    .accessibilityAction { state.beginRename(folder.id) }
                ZStack(alignment: .topLeading) {
                    FolderPageContent(folder: folder, size: gridSize)
                        .offset(x: state.folderSwipeOffset)
                }
                .frame(width: gridSize.width, height: gridSize.height)
                .clippedSideways()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                    state.drag.folderGridFrame = $0
                }
                // During a drag, the pages its items leave fewer of.
                let dots = state.shownFolderPageCount
                if pages > 1 {
                    HStack(spacing: 10) {
                        ForEach(0..<dots, id: \.self) { p in
                            // Hit target as large as the page dots'.
                            Circle()
                                .fill(.white.opacity(p == state.folderPage ? 0.95 : contrast == .increased ? 0.6 : 0.35))
                                .frame(width: 7, height: 7)
                                .padding(4)
                                .contentShape(Circle().inset(by: -4))
                                .onTapGesture { state.flipPage(p - state.folderPage) }
                                .accessibilityLabel("Folder page \(p + 1) of \(dots)")
                                .accessibilityAddTraits(p == state.folderPage ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { state.flipPage(p - state.folderPage) }
                        }
                    }
                }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(contrast == .increased ? 0.5 : 0.15)))
            .contentShape(RoundedRectangle(cornerRadius: 28))
            .onTapGesture {}
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                state.drag.folderPanelFrame = $0
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            // Measured in the panel's own space, which fills the overlay as the root does: in the
            // root's, frames come out scaled while the panel's transition runs, and the last one
            // (the panel at rest) wasn't always reported, leaving drags aimed at a stale frame.
            .coordinateSpace(name: Self.space)
        }
    }

    nonisolated static let space = "folderPanel"
}

struct FolderPageContent: View {
    @Environment(AppState.self) private var state
    @AccessibilityFocusState private var voiceOverFocus: UUID?
    let folder: Folder
    let size: CGSize

    var body: some View {
        let layout = GridLayout(size: size, rows: FolderLayout.rows(apps: folder.items.count, grid: state.grid),
                                columns: FolderLayout.columns(state.grid))
        let icon = state.folderIconSize(layout)
        let perPage = FolderLayout.perPage(state.grid)
        var entries: [(id: UUID, member: FolderMember?)] = state.remainingFolderItems().map { ($0.id, $0) }
        if state.drag.active, case .folder(let fid) = state.drag.source, fid == folder.id, let gap = state.drag.gap {
            entries.insert((PageView.gapID, nil), at: min(gap, entries.count))
        }
        let start = state.folderPage * perPage
        let visible = Array(entries.enumerated()).filter { $0.offset >= start && $0.offset < start + perPage }
        // By ID, as on a page: a drag leaves out the dragged members and adds a gap.
        let focus = state.focusIndex.flatMap { folder.items[safe: $0]?.id }
        let selection = state.selection
        let editing = state.editing
        let hovers = !state.drag.active && state.textEdit == nil
        let hidden = state.landing?.hides ?? []
        return ZStack(alignment: .topLeading) {
            ForEach(visible, id: \.element.id) { offset, entry in
                if let member = entry.member {
                    FolderItemCell(member: member, iconSize: icon, selected: selection.contains(member.id), focused: focus == member.id,
                                   editing: editing, hovers: hovers)
                        .opacity(hidden.contains(member.id) ? 0 : 1)
                        .accessibilityFocused($voiceOverFocus, equals: member.id)
                        .frame(width: layout.cell.width, height: layout.cell.height)
                        .position(layout.center(offset - start))
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.gridLabelsFit, layout.labelsFit(iconSize: icon))
        // VoiceOver follows the keyboard focus, also into a folder opened with focus in it.
        .onChange(of: focus, initial: true) { _, id in
            if let id { voiceOverFocus = id }
        }
        .onChange(of: voiceOverFocus) { _, id in
            guard let id, state.openFolderID == folder.id, !state.drag.active,
                  let i = entries.firstIndex(where: { $0.id == id }), i != state.focusIndex else { return }
            state.focusIndex = i
        }
    }
}

/// An app or action in the open folder, with its interactions.
struct FolderItemCell: View {
    @Environment(AppState.self) private var state
    let member: FolderMember
    let iconSize: CGFloat
    let selected: Bool
    let focused: Bool
    let editing: Bool
    var hovers = true
    /// Set while a long press that entered edit mode is held: its release is not a tap.
    @State private var swallowTap = false

    var body: some View {
        let item = member.gridItem
        ItemView(item: item, iconSize: iconSize, selected: selected, focused: focused,
                 editing: editing, onDelete: { state.remove([member.id]) })
            .modifier(TileMotion(enabled: hovers, cornerRadius: 14))
            .modifier(OpenMotion(id: member.id))
            .onTapGesture {
                if swallowTap { swallowTap = false; return }
                let mods = NSEvent.modifierFlags
                if mods.contains(.command) { state.toggleSelection(member.id) }
                else if mods.contains(.shift) { state.extendSelection(to: member.id) }
                // Edit mode never launches: a click selects.
                else if state.editing { state.toggleSelection(member.id) }
                // Launches the app, or runs the action, as on a page.
                else { state.activate(item) }
            }
            .modifier(ItemAccessibilityActions(id: member.id, selected: selected, open: { state.activate(item) }))
            .simultaneousGesture(
                // As on a page: a long press enters edit mode.
                LongPressGesture(minimumDuration: 0.7).onEnded { _ in
                    guard !state.drag.active, !state.editing else { return }
                    swallowTap = true
                    withAnimation(AppState.dragMotion(.default)) { state.editing = true }
                    Task {
                        while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(50)) }
                        try? await Task.sleep(for: .milliseconds(150))
                        swallowTap = false
                    }
                }
            )
            .contextMenu { ItemMenu(item: item) }
    }
}

extension Folder {
    /// How much it holds, as VoiceOver reads it: "3 apps", or "3 items" once it holds actions.
    var sizeText: Text {
        actions.isEmpty ? Text("\(items.count) apps") : Text("\(items.count) items")
    }
}

/// VoiceOver actions for a grid or folder item. The default action does what a click does:
/// in edit mode it selects (a folder opens when nothing is selected), otherwise it opens.
/// The ✕ button, merged into the item, can't be reached, so removing (and renaming and
/// selecting) are named actions.
/// Reads the state only in its actions, which run later: what the body shows comes in as
/// properties, so a selection change redraws only the cells it changes.
struct ItemAccessibilityActions: ViewModifier {
    @Environment(AppState.self) private var state
    let id: UUID
    let selected: Bool
    var isFolder = false
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityAction {
                if !state.editing || (isFolder && state.selection.isEmpty) { open() } else { state.toggleSelection(id) }
            }
            .accessibilityAction(named: selected ? Text("Deselect") : Text("Select")) { state.toggleSelection(id) }
            .accessibilityAction(named: "Rename") { state.beginRename(id) }
            .accessibilityAction(named: "Remove") { state.remove([id]) }
    }
}

// MARK: - Inline text editing

struct TextEditCard: View {
    @Environment(AppState.self) private var state
    let request: TextEditRequest
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
                .onTapGesture { state.textEdit = nil }
            VStack(alignment: .leading, spacing: 12) {
                Text(request.title).font(.headline)
                TextField(request.isPageTitle ? "Page Title" : "Name", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { state.commitTextEdit(text) }
                HStack {
                    Spacer()
                    Button("Cancel") { state.textEdit = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { state.commitTextEdit(text) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 280)
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
        }
        .onAppear {
            text = request.text
            focused = true
        }
    }
}

// MARK: - Menus

/// One line of a grid menu. The menus are described once, so a right-click (SwiftUI) and
/// ⌃Return (AppKit, which macOS 14 can't host SwiftUI menus in) show the same thing.
struct MenuEntry {
    enum Kind {
        case action(@MainActor () -> Void)
        case submenu([MenuEntry])
        case divider
    }

    var title = ""
    var kind: Kind
    var enabled = true
    var destructive = false

    /// How many item menus were built, for the debug scripts.
    nonisolated(unsafe) static var builds = 0

    static var divider: MenuEntry { MenuEntry(kind: .divider) }

    static func button(_ title: String, enabled: Bool = true, destructive: Bool = false,
                       _ action: @escaping @MainActor () -> Void) -> MenuEntry {
        MenuEntry(title: title, kind: .action(action), enabled: enabled, destructive: destructive)
    }

    static func submenu(_ title: String, _ entries: [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title, kind: .submenu(entries))
    }

    /// The right-click item menu for `item`.
    @MainActor
    static func item(_ item: GridItem, state: AppState) -> [MenuEntry] {
        builds += 1
        let targets = state.targets(for: item.id)
        let multi = targets.count > 1
        var entries: [MenuEntry] = []
        if case .app(let a) = item {
            entries.append(.button(String(localized: "Open")) {
                guard let current = state.grid.item(a.id)?.app else { return }
                state.launch(current)
            })
            entries.append(.button(String(localized: "Show in Finder")) {
                guard let current = state.grid.item(a.id)?.app else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: current.path)])
                // Finder comes forward like a launched app: an app opened behind mustn't cover it.
                state.onHideForLaunch()
            })
        } else if case .action(let a) = item {
            entries.append(.button(String(localized: "Open")) {
                guard let current = state.grid.item(a.id)?.action else { return }
                state.run(current, argument: nil)
            })
            if case .openFile = a.kind {
                entries.append(.button(String(localized: "Show in Finder")) {
                    guard case .openFile(let path, _) = state.grid.item(a.id)?.action?.kind else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([FileAccess.url(for: path)])
                    state.onHideForLaunch()
                })
            }
            if let running = state.runningActions[a.id], running.canStop {
                entries.append(.button(String(localized: "Stop")) { state.stopRuns(of: a.id) })
            }
            if state.lastRun[a.id] != nil {
                entries.append(.button(String(localized: "Show Last Output…")) {
                    guard let current = state.grid.item(a.id)?.action else { return }
                    state.onShowLastOutput(current)
                })
            }
            if !multi {
                entries.append(.button(String(localized: "Edit Action…")) { state.editAction(a.id) })
            }
        } else if case .folder(let f) = item {
            entries.append(.button(String(localized: "Open Folder")) { state.openFolder(f.id) })
            entries.append(.button(String(localized: "Ungroup")) { state.apply { $0.ungroup(f.id) } })
        }
        if !multi {
            entries.append(.button(String(localized: "Rename…")) { state.beginRename(item.id) })
        }
        entries.append(.divider)
        // A search-only action is on no page, so there's nothing to move.
        if targets.contains(where: { state.grid.locate($0) != nil }) {
            let pages = state.grid.pages.enumerated().map { p, page in
                MenuEntry.button(page.title.map { String(localized: "\(p + 1) — \($0)", comment: "Move to Page: a page's number and title") } ?? String(localized: "Page \(p + 1)")) {
                    state.moveToPage(targets, pageID: page.id)
                }
            }
            let newPage = MenuEntry.button(String(localized: "New Page")) { state.moveToPage(targets, pageID: nil) }
            entries.append(.submenu(multi ? String(localized: "Move \(targets.count) Items to Page") : String(localized: "Move to Page"),
                                    pages + [.divider, newPage]))
        }
        // Actions don't go in folders yet.
        if multi && state.canGroup(targets) {
            entries.append(.button(String(localized: "Group \(targets.count) Items")) { state.groupSelection(anchor: item.id) })
        }
        // Not from search results: the selection would stay behind, out of sight, once the
        // search is cleared (as ⌘A leaves search results alone).
        if state.query.isEmpty {
            let selected = state.selection.contains(item.id)
            entries.append(.button(selected ? String(localized: "Deselect") : String(localized: "Select")) { state.toggleSelection(item.id) })
        }
        entries.append(.divider)
        entries.append(.button(multi ? String(localized: "Remove \(targets.count) Items") : String(localized: "Remove from Grid"),
                               destructive: true) { state.remove(targets) })
        return entries
    }

    /// The page menu: the ⋯ button's, and a right-click on the background.
    @MainActor
    static func page(state: AppState) -> [MenuEntry] {
        let pageID = state.grid.pages[safe: state.currentPage]?.id
        var entries: [MenuEntry] = [
            .button(state.editing ? String(localized: "Done Editing") : String(localized: "Edit Layout")) { state.editing.toggle() },
            .divider,
            .button(String(localized: "Undo"), enabled: state.canUndo) { state.undo() },
            .button(String(localized: "Redo"), enabled: state.canRedo) { state.redo() },
            .divider,
            .button(String(localized: "New Page")) { state.newPage() },
            .button(String(localized: "Edit Page Title…")) { if let pageID { state.beginPageTitleEdit(pageID) } },
            .button(String(localized: "New Action…")) { state.newAction(onPage: pageID) },
        ]
        if state.currentItems.isEmpty && state.grid.pages.count > 1 {
            entries.append(.button(String(localized: "Delete Empty Page")) { if let pageID { state.deleteEmptyPage(pageID) } })
        }
        entries += [
            .button(String(localized: "Sort This Page")) { if let pageID { state.sortPage(pageID) } },
            .button(String(localized: "Sort Everything")) { state.sortEverything() },
            .divider,
            .button(String(localized: "Add Missing Apps…")) { state.onAddMissing() },
            .button(String(localized: "Settings…")) { state.onOpenSettings() },
        ]
        return entries
    }

    /// The same entries as an AppKit menu.
    @MainActor
    static func nsMenu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry.kind {
            case .divider:
                menu.addItem(.separator())
            case .submenu(let sub):
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.submenu = nsMenu(sub)
                menu.addItem(item)
            case .action(let action):
                let item = ActionMenuItem(title: entry.title, action: action)
                item.isEnabled = entry.enabled
                if entry.destructive {
                    // In red, as the right-click menu shows a destructive button.
                    item.attributedTitle = NSAttributedString(string: entry.title, attributes: [
                        .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.systemRed,
                    ])
                }
                menu.addItem(item)
            }
        }
        return menu
    }
}

/// An AppKit menu item that runs a closure.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, action run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func runAction() { run() }
}

/// Menu entries as SwiftUI menu content.
struct MenuEntries: View {
    let entries: [MenuEntry]

    var body: some View {
        // By position, so a menu built again unchanged keeps its identity.
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry.kind {
            case .divider:
                Divider()
            case .submenu(let sub):
                Menu(entry.title) { MenuEntries(entries: sub) }
            case .action(let action):
                Button(entry.title, role: entry.destructive ? .destructive : nil) { action() }
                    .disabled(!entry.enabled)
            }
        }
    }
}

struct ItemMenu: View {
    @Environment(AppState.self) private var state
    let item: GridItem

    var body: some View { MenuEntries(entries: MenuEntry.item(item, state: state)) }
}

struct BackgroundMenu: View {
    @Environment(AppState.self) private var state

    var body: some View { MenuEntries(entries: MenuEntry.page(state: state)) }
}

/// A command or script's state on its tile: a spinner while it runs, a warning after a
/// failed run, a slash when it can't run here. Said in the tile's accessibility value instead.
struct RunBadge: View {
    enum Status { case running, needsReview, failed, unavailable }

    @Environment(\.colorSchemeContrast) private var contrast
    let status: Status?
    let size: CGFloat

    var body: some View {
        if let status {
            let side = min(22, max(12, size * 0.32))
            ZStack {
                Circle().fill(.black.opacity(contrast == .increased ? 0.9 : 0.6))
                switch status {
                case .running:
                    ProgressView().controlSize(.small).scaleEffect(side / 22).tint(.white)
                case .needsReview:
                    Image(systemName: "eye").font(.system(size: side * 0.5, weight: .bold)).foregroundStyle(.yellow)
                case .failed:
                    Image(systemName: "exclamationmark").font(.system(size: side * 0.55, weight: .heavy)).foregroundStyle(.orange)
                case .unavailable:
                    Image(systemName: "nosign").font(.system(size: side * 0.55, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: side, height: side)
            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
            .offset(x: -size * 0.04, y: -size * 0.04)
            .accessibilityHidden(true)
        }
    }
}

/// An action's icon, the size of an app's: its SF Symbol or emoji on a rounded square, or
/// the picture chosen for it, loaded off the main thread and cached as app icons are.
struct ActionTile: View {
    let action: Action
    let size: CGFloat

    var body: some View {
        Group {
            if case .image(let path) = action.icon {
                ActionPicture(path: path, size: size, fallback: action.kind.defaultIcon)
            } else {
                ActionGlyph(icon: action.icon, size: size, hue: ActionTile.hue(for: action.id))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// A steady hue per action, so tiles side by side tell apart (not `hashValue`, which
    /// changes from launch to launch).
    static func hue(for id: UUID) -> Double {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        return Double(bytes.reduce(0) { ($0 &* 31 &+ Int($1)) % 360 }) / 360
    }
}

/// A symbol or an emoji on a rounded square shaped like an app icon's.
struct ActionGlyph: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let icon: ActionIcon
    let size: CGFloat
    let hue: Double

    var body: some View {
        // Inset like the artwork of a macOS app icon, which leaves a margin inside its frame.
        let side = size * 0.82
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.82),
                                              Color(hue: hue, saturation: 0.7, brightness: 0.55)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(contrast == .increased ? 0.6 : 0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: size * 0.03, y: size * 0.015)
            switch icon {
            case .symbol(let name):
                Image(systemName: NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "questionmark" : name)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .frame(width: side * 0.52, height: side * 0.52)
            case .emoji(let value):
                Text(verbatim: value)
                    .font(.system(size: side * 0.58))
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
            case .image:
                EmptyView()
            }
        }
        .frame(width: side, height: side)
    }
}

/// The picture chosen as an action's icon. Until it loads, or when it can't be read, the
/// action's default symbol stands in.
struct ActionPicture: View {
    let path: String
    let size: CGFloat
    let fallback: ActionIcon
    @State private var loaded: NSImage?

    var body: some View {
        Group {
            if let image = ActionPictureCache.shared.cached(path) ?? loaded {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                ActionGlyph(icon: fallback, size: size, hue: 0.6)
            }
        }
        .task(id: path) {
            let image = await ActionPictureCache.shared.image(path)
            guard !Task.isCancelled else { return }
            if image !== loaded { loaded = image }
        }
    }
}

/// Pictures chosen as action icons, read off the main thread, scaled down once and kept.
@MainActor
final class ActionPictureCache {
    static let shared = ActionPictureCache()
    private let cache = NSCache<NSString, NSImage>()

    func cached(_ path: String) -> NSImage? { cache.object(forKey: path as NSString) }

    func image(_ path: String) async -> NSImage? {
        if let image = cached(path) { return image }
        // Through its bookmark in the sandbox, whose access is in use.
        let url = FileAccess.url(for: path)
        let pixels = IconProvider.pixelSize
        let image = await Disk.run { () -> SendableImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: pixels,
                  ] as CFDictionary) else { return nil }
            return SendableImage(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        }?.image
        if let image { cache.setObject(image, forKey: path as NSString) }
        return image
    }
}
