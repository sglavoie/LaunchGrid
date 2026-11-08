import AppKit
import SwiftUI
import LaunchGridCore

// Opening an app that's already running, with a window on this display: its icon flies from
// its tile to that window, and a frame grows from the icon to the window's size, as the grid
// fades. The window is then exactly where the flight ended. Without a window to go to (not
// running, hidden, on another Space or display), the tile zooms toward you as before.

/// An icon on its way to its app's window (`AppState.launchFlight`).
struct LaunchFlight: Equatable {
    let id = UUID()
    let item: GridItem
    /// The icon's centre and size where it left from, in root coordinates.
    let from: CGPoint
    let size: CGFloat
    /// The window, in root coordinates.
    let to: CGRect

    /// LAUNCHGRID_DEBUG_FLIGHT_SLOW=n stretches it n times in a scratch run, to watch it.
    static let duration: TimeInterval = 0.3 * (Preferences.isScratch
        ? ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_FLIGHT_SLOW"].flatMap(Double.init) ?? 1 : 1)
    /// The last flight, described, for the debug scripts (it's over before they can look).
    nonisolated(unsafe) static var last = "-"

    static func == (a: LaunchFlight, b: LaunchFlight) -> Bool { a.id == b.id }
}

/// Where a running app's windows are. Bounds and owners come without Screen Recording
/// permission; window titles, which need it, aren't read.
enum WindowFinder {
    /// The frontmost ordinary window of `pid` on screen, in global display points with the
    /// origin at the top left of the main display, as Core Graphics gives them. Panels,
    /// menus and tiny windows (a palette, a status item's window) don't count.
    static func frontWindow(of pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        // Front to back: the first of its windows is the one in front.
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.05,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 160, rect.height >= 100 else { continue }
            return rect
        }
        return nil
    }

    /// The running copy of `app`: the one at its path, else any with its bundle ID.
    @MainActor static func running(_ app: AppRef) -> NSRunningApplication? {
        guard let id = app.bundleID else { return nil }
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !$0.isTerminated }
        return copies.first { $0.bundleURL?.path == app.path } ?? copies.first
    }
}

extension AppState {
    /// Where `id`'s icon is drawn now, in root coordinates, with its size: on the page shown,
    /// in the open folder's page shown, or among the search results shown. Nil elsewhere
    /// (the suggestions row, the Opened Lately shelf, another page).
    func iconPlace(_ id: UUID) -> (center: CGPoint, size: CGFloat)? {
        if !query.isEmpty {
            guard let i = searchResults.firstIndex(where: { $0.item.id == id }) else { return nil }
            let layout = searchLayout
            let frame = drag.pagerFrame
            var c = layout.center(i)
            let labels = prefs.showLabels && pageLayout.labelsFit(iconSize: pageIconSize)
            var size = pageIconSize
            if layout.inTopRow(i) {
                size = layout.heroIconSize(iconSize: pageIconSize, labels: labels)
                let heroCaption = layout.heroFitsCaption && searchContext(searchResults[0].item) != nil
                let caption = i == 0 && heroCaption ? SearchLayout.captionHeight(iconSize: size) : 0
                if labels { c.y -= (GridLayout.labelHeight(iconSize: size) + caption) / 2 }
                if i > 0 { c.y -= layout.topRowLift(heroIconSize: size, heroCaption: labels && heroCaption) }
            } else if labels {
                c.y -= GridLayout.labelHeight(iconSize: size) / 2
            }
            return (CGPoint(x: frame.minX + c.x, y: frame.minY + c.y), size)
        }
        if let folder = openFolder {
            let perPage = FolderLayout.perPage(grid)
            guard let index = folder.itemIDs.firstIndex(of: id), index / perPage == folderPage else { return nil }
            let c = iconCenter(index - folderPage * perPage, inFolder: true)
            let frame = drag.folderGridFrame
            return (CGPoint(x: frame.minX + c.x, y: frame.minY + c.y), folderIconSize)
        }
        guard let i = currentItems.firstIndex(where: { $0.id == id }) else { return nil }
        let c = iconCenter(i, inFolder: false)
        let frame = drag.pagerFrame
        return (CGPoint(x: frame.minX + c.x, y: frame.minY + c.y), pageIconSize)
    }

    /// Sets up `launchFlight` for opening `app`, when it's running with a window on the grid's
    /// display and its icon is in view. Hiding only, and none with Reduce Motion.
    func prepareFlight(for app: AppRef) {
        launchFlight = nil
        guard isShown, !Motion.reduced, let running = WindowFinder.running(app), !running.isHidden,
              let place = iconPlace(app.id),
              let window = WindowFinder.frontWindow(of: running.processIdentifier),
              let target = rootRect(window) else { return }
        // Mostly on this display: a window on another one is left to the ordinary zoom.
        let bounds = CGRect(origin: .zero, size: drag.rootSize)
        let shared = target.intersection(bounds)
        guard !shared.isNull, shared.width * shared.height >= 0.5 * target.width * target.height else { return }
        launchFlight = LaunchFlight(item: .app(app), from: place.center, size: place.size, to: target)
        LaunchFlight.last = "\(app.title) from \(Int(place.center.x)),\(Int(place.center.y)) size \(Int(place.size)) to \(Int(target.minX)),\(Int(target.minY)) \(Int(target.width))x\(Int(target.height))"
    }
}

/// The flying icon and the frame that grows into the window, over everything in the grid.
struct LaunchFlightLayer: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let flight = state.launchFlight {
            FlightGhost(flight: flight)
                .id(flight.id)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct FlightGhost: View {
    let flight: LaunchFlight
    @State private var arrived = false

    var body: some View {
        let to = flight.to
        let size = flight.size
        let tint = flight.item.hoverTint ?? .white
        let centre = CGPoint(x: to.midX, y: to.midY)
        ZStack {
            // The window's outline, from the icon's shape to the window's.
            RoundedRectangle(cornerRadius: arrived ? 12 : size * 0.225, style: .continuous)
                .fill(tint.opacity(0.22))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: arrived ? 12 : size * 0.225, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: arrived ? 12 : size * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.55), lineWidth: 1.5))
                .shadow(color: tint.opacity(0.35), radius: 24)
                .frame(width: arrived ? to.width : size, height: arrived ? to.height : size)
                .opacity(arrived ? 1 : 0)
                .position(arrived ? centre : flight.from)
            // The icon rides in the middle of it, growing a little and fading as it lands.
            Group {
                if case .app(let a) = flight.item { AppIcon(path: a.path, size: size) }
            }
            .frame(width: size, height: size)
            .opacity(arrived ? 0 : 1)
            .animation(.easeIn(duration: LaunchFlight.duration * 0.9), value: arrived)
            .scaleEffect(arrived ? 1.6 : 1)
            .position(arrived ? centre : flight.from)
        }
        .onAppear {
            withAnimation(.spring(response: LaunchFlight.duration, dampingFraction: 0.9)) { arrived = true }
        }
    }
}
