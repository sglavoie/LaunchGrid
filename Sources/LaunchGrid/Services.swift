import AppKit
import Carbon.HIToolbox
import CoreServices
import os
import ServiceManagement
import LaunchGridCore

// MARK: - Launching

enum Launcher {
    struct NotFound: LocalizedError {
        var errorDescription: String? { "The app is no longer on this Mac." }
    }

    struct VolumeNotMounted: LocalizedError {
        var volume: String
        var errorDescription: String? { "It's on “\(volume)”, which isn't connected." }
    }

    /// Opens the app at its stored path, falling back to its bundle ID.
    /// Returns the path that was actually launched.
    @MainActor
    static func launch(_ app: AppRef) async throws -> String {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        var failure: Error = NotFound()
        if FileManager.default.fileExists(atPath: app.path) {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: config)
                return app.path
            } catch {
                failure = error
            }
        }
        // An app on a volume that isn't mounted hasn't gone anywhere: say so, rather than open
        // another copy with its bundle ID (Xcode for Xcode-beta).
        if let volume = Volume.unmountedVolume(for: app.path) { throw VolumeNotMounted(volume: volume) }
        // Retry elsewhere only if Launch Services knows another copy.
        if let id = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), url.path != app.path {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return url.path
        }
        throw failure
    }
}

enum Volume {
    /// The name of the volume holding `path` when that volume isn't mounted. Only paths
    /// under /Volumes can be on one that isn't.
    static func unmountedVolume(for path: String) -> String? {
        let parts = (path as NSString).pathComponents
        guard parts.count > 2, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return FileManager.default.fileExists(atPath: "/Volumes/" + parts[2]) ? nil : parts[2]
    }
}

// MARK: - Icons

/// Loads app icons off the main thread and keeps them rendered at grid size.
final class IconProvider: @unchecked Sendable {
    static let shared = IconProvider()
    /// Icons are rendered once at this pixel size and scaled down by SwiftUI.
    static let pixelSize = 256

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "launchgrid.icons", qos: .userInitiated, attributes: .concurrent)
    /// When each cached icon's app was last modified, to spot apps updated in place.
    private let versions = OSAllocatedUnfairLock(initialState: [String: Date]())
    /// Renders under way, so a prewarm and an icon view asking for the same path share one.
    private let inFlight = OSAllocatedUnfairLock(initialState: [String: PendingRender]())

    private final class PendingRender: @unchecked Sendable {
        let done = DispatchGroup()
        var image: NSImage?
    }

    init() {
        cache.countLimit = 2000
        // Each icon is a 256 px RGBA bitmap (256 KB): about 1000 icons.
        cache.totalCostLimit = 256 << 20
    }

    func cached(_ path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    func icon(_ path: String) async -> NSImage {
        if let hit = cached(path) { return hit }
        return await withCheckedContinuation { (cont: CheckedContinuation<SendableImage, Never>) in
            queue.async {
                cont.resume(returning: SendableImage(image: self.render(path)))
            }
        }.image
    }

    /// Renders icons for the given paths in the background so the overlay opens instantly.
    func prewarm(_ paths: [String]) {
        let missing = paths.filter { cached($0) == nil }
        guard !missing.isEmpty else { return }
        queue.async { self.renderAll(missing) }
    }

    /// Renders icons for the given paths and returns once they're all cached.
    func renderAll(_ paths: [String]) {
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            _ = self.render(paths[i])
        }
    }

    func clear() {
        cache.removeAllObjects()
        versions.withLock { $0.removeAll() }
    }

    /// Removes cached icons whose app changed on disk since they were rendered; returns their paths.
    func dropStale(_ paths: [String]) -> [String] {
        let known = versions.withLock { $0 }
        let stale = paths.filter { path in
            guard let rendered = known[path] else { return false }
            return Self.modificationDate(path) != rendered
        }
        for path in stale { cache.removeObject(forKey: path as NSString) }
        versions.withLock { v in for path in stale { v[path] = nil } }
        return stale
    }

    /// An update rewrites the bundle's Info.plist (or replaces the whole bundle).
    private static func modificationDate(_ path: String) -> Date? {
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: path + "/Contents/Info.plist")) ?? (try? fm.attributesOfItem(atPath: path))
        return attrs?[.modificationDate] as? Date
    }

    @discardableResult
    private func render(_ path: String) -> NSImage {
        if let hit = cached(path) { return hit }
        let (pending, isOwner) = inFlight.withLock { map in
            if let pending = map[path] { return (pending, false) }
            let pending = PendingRender()
            pending.done.enter()
            map[path] = pending
            return (pending, true)
        }
        guard isOwner else {
            pending.done.wait()
            return pending.image ?? NSWorkspace.shared.icon(forFile: path)
        }
        let image = draw(path)
        pending.image = image
        inFlight.withLock { $0[path] = nil }
        pending.done.leave()
        return image
    }

    private func draw(_ path: String) -> NSImage {
        let version = Self.modificationDate(path)
        let source = NSWorkspace.shared.icon(forFile: path)
        let px = Self.pixelSize
        let size = NSSize(width: px / 2, height: px / 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return source }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        cache.setObject(image, forKey: path as NSString, cost: rep.bytesPerRow * rep.pixelsHigh)
        versions.withLock { $0[path] = version }
        return image
    }
}

struct SendableImage: @unchecked Sendable {
    let image: NSImage
}

// MARK: - Global hotkey

/// A single global hotkey through Carbon's `RegisterEventHotKey` (no Accessibility permission needed).
@MainActor
final class HotkeyService {
    static let shared = HotkeyService()

    var onTrigger: () -> Void = {}
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4C47_5244), id: 1) // 'LGRD'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { NSLog("LaunchGrid: hotkey registration failed (\(status))") }
        return status == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { HotkeyService.shared.onTrigger() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

enum KeyCombo {
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(Int(keyCode))
    }

    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func keyName(_ code: Int) -> String {
        if let f = functionKeys[code] { return f }
        switch code {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: return characterName(code) ?? "Key \(code)"
        }
    }

    /// The character the key produces on the current keyboard layout.
    static func characterName(_ code: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    /// Known system shortcuts. No public API lists them, so this is a static best effort.
    /// Entries with a symbolic hotkey ID are skipped when the user has turned that shortcut off
    /// or moved it to another key in System Settings.
    static func conflict(keyCode: UInt32, modifiers: UInt32) -> String? {
        let cmd = UInt32(cmdKey), opt = UInt32(optionKey), ctrl = UInt32(controlKey), shift = UInt32(shiftKey)
        let known: [(Int, UInt32, String, Int?)] = [
            (kVK_Space, cmd, "Spotlight", 64),
            (kVK_Space, cmd | opt, "Finder search window", 65),
            (kVK_Space, ctrl, "Select previous input source", 60),
            (kVK_Space, ctrl | opt, "Select next input source", 61),
            (kVK_Space, ctrl | cmd, "Character Viewer", nil),
            (kVK_Tab, cmd, "App Switcher", nil),
            (kVK_ANSI_3, cmd | shift, "Screenshot", 28),
            (kVK_ANSI_4, cmd | shift, "Screenshot selection", 30),
            (kVK_ANSI_5, cmd | shift, "Screenshot toolbar", 184),
            (kVK_ANSI_Q, cmd | ctrl, "Lock Screen", nil),
            (kVK_UpArrow, ctrl, "Mission Control", 32),
            (kVK_DownArrow, ctrl, "Application windows", 33),
            (kVK_F3, 0, "Mission Control", nil),
            (kVK_F11, 0, "Show Desktop", 36),
            (kVK_ANSI_Q, cmd, "Quit (in every app)", nil),
            (kVK_ANSI_W, cmd, "Close Window (in every app)", nil),
        ]
        guard let match = known.first(where: { $0.0 == Int(keyCode) && $0.1 == modifiers }) else { return nil }
        if let id = match.3, !isSystemShortcutActive(id: id, keyCode: keyCode, modifiers: modifiers) { return nil }
        return match.2
    }

    /// Whether macOS still binds symbolic hotkey `id` to this combo. A missing entry means the
    /// default binding, which is on.
    private static func isSystemShortcutActive(id: Int, keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                .dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = all[String(id)] as? [String: Any] else { return true }
        if let enabled = entry["enabled"] as? Bool, !enabled { return false }
        // parameters are [character, key code, NSEvent modifier flags].
        guard let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int], params.count == 3 else { return true }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        let stored = NSEvent.ModifierFlags(rawValue: UInt(params[2])).intersection([.command, .option, .control, .shift])
        return params[1] == Int(keyCode) && stored == flags
    }
}

// MARK: - File system watching

/// FSEvents on the application folders, coalescing bursts into one callback.
/// Callbacks arrive on the main queue only.
final class FolderWatcher: @unchecked Sendable {
    /// Whether a change in directory `path` can matter to a scan. Apps and updaters write deep
    /// inside bundles (caches, frameworks); only a bundle's top level and its `Contents`
    /// (where an update rewrites Info.plist) are worth a rescan.
    static func isRelevant(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard let bundle = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return true }
        let inside = parts.count - bundle - 1
        return inside == 0 || (inside == 1 && parts[bundle + 1] == "Contents")
    }

    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void
    /// The folders being watched: those of `paths` that existed when the watcher was made.
    let paths: [String]

    init(paths: [String], latency: TimeInterval = 2.0, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        self.paths = existing
        guard !existing.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            // No paths means something unusual (e.g. a dropped history); rescan to be safe.
            guard paths.isEmpty || paths.contains(where: FolderWatcher.isRelevant) else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        stream = FSEventStreamCreate(nil, callback, &context, existing as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

// MARK: - Open at login

@MainActor
enum LoginItem {
    /// On, or registered and waiting for the user's approval in System Settings.
    static var isRequested: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "Enabled"
        case .notRegistered: "Off"
        case .requiresApproval: "Needs approval in System Settings › General › Login Items"
        case .notFound: "Unavailable — move LaunchGrid.app to /Applications and reopen it"
        @unknown default: "Unknown"
        }
    }

    struct ScratchRun: LocalizedError {
        var errorDescription: String? { "Not available in a scratch run (LAUNCHGRID_DATA_DIR is set)." }
    }

    static func set(_ on: Bool) throws {
        // A scratch build must not replace the installed copy's login item.
        guard !Preferences.isScratch else { throw ScratchRun() }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
