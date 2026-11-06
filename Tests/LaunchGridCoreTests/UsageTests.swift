import Foundation
import Testing
@testable import LaunchGridCore

struct UsageTests {
    private func app(_ name: String) -> GridItem {
        .app(AppRef(bundleID: "test.\(name)", path: "/Applications/\(name).app", name: name))
    }

    @Test func usedAppComesFirstWithinTheSameKindOfMatch() {
        let safari = app("Safari"), slack = app("Slack")
        // Without use, the shorter name first.
        #expect(Search.results(in: [safari, slack], query: "s").map(\.title) == ["Slack", "Safari"])
        var usage = Usage()
        let now = Date()
        usage.record(safari, at: now)
        let ranked = Search.results(in: [safari, slack], query: "s", usage: { usage.score($0, at: now) })
        #expect(ranked.map(\.title) == ["Safari", "Slack"])
    }

    @Test func useNeverBeatsABetterKindOfMatch() {
        let notes = app("Notes"), keynote = app("Keynote")
        var usage = Usage()
        let now = Date()
        for _ in 0..<20 { usage.record(keynote, at: now) }
        // "no" starts Notes and is only inside Keynote.
        let ranked = Search.results(in: [keynote, notes], query: "no", usage: { usage.score($0, at: now) })
        #expect(ranked.map(\.title) == ["Notes", "Keynote"])
    }

    @Test func scoresHalveOverTheHalfLife() {
        let safari = app("Safari")
        var usage = Usage()
        let then = Date(timeIntervalSinceReferenceDate: 1_000_000)
        usage.record(safari, at: then)
        usage.record(safari, at: then)
        let later = then.addingTimeInterval(Usage.halfLife)
        #expect(abs(usage.score(safari, at: later) - 1) < 0.0001)
        // A clock set back doesn't add to it.
        #expect(usage.score(safari, at: then.addingTimeInterval(-1000)) == 2)
    }

    @Test func faintUseDoesNotReorder() {
        let safari = app("Safari"), slack = app("Slack")
        var usage = Usage()
        let then = Date(timeIntervalSinceReferenceDate: 1_000_000)
        usage.record(safari, at: then)
        let muchLater = then.addingTimeInterval(Usage.halfLife * 6)
        let ranked = Search.results(in: [safari, slack], query: "s", usage: { usage.score($0, at: muchLater) })
        #expect(ranked.map(\.title) == ["Slack", "Safari"])
    }

    @Test func roundTripsThroughAPropertyList() {
        var usage = Usage()
        usage.record(app("Safari"), at: Date(timeIntervalSinceReferenceDate: 5))
        let back = Usage(propertyList: usage.propertyList as Any)
        #expect(back == usage)
        // Anything unreadable is left out.
        let odd = Usage(propertyList: ["a": [1.0], "b": "x", "c": [Double.nan, 1], "d": [2.0, 3.0]] as [String: Any])
        #expect(odd.entries.keys.sorted() == ["d"])
    }

    @Test func keepsAtMostTheLimit() {
        var usage = Usage()
        let now = Date()
        for i in 0..<(Usage.limit + 5) { usage.record(app("A\(i)"), at: now) }
        #expect(usage.entries.count == Usage.limit)
    }

    @Test func highlightsTheLettersTyped() {
        #expect(Search.highlights(in: "Safari", query: "saf") == [0, 1, 2])
        #expect(Search.highlights(in: "Safari", query: "SAF") == [0, 1, 2])
        #expect(Search.highlights(in: "Visual Studio Code", query: "vsc") == [0, 7, 14])
        #expect(Search.highlights(in: "Visual Studio Code", query: "studio") == Array(7...12))
        #expect(Search.highlights(in: "Visual Studio Code", query: "vs code") == [0, 7, 14, 15, 16, 17])
        #expect(Search.highlights(in: "GarageBand", query: "grbd") == [0, 2, 6, 9])
        #expect(Search.highlights(in: "TextEdit", query: "edit") == [4, 5, 6, 7])
        #expect(Search.highlights(in: "Café", query: "cafe") == [0, 1, 2, 3])
        #expect(Search.highlights(in: "Wi-Fi Explorer", query: "wifi") == [0, 1, 3, 4])
        #expect(Search.highlights(in: "Notes", query: "xyz").isEmpty)
        #expect(Search.highlights(in: "Notes", query: "").isEmpty)
        // A word start that leaves later letters nowhere to go is passed over.
        #expect(Search.highlights(in: "Aab", query: "ab") == [1, 2])
    }
}
