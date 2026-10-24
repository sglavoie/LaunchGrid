import AppKit
import Carbon.HIToolbox
import Observation
import LaunchGridCore

enum WindowMode: String, CaseIterable, Identifiable {
    case fullScreen, behindDock, window
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fullScreen: String(localized: "Full Screen")
        case .behindDock: String(localized: "Full Screen with Dock")
        case .window: String(localized: "Window")
        }
    }
}

enum BackgroundStyle: String, CaseIterable, Identifiable {
    case material, wallpaper, glass, solid, image
    var id: String { rawValue }
    var label: String {
        switch self {
        case .material: String(localized: "Blurred Desktop")
        case .wallpaper: String(localized: "Wallpaper")
        case .glass: String(localized: "Liquid Glass")
        case .solid: String(localized: "Solid Colour")
        case .image: String(localized: "Custom Image")
        }
    }
}

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case monochrome, colour
    var id: String { rawValue }
    var label: String {
        switch self {
        case .monochrome: String(localized: "Monochrome")
        case .colour: String(localized: "Colour")
        }
    }
}

/// User settings, persisted in UserDefaults. Grid size lives in the grid itself.
@MainActor @Observable
final class Preferences {
    /// `just scratch` (LAUNCHGRID_DATA_DIR set): a development copy that keeps its own layout
    /// and settings and leaves the installed app's alone.
    nonisolated static let isScratch = ProcessInfo.processInfo.environment["LAUNCHGRID_DATA_DIR"] != nil

    /// The app's settings domain, or the scratch one.
    static var appDefaults: UserDefaults {
        isScratch ? UserDefaults(suiteName: "com.sglavoie.launchgrid.scratch") ?? .standard : .standard
    }

    @ObservationIgnored private let d: UserDefaults

    var hotkeyKeyCode: UInt32 { didSet { d.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode") } }
    var hotkeyModifiers: UInt32 { didSet { d.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers") } }
    var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") } }
    var windowMode: WindowMode { didSet { d.set(windowMode.rawValue, forKey: "windowMode") } }
    var background: BackgroundStyle { didSet { d.set(background.rawValue, forKey: "background") } }
    var solidColorHex: String { didSet { d.set(solidColorHex, forKey: "solidColorHex") } }
    /// Strength of the darkening tint, or for solid backgrounds of the colour's transparency
    /// (`Background.solidOpacity` turns it into an opacity).
    var backgroundOpacity: Double { didSet { d.set(backgroundOpacity, forKey: "backgroundOpacity") } }
    var blurRadius: Double { didSet { d.set(blurRadius, forKey: "blurRadius") } }
    var customImagePath: String? { didSet { d.set(customImagePath, forKey: "customImagePath") } }
    var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    var showInMenuBar: Bool { didSet { d.set(showInMenuBar, forKey: "showInMenuBar") } }
    var menuBarIconStyle: MenuBarIconStyle { didSet { d.set(menuBarIconStyle.rawValue, forKey: "menuBarIconStyle") } }
    var autoAddApps: Bool { didSet { d.set(autoAddApps, forKey: "autoAddApps") } }
    var hideAfterLaunch: Bool { didSet { d.set(hideAfterLaunch, forKey: "hideAfterLaunch") } }
    var hideOnEmptyClick: Bool { didSet { d.set(hideOnEmptyClick, forKey: "hideOnEmptyClick") } }
    /// Hide when switching to another Space, as Launchpad does, rather than follow along.
    var hideOnSpaceChange: Bool { didSet { d.set(hideOnSpaceChange, forKey: "hideOnSpaceChange") } }
    var iconScale: Double { didSet { d.set(iconScale, forKey: "iconScale") } }
    var showLabels: Bool { didSet { d.set(showLabels, forKey: "showLabels") } }
    var folderPlacement: FolderPlacement { didSet { d.set(folderPlacement.rawValue, forKey: "folderPlacement") } }
    var extraFolders: [String] { didSet { d.set(extraFolders, forKey: "extraFolders") } }
    /// Window-mode frames keyed by screen (name + display ID).
    var windowFrames: [String: String] { didSet { d.set(windowFrames, forKey: "windowFrames"); Self.windowFrameWrites += 1 } }
    /// How many times the window frames were written, for the debug scripts.
    nonisolated(unsafe) static var windowFrameWrites = 0

    /// - Parameter defaults: where settings are read and written; tests pass a throwaway suite.
    init(defaults: UserDefaults = Preferences.appDefaults) {
        d = defaults
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
            "menuBarIconStyle": MenuBarIconStyle.monochrome.rawValue,
            "autoAddApps": true,
            "hideAfterLaunch": true,
            "hideOnEmptyClick": true,
            "hideOnSpaceChange": false,
            "iconScale": 1.0,
            "showLabels": true,
            "folderPlacement": FolderPlacement.first.rawValue,
        ])
        // A hand-edited value out of range (`defaults write … -int -1`) falls back to ⌥Space.
        hotkeyKeyCode = UInt32(exactly: d.integer(forKey: "hotkeyKeyCode")) ?? UInt32(kVK_Space)
        hotkeyModifiers = UInt32(exactly: d.integer(forKey: "hotkeyModifiers")) ?? UInt32(optionKey)
        hotkeyEnabled = d.bool(forKey: "hotkeyEnabled")
        windowMode = WindowMode(rawValue: d.string(forKey: "windowMode") ?? "") ?? .fullScreen
        background = BackgroundStyle(rawValue: d.string(forKey: "background") ?? "") ?? .material
        solidColorHex = d.string(forKey: "solidColorHex") ?? "#1E2230"
        backgroundOpacity = d.double(forKey: "backgroundOpacity")
        blurRadius = d.double(forKey: "blurRadius")
        customImagePath = d.string(forKey: "customImagePath")
        showInDock = d.bool(forKey: "showInDock")
        showInMenuBar = d.bool(forKey: "showInMenuBar")
        menuBarIconStyle = MenuBarIconStyle(rawValue: d.string(forKey: "menuBarIconStyle") ?? "") ?? .monochrome
        autoAddApps = d.bool(forKey: "autoAddApps")
        hideAfterLaunch = d.bool(forKey: "hideAfterLaunch")
        hideOnEmptyClick = d.bool(forKey: "hideOnEmptyClick")
        hideOnSpaceChange = d.bool(forKey: "hideOnSpaceChange")
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

    /// WCAG relative luminance, 0 (black) to 1 (white).
    var luminance: Double {
        let c = usingColorSpace(.sRGB) ?? self
        func linear(_ v: CGFloat) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
