import AppKit
import SwiftUI
import LaunchGridCore

/// Root of the overlay: background, search, pager, page dots, folder and drag layers.
struct GridRootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            BackgroundView()
                .contentShape(Rectangle())
                .onTapGesture { backgroundClicked() }
                .contextMenu { BackgroundMenu() }

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

            if let folder = state.openFolder {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { state.closeFolder() }
                    .transition(.opacity)
                FolderPanel(folder: folder)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
            }

            DragLayer()

            if let edit = state.textEdit {
                TextEditCard(request: edit)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }

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

    private func backgroundClicked() {
        if state.textEdit != nil { return }
        if state.editing {
            state.editing = false
        } else if !state.selection.isEmpty {
            state.selection.removeAll()
        } else if !state.query.isEmpty {
            state.query = ""
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
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            SearchField()
            HStack {
                Spacer()
                // A selection made with ⌘-click or ⇧-click outside edit mode gets the same actions.
                if state.selection.count > 1 {
                    Button("Group") { state.groupSelection() }
                        .buttonStyle(PillButtonStyle())
                }
                if !state.selection.isEmpty {
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
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

struct SearchField: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.6))
            if state.query.isEmpty {
                Text("Search")
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Text(state.query)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Caret()
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(width: 240, height: 28)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
        .accessibilityLabel("Search, type to filter apps")
        .accessibilityValue(state.query)
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
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(prominent ? Color.accentColor : .white.opacity(0.18), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct PageTitle: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let page = state.currentPage
        let title = state.query.isEmpty && state.grid.pages.indices.contains(page) ? state.grid.pages[page].title : nil
        Group {
            if let title {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            } else if state.editing && state.query.isEmpty && state.grid.pages.indices.contains(page) {
                Text("Add Page Title")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { state.beginPageTitleEdit(page) }
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
                }
            }
            .offset(x: -CGFloat(state.currentPage) * w + state.swipeOffset)
            .frame(width: w, alignment: .leading)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: {
                state.drag.pagerFrame = $0
            }
        }
        .clipped()
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

    var body: some View {
        let layout = GridLayout(size: size, rows: state.grid.rows, columns: state.grid.columns)
        let icon = layout.iconSize(scale: state.prefs.iconScale)
        ZStack(alignment: .topLeading) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if let item = entry.item {
                    ItemCell(item: item, iconSize: icon, index: index, page: page)
                        .frame(width: layout.cell.width, height: layout.cell.height)
                        .position(layout.center(index))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// An item on a page, with its interactions.
struct ItemCell: View {
    @Environment(AppState.self) private var state
    let item: GridItem
    let iconSize: CGFloat
    let index: Int
    let page: Int
    /// Set while a long press that entered edit mode is held: its release is not a tap.
    @State private var swallowTap = false

    var body: some View {
        ItemView(
            item: item,
            iconSize: iconSize,
            selected: state.selection.contains(item.id),
            focused: page == state.currentPage && state.focusIndex == index && state.openFolder == nil,
            mergeTarget: state.drag.mergeTarget == item.id,
            editing: state.editing,
            onDelete: { state.remove([item.id]) }
        )
        .onTapGesture { tapped() }
        .modifier(ItemAccessibilityActions(id: item.id, isFolder: item.folder != nil, open: { state.activate(item) }))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.7).onEnded { _ in
                guard !state.drag.active, !state.editing else { return }
                swallowTap = true
                withAnimation { state.editing = true }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                            .foregroundStyle(.black.opacity(0.75))
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
            if state.prefs.showLabels {
                Text(item.title)
                    .font(.system(size: max(11, min(13, iconSize * 0.14))))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: iconSize * 1.5)
            }
        }
        .padding(6)
        .background {
            if selected || focused {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white.opacity(selected ? 0.22 : 0.14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(selected ? 0.55 : 0.3), lineWidth: 1.5))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.folder != nil ? "Folder \(item.title)" : item.title)
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
            if IconProvider.shared.cached(path) == nil || loaded != nil { loaded = await IconProvider.shared.icon(path) }
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

/// Gentle rotation wobble in edit mode. A repeating animation rather than a per-frame
/// timeline, so a full page of icons doesn't re-render its views every frame.
/// Off with Reduce Motion.
struct Jiggle: ViewModifier {
    let active: Bool
    let seed: Int
    @State private var tilted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let on = active && !reduceMotion
        // Slightly different periods keep neighbours out of step.
        let period = 0.15 + Double(abs(seed) % 7) * 0.008
        content
            .rotationEffect(.degrees(on ? (tilted ? 1.6 : -1.6) : 0))
            .animation(on ? .easeInOut(duration: period).repeatForever(autoreverses: true) : .easeOut(duration: 0.1),
                       value: tilted)
            .onChange(of: on, initial: true) { _, on in tilted = on }
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
        let size = state.pageLayout.iconSize(scale: state.prefs.iconScale)
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

    var body: some View {
        let count = state.query.isEmpty ? state.grid.pages.count + (state.showsVirtualPage ? 1 : 0) : 0
        HStack(spacing: 10) {
            if count > 1 {
                ForEach(0..<count, id: \.self) { p in
                    let title = state.grid.pages.indices.contains(p) ? state.grid.pages[p].title : nil
                    Circle()
                        .fill(.white.opacity(p == state.currentPage ? 0.95 : 0.35))
                        .frame(width: 8, height: 8)
                        .padding(4)
                        .contentShape(Circle().inset(by: -4))
                        .onTapGesture { state.goToPage(p) }
                        .help(state.grid.pages.indices.contains(p) ? title ?? "Page \(p + 1)" : "New page")
                        .accessibilityLabel(state.grid.pages.indices.contains(p)
                                            ? title.map { "Page \(p + 1), \($0)" } ?? "Page \(p + 1)" : "New page")
                        .accessibilityAddTraits(p == state.currentPage ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { state.goToPage(p) }
                }
            } else if !state.query.isEmpty {
                // Search shows one page of matches; say how many didn't fit.
                let hidden = state.allSearchResults.count - state.searchResults.count
                if hidden > 0 {
                    Text("\(hidden) more \(hidden == 1 ? "match" : "matches") — keep typing to narrow the search")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}

// MARK: - Search results

struct SearchResultsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        GeometryReader { geo in
            let layout = GridLayout(size: geo.size, rows: state.grid.rows, columns: state.grid.columns)
            let icon = layout.iconSize(scale: state.prefs.iconScale)
            let results = state.searchResults
            ZStack(alignment: .topLeading) {
                if results.isEmpty {
                    Text("No Results")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                ForEach(Array(results.enumerated()), id: \.element.id) { i, app in
                    ItemView(item: .app(app), iconSize: icon, focused: state.focusIndex == i)
                        .onTapGesture { state.launch(app) }
                        .accessibilityAction { state.launch(app) }
                        .contextMenu { ItemMenu(item: .app(app)) }
                        .frame(width: layout.cell.width, height: layout.cell.height)
                        .position(layout.center(i))
                }
            }
        }
    }
}

// MARK: - Folder

struct FolderPanel: View {
    @Environment(AppState.self) private var state
    let folder: Folder

    var body: some View {
        GeometryReader { geo in
            let grid = state.grid
            let pager = state.drag.pagerFrame
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
                    .onTapGesture { state.beginRename(folder.id) }
                    .help("Click to rename")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Renames the folder")
                    .accessibilityAction { state.beginRename(folder.id) }
                ZStack(alignment: .topLeading) {
                    FolderPageContent(folder: folder, size: gridSize)
                }
                .frame(width: gridSize.width, height: gridSize.height)
                .clipped()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: {
                    state.drag.folderGridFrame = $0
                }
                if pages > 1 {
                    HStack(spacing: 10) {
                        ForEach(0..<pages, id: \.self) { p in
                            // Hit target as large as the page dots'.
                            Circle()
                                .fill(.white.opacity(p == state.folderPage ? 0.95 : 0.35))
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
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.15)))
            .contentShape(RoundedRectangle(cornerRadius: 28))
            .onTapGesture {}
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: {
                state.drag.folderPanelFrame = $0
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

struct FolderPageContent: View {
    @Environment(AppState.self) private var state
    let folder: Folder
    let size: CGSize

    var body: some View {
        let layout = GridLayout(size: size, rows: FolderLayout.rows(apps: folder.apps.count, grid: state.grid),
                                columns: FolderLayout.columns(state.grid))
        let icon = GridLayout(size: state.drag.pagerFrame.size, rows: state.grid.rows, columns: state.grid.columns)
            .iconSize(scale: state.prefs.iconScale)
        let perPage = FolderLayout.perPage(state.grid)
        var entries: [(id: UUID, app: AppRef?)] = state.remainingFolderApps().map { ($0.id, $0) }
        if state.drag.active, case .folder(let fid) = state.drag.source, fid == folder.id, let gap = state.drag.gap {
            entries.insert((PageView.gapID, nil), at: min(gap, entries.count))
        }
        let start = state.folderPage * perPage
        let visible = Array(entries.enumerated()).filter { $0.offset >= start && $0.offset < start + perPage }
        return ZStack(alignment: .topLeading) {
            ForEach(visible, id: \.element.id) { offset, entry in
                if let app = entry.app {
                    FolderItemCell(app: app, iconSize: icon, focused: state.focusIndex == offset)
                        .frame(width: layout.cell.width, height: layout.cell.height)
                        .position(layout.center(offset - start))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

struct FolderItemCell: View {
    @Environment(AppState.self) private var state
    let app: AppRef
    let iconSize: CGFloat
    let focused: Bool
    /// Set while a long press that entered edit mode is held: its release is not a tap.
    @State private var swallowTap = false

    var body: some View {
        ItemView(item: .app(app), iconSize: iconSize, selected: state.selection.contains(app.id), focused: focused,
                 editing: state.editing, onDelete: { state.remove([app.id]) })
            .onTapGesture {
                if swallowTap { swallowTap = false; return }
                let mods = NSEvent.modifierFlags
                if mods.contains(.command) { state.toggleSelection(app.id) }
                else if mods.contains(.shift) { state.extendSelection(to: app.id) }
                // Edit mode never launches: a click selects.
                else if state.editing { state.toggleSelection(app.id) }
                else { state.launch(app) }
            }
            .modifier(ItemAccessibilityActions(id: app.id, open: { state.launch(app) }))
            .simultaneousGesture(
                // As on a page: a long press enters edit mode.
                LongPressGesture(minimumDuration: 0.7).onEnded { _ in
                    guard !state.drag.active, !state.editing else { return }
                    swallowTap = true
                    withAnimation { state.editing = true }
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
struct ItemAccessibilityActions: ViewModifier {
    @Environment(AppState.self) private var state
    let id: UUID
    var isFolder = false
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityAction {
                if !state.editing || (isFolder && state.selection.isEmpty) { open() } else { state.toggleSelection(id) }
            }
            .accessibilityAction(named: state.selection.contains(id) ? "Deselect" : "Select") { state.toggleSelection(id) }
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
                TextField("Name", text: $text)
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

struct ItemMenu: View {
    @Environment(AppState.self) private var state
    let item: GridItem

    var body: some View {
        let targets = state.targets(for: item.id)
        let multi = targets.count > 1
        if case .app(let a) = item {
            Button("Open") { state.launch(a) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)])
                state.onHide()
            }
        } else if case .folder(let f) = item {
            Button("Open Folder") { state.openFolder(f.id) }
            Button("Ungroup") { state.apply { $0.ungroup(f.id) } }
        }
        if !multi {
            Button("Rename…") { state.beginRename(item.id) }
        }
        Divider()
        Menu(multi ? "Move \(targets.count) Items to Page" : "Move to Page") {
            ForEach(state.grid.pages.indices, id: \.self) { p in
                Button(state.grid.pages[p].title.map { "\(p + 1) — \($0)" } ?? "Page \(p + 1)") {
                    state.moveToPage(targets, page: p)
                }
            }
            Divider()
            Button("New Page") { state.moveToPage(targets, page: state.grid.pages.count) }
        }
        if multi {
            Button("Group \(targets.count) Items") { state.groupSelection(anchor: item.id) }
        }
        Button(state.selection.contains(item.id) ? "Deselect" : "Select") { state.toggleSelection(item.id) }
        Divider()
        Button(multi ? "Remove \(targets.count) Items" : "Remove from Grid", role: .destructive) {
            state.remove(targets)
        }
    }
}

struct BackgroundMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button(state.editing ? "Done Editing" : "Edit Layout") { state.editing.toggle() }
        Divider()
        Button("Undo") { state.undo() }.disabled(!state.canUndo)
        Button("Redo") { state.redo() }.disabled(!state.canRedo)
        Divider()
        Button("New Page") { state.newPage() }
        Button("Edit Page Title…") { state.beginPageTitleEdit(state.currentPage) }
        if state.currentItems.isEmpty && state.grid.pages.count > 1 {
            Button("Delete Empty Page") { state.deleteCurrentPage() }
        }
        Button("Sort This Page") { state.sortCurrentPage() }
        Button("Sort Everything") { state.sortEverything() }
        Divider()
        Button("Add Missing Apps…") { state.onAddMissing() }
        Button("Settings…") { state.onOpenSettings() }
    }
}
