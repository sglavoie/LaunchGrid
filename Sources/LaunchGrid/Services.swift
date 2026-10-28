import AppKit
import Carbon.HIToolbox
import CoreServices
import os
import ServiceManagement
import LaunchGridCore

// MARK: - Disk

/// Blocking file-system work, run on a dispatch queue rather than Swift's few shared threads:
/// a read stalled on a volume that stopped answering holds a thread there, so launches, scans
/// and everything else async keep going.
enum Disk {
    static func run<T: Sendable>(on queue: DispatchQueue = .global(qos: .userInitiated),
                                 _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

// MARK: - Launching

enum Launcher {
    struct NotFound: LocalizedError {
        var errorDescription: String? { String(localized: "The app is no longer on this Mac.") }
    }

    struct VolumeNotMounted: LocalizedError {
        var volume: String
        var errorDescription: String? { String(localized: "It's on “\(volume)”, which isn't connected.") }
    }

    /// Opens the app at its stored path, falling back to its bundle ID when it's gone from
    /// there. Returns the path that was actually launched, and the app running from it.
    /// - Parameter activates: false opens it behind the grid, which stays up to open more.
    @MainActor
    static func launch(_ app: AppRef, activates: Bool = true) async throws -> (path: String, running: NSRunningApplication) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activates
        // Looked at off the main thread, so a stalled volume doesn't hang the app.
        let path = app.path
        let (exists, unmounted) = await Disk.run {
            (FileManager.default.fileExists(atPath: path), Volume.unmountedVolume(for: path))
        }
        // The app is still there and failed to open (damaged, refused by Gatekeeper, cancelled):
        // that's the answer, not a reason to open another copy with its bundle ID.
        if exists {
            return (app.path, try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: config))
        }
        // An app on a volume that isn't mounted hasn't gone anywhere: say so, rather than open
        // another copy with its bundle ID (Xcode for Xcode-beta).
        if let volume = unmounted { throw VolumeNotMounted(volume: volume) }
        // Retry elsewhere only if Launch Services knows another copy, and not one in the Trash.
        if let id = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
           url.path != app.path, !isInTrash(url.path) {
            return (url.path, try await NSWorkspace.shared.openApplication(at: url, configuration: config))
        }
        throw NotFound()
    }

    /// Brings an app opened behind the grid to the front. Through Launch Services, as opening
    /// it again: an inactive app asking another to activate may be refused.
    @MainActor
    static func bringForward(_ app: NSRunningApplication) {
        guard !app.isTerminated, let url = app.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { NSLog("LaunchGrid: could not bring \(url.path) forward: \(error)") }
        }
    }

    /// Whether `path` is inside a Trash: the home one (~/.Trash) or a volume's (.Trashes).
    nonisolated static func isInTrash(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return [url.pathComponents, url.resolvingSymlinksInPath().pathComponents]
            .contains { $0.contains { $0 == ".Trash" || $0 == ".Trashes" } }
    }

    /// Whether the person cancelled the launch (e.g. in Gatekeeper's "downloaded from the
    /// Internet" prompt): nothing to report.
    nonisolated static func isUserCancel(_ error: Error) -> Bool {
        var next: NSError? = error as NSError
        while let e = next {
            if e.domain == NSCocoaErrorDomain && e.code == NSUserCancelledError { return true }
            if e.domain == NSOSStatusErrorDomain && e.code == Int(userCanceledErr) { return true }
            next = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

enum Volume: Sendable {
    /// The name of the volume holding `path` when that volume isn't mounted. Only paths
    /// under /Volumes can be on one that isn't.
    /// `mounted`, the names in /Volumes when already known, saves looking.
    static func unmountedVolume(for path: String, mounted: Set<String>? = nil) -> String? {
        let parts = (path as NSString).pathComponents
        guard parts.count > 2, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        let there = mounted.map { $0.contains(parts[2]) } ?? FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
        return there ? nil : parts[2]
    }

    /// The names in /Volumes of the volumes mounted. Asked of the system, which works in the
    /// sandbox too, and added to what listing the folder gives; nil when neither can tell.
    static func mountedNames() -> Set<String>? {
        let fm = FileManager.default
        let listed = (try? fm.contentsOfDirectory(atPath: "/Volumes")).map(Set.init)
        guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: []) else { return listed }
        var names = Set(urls.map { ($0.path as NSString).pathComponents }
            .filter { $0.count == 3 && $0[1] == "Volumes" }
            .map { $0[2] })
        // The startup disk is mounted at /, and in /Volumes only as a link to it.
        if let root = urls.first(where: { $0.path == "/" }), let name = try? root.resourceValues(forKeys: [.volumeNameKey]).volumeName {
            names.insert(name)
        }
        return names.union(listed ?? [])
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
    /// Each cached icon's app version, to spot apps updated in place.
    private let versions = OSAllocatedUnfairLock(initialState: [String: String]())
    /// Renders under way, so a prewarm and an icon view asking for the same path share one:
    /// each holds who's waiting for it.
    private let inFlight = OSAllocatedUnfairLock(initialState: [String: [@Sendable (NSImage) -> Void]]())

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
                self.render(path) { cont.resume(returning: SendableImage(image: $0)) }
            }
        }.image
    }

    /// Renders icons for the given paths in the background so the overlay opens instantly.
    func prewarm(_ paths: [String]) {
        let missing = paths.filter { cached($0) == nil }
        guard !missing.isEmpty else { return }
        queue.async { self.renderBlocking(missing) }
    }

    /// Renders icons for the given paths and returns once they're all cached. The rendering
    /// and its waits stay on the icon queue, off Swift's cooperative threads.
    func renderAll(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.renderBlocking(paths)
                cont.resume()
            }
        }
    }

    /// Only on `queue`: blocks until every path is rendered. Paths another render already has
    /// under way are waited for once, at the end, rather than each holding a thread.
    private func renderBlocking(_ paths: [String]) {
        let done = DispatchGroup()
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            done.enter()
            self.render(paths[i]) { _ in done.leave() }
        }
        done.wait()
    }

    /// "Regenerate Icons": draws every icon again, replacing each cached one as its new one is
    /// ready, so icons on screen never fall back to placeholders. Icons of other apps go.
    func regenerate(_ paths: [String]) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                DispatchQueue.concurrentPerform(iterations: paths.count) { i in _ = self.draw(paths[i]) }
                let keep = Set(paths)
                let others = self.versions.withLock { v in
                    let gone = v.keys.filter { !keep.contains($0) }
                    for path in gone { v[path] = nil }
                    return gone
                }
                for path in others { self.cache.removeObject(forKey: path as NSString) }
                cont.resume()
            }
        }
    }

    /// Removes cached icons whose app changed on disk since they were rendered; returns their paths.
    /// The generic icon of an app that was missing when rendered goes stale once the app appears.
    func dropStale(_ paths: [String]) -> [String] {
        let known = versions.withLock { $0 }
        let stale = paths.filter { path in
            guard let rendered = known[path] else { return false }
            return Self.version(path) != rendered
        }
        for path in stale { cache.removeObject(forKey: path as NSString) }
        versions.withLock { v in for path in stale { v[path] = nil } }
        return stale
    }

    /// What an update changes in the bundle's Info.plist: its versions, and the icon's name.
    /// A missing app gets a version of its own, so its icon is still tracked. (Not the file's
    /// modification date: Apple's privacy manifest rules allow no reason for reading other apps'.)
    private static func version(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "missing" }
        let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        return ["CFBundleShortVersionString", "CFBundleVersion", "CFBundleIconFile", "CFBundleIconName"]
            .map { info?[$0] as? String ?? "" }.joined(separator: "|")
    }

    /// Calls `done` with the icon: at once from the cache, else when it's drawn, by this call or
    /// by the render already under way for that path. Never blocks a thread waiting.
    private func render(_ path: String, done: @escaping @Sendable (NSImage) -> Void) {
        if let hit = cached(path) { return done(hit) }
        let isOwner = inFlight.withLock { map in
            if map[path] != nil {
                map[path]?.append(done)
                return false
            }
            map[path] = [done]
            return true
        }
        guard isOwner else { return }
        // Cached before the waiters are taken, so a request in between finds it there.
        let image = draw(path)
        let waiting = inFlight.withLock { $0.removeValue(forKey: path) ?? [] }
        for waiter in waiting { waiter(image) }
    }

    private func draw(_ path: String) -> NSImage {
        let version = Self.version(path)
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
    /// The combo `hotKey` is registered for.
    private(set) var activeCombo: (keyCode: UInt32, modifiers: UInt32)?

    /// Registers the combo in place of the current one. The old one is released only once the
    /// new one is in, so a failure leaves the previous shortcut working.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if hotKey != nil, let active = activeCombo, active.keyCode == keyCode, active.modifiers == modifiers { return true }
        guard installHandlerIfNeeded() else { return false }
        let id = EventHotKeyID(signature: OSType(0x4C47_5244), id: 1) // 'LGRD'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("LaunchGrid: hotkey registration failed (\(status))")
            return false
        }
        unregister()
        hotKey = ref
        activeCombo = (keyCode, modifiers)
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        activeCombo = nil
    }

    /// False when the handler couldn't be installed: a registered hotkey would never fire.
    private func installHandlerIfNeeded() -> Bool {
        guard handler == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { HotkeyService.shared.onTrigger() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else {
            NSLog("LaunchGrid: installing the hotkey handler failed (\(status))")
            handler = nil
            return false
        }
        return true
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

    /// Keypad keys, which would otherwise read the same as the main keys they copy.
    static let keypadKeys: [Int: String] = [
        kVK_ANSI_Keypad0: "0", kVK_ANSI_Keypad1: "1", kVK_ANSI_Keypad2: "2", kVK_ANSI_Keypad3: "3",
        kVK_ANSI_Keypad4: "4", kVK_ANSI_Keypad5: "5", kVK_ANSI_Keypad6: "6", kVK_ANSI_Keypad7: "7",
        kVK_ANSI_Keypad8: "8", kVK_ANSI_Keypad9: "9", kVK_ANSI_KeypadDecimal: ".", kVK_ANSI_KeypadPlus: "+",
        kVK_ANSI_KeypadMinus: "-", kVK_ANSI_KeypadMultiply: "*", kVK_ANSI_KeypadDivide: "/",
        kVK_ANSI_KeypadEquals: "=", kVK_ANSI_KeypadClear: "⌧", kVK_ANSI_KeypadEnter: "⌤",
    ]

    static func keyName(_ code: Int) -> String {
        if let f = functionKeys[code] { return f }
        if let k = keypadKeys[code] { return String(localized: "Keypad \(k)") }
        switch code {
        case kVK_Space: return String(localized: "Space")
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
        default: return characterName(code) ?? String(localized: "Key \(code)")
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

    /// Whether `conflict` names a macOS shortcut that can be turned off in System Settings.
    static func conflictIsSystemSetting(keyCode: UInt32, modifiers: UInt32) -> Bool {
        knownShortcuts.contains { $0.0 == Int(keyCode) && $0.1 == modifiers && $0.3 != nil }
    }

    /// Whether `conflict` can tell a system shortcut turned off in System Settings from one
    /// still on. Not in the sandbox, where the system's shortcut settings can't be read (nor in
    /// the Mac App Store build, which doesn't try): such a conflict may already be resolved.
    static var readsSystemShortcuts: Bool {
        #if APP_STORE
        false
        #else
        !Sandbox.isActive
        #endif
    }

    /// Known system shortcuts. No public API lists them, so this is a static best effort.
    /// Entries with a symbolic hotkey ID are skipped when the user has turned that shortcut off
    /// or moved it to another key in System Settings.
    private static var knownShortcuts: [(Int, UInt32, String, Int?)] {
        let cmd = UInt32(cmdKey), opt = UInt32(optionKey), ctrl = UInt32(controlKey), shift = UInt32(shiftKey)
        return [
            (kVK_Space, cmd, String(localized: "Spotlight"), 64),
            (kVK_Space, cmd | opt, String(localized: "Finder search window"), 65),
            (kVK_Space, ctrl, String(localized: "Select previous input source"), 60),
            (kVK_Space, ctrl | opt, String(localized: "Select next input source"), 61),
            (kVK_Space, ctrl | cmd, String(localized: "Character Viewer"), nil),
            (kVK_Tab, cmd, String(localized: "App Switcher"), nil),
            (kVK_ANSI_3, cmd | shift, String(localized: "Screenshot"), 28),
            (kVK_ANSI_4, cmd | shift, String(localized: "Screenshot selection"), 30),
            (kVK_ANSI_5, cmd | shift, String(localized: "Screenshot toolbar"), 184),
            (kVK_ANSI_Q, cmd | ctrl, String(localized: "Lock Screen"), nil),
            (kVK_UpArrow, ctrl, String(localized: "Mission Control"), 32),
            (kVK_DownArrow, ctrl, String(localized: "Application windows"), 33),
            (kVK_F3, 0, String(localized: "Mission Control"), nil),
            (kVK_F11, 0, String(localized: "Show Desktop"), 36),
            (kVK_ANSI_Q, cmd, String(localized: "Quit (in every app)"), nil),
            (kVK_ANSI_W, cmd, String(localized: "Close Window (in every app)"), nil),
        ]
    }

    static func conflict(keyCode: UInt32, modifiers: UInt32) -> String? {
        let cmd = UInt32(cmdKey), opt = UInt32(optionKey), shift = UInt32(shiftKey)
        if let match = knownShortcuts.first(where: { $0.0 == Int(keyCode) && $0.1 == modifiers }) {
            if let id = match.3, !isSystemShortcutActive(id: id, keyCode: keyCode, modifiers: modifiers) { return nil }
            return match.2
        }
        // A global shortcut takes the key from every app, so these stop working everywhere.
        if modifiers == cmd, let command = commonCommands[Int(keyCode)] { return String(localized: "\(command) (in most apps)") }
        if modifiers == opt || modifiers == opt | shift, printableKeys.contains(Int(keyCode)) {
            return String(localized: "typing special characters (⌥ with this key types an accent or symbol)")
        }
        return nil
    }

    /// ⌘ shortcuts that nearly every app uses for editing and documents.
    static let commonCommands: [Int: String] = [
        kVK_ANSI_A: String(localized: "Select All"), kVK_ANSI_C: String(localized: "Copy"), kVK_ANSI_V: String(localized: "Paste"), kVK_ANSI_X: String(localized: "Cut"),
        kVK_ANSI_Z: String(localized: "Undo"), kVK_ANSI_S: String(localized: "Save"), kVK_ANSI_F: String(localized: "Find"), kVK_ANSI_G: String(localized: "Find Next"),
        kVK_ANSI_P: String(localized: "Print"), kVK_ANSI_N: String(localized: "New"), kVK_ANSI_T: String(localized: "New Tab"), kVK_ANSI_O: String(localized: "Open"),
        kVK_ANSI_H: String(localized: "Hide"), kVK_ANSI_M: String(localized: "Minimize"), kVK_ANSI_B: String(localized: "Bold"), kVK_ANSI_I: String(localized: "Italic"),
        kVK_ANSI_U: String(localized: "Underline"), kVK_ANSI_R: String(localized: "Reload"), kVK_ANSI_L: String(localized: "Go to Address"),
        kVK_ANSI_Comma: String(localized: "Settings"), kVK_ANSI_Grave: String(localized: "Cycle Windows"),
    ]

    /// Keys that type a character: with ⌥ (or ⌥⇧) alone they type accents and symbols. Space
    /// isn't one of them, so the default ⌥Space stays quiet.
    static let printableKeys: Set<Int> = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
        kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
        kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
        kVK_ANSI_Y, kVK_ANSI_Z,
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
        kVK_ANSI_8, kVK_ANSI_9,
        kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Backslash,
        kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash, kVK_ANSI_Grave,
        kVK_ISO_Section,
    ]

    /// Whether macOS still binds symbolic hotkey `id` to this combo. A missing entry means the
    /// default binding, which is on.
    private static func isSystemShortcutActive(id: Int, keyCode: UInt32, modifiers: UInt32) -> Bool {
        #if APP_STORE
        return true
        #else
        guard readsSystemShortcuts, let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
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
        #endif
    }
}

// MARK: - File system watching

/// FSEvents on the application folders, coalescing bursts into one callback.
/// Callbacks arrive on the main queue only.
final class FolderWatcher: @unchecked Sendable {
    /// Whether a change in directory `path` can matter to a scan. Apps and updaters write deep
    /// inside bundles (caches, frameworks); only a bundle's top level and its `Contents`
    /// (where an update rewrites Info.plist) are worth a rescan. Under one of `roots`, neither
    /// are hidden folders nor ones deeper than the scan reads (`maxDepth`), so a busy extra
    /// folder (Downloads, a project with `.git`) doesn't rescan at every write.
    static func isRelevant(_ path: String, roots: [String] = [], maxDepth: Int = 3) -> Bool {
        let parts = path.split(separator: "/")
        let root = roots.map { $0.split(separator: "/") }
            .filter { $0.count <= parts.count && parts.starts(with: $0) }
            .max { $0.count < $1.count }
        // A root can itself be inside a bundle (Xcode.app/Contents/Applications): only a bundle
        // below it counts.
        let bundle = parts[(root?.count ?? 0)...].firstIndex(where: { $0.lowercased().hasSuffix(".app") })
        if let root {
            // The folders between the root and the change (or the bundle it is in).
            let below = parts[root.count..<(bundle ?? parts.count)]
            if below.contains(where: { $0.hasPrefix(".") }) || below.count >= maxDepth { return false }
        }
        guard let bundle else { return true }
        let inside = parts.count - bundle - 1
        return inside == 0 || (inside == 1 && parts[bundle + 1] == "Contents")
    }

    /// `paths` with symlinks resolved too. On a volume that has stopped answering this can
    /// take a while, so it's read off the main thread.
    nonisolated static func resolve(_ paths: [String]) -> [String] {
        paths + paths.compactMap { path in
            guard let real = realpath(path, nil) else { return nil }
            defer { free(real) }
            let s = String(cString: real)
            return s == path ? nil : s
        }
    }

    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void
    /// The folders being watched. One that doesn't exist yet is watched too: with
    /// `kFSEventStreamCreateFlagWatchRoot`, creating it (a first app in ~/Applications, a
    /// volume mounting) is an event, and so is what lands in it afterwards.
    let paths: [String]
    /// `paths` as given and with symlinks resolved, as FSEvents reports them (/private/tmp for /tmp).
    private let realPaths: [String]

    /// `realPaths` from `resolve(paths)`, read off the main thread: without it they are read here.
    init(paths: [String], realPaths: [String]? = nil, latency: TimeInterval = 2.0, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        self.paths = paths
        self.realPaths = realPaths ?? Self.resolve(paths)
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            // No paths means something unusual (e.g. a dropped history); rescan to be safe.
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            guard paths.isEmpty || paths.contains(where: { FolderWatcher.isRelevant($0, roots: watcher.realPaths) }) else { return }
            MainActor.assumeIsolated { watcher.onChange() }
        }
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
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

// MARK: - Sandbox file access

/// Keeps access, across launches, to what the person picked in a panel: extra scan folders,
/// a custom background picture and apps added from elsewhere. Only the sandboxed (Mac App
/// Store) build needs it; in the other, every call does nothing.
@MainActor
enum FileAccess {
    /// What the sandbox calls do. Tests, which run outside the sandbox, swap in their own.
    @MainActor struct Backend {
        var isActive: () -> Bool
        var defaults: () -> UserDefaults
        var bookmark: (URL) -> Data?
        /// Resolves a bookmark and starts using it: nil when it can't be resolved or used.
        var open: (Data) -> (url: URL, stale: Bool)?
        var close: (URL) -> Void
        /// `open`, safe to call off the main thread, where the system's calls go: resolving a
        /// bookmark to a volume that has stopped answering would otherwise hang the app. Without
        /// it (the tests), bookmarks are resolved on the main thread.
        var openOffMain: (@Sendable (Data) -> Opened?)?

        static var system: Backend { Backend(
            isActive: { Sandbox.isActive },
            defaults: { Preferences.appDefaults },
            bookmark: { url in
                try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                      includingResourceValuesForKeys: nil, relativeTo: nil)
            },
            open: { data in
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutMounting], bookmarkDataIsStale: &stale),
                      url.startAccessingSecurityScopedResource() else { return nil }
                return (url, stale)
            },
            close: { $0.stopAccessingSecurityScopedResource() },
            openOffMain: { data in
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutMounting], bookmarkDataIsStale: &stale),
                      url.startAccessingSecurityScopedResource() else { return nil }
                return Opened(url: url, stale: stale)
            }
        ) }
    }

    /// A bookmark resolved and started, and whether it should be made again.
    struct Opened: Sendable {
        var url: URL
        var stale: Bool
    }

    static var backend = Backend.system
    private static let key = "bookmarks"
    /// Bookmarked items in use, by the path they were picked at (or have moved to since).
    private static var granted: [String: URL] = [:]
    /// Called when an item just picked couldn't be bookmarked: access to it ends when
    /// LaunchGrid quits.
    static var onBookmarkFailure: (URL) -> Void = { _ in }

    /// Whether access to `path` is held, for the tests.
    static func isGranted(_ path: String) -> Bool { granted[path] != nil }

    /// Ends the access held and goes back to the system's calls, for the tests.
    static func reset() {
        for url in granted.values { backend.close(url) }
        granted = [:]
        backend = .system
    }

    private static var saved: [String: Data] {
        get { backend.defaults().dictionary(forKey: key) as? [String: Data] ?? [:] }
        set { backend.defaults().set(newValue, forKey: key) }
    }

    /// Starts using the saved bookmarks not yet in use. At launch, and when a volume mounts:
    /// a bookmark to an unmounted volume only resolves once it's back. An item renamed or
    /// moved since it was picked is followed: its bookmark and the setting naming it (an extra
    /// folder, the background picture) take its new path. Returns the moves, old path to new,
    /// for the grid to follow apps added with Browse.
    @discardableResult
    static func restore(prefs: Preferences) -> [String: String] {
        guard backend.isActive() else { return [:] }
        let opened = pending.compactMapValues { backend.open($0).map { Opened(url: $0.url, stale: $0.stale) } }
        return use(opened, prefs: prefs)
    }

    /// `restore`, resolving the bookmarks off the main thread.
    static func restoreInBackground(prefs: Preferences) async -> [String: String] {
        guard backend.isActive() else { return [:] }
        guard let open = backend.openOffMain else { return restore(prefs: prefs) }
        let pending = pending
        let opened = await Disk.run { pending.compactMapValues(open) }
        return use(opened, prefs: prefs)
    }

    /// The saved bookmarks not in use.
    private static var pending: [String: Data] { saved.filter { granted[$0.key] == nil } }

    /// Starts using the bookmarks `opened`, by the path each was saved under, as `restore` does.
    private static func use(_ opened: [String: Opened], prefs: Preferences) -> [String: String] {
        let original = saved
        var saved = original
        var moves: [String: String] = [:]
        let usable = opened.filter { path, opened in
            // Taken into use meanwhile (resolved twice), or forgotten while it was resolved.
            guard granted[path] == nil, original[path] != nil else {
                backend.close(opened.url)
                return false
            }
            let now = opened.url.standardizedFileURL.path
            // Not into the Trash: that's on its way out, and the setting is better left as it was.
            if now != URL(fileURLWithPath: path).standardizedFileURL.path, !Launcher.isInTrash(now) {
                moves[path] = now
            }
            return true
        }
        // Vacate every old path before assigning destinations. Otherwise A → B followed by
        // B → C (or B → A) mistakes B's moving bookmark for an existing bookmark of A.
        for path in moves.keys { saved[path] = nil }
        for (path, opened) in usable {
            let (url, stale) = (opened.url, opened.stale)
            if let now = moves[path] {
                if saved[now] == nil {
                    saved[now] = backend.bookmark(url) ?? original[path]
                    granted[now] = url
                } else {
                    // Picked again at its new place: that bookmark has its own access.
                    backend.close(url)
                }
                NSLog("LaunchGrid: \(path) moved to \(now); following it")
                continue
            }
            granted[path] = url
            if stale, let fresh = backend.bookmark(url) { saved[path] = fresh }
        }
        self.saved = saved
        migrate(prefs, moves: moves)
        return moves
    }

    /// Resolves the bookmark kept for `path` again, after it was seen to move while in use
    /// (launching it opened a copy elsewhere): access held for the old path doesn't follow
    /// the move, and the bookmark must be filed under the new path, or the next save forgets
    /// it as no longer used. Returns the moves found, as `restore` does.
    static func follow(_ path: String, prefs: Preferences) -> [String: String] {
        guard backend.isActive(), let url = granted.removeValue(forKey: path) else { return [:] }
        backend.close(url)
        return restore(prefs: prefs)
    }

    /// `follow`, resolving the bookmarks off the main thread.
    static func followInBackground(_ path: String, prefs: Preferences) async -> [String: String] {
        guard backend.isActive(), let url = granted.removeValue(forKey: path) else { return [:] }
        backend.close(url)
        return await restoreInBackground(prefs: prefs)
    }

    /// Ends the access held to items on volumes no longer mounted (`mounted`, the names in
    /// /Volumes): it lapsed with the volume. When the volume comes back, `restore` resolves
    /// their bookmarks again, and follows them if it mounts under another name ("Ext 1").
    static func releaseUnmounted(mounted: Set<String>?) {
        guard backend.isActive() else { return }
        for path in granted.keys where Volume.unmountedVolume(for: path, mounted: mounted) != nil {
            if let url = granted.removeValue(forKey: path) { backend.close(url) }
        }
    }

    /// Whether `path` would be followed through a bookmark resolved off the main thread.
    static func followsInBackground(_ path: String) -> Bool {
        backend.isActive() && backend.openOffMain != nil && granted[path] != nil
    }

    /// For a scan to resolve off the main thread, with `reopenOffMain`, what `followVanished`
    /// takes: the bookmarks in use, by path. Nil when they are resolved on the main thread.
    static var bookmarksInUse: (bookmarks: [String: Data], open: @Sendable (Data) -> Opened?)? {
        guard backend.isActive(), let open = backend.openOffMain else { return nil }
        return (saved.filter { granted[$0.key] != nil }, open)
    }

    /// `follow` for each of `paths`, apps a scan found gone, that has a bookmark in use: one
    /// added with Browse and moved while LaunchGrid ran is followed rather than pruned.
    /// `reopened` holds their bookmarks as a scan resolved them again (`bookmarksInUse`).
    static func followVanished(_ paths: some Sequence<String>, prefs: Preferences, reopened: [String: Opened]? = nil) -> [String: String] {
        guard backend.isActive() else { return [:] }
        guard let reopened else {
            var moves: [String: String] = [:]
            for path in paths where granted[path] != nil {
                moves.merge(follow(path, prefs: prefs)) { found, _ in found }
            }
            return moves
        }
        var followed: [String: Opened] = [:]
        for path in Set(paths) {
            guard let url = granted.removeValue(forKey: path) else { continue }
            backend.close(url)
            followed[path] = reopened[path]
        }
        // Resolved for apps that weren't gone after all, or no longer in use: not needed.
        for (path, opened) in reopened where followed[path] == nil { backend.close(opened.url) }
        return use(followed, prefs: prefs)
    }

    /// Points the settings naming `old` (an extra scan folder, the background picture) at `new`.
    static func migrate(_ prefs: Preferences, from old: String, to new: String) {
        migrate(prefs, moves: [old: new])
    }

    /// All paths refer to the same snapshot: a setting follows its own item once, even when
    /// that item's destination is another item's old path.
    private static func migrate(_ prefs: Preferences, moves: [String: String]) {
        var folders = prefs.extraFolders.map { moves[$0] ?? $0 }
        if folders != prefs.extraFolders {
            var seen = Set<String>()
            folders = folders.filter { seen.insert($0).inserted }
            prefs.extraFolders = folders
        }
        if let old = prefs.customImagePath, let new = moves[old] { prefs.customImagePath = new }
    }

    /// Remembers an item just picked in a panel. False, after telling `onBookmarkFailure`,
    /// when it couldn't be bookmarked, so access to it won't outlast this run.
    @discardableResult
    static func remember(_ url: URL) -> Bool {
        guard backend.isActive(), granted[url.path] == nil else { return true }
        guard let data = backend.bookmark(url) else {
            NSLog("LaunchGrid: could not bookmark \(url.path); access ends when LaunchGrid quits")
            onBookmarkFailure(url)
            return false
        }
        saved[url.path] = data
        // Through the bookmark just made: the URL can be one built from a path (an app picked
        // with Browse), whose own access can't be started, and then a move while LaunchGrid
        // runs couldn't be followed.
        if let (scoped, _) = backend.open(data) { granted[url.path] = scoped }
        return true
    }

    static func forget(_ path: String) {
        guard backend.isActive() else { return }
        if let url = granted.removeValue(forKey: path) { backend.close(url) }
        saved[path] = nil
    }

    /// Forgets the bookmarks of apps added with Browse that are no longer in `inUse`.
    static func forgetApps(notIn inUse: Set<String>) {
        guard backend.isActive() else { return }
        for path in unusedApps(among: saved.keys, inUse: inUse) { forget(path) }
    }

    /// The app bundles among `bookmarked` that aren't in `inUse`. Folders and pictures are
    /// forgotten when their setting changes, not here.
    nonisolated static func unusedApps(among bookmarked: some Sequence<String>, inUse: Set<String>) -> [String] {
        bookmarked.filter { ($0 as NSString).pathExtension.lowercased() == "app" && !inUse.contains($0) }.sorted()
    }
}

// MARK: - Open at login

@MainActor
enum LoginItem {
    private static var status: SMAppService.Status {
        #if !APP_STORE
        // For the debug scripts, which can't get a login item approved or refused.
        if ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_LOGIN_STATUS"] == "requiresApproval" { return .requiresApproval }
        #endif
        return SMAppService.mainApp.status
    }

    /// On, or registered and waiting for the user's approval in System Settings.
    static var isRequested: Bool {
        [.enabled, .requiresApproval].contains(status)
    }

    /// Registered, but waiting for the user to allow it in System Settings.
    static var needsApproval: Bool {
        status == .requiresApproval
    }

    /// System Settings › General › Login Items, where a login item waiting for approval is allowed.
    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static var statusDescription: String {
        switch status {
        case .enabled: String(localized: "Enabled")
        case .notRegistered: String(localized: "Off")
        case .requiresApproval: String(localized: "Needs approval in System Settings › General › Login Items")
        case .notFound: String(localized: "Unavailable — move LaunchGrid.app to /Applications and reopen it")
        @unknown default: String(localized: "Unknown")
        }
    }

    struct ScratchRun: LocalizedError {
        var errorDescription: String? { String(localized: "Not available in a scratch run (LAUNCHGRID_DATA_DIR is set).") }
    }

    static func set(_ on: Bool) throws {
        // A scratch build must not replace the installed copy's login item.
        guard !Preferences.isScratch else { throw ScratchRun() }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
