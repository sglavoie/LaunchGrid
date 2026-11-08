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

    @Test func kindsSayHowToShowTheAnswer() throws {
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        let now = Date(timeIntervalSince1970: 1_768_478_400)
        let gb = Locale(identifier: "en_GB")
        #expect(Answer.answer(for: "12*7", locale: us)?.kind == .arithmetic)
        #expect(Answer.answer(for: "5 km in mi", locale: us)?.kind == .conversion(.length))
        #expect(Answer.answer(for: "70 f to c", locale: us)?.kind == .conversion(.temperature))
        #expect(Answer.answer(for: "2 GB in MB", locale: us)?.kind == .conversion(.data))
        #expect(Answer.answer(for: "3 days in hours", locale: us)?.value == "72 h")
        #expect(Answer.answer(for: "48 hours in days", locale: us)?.value == "2 d")
        // Static and custom units of one kind are different classes underneath.
        #expect(Answer.answer(for: "2 weeks in days", locale: us)?.value == "14 d")
        #expect(Answer.answer(for: "2 weeks in kg", locale: us) == nil)
        #expect(Answer.answer(for: "3 days in hours", locale: us)?.kind == .conversion(.duration))
        // 3pm in Los Angeles is midnight in Paris, the next day.
        #expect(Answer.answer(for: "3pm PST", now: now, timeZone: paris, locale: gb)?.kind == .time(hour: 0, minute: 0, dayShift: 1))
        #expect(Answer.answer(for: "9:30am tokyo", now: now, timeZone: paris, locale: gb)?.kind == .time(hour: 1, minute: 30, dayShift: 0))
        #expect(Answer.answer(for: "9am tokyo", now: now, timeZone: paris, locale: gb)?.kind == .time(hour: 1, minute: 0, dayShift: 0))
        #expect(Answer.answer(for: "11pm paris in tokyo", now: now, timeZone: paris, locale: gb)?.kind == .time(hour: 7, minute: 0, dayShift: 1))
        #expect(Answer.answer(for: "time in tokyo", now: now, timeZone: paris, locale: gb)?.kind == .time(hour: 21, minute: 0, dayShift: 0))
    }

    // MARK: Colours, dates, timestamps, bases, Base64

    /// 2026-01-15 12:00 UTC, a Thursday.
    private let now = Date(timeIntervalSince1970: 1_768_478_400)
    private let gb = Locale(identifier: "en_GB")

    private func answer(_ q: String, zone: String = "UTC") -> Answer? {
        Answer.answer(for: q, now: now, timeZone: TimeZone(identifier: zone)!, locale: gb)
    }

    /// Whether `text` has each of `parts`, in order: dates as the system writes them, whose
    /// commas and "at"s vary between versions of macOS.
    private func reads(_ text: String?, _ parts: String...) -> Bool {
        guard let text else { return false }
        var rest = Substring(text)
        for part in parts {
            guard let r = rest.range(of: part) else { return false }
            rest = rest[r.upperBound...]
        }
        return true
    }

    @Test func colours() {
        let hex = answer("#ff8800")
        #expect(hex?.value == "rgb(255, 136, 0)")
        #expect(hex?.note == "#ff8800 · hsl(32°, 100%, 50%)")
        #expect(hex?.question == "#ff8800")
        #expect(hex?.kind == .color(red: 255, green: 136, blue: 0))
        #expect(answer("#F80")?.value == "rgb(255, 136, 0)")
        let rgb = answer("rgb(255, 136, 0)")
        #expect(rgb?.value == "#ff8800")
        #expect(rgb?.note == "rgb(255, 136, 0) · hsl(32°, 100%, 50%)")
        #expect(answer("rgb(255,136,0)")?.value == "#ff8800")
        #expect(answer("RGB(0 0 0)")?.value == "#000000")
        #expect(answer("hsl(32, 100%, 50%)")?.value == "#ff8800")
        #expect(answer("hsl(32deg 100% 50%)")?.kind == .color(red: 255, green: 136, blue: 0))
        #expect(answer("hsl(0, 0%, 100%)")?.value == "#ffffff")
        #expect(answer("hsl(240, 100%, 25%)")?.value == "#000080")
        #expect(answer("hsl(-120, 100%, 50%)")?.value == "#0000ff")
        // The form asked for.
        #expect(answer("#ff8800 in hsl")?.value == "hsl(32, 100%, 50%)")
        #expect(answer("#ff8800 in hsl")?.note == "#ff8800 · rgb(255, 136, 0)")
        #expect(answer("#ff8800 in hsl")?.question == "#ff8800")
        #expect(answer("#ff8800 to rgb")?.value == "rgb(255, 136, 0)")
        #expect(answer("#f80 as hex")?.value == "#ff8800")
        #expect(answer("rgb(0, 128, 255) in hsl")?.value == "hsl(210, 100%, 50%)")
        #expect(answer("#808080 in hsl")?.value == "hsl(0, 0%, 50%)")
    }

    @Test func notColours() {
        for q in ["ff8800", "#ff88", "#ff88000", "#ggg", "#", "rgb(300, 0, 0)", "rgb(1, 2)", "rgb(1, 2, 3, 4)",
                  "rgb 1 2 3", "hsl(0, 200%, 50%)", "hsl(a, 1%, 1%)", "#ff8800 in cmyk", "rgb", "hsl()"] {
            #expect(answer(q) == nil, "\(q)")
        }
    }

    @Test func daysUntilAndSince() {
        let christmas = answer("days until dec 25")
        #expect(christmas?.value == "344 days")
        #expect(christmas?.question == "Days until")
        #expect(reads(christmas?.note, "Friday", "25 December"))
        #expect(christmas?.kind == .date)
        #expect(answer("Days until 25 December")?.value == "344 days")
        #expect(answer("how many days until christmas")?.value == "344 days")
        #expect(answer("days until 25th dec")?.value == "344 days")
        #expect(answer("days since jan 1")?.value == "14 days")
        #expect(reads(answer("days since jan 1")?.note, "Thursday", "1 January"))
        // Without a year, the next one or the last one: today is both.
        #expect(answer("days until jan 15")?.value == "0 days")
        #expect(answer("days since jan 15")?.value == "0 days")
        #expect(answer("days until jan 14")?.value == "364 days")
        #expect(reads(answer("days until jan 14")?.note, "Thursday", "14 January", "2027"))
        #expect(answer("days since dec 25")?.value == "21 days")
        #expect(reads(answer("days since dec 25")?.note, "Thursday", "25 December", "2025"))
        #expect(reads(answer("days until feb 29")?.note, "Tuesday", "29 February", "2028"))
        #expect(answer("days until new year")?.value == "351 days")
        // With a year.
        #expect(answer("days until 2027-01-01")?.value == "351 days")
        #expect(reads(answer("days until 2027-01-01")?.note, "Friday", "1 January", "2027"))
        #expect(answer("days until dec 25, 2027")?.value == "709 days")
        #expect(answer("days since 2025-01-15")?.value == "365 days")
        // Days count in the local time zone: at 12:00 UTC it's already the 16th on Kiritimati (UTC+14).
        #expect(answer("days since jan 1", zone: "Pacific/Kiritimati")?.value == "15 days")
    }

    @Test func notDayCounts() {
        for q in ["days until", "days until narnia", "days until feb 30", "days until 2027-02-30", "days until 2020-01-01",
                  "days since 2030-01-01", "days until dec", "days until 25", "days until dec 25 27", "days to hours",
                  "days until 2027-13-01", "days since jan 32"] {
            #expect(answer(q) == nil, "\(q)")
        }
    }

    @Test func daysAway() {
        let later = answer("100 days from now")
        #expect(reads(later?.value, "Saturday", "25 April", "2026"))
        #expect(later?.note == "2026-04-25")
        #expect(later?.question == "100 days from now")
        #expect(later?.kind == .date)
        #expect(reads(answer("in 100 days")?.value, "Saturday", "25 April", "2026"))
        #expect(answer("3 weeks from today")?.note == "2026-02-05")
        #expect(answer("in 2 wks")?.note == "2026-01-29")
        #expect(answer("10 days ago")?.note == "2026-01-05")
        #expect(answer("1 day ago")?.note == "2026-01-14")
        #expect(answer("2 months from now")?.note == "2026-03-15")
        #expect(answer("1 year ago")?.note == "2025-01-15")
        #expect(answer("5 days later")?.note == "2026-01-20")
    }

    @Test func notDaysAway() {
        for q in ["100 days", "in days", "in 100", "days ago", "in 3 days ago", "100 days from", "in 100 parsecs",
                  "in 1234567 days", "in -3 days", "a week from now"] {
            #expect(answer(q) == nil, "\(q)")
        }
    }

    @Test func weekNumber() {
        let week = answer("week number")
        #expect(week?.value == "3")
        #expect(week?.question == "Week number")
        #expect(reads(week?.note, "12", "18", "Jan", "2026"))
        #expect(week?.note?.hasPrefix("2026") == false)
        #expect(week?.kind == .date)
        #expect(answer("What week is it")?.value == "3")
        // ISO weeks start on Monday, and the first holds the year's first Thursday: Sunday
        // 4 January 2026 is still in week 1, Monday the 5th starts week 2.
        let sunday = Date(timeIntervalSince1970: 1_767_528_000)
        #expect(Answer.answer(for: "week number", now: sunday, timeZone: TimeZone(identifier: "UTC")!, locale: gb)?.value == "1")
        let monday = sunday.addingTimeInterval(86_400)
        #expect(Answer.answer(for: "week number", now: monday, timeZone: TimeZone(identifier: "UTC")!, locale: gb)?.value == "2")
    }

    @Test func unixTimestamps() {
        let seconds = answer("1768478400")
        #expect(reads(seconds?.value, "15 Jan 2026", "12:00:00"))
        #expect(seconds?.note == "2026-01-15T12:00:00Z")
        #expect(seconds?.kind == .timestamp)
        #expect(reads(answer("1768478400", zone: "Asia/Tokyo")?.value, "15 Jan 2026", "21:00:00"))
        let millis = answer("1768478400123")
        #expect(reads(millis?.value, "15 Jan 2026", "12:00:00"))
        #expect(millis?.note == "2026-01-15T12:00:00.123Z")
        // Now.
        for q in ["unix time", "now in unix", "timestamp", "Unix Timestamp"] {
            #expect(answer(q)?.value == "1768478400", "\(q)")
            #expect(answer(q)?.kind == .timestamp)
        }
        #expect(answer("unix time")?.note == "2026-01-15T12:00:00Z")
        #expect(answer("unix time")?.question == "Unix time")
    }

    @Test func notTimestamps() {
        // Too short, too long, before 2001 or after 2100 (a phone number, often), or not all digits.
        for q in ["100", "2024", "123456789", "12345678901", "999999999", "9999999999", "5551234567", "0000000000",
                  "123456789012", "99999999999999", "1768478400.5", "17684784OO", "unix", "epoch"] {
            #expect(answer(q) == nil, "\(q)")
        }
    }

    @Test func numberBases() {
        let hex = answer("0x1F")
        #expect(hex?.value == "31")
        #expect(hex?.question == "0x1F")
        #expect(hex?.note == "0b11111 · 0o37")
        #expect(hex?.kind == .numberBase)
        #expect(answer("0b1011")?.value == "11")
        #expect(answer("0o17")?.value == "15")
        #expect(answer("0xdead_beef")?.value == "3735928559")
        let toHex = answer("255 in hex")
        #expect(toHex?.value == "0xFF")
        #expect(toHex?.question == "255")
        #expect(toHex?.note == "0b11111111 · 0o377")
        #expect(answer("255 to binary")?.value == "0b11111111")
        #expect(answer("8 in octal")?.value == "0o10")
        #expect(answer("0x1F to binary")?.value == "0b11111")
        #expect(answer("0b11 in decimal")?.value == "3")
        #expect(answer("0 in hex")?.value == "0x0")
    }

    @Test func notNumberBases() {
        for q in ["0x", "0xZZ", "0b102", "0o9", "255", "255 in hexagon", "0x1F in hex", "255 in dec", "-5 in hex",
                  "1.5 in hex", "0x10000000000000000", "hex", "in hex"] {
            #expect(answer(q) == nil, "\(q)")
        }
    }

    @Test func base64() {
        let encoded = answer("base64 hello")
        #expect(encoded?.value == "aGVsbG8=")
        #expect(encoded?.question == "hello")
        #expect(encoded?.kind == .base64)
        #expect(answer("base64 Hello World")?.value == "SGVsbG8gV29ybGQ=")
        #expect(answer("Base64 encode héllo")?.value == "aMOpbGxv")
        let decoded = answer("decode aGVsbG8=")
        #expect(decoded?.value == "hello")
        #expect(decoded?.question == "aGVsbG8=")
        #expect(decoded?.kind == .base64)
        #expect(answer("base64 -d aGVsbG8=")?.value == "hello")
        #expect(answer("base64 --decode SGVsbG8gV29ybGQ")?.value == "Hello World")
        #expect(answer("decode aMOpbGxv")?.value == "héllo")
        // URL-safe Base64: "??>" is "Pz8-".
        #expect(answer("decode Pz8-")?.value == "??>")
    }

    @Test func notBase64() {
        // Not Base64, or bytes that aren't readable text.
        for q in ["base64", "base64 ", "decode", "decode hello", "decode test", "decode abc", "decode aGVs bG8=",
                  "decode aGV=sbG8", "decode AAEC", "decode //79", "base64 -d", "decode !!!!", "decode CQ=="] {
            #expect(answer(q) == nil, "\(q)")
        }
    }

    /// Ordinary searches for apps don't turn into answers.
    @Test func appSearchesStayAppSearches() {
        let searches = ["100", "7", "42", "2024", "Day One", "day one", "Week", "week", "Base", "base", "Days", "days",
                        "Calendar", "Clock", "Time Machine", "Timer", "Color Picker", "Digital Color Meter", "Hex Fiend",
                        "Base Camp", "Basecamp", "Decoder", "Unix", "Epoch", "Weekly", "Week Calendar", "Days Left",
                        "Countdown", "1Password", "Things 3", "Final Cut Pro", "Logic Pro X", "Xcode", "Pixelmator Pro",
                        "Affinity Photo 2", "#", "#hashtag", "rgb", "hsl", "Binary", "Octal", "Hex", "In", "Ago",
                        "from now", "Timestamp Converter", "100 days", "Decode", "Encode", "Decode Pro"]
        for q in searches {
            #expect(answer(q) == nil, "\(q) gave \(answer(q)?.value ?? "")")
        }
    }

    @Test func existingAnswersAreUnchanged() {
        #expect(answer("12*7")?.kind == .arithmetic)
        #expect(answer("5 km in mi")?.kind == .conversion(.length))
        #expect(answer("3 days in hours")?.value == "72 h")
        #expect(answer("100 days in weeks")?.value == "14.29 wk")
        #expect(answer("time in tokyo")?.value == "21:00")
        #expect(answer("tokyo time")?.value == "21:00")
        #expect(answer("3pm PST")?.kind == .time(hour: 23, minute: 0, dayShift: 0))
    }
}
