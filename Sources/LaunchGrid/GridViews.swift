import AppKit
import SwiftUI
import LaunchGridCore

/// Root of the overlay: background, search, pager, page dots, folder and drag layers.
struct GridRootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                }
            }
            // Opening and closing animate from here, not through `withAnimation`: called right
            // after another change (grouping makes the folder, then opens it), `withAnimation`
            // brought the view up to date first and the opening then sometimes never showed,
            // leaving a folder open that nobody could see.
            .animation(state.isShown ? AppState.pageAnimation : nil, value: state.openFolderID)

            DragLayer()

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

            ToastLayer()
                .allowsHitTesting(false)
        }
        .coordinateSpace(name: "root")
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("root"))
                .onChanged { state.dragChanged(start: $0.startLocation, location: $0.location) }
                .onEnded { state.dragEnded(start: $0.startLocation, location: $0.location, predicted: $0.predictedEndLocation) }
        )
        // With Reduce Motion the overlay only fades in.
        .scaleEffect(state.isShown || reduceMotion ? 1 : 1.04)
        .opacity(state.isShown ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: state.isShown)
        .environment(\.colorScheme, .dark)
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

    var body: some View {
        VStack {
            Spacer()
            if let toast = state.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 80)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: state.toast)
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
                if state.selectionActionable && state.selection.count > 1 {
                    Button("Group") { state.groupSelection() }
                        .buttonStyle(PillButtonStyle())
                }
                if state.selectionActionable {
                    Button("Remove") { state.remove(state.orderedSelection) }
                        .buttonStyle(PillButtonStyle())
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: {
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
            let from = settledPage ?? state.currentPage
            let drawn = (min(from, state.currentPage) - 1)...(max(from, state.currentPage) + 1)
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
        .clipped()
        // Pages run left to right in every language, as the swipes and arrow keys do.
        .environment(\.layoutDirection, .leftToRight)
        .task(id: state.currentPage) {
            if settledPage == nil { settledPage = state.currentPage; return }
            // Longer than the page spring takes to come to rest.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            settledPage = state.currentPage
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
        let focus = page == state.currentPage && state.openFolder == nil ? state.focusIndex : nil
        let selection = state.selection
        let mergeTarget = state.drag.mergeTarget
        let editing = state.editing
        ZStack(alignment: .topLeading) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if let item = entry.item {
                    ItemCell(item: item, iconSize: icon, selected: selection.contains(item.id), focused: focus == index,
                             mergeTarget: mergeTarget == item.id, editing: editing)
                        .accessibilityFocused($voiceOverFocus, equals: item.id)
                        .frame(width: layout.cell.width, height: layout.cell.height)
                        .position(layout.center(index))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.gridLabelsFit, layout.labelsFit(iconSize: icon))
        // VoiceOver follows the keyboard focus, also onto a page drawn afresh with focus on it
        // (⌘4, End, a page dot further away, a search result revealed).
        .onChange(of: focus, initial: true) { _, i in
            if let i, entries.indices.contains(i) { voiceOverFocus = entries[i].id }
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
            if item.folder != nil && state.selection.isEmpty { state.activate(item) } else { state.toggleSelection(item.id) }
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
                if editing, let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black.opacity(contrast == .increased ? 1 : 0.75))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(.white.opacity(0.92)))
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: -6)
                    // Merged into the item below; its "Remove" action stands in for it.
                    .accessibilityHidden(true)
                }
            }
            .modifier(Jiggle(active: editing, seed: item.id.hashValue))
            if state.prefs.showLabels && labelsFit {
                Text(item.title)
                    .font(.system(size: max(11, min(13, iconSize * 0.14))))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: iconSize * 1.5)
                    .modifier(Legible())
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
        .accessibilityLabel(item.folder != nil ? Text("Folder \(item.title)") : Text(verbatim: item.title))
        // VoiceOver reads a folder's size after its name.
        .accessibilityValue(item.folder.map { Text("\($0.apps.count) apps") } ?? Text(verbatim: ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .app(let a): AppIcon(path: a.path, size: iconSize)
        case .folder(let f): FolderIcon(folder: f, size: iconSize, open: mergeTarget)
        }
    }
}

struct AppIcon: View {
    @Environment(AppState.self) private var state
    let path: String
    let size: CGFloat
    /// Kept here too, so an icon the cache has since let go of stays on screen.
    @State private var loaded: NSImage?

    var body: some View {
        Group {
            if let image = IconProvider.shared.cached(path) ?? loaded {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22).fill(.white.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(path)|\(state.iconGeneration)") {
            // Returns at once from the cache.
            let image = await IconProvider.shared.icon(path)
            if image !== loaded { loaded = image }
        }
    }
}

struct FolderIcon: View {
    let folder: Folder
    let size: CGFloat
    var open = false

    var body: some View {
        let inner = size * 0.8
        let mini = (inner - size * 0.08 * 2) / 3
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(.white.opacity(open ? 0.38 : 0.24))
                .frame(width: size * 0.92, height: size * 0.92)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(mini), spacing: size * 0.04), count: 3), spacing: size * 0.04) {
                ForEach(folder.apps.prefix(9)) { app in
                    AppIcon(path: app.path, size: mini)
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

    func body(content: Content) -> some View {
        let on = active && !reduceMotion
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
        let size = state.pageLayout.iconSize(scale: state.prefs.iconScale, labels: state.prefs.showLabels)
        ZStack(alignment: .topTrailing) {
            Group {
                switch item {
                case .app(let a): AppIcon(path: a.path, size: size)
                case .folder(let f): FolderIcon(folder: f, size: size)
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
        HStack(spacing: 10) {
            if count > 1 {
                ForEach(0..<count, id: \.self) { p in
                    let title = state.grid.pages.indices.contains(p) ? state.grid.pages[p].title : nil
                    Circle()
                        .fill(.white.opacity(p == state.currentPage ? 0.95 : contrast == .increased ? 0.6 : 0.35))
                        .frame(width: 8, height: 8)
                        // A dark edge, so the dots show on a light background too.
                        .overlay(Circle().strokeBorder(.black.opacity(contrast == .increased ? 0.6 : 0.25), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 1.5)
                        .padding(4)
                        .contentShape(Circle().inset(by: -4))
                        .onTapGesture { state.goToPage(p) }
                        .help(state.grid.pages.indices.contains(p) ? title.map { Text(verbatim: $0) } ?? Text("Page \(p + 1)") : Text("New page"))
                        .accessibilityLabel(state.grid.pages.indices.contains(p)
                                            ? title.map { Text("Page \(p + 1), \($0)") } ?? Text("Page \(p + 1)") : Text("New page"))
                        .accessibilityAddTraits(p == state.currentPage ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { state.goToPage(p) }
                }
            } else if !state.query.isEmpty {
                // Search shows one page of matches; say how many didn't fit.
                let hidden = state.allSearchResults.count - state.searchResults.count
                if hidden > 0 {
                    // Separate keys, so a translation can give the count its plural forms.
                    Group {
                        if hidden == 1 { Text("1 more match — keep typing to narrow the search") }
                        else { Text("\(hidden) more matches — keep typing to narrow the search") }
                    }
                        .font(.callout)
                        .foregroundStyle(.white.opacity(contrast == .increased ? 0.9 : 0.6))
                        .modifier(Legible())
                }
            }
        }
    }
}

// MARK: - Search results

struct SearchResultsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    @AccessibilityFocusState private var voiceOverFocus: UUID?

    var body: some View {
        GeometryReader { geo in
            let layout = GridLayout(size: geo.size, rows: state.grid.rows, columns: state.grid.columns)
            let icon = layout.iconSize(scale: state.prefs.iconScale, labels: state.prefs.showLabels)
            let results = state.searchResults
            ZStack(alignment: .topLeading) {
                if results.isEmpty {
                    Text("No Results")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.white.opacity(contrast == .increased ? 0.85 : 0.6))
                        .modifier(Legible())
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                ForEach(Array(results.enumerated()), id: \.element.id) { i, app in
                    ItemView(item: .app(app), iconSize: icon, focused: state.focusIndex == i)
                        .onTapGesture { state.activateResult(app) }
                        .accessibilityAction { state.activateResult(app) }
                        .accessibilityFocused($voiceOverFocus, equals: app.id)
                        .contextMenu { ItemMenu(item: .app(app)) }
                        .frame(width: layout.cell.width, height: layout.cell.height)
                        .position(layout.center(i))
                }
            }
            .onChange(of: state.focusIndex) { _, i in
                if let i, results.indices.contains(i) { voiceOverFocus = results[i].id }
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

extension EnvironmentValues {
    /// Whether app names fit under the icons of the grid around (`GridLayout.labelsFit`).
    @Entry var gridLabelsFit = true
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
            let rows = FolderLayout.rows(apps: folder.apps.count, grid: grid)
            let cellW = max(pager.width, 400) / CGFloat(grid.columns)
            let cellH = max(pager.height, 300) / CGFloat(grid.rows)
            let gridSize = CGSize(width: cellW * CGFloat(cols), height: cellH * CGFloat(rows))
            let pages = FolderLayout.pageCount(apps: folder.apps.count, grid: grid)
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
                    .accessibilityLabel(Text(verbatim: "\(folder.name), ") + Text("\(folder.apps.count) apps"))
                    .accessibilityHint("Renames the folder")
                    .accessibilityAction { state.beginRename(folder.id) }
                ZStack(alignment: .topLeading) {
                    FolderPageContent(folder: folder, size: gridSize)
                        .offset(x: state.folderSwipeOffset)
                }
                .frame(width: gridSize.width, height: gridSize.height)
                .clipped()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                    state.drag.folderGridFrame = $0
                }
                if pages > 1 {
                    HStack(spacing: 10) {
                        ForEach(0..<pages, id: \.self) { p in
                            // Hit target as large as the page dots'.
                            Circle()
                                .fill(.white.opacity(p == state.folderPage ? 0.95 : contrast == .increased ? 0.6 : 0.35))
                                .frame(width: 7, height: 7)
                                .padding(4)
                                .contentShape(Circle().inset(by: -4))
                                .onTapGesture { state.flipPage(p - state.folderPage) }
                                .accessibilityLabel("Folder page \(p + 1) of \(pages)")
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
        let layout = GridLayout(size: size, rows: FolderLayout.rows(apps: folder.apps.count, grid: state.grid),
                                columns: FolderLayout.columns(state.grid))
        let icon = GridLayout(size: state.drag.pagerSize, rows: state.grid.rows, columns: state.grid.columns)
            .iconSize(scale: state.prefs.iconScale, labels: state.prefs.showLabels)
        let perPage = FolderLayout.perPage(state.grid)
        var entries: [(id: UUID, app: AppRef?)] = state.remainingFolderApps().map { ($0.id, $0) }
        if state.drag.active, case .folder(let fid) = state.drag.source, fid == folder.id, let gap = state.drag.gap {
            entries.insert((PageView.gapID, nil), at: min(gap, entries.count))
        }
        let start = state.folderPage * perPage
        let visible = Array(entries.enumerated()).filter { $0.offset >= start && $0.offset < start + perPage }
        let focus = state.focusIndex
        let selection = state.selection
        let editing = state.editing
        return ZStack(alignment: .topLeading) {
            ForEach(visible, id: \.element.id) { offset, entry in
                if let app = entry.app {
                    FolderItemCell(app: app, iconSize: icon, selected: selection.contains(app.id), focused: focus == offset, editing: editing)
                        .accessibilityFocused($voiceOverFocus, equals: app.id)
                        .frame(width: layout.cell.width, height: layout.cell.height)
                        .position(layout.center(offset - start))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.gridLabelsFit, layout.labelsFit(iconSize: icon))
        // VoiceOver follows the keyboard focus, also into a folder opened with focus in it.
        .onChange(of: focus, initial: true) { _, i in
            if let i, entries.indices.contains(i), let app = entries[i].app { voiceOverFocus = app.id }
        }
    }
}

struct FolderItemCell: View {
    @Environment(AppState.self) private var state
    let app: AppRef
    let iconSize: CGFloat
    let selected: Bool
    let focused: Bool
    let editing: Bool
    /// Set while a long press that entered edit mode is held: its release is not a tap.
    @State private var swallowTap = false

    var body: some View {
        ItemView(item: .app(app), iconSize: iconSize, selected: selected, focused: focused,
                 editing: editing, onDelete: { state.remove([app.id]) })
            .onTapGesture {
                if swallowTap { swallowTap = false; return }
                let mods = NSEvent.modifierFlags
                if mods.contains(.command) { state.toggleSelection(app.id) }
                else if mods.contains(.shift) { state.extendSelection(to: app.id) }
                // Edit mode never launches: a click selects.
                else if state.editing { state.toggleSelection(app.id) }
                else { state.launch(app) }
            }
            .modifier(ItemAccessibilityActions(id: app.id, selected: selected, open: { state.launch(app) }))
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
            .contextMenu { ItemMenu(item: .app(app)) }
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
            entries.append(.button(String(localized: "Open")) { state.launch(a) })
            entries.append(.button(String(localized: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)])
                // Finder comes forward like a launched app: an app opened behind mustn't cover it.
                state.onHideForLaunch()
            })
        } else if case .folder(let f) = item {
            entries.append(.button(String(localized: "Open Folder")) { state.openFolder(f.id) })
            entries.append(.button(String(localized: "Ungroup")) { state.apply { $0.ungroup(f.id) } })
        }
        if !multi {
            entries.append(.button(String(localized: "Rename…")) { state.beginRename(item.id) })
        }
        entries.append(.divider)
        let pages = state.grid.pages.enumerated().map { p, page in
            MenuEntry.button(page.title.map { String(localized: "\(p + 1) — \($0)", comment: "Move to Page: a page's number and title") } ?? String(localized: "Page \(p + 1)")) {
                state.moveToPage(targets, pageID: page.id)
            }
        }
        let newPage = MenuEntry.button(String(localized: "New Page")) { state.moveToPage(targets, pageID: nil) }
        entries.append(.submenu(multi ? String(localized: "Move \(targets.count) Items to Page") : String(localized: "Move to Page"),
                                pages + [.divider, newPage]))
        if multi {
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
        var entries: [MenuEntry] = [
            .button(state.editing ? String(localized: "Done Editing") : String(localized: "Edit Layout")) { state.editing.toggle() },
            .divider,
            .button(String(localized: "Undo"), enabled: state.canUndo) { state.undo() },
            .button(String(localized: "Redo"), enabled: state.canRedo) { state.redo() },
            .divider,
            .button(String(localized: "New Page")) { state.newPage() },
            .button(String(localized: "Edit Page Title…")) { state.beginPageTitleEdit(state.currentPage) },
        ]
        if state.currentItems.isEmpty && state.grid.pages.count > 1 {
            entries.append(.button(String(localized: "Delete Empty Page")) { state.deleteCurrentPage() })
        }
        entries += [
            .button(String(localized: "Sort This Page")) { state.sortCurrentPage() },
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
