import Foundation

/// A pane of System Settings that search can open: "bluetooth" or "dark mode" finds it, and
/// opening it hands its `x-apple.systempreferences:` link to System Settings. Nothing is looked
/// up: the list is here, and the app keeps only the panes this Mac has (`available(in:)`).
public struct SettingsPane: Equatable, Sendable, Identifiable {
    /// The pane's extension bundle ID, which its link names.
    public let id: String
    /// Its name, in English: `localizedName` is what's shown.
    public let name: String
    /// Other words for it, searched as its name is ("dark mode" for Appearance).
    public let keywords: [String]
    /// The SF Symbol on its tile.
    public let symbol: String
    /// Its tile's colour, as in System Settings' sidebar: red, green and blue, 0 to 1.
    public let color: (Double, Double, Double)

    public static func == (a: SettingsPane, b: SettingsPane) -> Bool { a.id == b.id }

    public var url: String { "x-apple.systempreferences:" + id }

    public var localizedName: String { Bundle.main.localizedString(forKey: name, value: name, table: "SettingsPanes") }

    /// A steady ID for the pane as a search result, the same from launch to launch, so what's
    /// opened most (`Usage`) is remembered by it.
    public var uuid: UUID { Self.uuid(for: id) }

    /// The pane as a search-only link action, which the grid's views know how to show. It's in
    /// no layout: opening it goes through `SettingsPane.pane(for:)`, never the grid.
    public var action: Action {
        Action(id: uuid, name: localizedName, keywords: [], icon: .symbol(symbol),
               kind: .openURL(template: url), showsOnGrid: false)
    }

    /// The pane a search result's ID stands for, if it is one.
    public static func pane(for uuid: UUID) -> SettingsPane? { byUUID[uuid] }

    private static let byUUID: [UUID: SettingsPane] = Dictionary(uniqueKeysWithValues: all.map { ($0.uuid, $0) })

    /// The panes in `panes` matching `query`, best first: only names or other words it starts
    /// (or starts a word of), never a letter here and there, so they don't crowd out apps.
    /// Nothing for a single letter.
    public static func matches(_ query: String, in panes: [SettingsPane] = all, limit: Int = 4) -> [SettingsPane] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let scored = panes.compactMap { pane -> (SettingsPane, Int)? in
            let names = [pane.localizedName, pane.name] + pane.keywords
            // Another word for it ranks a little below its name.
            let best = names.enumerated().compactMap { i, n in
                Search.score(n, query: q).map { i < 2 ? $0 : $0 - 25 }
            }.max()
            guard let best, best >= 650 - 25 else { return nil }
            return (pane, best)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.localizedName < $1.0.localizedName }
            .prefix(limit).map(\.0)
    }

    /// The panes whose extension is among `installed` (bundle IDs found on this Mac); all of
    /// them when that's empty, as when the folder couldn't be read.
    public static func available(in installed: Set<String>) -> [SettingsPane] {
        installed.isEmpty ? all : all.filter { installed.contains($0.id) }
    }

    /// A name-based UUID (FNV-1a over the pane's ID, twice with different seeds).
    static func uuid(for id: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in ("settings-pane:" + id).utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            return h
        }
        let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4)
        var bytes = withUnsafeBytes(of: a.bigEndian, Array.init) + withUnsafeBytes(of: b.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static let blue = (0.04, 0.48, 1.0), gray = (0.56, 0.56, 0.58), red = (1.0, 0.23, 0.19)
    private static let indigo = (0.35, 0.34, 0.84), green = (0.2, 0.78, 0.35), dark = (0.17, 0.17, 0.18)
    private static let pink = (1.0, 0.18, 0.33), cyan = (0.2, 0.68, 0.9), orange = (1.0, 0.58, 0.0)

    public static let all: [SettingsPane] = [
        SettingsPane(id: "com.apple.systempreferences.AppleIDSettings", name: "Apple Account",
                     keywords: ["iCloud", "Apple ID", "Media and Purchases"], symbol: "person.crop.circle.fill", color: blue),
        SettingsPane(id: "com.apple.wifi-settings-extension", name: "Wi-Fi",
                     keywords: ["Wireless", "WLAN", "Internet"], symbol: "wifi", color: blue),
        SettingsPane(id: "com.apple.BluetoothSettings", name: "Bluetooth",
                     keywords: ["AirPods", "Headphones", "Pairing"], symbol: "dot.radiowaves.left.and.right", color: blue),
        SettingsPane(id: "com.apple.Network-Settings.extension", name: "Network",
                     keywords: ["Ethernet", "DNS", "Proxy", "Firewall", "Internet"], symbol: "network", color: blue),
        SettingsPane(id: "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", name: "VPN",
                     keywords: [], symbol: "network.badge.shield.half.filled", color: blue),
        SettingsPane(id: "com.apple.Battery-Settings.extension", name: "Battery",
                     keywords: ["Energy", "Power", "Low Power Mode", "Energy Saver"], symbol: "battery.100percent", color: green),
        SettingsPane(id: "com.apple.systempreferences.GeneralSettings", name: "General",
                     keywords: [], symbol: "gearshape.fill", color: gray),
        SettingsPane(id: "com.apple.SystemProfiler.AboutExtension", name: "About",
                     keywords: ["About This Mac", "Serial Number", "macOS Version", "System Report"], symbol: "info.circle.fill", color: gray),
        SettingsPane(id: "com.apple.Software-Update-Settings.extension", name: "Software Update",
                     keywords: ["Upgrade", "macOS Update"], symbol: "arrow.down.circle.fill", color: gray),
        SettingsPane(id: "com.apple.settings.Storage", name: "Storage",
                     keywords: ["Disk Space", "Free Space"], symbol: "internaldrive.fill", color: gray),
        SettingsPane(id: "com.apple.AirDrop-Handoff-Settings.extension", name: "AirDrop & Handoff",
                     keywords: ["AirPlay Receiver", "Continuity"], symbol: "airplayaudio", color: gray),
        SettingsPane(id: "com.apple.LoginItems-Settings.extension", name: "Login Items & Extensions",
                     keywords: ["Startup Items", "Open at Login", "Background Items"], symbol: "list.bullet.rectangle.fill", color: gray),
        SettingsPane(id: "com.apple.Localization-Settings.extension", name: "Language & Region",
                     keywords: ["Locale", "Date Format", "Temperature Unit"], symbol: "globe", color: gray),
        SettingsPane(id: "com.apple.Date-Time-Settings.extension", name: "Date & Time",
                     keywords: ["Time Zone", "Clock", "24-Hour Time"], symbol: "clock.fill", color: gray),
        SettingsPane(id: "com.apple.Sharing-Settings.extension", name: "Sharing",
                     keywords: ["Screen Sharing", "File Sharing", "Remote Login", "Computer Name", "SSH"], symbol: "person.2.wave.2.fill", color: gray),
        SettingsPane(id: "com.apple.Time-Machine-Settings.extension", name: "Time Machine",
                     keywords: ["Backup"], symbol: "clock.arrow.circlepath", color: gray),
        SettingsPane(id: "com.apple.Transfer-Reset-Settings.extension", name: "Transfer or Reset",
                     keywords: ["Erase", "Factory Reset", "Migration"], symbol: "arrow.counterclockwise", color: gray),
        SettingsPane(id: "com.apple.Startup-Disk-Settings.extension", name: "Startup Disk",
                     keywords: ["Boot"], symbol: "internaldrive", color: gray),
        SettingsPane(id: "com.apple.Accessibility-Settings.extension", name: "Accessibility",
                     keywords: ["VoiceOver", "Zoom", "Reduce Motion", "Increase Contrast", "Reduce Transparency"], symbol: "accessibility", color: blue),
        SettingsPane(id: "com.apple.Appearance-Settings.extension", name: "Appearance",
                     keywords: ["Dark Mode", "Light Mode", "Accent Color", "Theme", "Icon Style"], symbol: "circle.lefthalf.filled", color: dark),
        SettingsPane(id: "com.apple.ControlCenter-Settings.extension", name: "Control Center",
                     keywords: ["Menu Bar"], symbol: "switch.2", color: gray),
        SettingsPane(id: "com.apple.Siri-Settings.extension", name: "Apple Intelligence & Siri",
                     keywords: ["Siri"], symbol: "sparkles", color: indigo),
        SettingsPane(id: "com.apple.Spotlight-Settings.extension", name: "Spotlight",
                     keywords: [], symbol: "magnifyingglass", color: gray),
        SettingsPane(id: "com.apple.settings.PrivacySecurity.extension", name: "Privacy & Security",
                     keywords: ["Permissions", "Camera", "Microphone", "Location Services", "Full Disk Access", "FileVault", "Input Monitoring", "Screen Recording"],
                     symbol: "hand.raised.fill", color: blue),
        SettingsPane(id: "com.apple.Desktop-Settings.extension", name: "Desktop & Dock",
                     keywords: ["Dock", "Mission Control", "Hot Corners", "Stage Manager", "Windows"], symbol: "dock.rectangle", color: dark),
        SettingsPane(id: "com.apple.Displays-Settings.extension", name: "Displays",
                     keywords: ["Monitor", "Resolution", "Brightness", "Night Shift", "Screen"], symbol: "sun.max.fill", color: blue),
        SettingsPane(id: "com.apple.Wallpaper-Settings.extension", name: "Wallpaper",
                     keywords: ["Desktop Picture", "Background"], symbol: "photo.fill", color: cyan),
        SettingsPane(id: "com.apple.Notifications-Settings.extension", name: "Notifications",
                     keywords: ["Alerts", "Banners"], symbol: "bell.badge.fill", color: red),
        SettingsPane(id: "com.apple.Sound-Settings.extension", name: "Sound",
                     keywords: ["Volume", "Audio Output", "Microphone Input", "Alert Sound"], symbol: "speaker.wave.2.fill", color: pink),
        SettingsPane(id: "com.apple.Focus-Settings.extension", name: "Focus",
                     keywords: ["Do Not Disturb", "DND"], symbol: "moon.fill", color: indigo),
        SettingsPane(id: "com.apple.Screen-Time-Settings.extension", name: "Screen Time",
                     keywords: ["Parental Controls", "App Limits"], symbol: "hourglass", color: indigo),
        SettingsPane(id: "com.apple.Lock-Screen-Settings.extension", name: "Lock Screen",
                     keywords: ["Screen Saver", "Sleep", "Require Password"], symbol: "lock.fill", color: dark),
        SettingsPane(id: "com.apple.Touch-ID-Settings.extension", name: "Touch ID & Password",
                     keywords: ["Fingerprint", "Login Password"], symbol: "touchid", color: pink),
        SettingsPane(id: "com.apple.Users-Groups-Settings.extension", name: "Users & Groups",
                     keywords: ["Accounts", "Guest User"], symbol: "person.2.fill", color: blue),
        SettingsPane(id: "com.apple.Internet-Accounts-Settings.extension", name: "Internet Accounts",
                     keywords: ["Mail Accounts", "Google", "Exchange", "Calendar Accounts"], symbol: "at", color: blue),
        SettingsPane(id: "com.apple.Game-Center-Settings.extension", name: "Game Center",
                     keywords: [], symbol: "gamecontroller.fill", color: gray),
        SettingsPane(id: "com.apple.Game-Controller-Settings.extension", name: "Game Controllers",
                     keywords: ["Gamepad", "Joystick"], symbol: "gamecontroller", color: gray),
        SettingsPane(id: "com.apple.WalletSettingsExtension", name: "Wallet & Apple Pay",
                     keywords: ["Apple Pay", "Cards"], symbol: "wallet.pass.fill", color: dark),
        SettingsPane(id: "com.apple.Keyboard-Settings.extension", name: "Keyboard",
                     keywords: ["Keyboard Shortcuts", "Input Sources", "Dictation", "Key Repeat", "Text Replacements"], symbol: "keyboard.fill", color: gray),
        SettingsPane(id: "com.apple.Mouse-Settings.extension", name: "Mouse",
                     keywords: ["Pointer Speed", "Scrolling"], symbol: "computermouse.fill", color: gray),
        SettingsPane(id: "com.apple.Trackpad-Settings.extension", name: "Trackpad",
                     keywords: ["Gestures", "Tap to Click", "Natural Scrolling"], symbol: "hand.point.up.left.fill", color: gray),
        SettingsPane(id: "com.apple.Print-Scan-Settings.extension", name: "Printers & Scanners",
                     keywords: ["Printer", "Scanner"], symbol: "printer.fill", color: gray),
        SettingsPane(id: "com.apple.Family-Settings.extension", name: "Family",
                     keywords: ["Family Sharing"], symbol: "figure.2.and.child.holdinghands", color: orange),
    ]
}
