import Foundation
import Testing
@testable import LaunchGrid
@testable import LaunchGridCore

/// The first-run tour: once, after the first layout; each step moves on when it's done.
@MainActor @Suite(.tempDir, .serialized) struct TourTests {
    private func waitFor(_ condition: () -> Bool, seconds: Double = 20) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test(.timeLimit(.minutes(1))) func theFirstStepTypesItsExampleAndMovesOnOnceTheAnswerIsCopied() async {
        let state = makeState(["Alpha"])
        state.isShown = true
        state.startTour()
        #expect(state.tourStep == .answer)
        #expect(state.prefs.firstsSeen.contains(AppState.tourSeen))
        await waitFor { state.query == AppState.tourExample }
        #expect(state.query == AppState.tourExample)
        #expect(state.searchAnswer != nil)
        // Something else done doesn't count.
        state.tourDid(.undid)
        state.tourDid(.copiedAnswer)
        await waitFor { state.tourStep == .sort }
        #expect(state.tourStep == .sort)
        // Its example is cleared on the way.
        #expect(state.query.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func eachStepFinishesOnItsOwnEventAndTheLastEndsTheTour() async {
        let state = makeState(["Alpha"])
        state.isShown = true
        state.startTour()
        state.advanceTour()
        #expect(state.tourStep == .sort)
        state.tourDid(.sorted)
        await waitFor { state.tourStep == .undo }
        state.tourDid(.undid)
        await waitFor { state.tourStep == .command }
        #expect(state.tourStep == .command)
        state.commandHeld = true
        state.commandHeld = false
        await waitFor { state.tourStep == nil }
        #expect(state.tourStep == nil)
        #expect(state.toastSparkles)
    }

    @Test func skippingEndsItAndClearsItsExample() {
        let state = makeState(["Alpha"])
        state.isShown = true
        state.startTour()
        state.query = AppState.tourExample
        state.endTour()
        #expect(state.tourStep == nil)
        #expect(state.query.isEmpty)
    }

    @Test func itIsPendingAfterTheFirstLayoutOnlyOnce() {
        let fresh = AppState(prefs: testPreferences(), store: GridStore(url: TempDir.url.appendingPathComponent("a.json")))
        fresh.replaceGrid(Grid(rows: 5, columns: 7))
        #expect(fresh.tourPending == AppState.toursByItself)

        let seen = AppState(prefs: testPreferences(), store: GridStore(url: TempDir.url.appendingPathComponent("b.json")))
        seen.prefs.firstsSeen.insert(AppState.tourSeen)
        seen.replaceGrid(Grid(rows: 5, columns: 7))
        #expect(!seen.tourPending)
    }
}
