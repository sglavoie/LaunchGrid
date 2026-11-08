import AppKit
import SwiftUI
import LaunchGridCore

// What the grid tells you it can do: the answer under the search field, and the key hints and
// shortcuts that holding ⌘ shows.

/// Under the search field, in the page title's place: a sum or conversion worked out from what
/// was typed (Return or a click copies it), else, while ⌘ is held, what Return and its
/// companions do with the result they'd act on. Unasked, the results speak for themselves.
struct SearchHintLine: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if let answer = state.searchAnswer {
                // One card while typing changes the answer: its value rolls to the new one.
                AnswerCard(answer: answer)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            } else if state.commandHeld, let match = target {
                HStack(spacing: 16) {
                    KeyHint(keys: "↩", label: openLabel(match))
                    if state.fileURL(of: match.item) != nil, !state.editing {
                        KeyHint(keys: "⌘↩", label: Text("Show in Finder"))
                        KeyHint(keys: "⌘Y", label: Text("Quick Look"))
                    }
                }
                .transition(.opacity)
                // Keyboard hints; VoiceOver users have the item's own actions.
                .accessibilityHidden(true)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: state.searchAnswer != nil)
        .animation(.easeOut(duration: 0.18), value: state.commandHeld)
    }

    /// The result Return acts on: the focused one, or the first.
    private var target: Search.Match? {
        state.searchResults[safe: state.focusIndex ?? 0]
    }

    private func openLabel(_ match: Search.Match) -> Text {
        if state.editing { return Text("Show on Grid") }
        switch match.item {
        case .app: return Text("Open")
        case .folder: return Text("Open Folder")
        case .action(let a):
            if SettingsPane.pane(for: a.id) != nil || AppCommand.command(for: a.id) != nil { return Text("Open") }
            if let argument = match.argument { return Text("Run with “\(argument)”") }
            return Text("Run")
        }
    }
}

/// A key, or keys, in a little cap, and what it does: "⌘↩ Show in Finder".
struct KeyHint: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let keys: String
    let label: Text

    var body: some View {
        let high = contrast == .increased
        HStack(spacing: 5) {
            Text(verbatim: keys)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(.white.opacity(high ? 0.3 : 0.16), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(high ? 0.5 : 0.18), lineWidth: 0.5))
                // Whole, as "Space" or "⌥ ←→↑↓": the label gives way first.
                .fixedSize()
            label
                .font(.system(size: 12))
        }
        .foregroundStyle(.white.opacity(high ? 0.95 : 0.7))
        .lineLimit(1)
        .modifier(Legible())
    }
}

/// The number on a search result (or page dot) while ⌘ is held: ⌘ and it opens that one.
struct KeyBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.black.opacity(0.8))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(.white.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .accessibilityHidden(true)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }
}

/// While ⌘ is held: the shortcuts there are for what's on screen (`KeyShortcut.strip`), in a
/// strip at the bottom, ending with the one that shows them all.
struct ShortcutStrip: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let entries = KeyShortcut.strip(KeyShortcut.Context.current(state))
        // As wide as what's in it, up to 760 points: two keys mid-drag make a short strip.
        FlowLayout(spacing: 16, lineSpacing: 8, maxWidth: 760) {
            ForEach(entries) { entry in
                KeyHint(keys: entry.keys, label: Text(entry.stripLabel))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Lays its children out in rows, left to right, starting a new row when one is full; each
/// row centred.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    /// The widest it gets, whatever it's offered.
    var maxWidth: CGFloat = .infinity

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows.map { $0.map { (index: $0.0, size: $0.1) } }
    }

    private func rowWidth(_ row: [(index: Int, size: CGSize)]) -> CGFloat {
        let widths: CGFloat = row.map(\.size.width).reduce(0, +)
        return widths + spacing * CGFloat(max(row.count - 1, 0))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? .infinity, maxWidth)
        let rows = rows(subviews, width: width)
        let widest: CGFloat = rows.map(rowWidth).max() ?? 0
        let heights: [CGFloat] = rows.map { row in row.map(\.size.height).max() ?? 0 }
        let gaps: CGFloat = lineSpacing * CGFloat(max(rows.count - 1, 0))
        let height: CGFloat = heights.reduce(0, +) + gaps
        return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: min(bounds.width, maxWidth)) {
            let height: CGFloat = row.map(\.size.height).max() ?? 0
            var x = bounds.midX - rowWidth(row) / 2
            for entry in row {
                subviews[entry.index].place(at: CGPoint(x: x, y: y + (height - entry.size.height) / 2), proposal: ProposedViewSize(entry.size))
                x += entry.size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}

/// The empty search field's text: "Search", and nothing more. What to try is the tour's to
/// show, once, rather than the field's every time the grid shows.
struct SearchPlaceholder: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text("Search")
            .foregroundStyle(.white.opacity(contrast == .increased ? 0.75 : 0.55))
            .fixedSize()
    }
}

/// The keyword an action was found by, as a token at the start of the search: what follows it
/// is what the action is given.
struct KeywordChip: View {
    let action: Action
    let keyword: String

    var body: some View {
        HStack(spacing: 4) {
            ActionTile(action: action, size: 15)
            Text(verbatim: keyword)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.leading, 3).padding(.trailing, 7).padding(.vertical, 1)
        .background(Color(hue: ActionTile.hue(for: action.id), saturation: 0.55, brightness: 0.6).opacity(0.85), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .fixedSize()
    }

    /// When the first result is an action found by its keyword with an argument after it, and
    /// the caret is past the keyword: the action, the keyword as typed, and what's typed before
    /// the caret after it.
    @MainActor
    static func split(_ state: AppState, line: TextLine) -> (action: Action, keyword: String, beforeCaret: String)? {
        guard let first = state.searchResults.first, case .action(let action) = first.item,
              let argument = first.argument,
              let r = state.query.range(of: argument, options: .backwards) else { return nil }
        let prefix = String(state.query[..<r.lowerBound])
        let keyword = prefix.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty, line.beforeCaret.hasPrefix(prefix) else { return nil }
        return (action, keyword, String(line.beforeCaret.dropFirst(prefix.count)))
    }
}
