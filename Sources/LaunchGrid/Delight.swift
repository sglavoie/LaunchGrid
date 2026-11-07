import AppKit
import SwiftUI
import LaunchGridCore

// Small things that make the grid feel finished: one glass surface for everything that floats
// over it, the keyboard focus gliding from tile to tile, the Calendar and Clock icons showing
// today's date and the time as the Dock's do, answers shown as cards, the apps you open around
// this time of day, and System Settings panes found by search.

// MARK: - Glass

/// What floats over the grid (the search field, buttons, messages, tips, the open folder) on
/// one surface: Liquid Glass from macOS 26, a material before it. With Increase Contrast,
/// a clear edge.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let high = contrast == .increased
        Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.ultraThinMaterial, in: shape)
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(high ? 0.55 : 0.12), lineWidth: high ? 1 : 0.5))
    }
}

extension View {
    func glassSurface<S: InsettableShape>(_ shape: S) -> some View {
        modifier(GlassSurface(shape: shape))
    }
}

// MARK: - Keyboard focus

/// The keyboard focus: a soft glow in the focused icon's own colour with a light edge, one for
/// the whole grid, so it glides from tile to tile as the arrow keys move it instead of jumping.
/// With Increase Contrast, a bold edge with a dark rim, readable on any background.
struct FocusHalo: View {
    let center: CGPoint
    let size: CGSize
    let tint: Color?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.reduceMotion) private var reduceMotion

    static let cornerRadius: CGFloat = 16

    var body: some View {
        let high = contrast == .increased
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let glow = tint ?? .white
        shape
            .fill(RadialGradient(colors: [glow.opacity(high ? 0.45 : 0.34), glow.opacity(high ? 0.2 : 0.08)],
                                 center: .center, startRadius: 0, endRadius: max(size.width, size.height) * 0.6))
            .overlay(shape.fill(.white.opacity(high ? 0.16 : 0.07)))
            .overlay(shape.strokeBorder(.white.opacity(high ? 1 : 0.75), lineWidth: high ? 3 : 1.5))
            .overlay(shape.inset(by: -1).strokeBorder(.black.opacity(high ? 0.7 : 0.3), lineWidth: 1))
            .shadow(color: glow.opacity(high ? 0 : 0.45), radius: 10)
            .frame(width: size.width, height: size.height)
            .position(center)
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.82), value: center)
            .animation(.easeOut(duration: 0.2), value: tint)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
    }

    /// Around a tile of `iconSize` in a cell of `cell`: the icon, its name under it when shown,
    /// and a margin, never wider than the cell.
    /// `caption`: a second line under the name (a search result's argument or kind).
    static func size(iconSize: CGFloat, labels: Bool, cell: CGSize, caption: Bool = false) -> CGSize {
        let height = iconSize + 14 + (labels ? GridLayout.labelHeight(iconSize: iconSize) + (caption ? 12 : 0) : 0)
        return CGSize(width: min(cell.width - 4, max(iconSize * 1.38, iconSize + 20)), height: min(cell.height, height))
    }
}

// MARK: - Lift

extension EnvironmentValues {
    /// How a tile is held: lifted under the pointer (1), pressed in (-1) or at rest (0), for
    /// its icon's shadow (`TileMotion` sets it, `ItemView` draws it).
    @Entry var tileLift: Int = 0
}

/// The soft shadow under an icon, which spreads and drops as the tile lifts under the
/// pointer and tightens as it's pressed, so the lift reads as height. One blurred picture
/// made once and scaled, rather than a shadow worked out for every icon on every frame, which
/// slowed the grid's showing. None for a folder, whose tile is glass. At rest with Reduce Motion.
struct IconShadow: ViewModifier {
    let lift: Int
    let size: CGFloat
    @Environment(\.reduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let (opacity, scale, y): (Double, CGFloat, CGFloat) = switch reduceMotion ? 0 : lift {
        case 1: (0.62, 1.12, 0.09)
        case -1: (0.5, 0.94, 0.015)
        default: (0.5, 1, 0.035)
        }
        content
            .background {
                if size > 0 {
                    Image(nsImage: Self.picture)
                        .resizable()
                        .frame(width: size * Self.reach * scale, height: size * Self.reach * scale)
                        .offset(y: size * y)
                        .opacity(opacity)
                        .allowsHitTesting(false)
                        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: lift)
                }
            }
    }

    /// The picture's size over the icon's: its shape is the icon's artwork (0.82 of the icon's
    /// frame) drawn at `Self.shape` of the picture.
    private static let shape: CGFloat = 0.6
    private static let reach: CGFloat = 0.82 / shape

    /// A blurred rounded square, black fading out, drawn once.
    private static let picture: NSImage = {
        let side = 256
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            let w = CGFloat(side) * shape
            let rect = CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - w) / 2, width: w, height: w)
            // The shape is drawn far off to one side; only its shadow, cast back, lands here.
            let shadow = NSShadow()
            shadow.shadowColor = .black
            shadow.shadowBlurRadius = CGFloat(side) * 0.07
            shadow.shadowOffset = NSSize(width: CGFloat(side) * 4, height: 0)
            shadow.set()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.offsetBy(dx: -CGFloat(side) * 4, dy: 0), xRadius: w * 0.225, yRadius: w * 0.225).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let image = NSImage(size: NSSize(width: side / 2, height: side / 2))
        image.addRepresentation(rep)
        return image
    }()
}

// MARK: - Live icons

/// The Calendar and Clock icons drawn live, as the Dock draws them: today's date, and the
/// time with its second hand turning. Only in the Default and Dark icon styles, whose look
/// they follow; Clear and Tinted icons stay as macOS draws them.
enum LiveIcon {
    case calendar, clock

    /// Bundle IDs by path, looked up once: every icon view asks.
    @MainActor private static var bundleIDs: [String: String?] = [:]

    @MainActor static func kind(for path: String) -> LiveIcon? {
        guard path.hasSuffix("/Calendar.app") || path.hasSuffix("/Clock.app") else { return nil }
        let id: String?
        if let known = bundleIDs[path] {
            id = known
        } else {
            id = Bundle(path: path)?.bundleIdentifier
            bundleIDs[path] = id
        }
        switch id {
        case "com.apple.iCal": return .calendar
        case "com.apple.clock": return .clock
        default: return nil
        }
    }

    enum Style { case light, dark }

    /// The icon style chosen in System Settings › Appearance, when live icons follow it.
    static var style: Style? {
        #if !APP_STORE
        // For the debug scripts, without changing the Mac's setting: dark, light or none.
        if let forced = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_LIVE_STYLE"] {
            return forced == "dark" ? .dark : forced == "light" ? .light : nil
        }
        #endif
        return style(forTheme: UserDefaults.standard.string(forKey: "AppleIconAppearanceTheme") ?? "")
    }

    /// The style for a value of `AppleIconAppearanceTheme` ("RegularDark", "ClearLight"…;
    /// none for the Default style).
    static func style(forTheme theme: String) -> Style? {
        if theme.contains("Clear") || theme.contains("Tinted") { return nil }
        return theme.contains("Dark") ? .dark : .light
    }
}

/// The shape of a macOS app icon's artwork inside its frame, as `ActionGlyph` draws it.
private struct IconTile<Content: View>: View {
    let size: CGFloat
    let style: LiveIcon.Style
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        let side = size * 0.82
        let shape = RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
        ZStack {
            shape.fill(style == .dark
                       ? LinearGradient(colors: [Color(white: 0.2), Color(white: 0.09)], startPoint: .top, endPoint: .bottom)
                       : LinearGradient(colors: [.white, Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(.white.opacity(style == .dark ? 0.14 : 0.5), lineWidth: max(0.5, size / 200))
            content(side)
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .frame(width: size, height: size)
    }
}

/// Today's weekday and date, in Calendar's red and black (white in the Dark style).
struct LiveCalendarIcon: View {
    let size: CGFloat
    let style: LiveIcon.Style

    var body: some View {
        TimelineView(.everyMinute) { context in
            IconTile(size: size, style: style) { side in
                VStack(spacing: -side * 0.04) {
                    Text(context.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: side * 0.16, weight: .semibold))
                        .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.19))
                    Text(context.date.formatted(.dateTime.day()))
                        .font(.system(size: side * 0.52, weight: .light))
                        .foregroundStyle(style == .dark ? .white : Color(white: 0.12))
                        .monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.top, side * 0.02)
            }
        }
    }
}

/// The time now on a clock face, the second hand turning while the grid is shown.
struct LiveClockIcon: View {
    @Environment(AppState.self) private var state
    @Environment(\.reduceMotion) private var reduceMotion
    let size: CGFloat
    let style: LiveIcon.Style

    var body: some View {
        // Once a minute while hidden, or with Reduce Motion (no second hand then).
        let ticking = state.isShown && !reduceMotion && size >= 32
        TimelineView(.periodic(from: .now, by: ticking ? 1 : 60)) { context in
            let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: context.date)
            IconTile(size: size, style: style) { side in
                ClockFace(hour: Double(parts.hour ?? 0), minute: Double(parts.minute ?? 0),
                          second: ticking ? Double(parts.second ?? 0) : nil,
                          face: style == .dark ? Color(white: 0.1) : .white,
                          ink: style == .dark ? .white : Color(white: 0.1),
                          accent: Color(red: 1, green: 0.58, blue: 0), numerals: side >= 40)
                    .padding(side * 0.07)
            }
        }
    }
}

/// An analogue clock face: ticks (and numerals when there's room), hour and minute hands and,
/// given one, a second hand.
struct ClockFace: View {
    let hour: Double
    let minute: Double
    var second: Double?
    let face: Color
    let ink: Color
    let accent: Color
    var numerals = true

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(face))
            func point(_ turn: Double, _ length: CGFloat) -> CGPoint {
                let a = turn * 2 * .pi
                return CGPoint(x: c.x + sin(a) * length, y: c.y - cos(a) * length)
            }
            for i in 0..<60 {
                let major = i % 5 == 0
                if !major && r < 30 { continue }
                var tick = Path()
                tick.move(to: point(Double(i) / 60, r * (major ? 0.8 : 0.86)))
                tick.addLine(to: point(Double(i) / 60, r * 0.92))
                ctx.stroke(tick, with: .color(ink.opacity(major ? 0.75 : 0.3)), lineWidth: major ? r * 0.035 : r * 0.015)
            }
            if numerals {
                for (i, n) in [12, 3, 6, 9].enumerated() {
                    let text = Text(verbatim: "\(n)").font(.system(size: r * 0.24, weight: .medium)).foregroundColor(ink.opacity(0.85))
                    ctx.draw(text, at: point(Double(i) / 4, r * 0.6))
                }
            }
            func hand(_ turn: Double, _ length: CGFloat, _ width: CGFloat, _ color: Color, tail: CGFloat = 0.1) {
                var p = Path()
                p.move(to: point(turn + 0.5, r * tail))
                p.addLine(to: point(turn, length))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            let m = minute + (second ?? 0) / 60
            hand((hour.truncatingRemainder(dividingBy: 12) + m / 60) / 12, r * 0.5, r * 0.085, ink)
            hand(m / 60, r * 0.76, r * 0.06, ink)
            if let second { hand(second / 60, r * 0.84, max(1, r * 0.022), accent, tail: 0.2) }
            let dot = r * 0.07
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)),
                     with: .color(second == nil ? ink : accent))
        }
    }
}

// MARK: - Answers

/// A sum, a conversion or a time elsewhere as a card under the search field: what kind of
/// answer it is, the question, the answer large, and for a time, a small clock that's light by
/// day and dark by night, with "Tomorrow" or "Yesterday" when it falls on another day.
struct AnswerCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    let answer: Answer

    var body: some View {
        let high = contrast == .increased
        Button { state.copyAnswer() } label: {
            HStack(spacing: 10) {
                glyph
                    .frame(width: 24, height: 24)
                Text(verbatim: answer.question)
                    .foregroundStyle(.white.opacity(high ? 0.9 : 0.7))
                Image(systemName: isArithmetic ? "equal" : "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(high ? 0.8 : 0.45))
                Text(verbatim: answer.value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let shift = dayShift {
                    Text(shift > 0 ? "Tomorrow" : "Yesterday")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((shift > 0 ? Color.orange : Color.purple).opacity(0.85), in: Capsule())
                }
                if let note = shownNote {
                    Text(verbatim: note)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(high ? 0.85 : 0.6))
                }
                if state.focusIndex == nil {
                    KeyHint(keys: "↩", label: Text("Copy"))
                        .padding(.leading, 4)
                }
            }
            .font(.system(size: 15))
            .lineLimit(1)
            .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 4)
            .glassSurface(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: answer.value)
        .accessibilityLabel(Text(verbatim: "\(answer.question) = \(answer.value)\(answer.note.map { ", \($0)" } ?? "")"))
        .accessibilityHint("Copies it")
    }

    private var isArithmetic: Bool { answer.kind == .arithmetic }

    private var dayShift: Int? {
        if case .time(_, _, let shift) = answer.kind, shift != 0 { shift } else { nil }
    }

    /// The note, without the day it falls on, which the badge says.
    private var shownNote: String? {
        guard let note = answer.note else { return nil }
        guard dayShift != nil else { return note }
        let trimmed = note.replacingOccurrences(of: String(localized: ", next day"), with: "")
            .replacingOccurrences(of: String(localized: ", previous day"), with: "")
        return trimmed.isEmpty ? nil : trimmed
    }

    @ViewBuilder private var glyph: some View {
        switch answer.kind {
        case .time(let hour, let minute, _):
            let day = (6..<18).contains(hour)
            ClockFace(hour: Double(hour), minute: Double(minute), second: nil,
                      face: day ? Color(red: 1, green: 0.93, blue: 0.75) : Color(red: 0.16, green: 0.18, blue: 0.4),
                      ink: day ? Color(white: 0.15) : .white, accent: .orange, numerals: false)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: day ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 10, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(day ? Color(red: 1, green: 0.62, blue: 0) : Color(red: 0.8, green: 0.84, blue: 1))
                        .shadow(color: .black.opacity(0.25), radius: 0.5)
                        .offset(x: 5, y: -4)
                }
        case .conversion(let category):
            symbolBadge(Self.symbol(for: category), hue: Self.hue(for: category))
        case .arithmetic:
            symbolBadge("plus.forwardslash.minus", hue: 0.08)
        }
    }

    private func symbolBadge(_ name: String, hue: Double) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(LinearGradient(colors: [Color(hue: hue, saturation: 0.6, brightness: 0.85),
                                                Color(hue: hue, saturation: 0.75, brightness: 0.6)],
                                       startPoint: .top, endPoint: .bottom), in: Circle())
    }

    static func symbol(for category: Answer.Category) -> String {
        switch category {
        case .length: "ruler"
        case .mass: "scalemass"
        case .temperature: "thermometer.medium"
        case .volume: "drop"
        case .speed: "gauge.with.dots.needle.67percent"
        case .data: "internaldrive"
        case .duration: "hourglass"
        case .area: "square.dashed"
        }
    }

    static func hue(for category: Answer.Category) -> Double {
        switch category {
        case .length: 0.58
        case .mass: 0.75
        case .temperature: 0.02
        case .volume: 0.52
        case .speed: 0.12
        case .data: 0.62
        case .duration: 0.85
        case .area: 0.33
        }
    }
}

// MARK: - Suggestions

/// Above the first page, when it has no title: the apps (and actions) opened most around this
/// time of day, small, to open with a click. Off unless chosen in Settings, and only once a
/// habit shows (`Usage.suggestions`). Never in place of a page's own items, which stay put.
struct SuggestionsRow: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    let items: [GridItem]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(contrast == .increased ? 0.9 : 0.55))
                .modifier(Legible())
                .help("Opened around this time of day")
                .accessibilityHidden(true)
            ForEach(items) { item in
                Button { state.activate(item) } label: {
                    Group {
                        switch item {
                        case .app(let a): AppIcon(path: a.path, size: 26)
                        case .action(let a): ActionTile(action: a, size: 26)
                        case .folder(let f): FolderIcon(folder: f, size: 26)
                        }
                    }
                    .modifier(IconShadow(lift: 0, size: 26))
                }
                .buttonStyle(.plain)
                .modifier(TileMotion(enabled: true, cornerRadius: 8))
                .help(Text(verbatim: item.title))
                .accessibilityLabel(Text("Suggested: \(item.title)"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }
}

// MARK: - System Settings

/// A System Settings pane's tile: its symbol on its colour, as in Settings' sidebar.
struct SettingsPaneGlyph: View {
    let pane: SettingsPane
    let size: CGFloat

    var body: some View {
        let side = size * 0.82
        let (r, g, b) = pane.color
        let base = Color(.sRGB, red: r, green: g, blue: b)
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [base.opacity(0.85), base], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 1))
            Image(systemName: NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil) == nil ? "gearshape.fill" : pane.symbol)
                .resizable()
                .scaledToFit()
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .frame(width: side * 0.54, height: side * 0.54)
        }
        .frame(width: side, height: side)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The System Settings panes this Mac has, read once from the extensions in the system's
/// ExtensionKit folder (bundle IDs only). Until that's done, or if it can't be read, all.
@MainActor
enum SettingsPaneCatalog {
    private(set) static var available: [SettingsPane] = SettingsPane.all

    static func load() {
        Task.detached(priority: .utility) {
            let installed = installedIDs()
            await MainActor.run { available = SettingsPane.available(in: installed) }
        }
    }

    nonisolated static func installedIDs() -> Set<String> {
        let folder = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let wanted = Set(SettingsPane.all.map(\.id))
        var found = Set<String>()
        for name in names where name.hasSuffix(".appex") {
            let plist = folder.appendingPathComponent(name).appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let id = info["CFBundleIdentifier"] as? String, wanted.contains(id) else { continue }
            found.insert(id)
        }
        return found
    }
}
