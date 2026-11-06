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
    nonisolated(unsafe) static var lastMilliseconds: Double?
}

// MARK: - Tiles

/// A tile under the pointer lifts a little and brightens behind; with the button held on it,
/// it sinks in and springs back on release. Not during a drag, which has its own motion.
struct TileMotion: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    /// Held down on this tile: set as the button goes down over it, kept until it's let go
    /// (the pointer's hover can end as the press begins).
    @State private var pressed = false

    func body(content: Content) -> some View {
        let lift = enabled && !reduceMotion
        content
            .background {
                if enabled && hovered && !pressed {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.white.opacity(0.08))
                        .transition(.opacity)
                }
            }
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
/// fades. The first show after a layout is made builds it in tile by tile, from small.
struct AppearMotion: ViewModifier {
    /// From the middle of the page, in cells.
    let distance: Double
    /// Its place on the page, for the first show's build.
    let order: Int
    let current: Bool
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shown = state.isShown
        let intro = state.introPending
        // Hiding to open an item, `OpenMotion` moves the tiles, and the window's fade hides them.
        let still = reduceMotion || !current || (!shown && state.launchingID != nil)
        content
            .scaleEffect(still || shown ? 1 : intro ? 0.4 : 1.04)
            .opacity(still || shown ? 1 : 0)
            .animation(still ? nil : shown ? appear(intro: intro) : .easeIn(duration: 0.12), value: shown)
    }

    private func appear(intro: Bool) -> Animation {
        intro ? .spring(response: 0.5, dampingFraction: 0.72).delay(0.08 + Double(order) * 0.028)
            : .spring(response: 0.34, dampingFraction: 0.8).delay(distance * 0.02)
    }
}

/// The tile being opened zooms toward you as the grid hides, the others drawing back; opened
/// with the grid staying up, it pulses.
struct OpenMotion: ViewModifier {
    let id: UUID
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let launching = state.launchingID
        let scale: CGFloat = reduceMotion || launching == nil ? 1 : launching == id ? 1.3 : 0.92
        let pulse = state.launchPulse.id == id ? state.launchPulse.count : 0
        content
            .scaleEffect(scale)
            .animation(.easeOut(duration: 0.22), value: launching)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: pulse) { view, s in
                view.scaleEffect(reduceMotion ? 1 : s)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.86, duration: 0.09)
                    SpringKeyframe(1.0, duration: 0.35, spring: .init(response: 0.3, dampingRatio: 0.5))
                }
            }
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
