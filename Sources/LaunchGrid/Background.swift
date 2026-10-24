import AppKit
import CoreImage
import SwiftUI
import LaunchGridCore

/// The core model's item type; SwiftUI also has a `GridItem`.
typealias GridItem = LaunchGridCore.GridItem
typealias Grid = LaunchGridCore.Grid

struct BackgroundView: View {
    @Environment(AppState.self) private var state
    /// Counts Space switches: each Space can have its own wallpaper.
    @State private var spaceChanges = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let prefs = state.prefs
        // Pictures are looked up again on each show and Space switch: each Space can have its
        // own wallpaper, and either picture may have been changed since.
        let _ = (state.isShown, spaceChanges)
        ZStack {
            switch prefs.background {
            case .material:
                VisualEffect(material: .fullScreenUI)
            case .glass:
                if #available(macOS 26.0, *) {
                    Rectangle().fill(.clear).glassEffect(.regular, in: Rectangle())
                } else {
                    VisualEffect(material: .hudWindow)
                }
            case .wallpaper:
                BlurredImage(url: wallpaperURL, radius: prefs.blurRadius)
            case .image:
                BlurredImage(url: prefs.customImagePath.map { URL(fileURLWithPath: $0) }, radius: prefs.blurRadius)
            case .solid:
                Color(nsColor: prefs.solidColor)
            }
            // For solid colours the slider reads as transparency instead (below).
            if prefs.background != .solid {
                Color.black.opacity(prefs.backgroundOpacity)
            }
        }
        .opacity(prefs.background == .solid ? Self.solidOpacity(prefs.backgroundOpacity, reduceTransparency: reduceTransparency) : 1)
        .ignoresSafeArea()
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)) { _ in
            spaceChanges += 1
        }
    }

    /// A solid colour's opacity for the Transparency slider's value. Opaque with Reduce
    /// Transparency, which asks for no see-through backgrounds.
    static func solidOpacity(_ transparency: Double, reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1 : max(0.15, 1 - transparency * 0.8)
    }

    /// How many times the wallpaper was looked up, for the debug scripts.
    nonisolated(unsafe) static var wallpaperLookups = 0

    private var wallpaperURL: URL? {
        Self.wallpaperLookups += 1
        let screen = NSScreen.screens.first { $0.displayID == state.screenID } ?? NSScreen.main
        return screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        v.material = material
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

/// An image scaled to fill, blurred once and cached. Falls back to the blurred desktop
/// while loading, or when the file can't be decoded (e.g. a dynamic or aerial wallpaper).
struct BlurredImage: View {
    let url: URL?
    /// In points on screen, whatever the picture's own size.
    let radius: Double
    /// Read when the parent redraws (each show and Space switch), not only when the path
    /// changes: a body with the same inputs isn't run again.
    private let identity: String
    @State private var image: NSImage?
    /// The picture `image` was made from: another one (a different display's wallpaper) isn't
    /// left on screen while the new one blurs.
    @State private var shownIdentity: String?
    @Environment(\.displayScale) private var displayScale

    init(url: URL?, radius: Double) {
        self.url = url
        self.radius = radius
        identity = url.map(ImageBlurCache.identity) ?? ""
    }

    var body: some View {
        GeometryReader { geo in
            // The size filled sets how strong the blur is in the picture's own pixels. Rounded
            // up, so a window animating open (or being resized) doesn't blur at every frame.
            let size = CGSize(width: (geo.size.width / 128).rounded(.up) * 128, height: (geo.size.height / 128).rounded(.up) * 128)
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    VisualEffect(material: .fullScreenUI)
                }
            }
            .task(id: "\(identity)|\(radius)|\(size.width)x\(size.height)@\(displayScale)") {
                await load(size: size)
            }
            .animation(.easeInOut(duration: 0.2), value: shownIdentity)
        }
    }

    private func load(size: CGSize) async {
        guard let url, size.width > 0, size.height > 0 else {
            if url == nil { image = nil; shownIdentity = nil }
            return
        }
        let identity = identity
        let target = ImageBlurCache.Target(radius: radius, size: size, pixelScale: displayScale)
        if let hit = ImageBlurCache.shared.cached(url: url, target) { show(hit, identity); return }
        if shownIdentity != identity {
            // Another picture: the blurred desktop stands in until it is ready.
            show(nil, nil)
        } else if image != nil {
            // Dragging the Blur slider steps through radii: blur only the one it rests on.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
        }
        let made = await Task.detached(priority: .userInitiated) {
            ImageBlurCache.shared.image(url: url, target).map(SendableImage.init)
        }.value?.image
        guard !Task.isCancelled else { return }
        show(made, made == nil ? nil : identity)
    }

    /// A new picture fades in; the stand-in replaces the old one at once, so the old one
    /// doesn't linger through a fade.
    private func show(_ image: NSImage?, _ identity: String?) {
        var transaction = Transaction()
        transaction.disablesAnimations = image == nil
        withTransaction(transaction) {
            self.image = image
            shownIdentity = identity
        }
    }
}

final class ImageBlurCache: @unchecked Sendable {
    static let shared = ImageBlurCache()
    private let cache = NSCache<NSString, NSImage>()
    private let context = CIContext()

    init() {
        // A few screens' wallpapers and a custom image; older blurs are cheap to redo.
        cache.countLimit = 8
    }

    private let lock = NSLock()
    private var renderCount = 0
    /// Blurs made (not served from the cache), for the debug scripts.
    var renders: Int { lock.withLock { renderCount } }

    /// The path and the file it names now: a picture replaced at the same path (a new file
    /// saved over it) is a new picture. Not by modification date, which would need a reason
    /// in the privacy manifest.
    static func identity(of url: URL) -> String {
        let file = (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        return "\(url.path)|\(file.map { String(describing: $0) } ?? "")"
    }

    /// What a picture is rendered for: the blur radius in points, and the size (in points,
    /// at `pixelScale` pixels each) it is scaled to fill.
    struct Target: Sendable {
        var radius: Double
        var size: CGSize
        var pixelScale: CGFloat
    }

    private func key(url: URL, _ t: Target) -> NSString {
        "\(Self.identity(of: url))|\(t.radius)|\(t.size.width)x\(t.size.height)@\(t.pixelScale)" as NSString
    }

    func cached(url: URL, _ target: Target) -> NSImage? {
        cache.object(forKey: key(url: url, target))
    }

    func image(url: URL, _ target: Target) -> NSImage? {
        let key = key(url: url, target)
        if let hit = cache.object(forKey: key) { return hit }
        // Upright, as the camera held it: a portrait photo is stored sideways with an EXIF orientation.
        guard var ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let source = ci.extent.size
        // Points on screen per source pixel, as the picture is scaled to fill.
        let fill = max(target.size.width / max(source.width, 1), target.size.height / max(source.height, 1))
        // Blurred, work at a reduced size: the longer side sets it, so a tall picture is shrunk
        // as much as a wide one. Unblurred, at the screen's own resolution, so it stays sharp.
        let scale = target.radius > 0
            ? min(1, 1600 / max(source.width, source.height, 1))
            : min(1, fill * max(target.pixelScale, 1))
        ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = ci.extent.integral
        if target.radius > 0 {
            // The radius is in points on screen: one working pixel is `fill / scale` points.
            ci = ci.clampedToExtent().applyingGaussianBlur(sigma: target.radius * scale / fill).cropped(to: extent)
        }
        guard let cg = context.createCGImage(ci, from: extent) else { return nil }
        lock.withLock { renderCount += 1 }
        let out = NSImage(cgImage: cg, size: extent.size)
        cache.setObject(out, forKey: key)
        return out
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Key for per-screen window frames: the display's UUID, which survives reconnecting
    /// and restarts, unlike its number.
    var frameKey: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else { return legacyFrameKey }
        return Self.stableKeyPrefix + (string as String)
    }

    /// The key frames were saved under before; read once to migrate them.
    var legacyFrameKey: String { "\(localizedName)-\(displayID)" }

    static let stableKeyPrefix = "display-"

    static func isStableFrameKey(_ key: String) -> Bool { key.hasPrefix(stableKeyPrefix) }
}
