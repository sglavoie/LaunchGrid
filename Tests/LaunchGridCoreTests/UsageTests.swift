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
        let back = Usage(propertyList: usage.propertyList as Any, hours: usage.hoursPropertyList as Any)
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

    @Test func suggestsWhatsOpenedAroundThisTimeOfDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let mail = app("Mail"), music = app("Music"), xcode = app("Xcode")
        var usage = Usage()
        // 2026-01-15 09:00 UTC, and the evening of the same day.
        let morning = Date(timeIntervalSince1970: 1_768_467_600)
        let evening = morning.addingTimeInterval(12 * 3600)
        for _ in 0..<3 { usage.record(mail, at: morning, calendar: calendar) }
        for _ in 0..<2 { usage.record(xcode, at: morning, calendar: calendar) }
        for _ in 0..<4 { usage.record(music, at: evening, calendar: calendar) }
        #expect(usage.suggestions(at: morning, calendar: calendar) == [Usage.key(for: mail)!, Usage.key(for: xcode)!])
        #expect(usage.suggestions(at: evening, calendar: calendar) == [Usage.key(for: music)!])
        // An hour or so either side still counts, at half.
        #expect(usage.suggestions(at: morning.addingTimeInterval(3 * 3600), calendar: calendar).isEmpty)
        #expect(usage.suggestions(at: morning.addingTimeInterval(3 * 3600), calendar: calendar, minimum: 1.2) == [Usage.key(for: mail)!])
        #expect(usage.suggestions(at: morning.addingTimeInterval(3 * 3600), calendar: calendar, minimum: 0.9) == [Usage.key(for: mail)!, Usage.key(for: xcode)!])
        // A habit long gone fades away.
        #expect(usage.suggestions(at: morning.addingTimeInterval(Usage.halfLife * 3), calendar: calendar) == [])
    }

    @Test func hoursRoundTripBesideTheScores() {
        let mail = app("Mail")
        var usage = Usage()
        usage.record(mail)
        let back = Usage(propertyList: usage.propertyList, hours: usage.hoursPropertyList)
        #expect(back == usage)
        // An older build's record, scores alone, still reads.
        #expect(Usage(propertyList: usage.propertyList).entries == usage.entries)
        // Buckets for a key with no score, or of the wrong length, are left out.
        let odd = Usage(propertyList: usage.propertyList, hours: ["app:other": Array(repeating: 1.0, count: 9), Usage.key(for: mail)!: [1.0, 2.0]])
        #expect(odd.hours.isEmpty)
    }
}
