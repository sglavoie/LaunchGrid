import AppKit
import SwiftUI
import LaunchGridCore

// The first-run tour: a card over the grid that has you do the three things worth trying first,
// for real, one at a time. Search works out "5 km in mi" as it types itself and Return copies
// it; the grid sorts itself by colour and ⌘Z puts it back; holding ⌘ shows what works now.
// It starts once, the first time the grid shows after the first layout is made, and comes back
// from the ⋯ menu (Show Me Around). Each step moves on when it's done, or with Next.

/// A step of the tour, in order.
enum TourStep: Int, CaseIterable {
    case answer, sort, undo, command

    var title: String {
        switch self {
        case .answer: String(localized: "Search works things out")
        case .sort: String(localized: "Sort everything by colour")
        case .undo: String(localized: "Changed your mind?")
        case .command: String(localized: "Hold ⌘ for a moment")
        }
    }
}

/// What was just done, which can finish a step.
enum TourEvent {
    case copiedAnswer, sorted, undid, releasedCommand
}

extension AppState {
    /// In `Preferences.firstsSeen` once the tour has started: it starts by itself only once.
    static let tourSeen = "tour"

    /// Off for debug scripts and UI scenarios, which drive the grid themselves: a tour typing
    /// into search would get in their way. A script starts one with its `tour` step.
    static var toursByItself = true

    /// What the tour types into the search field.
    static let tourExample = "5 km in mi"

    /// Starts the tour, from its first step: at the first show after the first layout, or
    /// from the ⋯ menu.
    func startTour() {
        tourPending = false
        prefs.firstsSeen.insert(Self.tourSeen)
        // The answer's own first-time shimmer belongs to the tour's first step.
        prefs.firstsSeen.remove(First.answer.rawValue)
        if openFolderID != nil { closeFolder() }
        editing = false
        showingShortcuts = false
        goTo(.answer)
    }

    /// Ends the tour (Skip, Done, or after its last step).
    func endTour() {
        tourTyping?.cancel()
        tourTyping = nil
        if tourStep == .answer && query == Self.tourExample { query = "" }
        tourStep = nil
    }

    /// Next, or a step done: on to the step after it. Past the last, a sparkle to finish.
    func advanceTour() {
        guard let step = tourStep else { return }
        guard let next = TourStep(rawValue: step.rawValue + 1) else {
            endTour()
            showToast(String(localized: "You're all set. Just type to find anything."), sparkles: true)
            return
        }
        goTo(next)
    }

    private func goTo(_ step: TourStep) {
        tourTyping?.cancel()
        tourTyping = nil
        if tourStep == .answer && query == Self.tourExample { query = "" }
        tourStep = step
        if step == .answer { typeExample() }
    }

    /// Something was done: the step it finishes moves on, a moment later so its own effect
    /// (the copied toast, the wave) is seen first.
    func tourDid(_ event: TourEvent) {
        guard let step = tourStep else { return }
        let finishes = switch (step, event) {
        case (.answer, .copiedAnswer), (.sort, .sorted), (.undo, .undid), (.command, .releasedCommand): true
        default: false
        }
        guard finishes else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(step == .command ? 0.4 : 0.9))
            guard let self, self.tourStep == step else { return }
            self.advanceTour()
        }
    }

    /// The grid showed: a pending tour starts once the grid has settled in, and a tour left on
    /// its first step types its example again (hiding cleared the search).
    func tourDidShow() {
        if tourPending {
            tourPending = false
            Task { [weak self] in
                // After the first layout's build-in.
                try? await Task.sleep(for: .seconds(Motion.reduced ? 0.4 : 2.2))
                guard let self, self.isShown, self.tourStep == nil else { return }
                self.startTour()
            }
        } else if tourStep == .answer {
            typeExample()
        }
    }

    /// Types "5 km in mi" into an empty search field, a letter at a time, so the answer is seen
    /// being worked out. Whatever is typed meanwhile takes over.
    private func typeExample() {
        tourTyping?.cancel()
        tourTyping = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            var typed = ""
            for ch in Self.tourExample {
                guard let self, !Task.isCancelled, self.isShown, self.tourStep == .answer, self.query == typed else { return }
                typed.append(ch)
                self.query = typed
                try? await Task.sleep(for: .milliseconds(Motion.reduced ? 0 : 75))
            }
        }
    }

    /// How to open the grid, as the shortcut set in Settings.
    var hotkeyText: String {
        KeyCombo.describe(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
    }
}

/// The tour's card, above the page dots: which step, what to do, and Skip / Next.
struct TourCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast
    let step: TourStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.yellow, .orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .symbolEffect(.bounce, value: step)
                    .accessibilityHidden(true)
                Text(step.title)
                    .font(.headline)
                Spacer(minLength: 12)
                StepDots(current: step.rawValue, count: TourStep.allCases.count)
            }
            message
                .font(.callout)
                .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(String(localized: "Skip Tour")) { state.endTour() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                actionButton
                Button(step == .command ? String(localized: "Done") : String(localized: "Next")) { state.advanceTour() }
                    .buttonStyle(PillButtonStyle(prominent: step != .sort))
            }
            .font(.callout.weight(.medium))
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 400)
        // Darker under the glass than a message: it sits over icons, which mustn't show through.
        .background(.black.opacity(contrast == .increased ? 0.6 : 0.38), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tour, step \(step.rawValue + 1) of \(TourStep.allCases.count)"))
    }

    private var symbol: String {
        switch step {
        case .answer: "equal.circle"
        case .sort: "paintpalette"
        case .undo: "arrow.uturn.backward.circle"
        case .command: "command"
        }
    }

    @ViewBuilder private var message: some View {
        switch step {
        case .answer:
            Text("Sums, conversions and times elsewhere are worked out as you type. Press \(Text(verbatim: "↩").bold()) to copy the answer, then try your own: 12*7, 3pm in Tokyo.")
        case .sort:
            Text("Every icon sweeps into place, red through purple, in one wave.")
        case .undo:
            Text("Press \(Text(verbatim: "⌘Z").bold()) and everything goes back where it was. Any change can be undone, fifty steps back.")
        case .command:
            Text("Hold \(Text(verbatim: "⌘")) and the shortcuts that work right now appear; \(Text(verbatim: "⌘/").bold()) shows them all. Open LaunchGrid from anywhere with \(Text(verbatim: state.hotkeyText).bold()).")
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch step {
        case .sort:
            Button(String(localized: "Sort by Colour")) { state.sortEverythingByColour() }
                .buttonStyle(PillButtonStyle(prominent: true))
        case .undo:
            Button(String(localized: "Put It Back")) { state.undo() }
                .buttonStyle(PillButtonStyle())
        default:
            EmptyView()
        }
    }

    private struct StepDots: View {
        let current: Int
        let count: Int

        var body: some View {
            HStack(spacing: 5) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(i == current ? 0.95 : i < current ? 0.55 : 0.25))
                        .frame(width: i == current ? 14 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: current)
            .accessibilityHidden(true)
        }
    }
}

/// Where the tour's card goes: over the bottom of the grid, above the messages.
struct TourLayer: View {
    @Environment(AppState.self) private var state
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer()
            // Out of the way while ⌘ is held: the strip of shortcuts shows where it is.
            if let step = state.tourStep, state.textEdit == nil, !state.showingShortcuts, !state.commandHeld {
                TourCard(step: step)
                    .padding(.bottom, 20)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.8), value: state.tourStep)
        .animation(.easeOut(duration: 0.18), value: state.commandHeld)
    }
}
