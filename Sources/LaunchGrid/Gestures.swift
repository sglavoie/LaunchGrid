import AppKit
import Observation
import SwiftUI

/// Opens the grid from a trackpad pinch or a screen corner, as set in Settings › General.
///
/// The pinch follows the fingers: the grid fades and settles in as they close, and opening
/// them again before letting go puts it back. Pinching opens it over the bare desktop (where no
/// app's own zoom is under the pointer), or anywhere with four fingers when the trackpad says
/// how many are down and the system's own pinch gesture is off. On the grid, spreading the
/// fingers closes it the same way. Neither needs a permission: the watcher only reads pinches
/// and pointer moves, never keys.
@MainActor @Observable
final class GestureWatcher {
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let overlay: OverlayController
    @ObservationIgnored private var monitors: [Any] = []

    init(prefs: Preferences, overlay: OverlayController) {
        self.prefs = prefs
        self.overlay = overlay
    }

    /// Starts or stops watching to match the settings.
    func apply() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        cornerTimer?.invalidate()
        cornerTimer = nil
        stopTap()
        if prefs.pinchToOpen {
            // Pinches in other apps (over the desktop: Finder's): opening. AppKit's global
            // monitors never see pinches, so a tap that only listens.
            startTap()
            // Without the tap (refused), pinches on the grid itself still close it, when they reach it.
            if pinchUnavailable, let m = NSEvent.addLocalMonitorForEvents(matching: .magnify, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.magnify(event, fromTap: false) }
                return event
            }) { monitors.append(m) }
        } else {
            pinchUnavailable = false
        }
        if prefs.hotCorner != .none {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
                MainActor.assumeIsolated { self?.pointerMoved() }
                return event
            }) { monitors.append(m) }
        }
    }

    // MARK: Pinch

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    /// Set when macOS refused the tap: Settings says so, with a way to ask for access.
    private(set) var pinchUnavailable = false

    private func startTap() {
        #if !APP_STORE
        // LAUNCHGRID_DEBUG_PINCH_REFUSED: as if macOS refused the tap, for the warning in Settings.
        if Preferences.isScratch, ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_PINCH_REFUSED"] != nil {
            pinchUnavailable = true
            return
        }
        #endif
        let mask = CGEventMask(1) << 29 // gestures, which carry pinches
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // Turned off when it once took too long: turn it back on.
                if let info { MainActor.assumeIsolated { Unmanaged<GestureWatcher>.fromOpaque(info).takeUnretainedValue().reenableTap() } }
            } else if let info, let ns = NSEvent(cgEvent: event), ns.type == .magnify {
                MainActor.assumeIsolated { Unmanaged<GestureWatcher>.fromOpaque(info).takeUnretainedValue().magnify(ns, fromTap: true) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else {
            pinchUnavailable = true
            return
        }
        pinchUnavailable = false
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
    }

    private func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    /// Asks macOS for the access the pinch needs, if it refused it (Input Monitoring).
    func requestPinchAccess() {
        _ = CGRequestListenEventAccess()
        apply()
    }

    /// The pinch being followed: whether it opens the grid (else closes it), and how far the
    /// fingers have gone (the magnification added up).
    @ObservationIgnored private var pinch: (opening: Bool, total: CGFloat, following: Bool)?

    /// How much of a pinch takes the grid all the way, in magnification.
    static let pinchReach: CGFloat = 0.5
    /// How far a pinch must go before it's let go for the grid to finish opening (or closing).
    static let commitAt: CGFloat = 0.3

    /// A pinch event, from the tap (every app's, the grid's too) or, without the tap, the grid's
    /// own. With the grid hidden it may open it; shown, it may close it.
    func magnify(_ event: NSEvent, fromTap: Bool) {
        if event.phase.contains(.began) {
            if overlay.isVisible {
                pinch = (false, 0, false)
            } else {
                pinch = fromTap && Self.opensHere(event) ? (true, 0, false) : nil
            }
            return
        }
        guard var p = pinch else { return }
        if event.phase.contains(.changed) {
            p.total += event.magnification
            // Opening wants the fingers closing (less magnification), closing wants them opening.
            let along = p.opening ? -p.total : p.total
            if !p.following {
                // Not until it's clearly going the right way: a pinch the other way is an app's zoom.
                guard along > 0.03 else {
                    if along < -0.08 { pinch = nil } else { pinch = p }
                    return
                }
                p.following = true
                overlay.pinchBegan(opening: p.opening)
            }
            overlay.pinchChanged(progress: min(max(along / Self.pinchReach, 0), 1))
            pinch = p
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            pinch = nil
            guard p.following else { return }
            let along = p.opening ? -p.total : p.total
            overlay.pinchEnded(commit: !event.phase.contains(.cancelled) && along / Self.pinchReach >= Self.commitAt)
        }
    }

    /// Whether a pinch elsewhere should open the grid: four fingers or more, when the trackpad
    /// says how many, or over the bare desktop with any.
    static func opensHere(_ event: NSEvent) -> Bool {
        #if !APP_STORE
        if Preferences.isScratch, ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_PINCH_ANYWHERE"] != nil { return true }
        #endif
        let fingers = event.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled }.count
        if fingers >= 4 { return true }
        return desktopUnderPointer()
    }

    /// Whether nothing but the desktop is under the pointer: no window of any app, the Dock or
    /// the menu bar. Bounds and layers only, which need no permission.
    static func desktopUnderPointer() -> Bool {
        let mouse = NSEvent.mouseLocation
        // Window bounds count from the top of the main display, down.
        guard let top = NSScreen.screens.first?.frame.maxY else { return false }
        let point = CGPoint(x: mouse.x, y: top - mouse.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let own = ProcessInfo.processInfo.processIdentifier
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? Int32) != own,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            return false
        }
        return true
    }

    // MARK: Hot corner

    @ObservationIgnored private var cornerTimer: Timer?
    /// Set once the corner has done its job, until the pointer leaves it.
    @ObservationIgnored private var cornerUsed = false

    /// How long the pointer rests in the corner first, so passing through it does nothing.
    static let cornerDwell: TimeInterval = 0.15

    private func pointerMoved() {
        let inCorner = Self.isInCorner(prefs.hotCorner)
        guard inCorner else {
            cornerUsed = false
            cornerTimer?.invalidate()
            cornerTimer = nil
            return
        }
        // Dragging a window or a file into the corner isn't asking for the grid.
        guard !cornerUsed, cornerTimer == nil, NSEvent.pressedMouseButtons == 0 else { return }
        let timer = Timer(timeInterval: Self.cornerDwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cornerTimer = nil
                guard Self.isInCorner(self.prefs.hotCorner), NSEvent.pressedMouseButtons == 0 else { return }
                self.cornerUsed = true
                self.overlay.toggle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cornerTimer = timer
    }

    /// Whether the pointer is in `corner` of the display it's on, within a few points.
    static func isInCorner(_ corner: HotCorner) -> Bool {
        let p = NSEvent.mouseLocation
        guard corner != .none, let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return false }
        return isInCorner(corner, point: p, of: screen.frame)
    }

    nonisolated static func isInCorner(_ corner: HotCorner, point p: CGPoint, of f: CGRect, slack: CGFloat = 3) -> Bool {
        let left = p.x <= f.minX + slack, right = p.x >= f.maxX - 1 - slack
        let bottom = p.y <= f.minY + slack, top = p.y >= f.maxY - 1 - slack
        switch corner {
        case .none: return false
        case .topLeft: return top && left
        case .topRight: return top && right
        case .bottomLeft: return bottom && left
        case .bottomRight: return bottom && right
        }
    }
}
