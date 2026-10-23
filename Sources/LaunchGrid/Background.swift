import AppKit
import CoreImage
import SwiftUI
import LaunchGridCore

/// The core model's item type; SwiftUI also has a `GridItem`.
typealias GridItem = LaunchGridCore.GridItem
typealias Grid = LaunchGridCore.Grid

struct BackgroundView: View {
    @Environment(AppState.self) private var state
    @Environment(\.screenID) private var screenID

    var body: some View {
        let prefs = state.prefs
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
        .opacity(prefs.background == .solid ? max(0.15, 1 - prefs.backgroundOpacity * 0.8) : 1)
        .ignoresSafeArea()
    }

    private var wallpaperURL: URL? {
        let screen = NSScreen.screens.first { $0.displayID == screenID } ?? NSScreen.main
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
    let radius: Double
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
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
        .task(id: "\(url?.path ?? "")|\(radius)") {
            guard let url else { image = nil; return }
            let r = radius
            image = await Task.detached(priority: .userInitiated) {
                ImageBlurCache.shared.image(url: url, radius: r).map(SendableImage.init)
            }.value?.image
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

    func image(url: URL, radius: Double) -> NSImage? {
        let key = "\(url.path)|\(radius)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        // Upright, as the camera held it: a portrait photo is stored sideways with an EXIF orientation.
        guard var ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        // Work at a reduced size: the result is blurred anyway. The longer side sets it, so a
        // tall picture is shrunk as much as a wide one.
        let scale = min(1, 1600 / max(ci.extent.width, ci.extent.height, 1))
        ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = ci.extent
        if radius > 0 {
            ci = ci.clampedToExtent().applyingGaussianBlur(sigma: radius * scale * 1.5).cropped(to: extent)
        }
        guard let cg = context.createCGImage(ci, from: extent) else { return nil }
        let out = NSImage(cgImage: cg, size: extent.size)
        cache.setObject(out, forKey: key)
        return out
    }
}

private struct ScreenIDKey: EnvironmentKey {
    static let defaultValue: CGDirectDisplayID = 0
}

extension EnvironmentValues {
    var screenID: CGDirectDisplayID {
        get { self[ScreenIDKey.self] }
        set { self[ScreenIDKey.self] = newValue }
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
