import Foundation

/// A quick answer search can give for what was typed, shown above the results (Return copies
/// it): arithmetic ("12*7", "=2^10", "(3+4)/2"), a unit conversion ("5 km in mi", "70 f to c",
/// "2 GB in MB") or a time elsewhere ("3pm PST", "15:00 utc in tokyo", "time in london").
/// Worked out here, from what was typed alone: nothing is looked up anywhere.
public struct Answer: Equatable, Sendable {
    /// The question as it will be shown: "12 × 7", "5 km".
    public var question: String
    /// What Return copies: "84", "3.11 mi", "17:00".
    public var value: String
    /// A word on what the value is, if it needs one: "your time", "in Tokyo".
    public var note: String?

    public init(question: String, value: String, note: String? = nil) {
        self.question = question
        self.value = value
        self.note = note
    }

    /// The answer for `query`, or nil when it isn't a question of these kinds. `now`, the time
    /// zone and the locale are for the tests.
    public static func answer(for query: String, now: Date = Date(), timeZone: TimeZone = .current,
                              locale: Locale = .current) -> Answer? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count <= 120 else { return nil }
        if let a = arithmetic(q, locale: locale) { return a }
        if let a = conversion(q, locale: locale) { return a }
        if let a = time(q, now: now, timeZone: timeZone, locale: locale) { return a }
        return nil
    }

    // MARK: Arithmetic

    static func arithmetic(_ q: String, locale: Locale) -> Answer? {
        var text = q
        let forced = text.hasPrefix("=")
        if forced { text.removeFirst() }
        let allowed = CharacterSet(charactersIn: "0123456789.,+-*/×÷^%() \u{2212}")
        let letters = text.lowercased().replacingOccurrences(of: "sqrt", with: "").replacingOccurrences(of: "pi", with: "")
            .replacingOccurrences(of: "π", with: "").replacingOccurrences(of: "√", with: "")
        guard !text.isEmpty, letters.unicodeScalars.allSatisfy(allowed.contains),
              text.contains(where: \.isNumber) else { return nil }
        // A lone number, or one with a sign, isn't a sum to work out ("-5", "2024"); "=" asks anyway.
        let hasOperator = text.dropFirst().contains { "+-*/×÷^%\u{2212}".contains($0) } || text.lowercased().contains("sqrt") || text.contains("√")
        guard hasOperator || forced else { return nil }
        var parser = ExpressionParser(text, decimalSeparator: locale.decimalSeparator ?? ".")
        guard let value = parser.parse(), value.isFinite else { return nil }
        return Answer(question: pretty(text), value: format(value, locale: locale))
    }

    /// "12*7" as "12 × 7": the operators spaced out and written as on paper.
    static func pretty(_ text: String) -> String {
        var out = ""
        for ch in text where !ch.isWhitespace {
            switch ch {
            case "*", "×": out += " × "
            case "/", "÷": out += " ÷ "
            case "+": out += " + "
            case "-", "\u{2212}":
                // A minus after an operator or at the start is a sign: no spaces.
                let last = out.last(where: { !$0.isWhitespace })
                if last == nil || "×÷+−(^".contains(last!) { out += "−" } else { out += " − " }
            default: out.append(ch)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Up to 10 significant digits, without a trailing ".0", grouped as the locale groups them.
    static func format(_ value: Double, locale: Locale, maxFraction: Int = 10) -> String {
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e15 || magnitude < 1e-9 {
            let f = NumberFormatter()
            f.locale = locale
            f.numberStyle = .scientific
            f.maximumSignificantDigits = 8
            return f.string(from: value as NSNumber) ?? "\(value)"
        }
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesSignificantDigits = true
        f.maximumSignificantDigits = 10
        f.usesGroupingSeparator = magnitude >= 10_000
        return f.string(from: value as NSNumber) ?? "\(value)"
    }

    // MARK: Units

    struct UnitName {
        let unit: Dimension
        let names: [String]
    }

    static let units: [UnitName] = [
        // Length
        UnitName(unit: UnitLength.millimeters, names: ["mm", "millimeter", "millimeters", "millimetre", "millimetres"]),
        UnitName(unit: UnitLength.centimeters, names: ["cm", "centimeter", "centimeters", "centimetre", "centimetres"]),
        UnitName(unit: UnitLength.meters, names: ["m", "meter", "meters", "metre", "metres"]),
        UnitName(unit: UnitLength.kilometers, names: ["km", "kilometer", "kilometers", "kilometre", "kilometres"]),
        UnitName(unit: UnitLength.inches, names: ["in", "inch", "inches", "\""]),
        UnitName(unit: UnitLength.feet, names: ["ft", "foot", "feet", "'"]),
        UnitName(unit: UnitLength.yards, names: ["yd", "yard", "yards"]),
        UnitName(unit: UnitLength.miles, names: ["mi", "mile", "miles"]),
        UnitName(unit: UnitLength.nauticalMiles, names: ["nmi", "nautical mile", "nautical miles"]),
        // Mass
        UnitName(unit: UnitMass.milligrams, names: ["mg", "milligram", "milligrams"]),
        UnitName(unit: UnitMass.grams, names: ["g", "gram", "grams"]),
        UnitName(unit: UnitMass.kilograms, names: ["kg", "kilo", "kilos", "kilogram", "kilograms"]),
        UnitName(unit: UnitMass.metricTons, names: ["t", "tonne", "tonnes"]),
        UnitName(unit: UnitMass.ounces, names: ["oz", "ounce", "ounces"]),
        UnitName(unit: UnitMass.pounds, names: ["lb", "lbs", "pound", "pounds"]),
        UnitName(unit: UnitMass.stones, names: ["st", "stone", "stones"]),
        // Temperature
        UnitName(unit: UnitTemperature.celsius, names: ["c", "°c", "celsius", "degc"]),
        UnitName(unit: UnitTemperature.fahrenheit, names: ["f", "°f", "fahrenheit", "degf"]),
        UnitName(unit: UnitTemperature.kelvin, names: ["k", "kelvin"]),
        // Volume
        UnitName(unit: UnitVolume.milliliters, names: ["ml", "milliliter", "milliliters", "millilitre", "millilitres"]),
        UnitName(unit: UnitVolume.liters, names: ["l", "liter", "liters", "litre", "litres"]),
        UnitName(unit: UnitVolume.gallons, names: ["gal", "gallon", "gallons"]),
        UnitName(unit: UnitVolume.quarts, names: ["qt", "quart", "quarts"]),
        UnitName(unit: UnitVolume.pints, names: ["pt", "pint", "pints"]),
        UnitName(unit: UnitVolume.cups, names: ["cup", "cups"]),
        UnitName(unit: UnitVolume.fluidOunces, names: ["fl oz", "floz", "fluid ounce", "fluid ounces"]),
        UnitName(unit: UnitVolume.tablespoons, names: ["tbsp", "tablespoon", "tablespoons"]),
        UnitName(unit: UnitVolume.teaspoons, names: ["tsp", "teaspoon", "teaspoons"]),
        // Speed
        UnitName(unit: UnitSpeed.kilometersPerHour, names: ["km/h", "kmh", "kph"]),
        UnitName(unit: UnitSpeed.milesPerHour, names: ["mph", "mi/h"]),
        UnitName(unit: UnitSpeed.metersPerSecond, names: ["m/s"]),
        UnitName(unit: UnitSpeed.knots, names: ["kn", "kt", "knot", "knots"]),
        // Data
        UnitName(unit: UnitInformationStorage.bytes, names: ["b", "byte", "bytes"]),
        UnitName(unit: UnitInformationStorage.kilobytes, names: ["kb", "kilobyte", "kilobytes"]),
        UnitName(unit: UnitInformationStorage.megabytes, names: ["mb", "megabyte", "megabytes"]),
        UnitName(unit: UnitInformationStorage.gigabytes, names: ["gb", "gigabyte", "gigabytes"]),
        UnitName(unit: UnitInformationStorage.terabytes, names: ["tb", "terabyte", "terabytes"]),
        UnitName(unit: UnitInformationStorage.kibibytes, names: ["kib"]),
        UnitName(unit: UnitInformationStorage.mebibytes, names: ["mib"]),
        UnitName(unit: UnitInformationStorage.gibibytes, names: ["gib"]),
        // Time
        UnitName(unit: UnitDuration.seconds, names: ["s", "sec", "secs", "second", "seconds"]),
        UnitName(unit: UnitDuration.minutes, names: ["min", "mins", "minute", "minutes"]),
        UnitName(unit: UnitDuration.hours, names: ["h", "hr", "hrs", "hour", "hours"]),
        UnitName(unit: UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400)), names: ["d", "day", "days"]),
        UnitName(unit: UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800)), names: ["wk", "week", "weeks"]),
        // Area
        UnitName(unit: UnitArea.squareMeters, names: ["m2", "m²", "sq m", "square meter", "square meters", "square metre", "square metres"]),
        UnitName(unit: UnitArea.squareFeet, names: ["ft2", "ft²", "sq ft", "square foot", "square feet"]),
        UnitName(unit: UnitArea.squareKilometers, names: ["km2", "km²", "sq km"]),
        UnitName(unit: UnitArea.squareMiles, names: ["mi2", "mi²", "sq mi"]),
        UnitName(unit: UnitArea.hectares, names: ["ha", "hectare", "hectares"]),
        UnitName(unit: UnitArea.acres, names: ["ac", "acre", "acres"]),
    ]

    static func unit(named raw: String) -> Dimension? {
        let name = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return units.first { $0.names.contains(name) }?.unit
    }

    /// The symbol shown after a converted value: the first name it's known by, which is the
    /// short one ("mi", "°F" for clarity on temperatures).
    static func symbol(_ unit: Dimension) -> String {
        switch unit {
        case UnitTemperature.celsius: return "°C"
        case UnitTemperature.fahrenheit: return "°F"
        case UnitTemperature.kelvin: return "K"
        case UnitInformationStorage.kilobytes: return "KB"
        case UnitInformationStorage.megabytes: return "MB"
        case UnitInformationStorage.gigabytes: return "GB"
        case UnitInformationStorage.terabytes: return "TB"
        case UnitInformationStorage.kibibytes: return "KiB"
        case UnitInformationStorage.mebibytes: return "MiB"
        case UnitInformationStorage.gibibytes: return "GiB"
        case UnitInformationStorage.bytes: return "B"
        default: return units.first { $0.unit == unit }?.names.first ?? unit.symbol
        }
    }

    /// "<number> <unit> in|to|as <unit>", the number first or with no space ("5km in mi").
    static func conversion(_ q: String, locale: Locale) -> Answer? {
        let lower = q.lowercased()
        var split: (String, String)?
        for word in [" in ", " to ", " as ", " → ", " -> ", " = "] {
            if let r = lower.range(of: word, options: .backwards) {
                split = (String(lower[..<r.lowerBound]), String(lower[r.upperBound...]))
                break
            }
        }
        guard let (left, right) = split else { return nil }
        let decimal = locale.decimalSeparator ?? "."
        // The number: digits, a sign, a decimal point (either kind) and thousands separators.
        let numberEnd = left.firstIndex { !($0.isNumber || $0 == "." || $0 == "," || $0 == "-" || $0 == "\u{2212}") } ?? left.endIndex
        var numberText = String(left[..<numberEnd]).replacingOccurrences(of: "\u{2212}", with: "-")
        guard numberText.contains(where: \.isNumber) else { return nil }
        if decimal == "," {
            numberText = numberText.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else {
            numberText = numberText.replacingOccurrences(of: ",", with: "")
        }
        guard let number = Double(numberText),
              let from = unit(named: String(left[numberEnd...])),
              let to = unit(named: right),
              type(of: from) == type(of: to), from != to else { return nil }
        let converted = Measurement(value: number, unit: from).converted(to: to).value
        guard converted.isFinite else { return nil }
        let shown = format(rounded(converted), locale: locale)
        return Answer(question: "\(format(number, locale: locale)) \(symbol(from))", value: "\(shown) \(symbol(to))")
    }

    /// A conversion to a few decimal places: 3.106855961 mi is 3.11 mi to anyone asking.
    static func rounded(_ value: Double) -> Double {
        let magnitude = abs(value)
        let places: Double = magnitude >= 100 ? 1 : magnitude >= 1 ? 2 : 4
        let scale = pow(10, places)
        let r = (value * scale).rounded() / scale
        // Still something, rather than 0, for a tiny amount.
        return r == 0 ? value : r
    }

    // MARK: Time

    /// "3pm PST", "15:00 utc", "9:30 am tokyo in paris", "time in london", "london time",
    /// "now in new york".
    static func time(_ q: String, now: Date, timeZone local: TimeZone, locale: Locale) -> Answer? {
        let lower = q.lowercased().trimmingCharacters(in: .whitespaces)
        // The time now somewhere.
        for prefix in ["time in ", "now in ", "what time is it in "] where lower.hasPrefix(prefix) {
            guard let zone = zone(named: String(lower.dropFirst(prefix.count))) else { return nil }
            return Answer(question: String(localized: "Time in \(zone.name)"),
                          value: clock(now, in: zone.zone, locale: locale), note: zoneNote(zone.zone, at: now, locale: locale))
        }
        if lower.hasSuffix(" time"), let zone = zone(named: String(lower.dropLast(5))) {
            return Answer(question: String(localized: "Time in \(zone.name)"),
                          value: clock(now, in: zone.zone, locale: locale), note: zoneNote(zone.zone, at: now, locale: locale))
        }
        // A time somewhere, here (or in a second place after " in ").
        var source = lower
        var target: (zone: TimeZone, name: String)?
        if let r = lower.range(of: " in ", options: .backwards) ?? lower.range(of: " to ", options: .backwards) {
            guard let z = zone(named: String(lower[r.upperBound...])) else { return nil }
            target = (z.zone, z.name)
            source = String(lower[..<r.lowerBound])
        }
        guard let (hour, minute, rest) = clockTime(source), !rest.isEmpty, let from = zone(named: rest) else { return nil }
        // That time today where it is.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = from.zone
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour
        parts.minute = minute
        guard let date = calendar.date(from: parts) else { return nil }
        let to = target?.zone ?? local
        let question = "\(clock(date, in: from.zone, locale: locale)) \(from.name)"
        let note: String = if let target {
            String(localized: "in \(target.name)") + dayShift(date, from: from.zone, to: target.zone)
        } else {
            String(localized: "your time") + dayShift(date, from: from.zone, to: local)
        }
        return Answer(question: question, value: clock(date, in: to, locale: locale), note: note)
    }

    /// "3pm", "3:30 pm", "15:00", "9am" at the start of `s`, and what's left after it.
    static func clockTime(_ s: String) -> (hour: Int, minute: Int, rest: String)? {
        let scanner = Scanner(string: s)
        scanner.charactersToBeSkipped = nil
        guard let hour = scanner.scanInt(), (0...24).contains(hour) else { return nil }
        var minute = 0
        var hasMinutes = false
        if scanner.scanString(":") != nil || scanner.scanString(".") != nil || scanner.scanString("h") != nil {
            guard let m = scanner.scanInt(), (0...59).contains(m) else { return nil }
            minute = m
            hasMinutes = true
        }
        _ = scanner.scanCharacters(from: .whitespaces)
        var h = hour
        if scanner.scanString("am") != nil || scanner.scanString("a.m.") != nil {
            guard (1...12).contains(hour) else { return nil }
            h = hour == 12 ? 0 : hour
        } else if scanner.scanString("pm") != nil || scanner.scanString("p.m.") != nil {
            guard (1...12).contains(hour) else { return nil }
            h = hour == 12 ? 12 : hour + 12
        } else if !hasMinutes {
            // "3 tokyo" is too loose to be a time; "15:00 tokyo" or "3pm tokyo" aren't.
            return nil
        }
        guard h < 24 else { return nil }
        let rest = String(s[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
        return (h, minute, rest)
    }

    /// Time zone abbreviations people type, beyond what `TimeZone(abbreviation:)` knows, and
    /// a few places that aren't in a zone's identifier.
    static let zoneNames: [String: String] = [
        "pt": "America/Los_Angeles", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "pacific": "America/Los_Angeles",
        "mt": "America/Denver", "mst": "America/Denver", "mdt": "America/Denver", "mountain": "America/Denver",
        "ct": "America/Chicago", "cst": "America/Chicago", "cdt": "America/Chicago", "central": "America/Chicago",
        "et": "America/New_York", "est": "America/New_York", "edt": "America/New_York", "eastern": "America/New_York",
        "akst": "America/Anchorage", "hst": "Pacific/Honolulu",
        "gmt": "GMT", "utc": "UTC", "z": "UTC", "zulu": "UTC",
        "bst": "Europe/London", "ist": "Asia/Kolkata", "cet": "Europe/Paris", "cest": "Europe/Paris",
        "eet": "Europe/Athens", "eest": "Europe/Athens", "wet": "Europe/Lisbon", "msk": "Europe/Moscow",
        "jst": "Asia/Tokyo", "kst": "Asia/Seoul", "hkt": "Asia/Hong_Kong", "sgt": "Asia/Singapore",
        "aest": "Australia/Sydney", "aedt": "Australia/Sydney", "acst": "Australia/Adelaide", "awst": "Australia/Perth",
        "nzst": "Pacific/Auckland", "nzdt": "Pacific/Auckland",
        "new york": "America/New_York", "nyc": "America/New_York", "san francisco": "America/Los_Angeles", "sf": "America/Los_Angeles",
        "seattle": "America/Los_Angeles", "boston": "America/New_York", "washington": "America/New_York", "miami": "America/New_York",
        "atlanta": "America/New_York", "dallas": "America/Chicago", "houston": "America/Chicago", "austin": "America/Chicago",
        "montreal": "America/Toronto", "ottawa": "America/Toronto", "beijing": "Asia/Shanghai", "delhi": "Asia/Kolkata",
        "mumbai": "Asia/Kolkata", "bangalore": "Asia/Kolkata", "munich": "Europe/Berlin", "barcelona": "Europe/Madrid",
        "geneva": "Europe/Zurich", "osaka": "Asia/Tokyo", "kyoto": "Asia/Tokyo", "melbourne": "Australia/Melbourne",
    ]

    /// The zone `raw` names: an abbreviation, an alias above, or a city in a zone identifier
    /// ("tokyo" for Asia/Tokyo, "los angeles").
    static func zone(named raw: String) -> (zone: TimeZone, name: String)? {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return nil }
        if let id = zoneNames[name], let z = TimeZone(identifier: id) {
            let shown = name.count <= 5 && !name.contains(" ") ? name.uppercased() : name.capitalized
            return (z, shown)
        }
        let wanted = name.replacingOccurrences(of: " ", with: "_")
        if let id = TimeZone.knownTimeZoneIdentifiers.first(where: { $0.split(separator: "/").last?.lowercased() == wanted }),
           let z = TimeZone(identifier: id) {
            return (z, String(id.split(separator: "/").last!).replacingOccurrences(of: "_", with: " "))
        }
        return nil
    }

    static func clock(_ date: Date, in zone: TimeZone, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date)
    }

    /// The zone's offset from UTC now: "UTC+9".
    static func zoneNote(_ zone: TimeZone, at date: Date, locale: Locale) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let h = seconds / 3600, m = abs(seconds % 3600) / 60
        let sign = seconds < 0 ? "−" : "+"
        return m == 0 ? "UTC\(sign)\(abs(h))" : String(format: "UTC%@%d:%02d", sign, abs(h), m)
    }

    /// ", next day" or ", previous day" when the time falls on another date there.
    static func dayShift(_ date: Date, from: TimeZone, to: TimeZone) -> String {
        var a = Calendar(identifier: .gregorian), b = a
        a.timeZone = from
        b.timeZone = to
        let da = a.dateComponents([.year, .month, .day], from: date), db = b.dateComponents([.year, .month, .day], from: date)
        guard let x = a.date(from: da), let y = a.date(from: db), x != y else { return "" }
        return y > x ? String(localized: ", next day") : String(localized: ", previous day")
    }
}

/// Arithmetic with the usual precedence: + − below × ÷ %, below ^ (right to left), unary minus,
/// parentheses, √ and sqrt(), π and pi. A "%" after a number is a percentage ("50%" is 0.5,
/// "200 + 10%" adds 10% of 200, as a calculator does).
struct ExpressionParser {
    private let chars: [Character]
    private var i = 0
    private let decimalSeparator: Character

    init(_ text: String, decimalSeparator: String) {
        chars = Array(text.lowercased().filter { !$0.isWhitespace })
        self.decimalSeparator = decimalSeparator.first ?? "."
    }

    mutating func parse() -> Double? {
        guard let v = sum(), i == chars.count else { return nil }
        return v
    }

    private var peek: Character? { i < chars.count ? chars[i] : nil }

    private mutating func eat(_ c: Character) -> Bool {
        if peek == c { i += 1; return true }
        return false
    }

    private mutating func sum() -> Double? {
        guard var v = product() else { return nil }
        while let c = peek, "+-\u{2212}".contains(c) {
            i += 1
            guard let rhs = product(percentOf: v) else { return nil }
            v = c == "+" ? v + rhs : v - rhs
        }
        return v
    }

    /// `percentOf`: the left side of a + or −, which a trailing % takes its share of.
    private mutating func product(percentOf base: Double? = nil) -> Double? {
        guard var v = power(percentOf: base) else { return nil }
        while let c = peek, "*/×÷%".contains(c) {
            // "%" here is the percentage sign, if nothing follows it that it could divide.
            if c == "%" {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if next == nil || ")+-\u{2212}*/×÷".contains(next!) { break }
            }
            i += 1
            guard let rhs = power() else { return nil }
            switch c {
            case "*", "×": v *= rhs
            case "/", "÷": guard rhs != 0 else { return nil }; v /= rhs
            default: guard rhs != 0 else { return nil }; v = v.truncatingRemainder(dividingBy: rhs)
            }
        }
        return v
    }

    private mutating func power(percentOf base: Double? = nil) -> Double? {
        guard var v = unary() else { return nil }
        // A percentage only when nothing it could take the remainder by follows it.
        if peek == "%", i + 1 == chars.count || ")+-\u{2212}*/×÷^".contains(chars[i + 1]) {
            i += 1
            v = base.map { $0 * v / 100 } ?? v / 100
        }
        if eat("^") {
            guard let e = power() else { return nil }
            v = pow(v, e)
        }
        return v
    }

    private mutating func unary() -> Double? {
        if eat("-") || eat("\u{2212}") { return unary().map { -$0 } }
        if eat("+") { return unary() }
        if eat("√") { return unary().flatMap { $0 < 0 ? nil : $0.squareRoot() } }
        return atom()
    }

    private mutating func atom() -> Double? {
        if eat("(") {
            guard let v = sum(), eat(")") else { return nil }
            return v
        }
        if word("sqrt") {
            guard eat("("), let v = sum(), eat(")"), v >= 0 else { return nil }
            return v.squareRoot()
        }
        if word("pi") || eat("π") { return .pi }
        return number()
    }

    private mutating func word(_ w: String) -> Bool {
        let letters = Array(w)
        guard i + letters.count <= chars.count, Array(chars[i..<i + letters.count]) == letters else { return false }
        i += letters.count
        return true
    }

    private mutating func number() -> Double? {
        var digits = ""
        var seenPoint = false
        while let c = peek {
            if c.isNumber, c.isASCII {
                digits.append(c)
            } else if c == decimalSeparator || (c == "." && decimalSeparator == ","), !seenPoint {
                // In a locale with a decimal comma, a point reads as a decimal point too.
                digits.append(".")
                seenPoint = true
            } else if c == "," && decimalSeparator == "." {
                // A thousands separator, between digits.
                guard i + 1 < chars.count, chars[i + 1].isNumber else { return nil }
            } else {
                break
            }
            i += 1
        }
        return digits.isEmpty || digits == "." ? nil : Double(digits)
    }
}
