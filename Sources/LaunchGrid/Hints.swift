import AppKit
import SwiftUI
import LaunchGridCore

// What the grid tells you it can do: the answer and key hints under the search field, the
// shortcuts ⌘ shows when held, and what the empty search field suggests trying (the tips among it).

/// Under the search field, in the page title's place: a sum or conversion worked out from what
/// was typed (Return or a click copies it), else what Return and its companions do with the
/// result they'd act on.
struct SearchHintLine: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if let answer = state.searchAnswer {
                // One card while typing changes the answer: its value rolls to the new one.
                AnswerCard(answer: answer)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            } else if let match = target {
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

/// What the empty search field suggests after "Search": something to try, a different one each
/// time the grid shows and every few seconds while it sits there. The tips not yet taken come
/// round with the rest (`AppState.Tip`), until what they say has been done; there's nothing to
/// dismiss, as a placeholder covers nothing.
enum SearchPrompt: Hashable {
    case tip(AppState.Tip)
    case sum, conversion, time, settingsPane
    /// An app found by its initials: "vsc" for Visual Studio Code.
    case initials(letters: String, name: String)
    /// An action's keyword: typing it runs the action.
    case keyword(word: String, name: String)
}

extension AppState {
    /// What the empty search field can suggest, in the order it goes round them.
    var searchPrompts: [SearchPrompt] {
        // Typing is what the field itself asks for: that tip isn't one more prompt.
        var tips = Tip.allCases.filter { $0 != .typeToSearch && !prefs.tipsSeen.contains($0.rawValue) }.map(SearchPrompt.tip)
        var examples: [SearchPrompt] = [.sum, .conversion, .time]
        if let (letters, name) = initialsExample { examples.insert(.initials(letters: letters, name: name), at: 1) }
        if let action = grid.allActions.first(where: { !$0.keywords.isEmpty }), let word = action.keywords.first {
            examples.insert(.keyword(word: word, name: action.name), at: 2)
        }
        if prefs.searchSettingsPanes { examples.append(.settingsPane) }
        // A tip after every example, while there are tips left.
        var out: [SearchPrompt] = []
        for example in examples {
            out.append(example)
            if !tips.isEmpty { out.append(tips.removeFirst()) }
        }
        return out + tips
    }

    /// An app on the grid whose name's initials find it, the same one for a while: one of up to
    /// eight, picked by the day of the year.
    private var initialsExample: (String, String)? {
        let names = grid.allApps.map(\.name).filter { name in
            let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
            return (2...4).contains(words.count) && words.allSatisfy { $0.first?.isLetter == true }
        }
        // Three letters or more where there are such names: two can read as a prefix.
        let long = names.filter { $0.split(whereSeparator: { $0 == " " || $0 == "-" }).count >= 3 }
        let picks = Array(Set(long.isEmpty ? names : long)).sorted().prefix(8)
        guard !picks.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let name = picks[day % picks.count]
        let letters = name.split(whereSeparator: { $0 == " " || $0 == "-" }).compactMap(\.first).map { String($0).lowercased() }.joined()
        return (letters, name)
    }
}

/// The empty search field's text: "Search" and, fainter, something to try (`SearchPrompt`).
struct SearchPlaceholder: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.reduceMotion) private var reduceMotion
    /// Advances while the grid sits idle with nothing typed.
    @State private var tick = 0

    var body: some View {
        let high = contrast == .increased
        let prompts = state.searchPrompts
        let prompt = prompts.isEmpty ? nil : prompts[(state.showCount + tick) % prompts.count]
        HStack(spacing: 10) {
            Text("Search")
                .foregroundStyle(.white.opacity(high ? 0.75 : 0.55))
                .fixedSize()
            ZStack(alignment: .leading) {
                if let prompt {
                    text(prompt)
                        .foregroundStyle(.white.opacity(high ? 0.6 : 0.36))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(prompt)
                        .transition(reduceMotion ? .opacity : .push(from: .bottom).combined(with: .opacity))
                }
            }
            .clipped()
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: prompt)
        .task(id: state.isShown) {
            guard state.isShown else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                tick &+= 1
            }
        }
    }

    private func text(_ prompt: SearchPrompt) -> Text {
        switch prompt {
        case .sum: Text("Try “12*7” or “200 + 10%”")
        case .conversion: Text("Try “5 km in mi”")
        case .time: Text("Try “3pm in Tokyo”")
        case .settingsPane: Text("Try “bluetooth” or “dark mode”")
        case .initials(let letters, let name): Text("Try “\(letters)” for \(name)")
        case .keyword(let word, let name): Text("Type “\(word)” to run \(name)")
        case .tip(.holdCommand): Text("Hold ⌘ to see the shortcuts")
        case .tip(.allShortcuts): Text("⌘/ shows every shortcut")
        case .tip(.dropFile):
            Text("Dragging a file? Press \(KeyCombo.describe(keyCode: state.prefs.hotkeyKeyCode, modifiers: state.prefs.hotkeyModifiers)) to drop it on an app")
        case .tip(.typeToSearch): Text("Just type")
        }
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
