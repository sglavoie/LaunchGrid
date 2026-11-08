import AppKit
import SwiftUI
import os
import LaunchGridCore

// Motion and feedback shared by the grid's views: hovering and pressing tiles, the grid
// settling in as it shows, an opened item zooming toward you, dropped icons gliding into place,
// folders opening out of their tile, and the trackpad's taps during a drag.
// Everything here stands still with Reduce Motion.

/// A dropped icon on its way into its place (`AppState.land`).
struct Landing: Equatable {
    let id = UUID()
    let item: GridItem
    let count: Int
    /// In root coordinates, as the drag ghost's.
    let from: CGPoint
    let to: CGPoint
    let size: CGFloat
    /// 1 into a slot, smaller into a folder's tile.
    let endScale: CGFloat
    /// Tiles kept empty until it's there.
    let hides: Set<UUID>

    static let duration: TimeInterval = 0.26
    /// The last landing, described, for the debug scripts (it's over before they can look).
    nonisolated(unsafe) static var last = "-"

    static func == (a: Landing, b: Landing) -> Bool { a.id == b.id }
}

/// Force Touch trackpad taps: a gap opening, a folder about to form, a page turned under a drag.
enum Haptics {
    /// Taps asked for so far, for the debug scripts (a tap can't be felt over SSH).
    nonisolated(unsafe) static var count = 0

    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        count += 1
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

/// How long the grid takes from being asked to show to its first frame on screen.
enum ShowTiming {
    static let signposter = OSSignposter(subsystem: "com.sglavoie.launchgrid", category: "Show")
    /// The last show's time to first frame, in milliseconds, for the debug scripts.
    nonisolated(unsafe) static var lastMilliseconds: Double? {
        didSet { if let ms = lastMilliseconds { samples.append(ms); if samples.count > 200 { samples.removeFirst() } } }
    }
    /// Every show's time this run, oldest first: the first is the cold one (the panel and its
    /// views made for the first time), the rest warm.
    nonisolated(unsafe) static var samples: [Double] = []

    /// "cold 212 ms, warm p50 18 ms, p95 31 ms (n=9)".
    static var summary: String {
        guard let cold = samples.first else { return "no shows yet" }
        let warm = samples.dropFirst().sorted()
        func pct(_ p: Double) -> Double { warm[min(warm.count - 1, Int((Double(warm.count - 1) * p).rounded()))] }
        let warmText = warm.isEmpty ? "no warm shows" : String(format: "warm p50 %.0f ms, p95 %.0f ms (n=%d)", pct(0.5), pct(0.95), warm.count)
        return String(format: "cold %.0f ms, ", cold) + warmText
    }
}

// MARK: - Tiles

/// A tile under the pointer lifts a little and brightens behind; with the button held on it,
/// it sinks in and springs back on release. Not during a drag, which has its own motion.
struct TileMotion: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat
    /// The icon's own colour, which the glow behind it takes; white when it has none.
    var tint: Color? = nil
    @Environment(AppState.self) private var state
    @Environment(\.reduceMotion) private var reduceMotion
    @State private var hovered = false
    /// Held down on this tile: set as the button goes down over it, kept until it's let go
    /// (the pointer's hover can end as the press begins).
    @State private var pressed = false

    func body(content: Content) -> some View {
        let lift = enabled && !reduceMotion
        content
            .background {
                if enabled && hovered && !pressed {
                    if let tint {
                        // The icon's colour glowing from behind it, on the faint white of any tile.
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(RadialGradient(colors: [tint.opacity(0.42), tint.opacity(0.1)],
                                                 center: .center, startRadius: 0, endRadius: 64))
                            .overlay(RoundedRectangle(cornerRadius: cornerRadius).fill(.white.opacity(0.04)))
                            .transition(.opacity)
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.white.opacity(0.08))
                            .transition(.opacity)
                    }
                }
            }
            // The icon's shadow follows the lift (`IconShadow`).
            .environment(\.tileLift, enabled ? (pressed ? -1 : hovered ? 1 : 0) : 0)
            .scaleEffect(lift ? (pressed ? 0.92 : hovered ? 1.05 : 1) : 1)
            .animation(.spring(response: pressed ? 0.12 : 0.3, dampingFraction: pressed ? 0.9 : 0.62), value: pressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hovered)
            .onHover { hovered = $0 }
            .onChange(of: state.mouseDown) { _, down in pressed = down && hovered && enabled }
            .onChange(of: enabled) { _, on in if !on { hovered = false; pressed = false } }
    }
}

/// The grid settling in as it shows: each tile comes in from slightly larger, the ones near the
/// middle first, so the grid seems to settle out from it; hiding, they drift back out as it
/// fades. Called from somewhere (the pointer, a hot corner, the menu-bar icon), the tiles
/// come out of there instead, the nearest first, and go back into it as the grid hides. The
/// first show after a layout is made builds it in tile by tile, from small.
struct AppearMotion: ViewModifier {
    /// From where the grid comes out of (the middle of the page, or `toOrigin`), in cells.
    let distance: Double
    /// Its place on the page, for the first show's build.
    let order: Int
    let current: Bool
    /// From the tile to where the grid was called from; nil for the middle.
    var toOrigin: CGSize? = nil
    @Environment(AppState.self) private var state
    @Environment(\.reduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shown = state.isShown
        let intro = state.introPending
        // Hiding to open an item, `OpenMotion` moves the tiles, and the window's fade hides them.
        let still = reduceMotion || !current || (!shown && state.launchingID != nil)
        // Out of the origin: from a little way toward it, smaller.
        let pull = still || shown || intro ? CGSize.zero : (toOrigin.map { CGSize(width: $0.width * 0.22, height: $0.height * 0.22) } ?? .zero)
        content
            .scaleEffect(still || shown ? 1 : intro ? 0.4 : toOrigin == nil ? 1.04 : 0.82)
            .offset(pull)
            .opacity(still || shown ? 1 : 0)
            .animation(still ? nil : shown ? appear(intro: intro) : .easeIn(duration: 0.12), value: shown)
    }

    private func appear(intro: Bool) -> Animation {
        if intro { return .spring(response: 0.5, dampingFraction: 0.72).delay(0.08 + Double(order) * 0.028) }
        // From a corner the farthest tiles are several cells away: a shorter step keeps the
        // whole under a quarter of a second.
        return toOrigin == nil ? .spring(response: 0.34, dampingFraction: 0.8).delay(distance * 0.02)
            : .spring(response: 0.4, dampingFraction: 0.78).delay(min(distance * 0.016, 0.2))
    }
}

/// The tile being opened zooms toward you as the grid hides, the others drawing back; opened
/// with the grid staying up, it pulses.
struct OpenMotion: ViewModifier {
    let id: UUID
    @Environment(AppState.self) private var state
    @Environment(\.reduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let launching = state.launchingID
        let scale: CGFloat = reduceMotion || launching == nil ? 1 : launching == id ? 1.3 : 0.92
        let pulse = state.launchPulse.id == id ? state.launchPulse.count : 0
        let still = reduceMotion
        content
            .scaleEffect(scale)
            .animation(.easeOut(duration: 0.22), value: launching)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: pulse) { view, s in
                view.scaleEffect(still ? 1 : s)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.86, duration: 0.09)
                    SpringKeyframe(1.0, duration: 0.35, spring: .init(response: 0.3, dampingRatio: 0.5))
                }
            }
    }
}

/// The running dot coming in (from small, popping slightly past its size) or shrinking away.
struct DotPop: ViewModifier, Animatable {
    var scale: CGFloat
    nonisolated var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    func body(content: Content) -> some View {
        return content.scaleEffect(scale).opacity(Double(min(1, max(0, (scale - 0.1) / 0.5))))
    }
}

/// The small dot under a running app, as in the Dock.
struct RunningDot: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(.white.opacity(0.9))
            .frame(width: max(3, min(5, size * 0.06)), height: max(3, min(5, size * 0.06)))
            .shadow(color: .black.opacity(0.5), radius: 1)
            .accessibilityHidden(true)
    }
}

/// A search result's name, with the letters typed in bold and the rest a little dimmer.
func highlightedTitle(_ title: String, query: String, contrast: ColorSchemeContrast) -> Text {
    let marks = Set(Search.highlights(in: title, query: query))
    guard !marks.isEmpty else { return Text(verbatim: title) }
    var out = AttributedString()
    for (i, ch) in title.enumerated() {
        var run = AttributedString(String(ch))
        if marks.contains(i) {
            run.inlinePresentationIntent = .stronglyEmphasized
        } else {
            run.foregroundColor = .white.opacity(contrast == .increased ? 0.95 : 0.78)
        }
        out += run
    }
    return Text(out)
}

// MARK: - Folders

/// A folder panel opening out of its tile and closing back into it: from the tile's size at
/// its place to full size in the middle.
struct FolderZoom: ViewModifier, Animatable {
    var progress: Double
    /// From the panel's centre to the tile's.
    let offset: CGSize
    /// The tile's size over the panel's.
    let startScale: CGFloat

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = CGFloat(progress)
        return content
            .scaleEffect(startScale + (1 - startScale) * p)
            .offset(x: offset.width * (1 - p), y: offset.height * (1 - p))
            // It's there almost at once, so the tile seems to grow rather than a panel fade in.
            .opacity(min(1, Double(p) * 4))
    }
}

extension AnyTransition {
    static func folderZoom(offset: CGSize, startScale: CGFloat) -> AnyTransition {
        .modifier(active: FolderZoom(progress: 0, offset: offset, startScale: startScale),
                  identity: FolderZoom(progress: 1, offset: offset, startScale: startScale))
    }
}

// MARK: - Landing

/// A dropped icon gliding from where it was let go into its place.
struct LandingLayer: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let landing = state.landing {
            LandingGhost(landing: landing)
                .id(landing.id)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct LandingGhost: View {
    let landing: Landing
    @State private var arrived = false

    var body: some View {
        let size = landing.size
        Group {
            switch landing.item {
            case .app(let a): AppIcon(path: a.path, size: size)
            case .folder(let f): FolderIcon(folder: f, size: size)
            case .action(let a): ActionTile(action: a, size: size)
            }
        }
        // From the lifted ghost's look to the tile's.
        .scaleEffect(arrived ? landing.endScale : 1.1)
        .shadow(color: .black.opacity(arrived ? 0 : 0.35), radius: arrived ? 0 : 12, y: arrived ? 0 : 6)
        .opacity(arrived && landing.endScale < 1 ? 0 : 1)
        .position(arrived ? landing.to : landing.from)
        .onAppear {
            withAnimation(.spring(response: Landing.duration, dampingFraction: 0.86)) { arrived = true }
        }
    }
}

// MARK: - Background

/// The background coming in as the grid shows: it fades in over the desktop, which seems to
/// blur as it does, and a picture settles from slightly larger, as if the desktop drew back.
/// Hiding reverses it. With Reduce Motion, it only fades.
struct BackgroundEntrance: ViewModifier {
    /// Whether it zooms too: a picture does; a blur of what's behind the window or a flat
    /// colour shows no difference.
    let zooms: Bool
    @Environment(AppState.self) private var state
    @Environment(\.reduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Hiding to open an item, the window's own fade takes it, with the opened tile's zoom.
        let shown = state.isShown || state.launchingID != nil
        content
            .scaleEffect(zooms && !reduceMotion && !state.isShown ? 1.06 : 1, anchor: anchor)
            .opacity(shown ? 1 : 0)
            .animation(state.isShown ? .easeOut(duration: Self.duration) : .easeIn(duration: 0.12), value: state.isShown)
    }

    static let duration: TimeInterval = 0.32

    /// Where the grid was called from, as a point in the window: the picture draws back toward it.
    private var anchor: UnitPoint {
        guard let o = state.showOrigin, state.drag.rootSize.width > 0, state.drag.rootSize.height > 0 else { return .center }
        return UnitPoint(x: o.x / state.drag.rootSize.width, y: o.y / state.drag.rootSize.height)
    }
}

/// A picture background drifts a little as the pages turn, slower than the icons, so the grid
/// seems to float over it. It follows a swipe as it goes. Still with Reduce Motion.
struct Parallax: ViewModifier {
    @Environment(AppState.self) private var state
    @Environment(\.reduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let pages = state.query.isEmpty ? state.grid.pages.count : 1
        let offset = reduceMotion ? 0 : Self.offset(page: state.currentPage, swipe: state.swipeOffset,
                                                    pageWidth: state.drag.pagerSize.width, pages: pages)
        let reach = reduceMotion ? 0 : Self.reach(pages: pages)
        content
            // Just large enough that neither edge comes into view at the first or last page.
            .scaleEffect(width > 0 && reach > 0 ? 1 + 2 * (reach + 4) / width : 1)
            .offset(x: offset)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// How far the picture moves for each page: less the more pages there are, so the whole
    /// run stays within a few percent of the screen.
    static func travel(pages: Int) -> CGFloat { pages < 2 ? 0 : min(18, 90 / CGFloat(pages - 1)) }

    /// The furthest it goes from the middle, either way.
    static func reach(pages: Int) -> CGFloat { CGFloat(max(pages - 1, 0)) / 2 * travel(pages: pages) }

    /// Where the picture is for the page shown and the swipe under way: the middle page leaves
    /// it centred, earlier ones move it right, later ones left. Past either end (the swipe's
    /// rubber band), it goes only a little further.
    static func offset(page: Int, swipe: CGFloat, pageWidth: CGFloat, pages: Int) -> CGFloat {
        guard pages > 1 else { return 0 }
        let at = Double(page) - Double(swipe / max(pageWidth, 1))
        let clamped = min(max(at, -0.25), Double(pages - 1) + 0.25)
        return -CGFloat(clamped - Double(pages - 1) / 2) * travel(pages: pages)
    }
}

// MARK: - New apps

/// The blue dot beside a newly installed app's name, as Launchpad shows, until it's opened.
struct NewAppDot: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color(red: 0.25, green: 0.6, blue: 1))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.45), radius: 1)
            .accessibilityHidden(true)
    }
}

extension GridItem {
    /// The colour its hover glow takes: an app icon's own, an action glyph's hue; none for a
    /// folder or a picture.
    @MainActor var hoverTint: Color? {
        switch self {
        case .app(let a):
            IconProvider.shared.tint(a.path).map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue) }
        case .action(let a):
            if case .image = a.icon { nil } else { Color(hue: ActionTile.hue(for: a.id), saturation: 0.6, brightness: 0.95) }
        case .folder: nil
        }
    }
}

extension GridItem {
    /// The hue (0..<1) a colour sort places it by: an app icon's own colour, an action
    /// glyph's hue, a folder by its first app with a colour; nil for a grey one, a picture,
    /// or an icon not drawn yet.
    @MainActor var colourHue: Double? {
        switch self {
        case .app(let a): Self.hue(ofIconAt: a.path)
        case .action(let a): Self.hue(of: a)
        case .folder(let f):
            f.items.lazy.compactMap { member -> Double? in
                switch member {
                case .app(let a): Self.hue(ofIconAt: a.path)
                case .action(let a): Self.hue(of: a)
                }
            }.first
        }
    }

    @MainActor private static func hue(ofIconAt path: String) -> Double? {
        guard let t = IconProvider.shared.tint(path) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        NSColor(srgbRed: t.red, green: t.green, blue: t.blue, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return Double(h)
    }

    @MainActor private static func hue(of action: Action) -> Double? {
        if case .image = action.icon { return nil }
        return ActionTile.hue(for: action.id)
    }
}

// MARK: - Folder peek

/// What's in a folder, fanned out over its tile while the pointer rests on it: its first apps,
/// larger than the tile's thumbnails, and how many there are. VoiceOver reads the count on
/// the tile itself.
struct FolderPeek: View {
    let folder: Folder
    @Environment(\.colorSchemeContrast) private var contrast

    static let shown = 8

    var body: some View {
        let members = Array(folder.items.prefix(Self.shown))
        let more = folder.items.count - members.count
        VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: SwiftUI.GridItem(.fixed(36), spacing: 8), count: min(4, max(members.count, 1))), spacing: 8) {
                ForEach(Array(members.enumerated()), id: \.element.id) { i, member in
                    Group {
                        switch member {
                        case .app(let app): AppIcon(path: app.path, size: 36)
                        case .action(let action): ActionTile(action: action, size: 36)
                        }
                    }
                    .modifier(PeekFan(order: i))
                }
            }
            Text(more > 0 ? "\(folder.name) · \(more) more" : folder.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.8))
                .lineLimit(1)
        }
        .padding(10)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Each icon in a folder's peek comes out a moment after the one before. Still with Reduce Motion.
private struct PeekFan: ViewModifier {
    let order: Int
    @Environment(\.reduceMotion) private var reduceMotion
    @State private var out = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(out || reduceMotion ? 1 : 0.5)
            .opacity(out || reduceMotion ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.7).delay(Double(order) * 0.025)) { out = true }
            }
    }
}

// MARK: - Launching

/// A ring turning around an app opened behind the grid until it has finished launching: the
/// Dock's bouncing icon, which the grid covers. Shown only once a launch takes a moment, so an
/// app already running doesn't flash it. A steady ring with Reduce Motion.
struct LaunchRing: View {
    let size: CGFloat
    @Environment(\.reduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: reduceMotion ? 1 : 0.28)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: size * 1.12, height: size * 1.12)
        .shadow(color: .black.opacity(0.4), radius: 2)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { visible = true }
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
        }
    }
}
