import AppKit
import Carbon.HIToolbox
import Observation
import LaunchGridCore

enum WindowMode: String, CaseIterable, Identifiable {
    case fullScreen, behindDock, window
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fullScreen: "Full Screen"
        case .behindDock: "Full Screen Behind Dock"
        case .window: "Window"
        }
    }
}

enum BackgroundStyle: String, CaseIterable, Identifiable {
    case material, wallpaper, glass, solid, image
    var id: String { rawValue }
    var label: String {
        switch self {
        case .material: "Blurred Desktop"
        case .wallpaper: "Wallpaper"
        case .glass: "Liquid Glass"
        case .solid: "Solid Colour"
        case .image: "Custom Image"
        }
    }
}

/// User settings, persisted in UserDefaults. Grid size lives in the grid itself.
@MainActor @Observable
final class Preferences {
    @ObservationIgnored private let d = UserDefaults.standard

    var hotkeyKeyCode: UInt32 { didSet { d.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode") } }
    var hotkeyModifiers: UInt32 { didSet { d.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers") } }
    var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    var windowMode: WindowMode { didSet { d.set(windowMode.rawValue, forKey: "windowMode") } }
    var background: BackgroundStyle { didSet { d.set(background.rawValue, forKey: "background") } }
    var solidColorHex: String { didSet { d.set(solidColorHex, forKey: "solidColorHex") } }
    /// Strength of the darkening tint (or colour opacity for solid backgrounds).
    var backgroundOpacity: Double { didSet { d.set(backgroundOpacity, forKey: "backgroundOpacity") } }
    var blurRadius: Double { didSet { d.set(blurRadius, forKey: "blurRadius") } }
    var customImagePath: String? { didSet { d.set(customImagePath, forKey: "customImagePath") } }
    var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    var showInMenuBar: Bool { didSet { d.set(showInMenuBar, forKey: "showInMenuBar") } }
    var autoAddApps: Bool { didSet { d.set(autoAddApps, forKey: "autoAddApps") } }
    var hideAfterLaunch: Bool { didSet { d.set(hideAfterLaunch, forKey: "hideAfterLaunch") } }
    var hideOnEmptyClick: Bool { didSet { d.set(hideOnEmptyClick, forKey: "hideOnEmptyClick") } }
    var iconScale: Double { didSet { d.set(iconScale, forKey: "iconScale") } }
    var showLabels: Bool { didSet { d.set(showLabels, forKey: "showLabels") } }
    var folderPlacement: FolderPlacement { didSet { d.set(folderPlacement.rawValue, forKey: "folderPlacement") } }
    var extraFolders: [String] { didSet { d.set(extraFolders, forKey: "extraFolders") } }
    /// Window-mode frames keyed by screen (name + display ID).
    var windowFrames: [String: String] { didSet { d.set(windowFrames, forKey: "windowFrames") } }

    init() {
        d.register(defaults: [
            "hotkeyKeyCode": kVK_Space,
            "hotkeyModifiers": optionKey,
            "hotkeyEnabled": true,
            "windowMode": WindowMode.fullScreen.rawValue,
            "background": BackgroundStyle.material.rawValue,
            "solidColorHex": "#1E2230",
            "backgroundOpacity": 0.25,
            "blurRadius": 30.0,
            "showInDock": false,
            "showInMenuBar": true,
            "autoAddApps": true,
            "hideAfterLaunch": true,
            "hideOnEmptyClick": true,
            "iconScale": 1.0,
            "showLabels": true,
            "folderPlacement": FolderPlacement.first.rawValue,
        ])
        hotkeyKeyCode = UInt32(d.integer(forKey: "hotkeyKeyCode"))
        hotkeyModifiers = UInt32(d.integer(forKey: "hotkeyModifiers"))
        hotkeyEnabled = d.bool(forKey: "hotkeyEnabled")
        windowMode = WindowMode(rawValue: d.string(forKey: "windowMode") ?? "") ?? .fullScreen
        background = BackgroundStyle(rawValue: d.string(forKey: "background") ?? "") ?? .material
        solidColorHex = d.string(forKey: "solidColorHex") ?? "#1E2230"
        backgroundOpacity = d.double(forKey: "backgroundOpacity")
        blurRadius = d.double(forKey: "blurRadius")
        customImagePath = d.string(forKey: "customImagePath")
        showInDock = d.bool(forKey: "showInDock")
        showInMenuBar = d.bool(forKey: "showInMenuBar")
        autoAddApps = d.bool(forKey: "autoAddApps")
        hideAfterLaunch = d.bool(forKey: "hideAfterLaunch")
        hideOnEmptyClick = d.bool(forKey: "hideOnEmptyClick")
        iconScale = d.double(forKey: "iconScale")
        showLabels = d.bool(forKey: "showLabels")
        folderPlacement = FolderPlacement(rawValue: d.string(forKey: "folderPlacement") ?? "") ?? .first
        extraFolders = d.stringArray(forKey: "extraFolders") ?? []
        windowFrames = (d.dictionary(forKey: "windowFrames") as? [String: String]) ?? [:]
        if !showInDock && !showInMenuBar { showInMenuBar = true }
    }

    var scanRoots: [URL] {
        AppScanner.defaultRoots + extraFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var solidColor: NSColor {
        get { NSColor(hex: solidColorHex) ?? .black }
        set { solidColorHex = newValue.hexString }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
