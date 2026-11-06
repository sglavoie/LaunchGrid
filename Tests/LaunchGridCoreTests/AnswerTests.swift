import Foundation
import Testing
@testable import LaunchGridCore

struct AnswerTests {
    private let us = Locale(identifier: "en_US")
    private let fr = Locale(identifier: "fr_FR")

    private func value(_ q: String, locale: Locale? = nil) -> String? {
        Answer.answer(for: q, locale: locale ?? us)?.value
    }

    @Test func arithmetic() {
        #expect(value("12*7") == "84")
        #expect(value("=2^10") == "1024")
        #expect(value("(3+4)/2") == "3.5")
        #expect(value("2+3*4") == "14")
        #expect(value("2^3^2") == "512")
        #expect(value("-3 + 5") == "2")
        #expect(value("10 % 3") == "1")
        #expect(value("200 + 10%") == "220")
        #expect(value("50% * 8") == "4")
        #expect(value("sqrt(16) + 1") == "5")
        #expect(value("1/3") == "0.3333333333")
        #expect(value("1,000 * 3") == "3000")
        #expect(value("123456*1000") == "123,456,000")
    }

    @Test func notArithmetic() {
        // A number alone, a name with digits, or something that doesn't parse.
        #expect(value("2024") == nil)
        #expect(value("-5") == nil)
        #expect(value("1password") == nil)
        #expect(value("3ds max") == nil)
        #expect(value("5/0") == nil)
        #expect(value("(2+3") == nil)
        #expect(value("+") == nil)
        #expect(value("") == nil)
        // "=" asks for a lone number anyway.
        #expect(value("=42") == "42")
    }

    @Test func decimalCommaLocale() {
        #expect(value("1,5*2", locale: fr) == "3")
        #expect(value("10/4", locale: fr) == "2,5")
    }

    @Test func questionReadsAsOnPaper() {
        #expect(Answer.answer(for: "12*7", locale: us)?.question == "12 × 7")
        #expect(Answer.answer(for: "-3+-2", locale: us)?.question == "−3 + −2")
    }

    @Test func unitConversions() {
        #expect(value("5 km in mi") == "3.11 mi")
        #expect(value("5km to miles") == "3.11 mi")
        #expect(value("100 f to c") == "37.78 °C")
        #expect(value("0 c in f") == "32 °F")
        #expect(value("2 GB in MB") == "2000 MB")
        #expect(value("1 lb in g") == "453.6 g")
        #expect(value("90 min in h") == "1.5 h")
        #expect(value("1 cup in ml") == "240 ml")
        #expect(value("60 mph in km/h") == "96.56 km/h")
        #expect(Answer.answer(for: "5 km in mi", locale: us)?.question == "5 km")
    }

    @Test func notConversions() {
        // Different kinds, unknown units, the same unit, or words that only look like it.
        #expect(value("5 km in kg") == nil)
        #expect(value("5 parsecs in km") == nil)
        #expect(value("5 km in km") == nil)
        #expect(value("songs in music") == nil)
        #expect(value("log in to github") == nil)
    }

    @Test func timeElsewhere() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        // 2026-01-15 12:00 UTC, in winter: Paris is UTC+1, Tokyo UTC+9, Los Angeles UTC−8.
        let now = Date(timeIntervalSince1970: 1_768_478_400)
        let gb = Locale(identifier: "en_GB")
        #expect(Answer.answer(for: "3pm PST", now: now, timeZone: paris, locale: gb)?.value == "00:00")
        #expect(Answer.answer(for: "3pm PST", now: now, timeZone: paris, locale: gb)?.note == "your time, next day")
        #expect(Answer.answer(for: "15:00 utc in tokyo", now: now, timeZone: paris, locale: gb)?.value == "00:00")
        #expect(Answer.answer(for: "9:30am tokyo", now: now, timeZone: utc, locale: gb)?.value == "00:30")
        let there = try #require(Answer.answer(for: "time in tokyo", now: now, timeZone: paris, locale: gb))
        #expect(there.value == "21:00")
        #expect(there.note == "UTC+9")
        #expect(there.question == "Time in Tokyo")
        #expect(Answer.answer(for: "new york time", now: now, timeZone: paris, locale: gb)?.value == "07:00")
        #expect(Answer.answer(for: "time in kathmandu", now: now, timeZone: paris, locale: gb)?.note == "UTC+5:45")
    }

    @Test func notTimes() {
        // A number without "am", "pm" or minutes, or a place nobody knows.
        #expect(value("3 tokyo") == nil)
        #expect(value("3pm atlantis") == nil)
        #expect(value("time in narnia") == nil)
        #expect(value("tokyo") == nil)
        #expect(value("13pm utc") == nil)
    }
}
