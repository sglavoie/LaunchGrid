import Foundation

/// A quick answer search can give for what was typed, shown above the results (Return copies
/// it): arithmetic ("12*7", "=2^10", "(3+4)/2"), a unit conversion ("5 km in mi", "70 f to c",
/// "2 GB in MB"), a time elsewhere ("3pm PST", "15:00 utc in tokyo", "time in london"), a colour
/// ("#ff8800", "rgb(255, 136, 0)"), a date ("days until dec 25", "in 100 days", "week number"),
/// a Unix timestamp ("1768478400", "unix time"), a number in another base ("0x1F", "255 in hex")
/// or Base64 ("base64 hello", "decode aGVsbG8="). Worked out here, from what was typed alone
/// (and the clock): nothing is looked up anywhere, and no file is read.
public struct Answer: Equatable, Sendable {
    /// The question as it will be shown: "12 × 7", "5 km".
    public var question: String
    /// What Return copies: "84", "3.11 mi", "17:00".
    public var value: String
    /// A word on what the value is, if it needs one: "your time", "in Tokyo".
    public var note: String?
    /// What kind of answer it is, for how it's shown: a clock for a time, a unit's symbol.
    public var kind: Kind

    /// What an answer is about.
    public enum Kind: Equatable, Sendable {
        case arithmetic
        /// A conversion between units of `category`.
        case conversion(Category)
        /// A time: the hour (0–23) and minute shown in `value`, and whether that falls on the
        /// day after (1) or before (-1) the time asked about.
        case time(hour: Int, minute: Int, dayShift: Int)
        /// A colour, its red, green and blue (0–255) for a swatch.
        case color(red: Int, green: Int, blue: Int)
        /// A date: days until or since one, a day some days away, or the week number.
        case date
        /// A Unix timestamp as a date, or the time now as one.
        case timestamp
        /// A whole number written in another base: hexadecimal, binary, octal or decimal.
        case numberBase
        /// Text to Base64, or Base64 back to text.
        case base64
    }

    /// What a converted quantity measures.
    public enum Category: String, Equatable, Sendable {
        case length, mass, temperature, volume, speed, data, duration, area
    }

    public init(question: String, value: String, note: String? = nil, kind: Kind = .arithmetic) {
        self.question = question
        self.value = value
        self.note = note
        self.kind = kind
    }

    /// The answer for `query`, or nil when it isn't a question of these kinds. `now`, the time
    /// zone and the locale are for the tests.
    public static func answer(for query: String, now: Date = Date(), timeZone: TimeZone = .current,
                              locale: Locale = .current) -> Answer? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count <= 120 else { return nil }
        if let a = arithmetic(q, locale: locale) { return a }
        if let a = conversion(q, locale: locale) { return a }
        // Before times, which take "… in …" and "… time" as a place and give up on anything else.
        if let a = colour(q) { return a }
        if let a = numberBase(q) { return a }
        if let a = base64(q) { return a }
        if let a = timestamp(q, now: now, timeZone: timeZone, locale: locale) { return a }
        if let a = date(q, now: now, timeZone: timeZone, locale: locale) { return a }
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
              category(of: from) == category(of: to), from != to else { return nil }
        let converted = Measurement(value: number, unit: from).converted(to: to).value
        guard converted.isFinite else { return nil }
        let shown = format(rounded(converted), locale: locale)
        return Answer(question: "\(format(number, locale: locale)) \(symbol(from))", value: "\(shown) \(symbol(to))",
                      kind: .conversion(category(of: from)))
    }

    /// What a unit measures.
    static func category(of unit: Dimension) -> Category {
        switch unit {
        case is UnitLength: .length
        case is UnitMass: .mass
        case is UnitTemperature: .temperature
        case is UnitVolume: .volume
        case is UnitSpeed: .speed
        case is UnitInformationStorage: .data
        case is UnitDuration: .duration
        default: .area
        }
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
                          value: clock(now, in: zone.zone, locale: locale), note: zoneNote(zone.zone, at: now, locale: locale),
                          kind: timeKind(now, in: zone.zone, shift: 0))
        }
        if lower.hasSuffix(" time"), let zone = zone(named: String(lower.dropLast(5))) {
            return Answer(question: String(localized: "Time in \(zone.name)"),
                          value: clock(now, in: zone.zone, locale: locale), note: zoneNote(zone.zone, at: now, locale: locale),
                          kind: timeKind(now, in: zone.zone, shift: 0))
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
        return Answer(question: question, value: clock(date, in: to, locale: locale), note: note,
                      kind: timeKind(date, in: to, shift: dayOffset(date, from: from.zone, to: to)))
    }

    static func timeKind(_ date: Date, in zone: TimeZone, shift: Int) -> Kind {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return .time(hour: parts.hour ?? 0, minute: parts.minute ?? 0, dayShift: shift)
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
        switch dayOffset(date, from: from, to: to) {
        case 0: ""
        case let d where d > 0: String(localized: ", next day")
        default: String(localized: ", previous day")
        }
    }

    /// 1 when `date` falls on the day after in `to` than in `from`, -1 the day before, else 0.
    static func dayOffset(_ date: Date, from: TimeZone, to: TimeZone) -> Int {
        var a = Calendar(identifier: .gregorian), b = a
        a.timeZone = from
        b.timeZone = to
        let da = a.dateComponents([.year, .month, .day], from: date), db = b.dateComponents([.year, .month, .day], from: date)
        guard let x = a.date(from: da), let y = a.date(from: db), x != y else { return 0 }
        return y > x ? 1 : -1
    }
    // MARK: Colours

    /// The ways a colour is written.
    enum ColourForm: String {
        case hex, rgb, hsl
    }

    /// "#ff8800", "#f80", "rgb(255, 136, 0)", "hsl(32, 100%, 50%)", each alone (answered in rgb,
    /// or in hex for rgb and hsl) or "in|to|as hex|rgb|hsl". Hex only with its "#": "ff8800"
    /// alone could be anything.
    static func colour(_ q: String) -> Answer? {
        var source = q
        var target: ColourForm?
        for word in [" in ", " to ", " as "] {
            if let r = q.range(of: word, options: [.backwards, .caseInsensitive]),
               let form = ColourForm(rawValue: q[r.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()) {
                target = form
                source = String(q[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let (rgb, form) = parseColour(source.lowercased()) else { return nil }
        let to = target ?? (form == .hex ? .rgb : .hex)
        let others = [ColourForm.hex, .rgb, .hsl].filter { $0 != to }
            .map { colourText(rgb, $0, degrees: true) }.joined(separator: " · ")
        return Answer(question: source, value: colourText(rgb, to, degrees: false), note: others,
                      kind: .color(red: rgb.r, green: rgb.g, blue: rgb.b))
    }

    typealias RGB = (r: Int, g: Int, b: Int)

    static func parseColour(_ s: String) -> (RGB, ColourForm)? {
        if s.hasPrefix("#") {
            var digits = Array(s.dropFirst())
            guard digits.count == 3 || digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
            if digits.count == 3 { digits = digits.flatMap { [$0, $0] } }
            guard let n = Int(String(digits), radix: 16) else { return nil }
            return ((n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF), .hex)
        }
        func arguments(_ name: String) -> [String]? {
            guard s.hasPrefix(name + "("), s.hasSuffix(")") else { return nil }
            let inside = s.dropFirst(name.count + 1).dropLast()
            let parts = inside.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
            return parts.count == 3 ? parts : nil
        }
        if let parts = arguments("rgb") {
            let values = parts.compactMap { Int($0) }
            guard values.count == 3, values.allSatisfy((0...255).contains) else { return nil }
            return ((values[0], values[1], values[2]), .rgb)
        }
        if let parts = arguments("hsl") {
            func number(_ text: String, dropping suffixes: [String]) -> Double? {
                var t = text
                for suffix in suffixes where t.hasSuffix(suffix) { t.removeLast(suffix.count); break }
                return Double(t)
            }
            guard let h = number(parts[0], dropping: ["°", "deg"]), h.isFinite,
                  let sat = number(parts[1], dropping: ["%"]), let light = number(parts[2], dropping: ["%"]),
                  (0...100).contains(sat), (0...100).contains(light) else { return nil }
            return (rgb(hue: h, saturation: sat / 100, lightness: light / 100), .hsl)
        }
        return nil
    }

    static func rgb(hue: Double, saturation s: Double, lightness l: Double) -> RGB {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch h {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        func byte(_ v: Double) -> Int { min(255, max(0, Int(((v + m) * 255).rounded()))) }
        return (byte(r), byte(g), byte(b))
    }

    /// Hue in degrees, saturation and lightness in percent, each rounded.
    static func hsl(_ c: RGB) -> (h: Int, s: Int, l: Int) {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let high = max(r, g, b), low = min(r, g, b)
        let l = (high + low) / 2
        guard high != low else { return (0, 0, Int((l * 100).rounded())) }
        let d = high - low
        let s = l > 0.5 ? d / (2 - high - low) : d / (high + low)
        var h: Double = switch high {
        case r: (g - b) / d + (g < b ? 6 : 0)
        case g: (b - r) / d + 2
        default: (r - g) / d + 4
        }
        h *= 60
        return (Int(h.rounded()) % 360, Int((s * 100).rounded()), Int((l * 100).rounded()))
    }

    /// "#ff8800", "rgb(255, 136, 0)", "hsl(32, 100%, 50%)": as CSS takes them, or with a degree
    /// sign on the hue for reading.
    static func colourText(_ c: RGB, _ form: ColourForm, degrees: Bool) -> String {
        switch form {
        case .hex: return String(format: "#%02x%02x%02x", c.r, c.g, c.b)
        case .rgb: return "rgb(\(c.r), \(c.g), \(c.b))"
        case .hsl:
            let (h, s, l) = hsl(c)
            return "hsl(\(h)\(degrees ? "°" : ""), \(s)%, \(l)%)"
        }
    }

    // MARK: Number bases

    static let radixNames: [String: Int] = [
        "hex": 16, "hexadecimal": 16, "bin": 2, "binary": 2, "oct": 8, "octal": 8, "dec": 10, "decimal": 10,
    ]

    /// "0x1F", "0b1011", "0o17" in decimal, and "255 in hex", "0x1F to binary", "17 as octal".
    /// A plain number alone isn't asked about.
    static func numberBase(_ q: String) -> Answer? {
        let lower = q.lowercased()
        var source = lower
        var target: Int?
        for word in [" in ", " to ", " as "] {
            if let r = lower.range(of: word, options: .backwards),
               let radix = radixNames[lower[r.upperBound...].trimmingCharacters(in: .whitespaces)] {
                target = radix
                source = lower[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let (n, radix) = integerLiteral(source), radix != 10 || target != nil else { return nil }
        let to = target ?? 10
        guard to != radix else { return nil }
        let others = [10, 16, 2, 8].filter { $0 != to && $0 != radix }.map { based(n, $0) }.joined(separator: " · ")
        return Answer(question: based(n, radix), value: based(n, to), note: others, kind: .numberBase)
    }

    /// A whole number with its base: "0x1f", "0b1011", "0o17", or plain digits.
    static func integerLiteral(_ raw: String) -> (UInt64, Int)? {
        let s = raw.replacingOccurrences(of: "_", with: "")
        let prefixes = ["0x": 16, "0b": 2, "0o": 8]
        var radix = 10
        var digits = Substring(s)
        if let (prefix, r) = prefixes.first(where: { s.hasPrefix($0.key) }) {
            radix = r
            digits = s.dropFirst(prefix.count)
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let n = UInt64(digits, radix: radix) else { return nil }
        return (n, radix)
    }

    /// `n` in base `radix`, with its prefix: "0x1F", "0b11111", "0o37", "31".
    static func based(_ n: UInt64, _ radix: Int) -> String {
        switch radix {
        case 16: "0x" + String(n, radix: 16, uppercase: true)
        case 2: "0b" + String(n, radix: 2)
        case 8: "0o" + String(n, radix: 8)
        default: String(n)
        }
    }

    // MARK: Base64

    /// "base64 hello" (or "base64 encode …", "to base64 …") as Base64, and "decode aGVsbG8=",
    /// "base64 -d …" back to text, only when that's readable text.
    static func base64(_ q: String) -> Answer? {
        let lower = q.lowercased()
        func rest(after prefixes: [String]) -> String? {
            guard let p = prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
            let text = String(q.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        if let text = rest(after: ["base64 -d ", "base64 --decode ", "base64 decode ", "decode base64 ", "from base64 ", "decode "]) {
            guard let decoded = decodeBase64(text) else { return nil }
            return Answer(question: text, value: decoded, note: String(localized: "from Base64"), kind: .base64)
        }
        if let text = rest(after: ["base64 encode ", "encode base64 ", "to base64 ", "base64 "]),
           !["-d", "--decode", "decode", "encode", "-e"].contains(text.lowercased()) {
            return Answer(question: text, value: Data(text.utf8).base64EncodedString(), note: String(localized: "in Base64"),
                          kind: .base64)
        }
        return nil
    }

    /// The text `encoded` holds, standard or URL-safe, padded or not; nil unless it's UTF-8
    /// with nothing unprintable in it.
    static func decodeBase64(_ encoded: String) -> String? {
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/-_=")
        guard encoded.count >= 4, encoded.unicodeScalars.allSatisfy(alphabet.contains) else { return nil }
        var text = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let unpadded = text.replacingOccurrences(of: "=", with: "")
        // "=" only at the end.
        guard text.hasPrefix(unpadded) else { return nil }
        text = unpadded + String(repeating: "=", count: (4 - unpadded.count % 4) % 4)
        guard let data = Data(base64Encoded: text), !data.isEmpty,
              let decoded = String(data: data, encoding: .utf8),
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\u{FFFD}" }),
              !decoded.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return decoded
    }

    // MARK: Unix timestamps

    static let unixPhrases: Set<String> = [
        "unix time", "unix timestamp", "timestamp", "now in unix", "unix now", "epoch time",
        "current timestamp", "time in unix",
    ]

    /// "unix time" now, and a 10-digit (seconds) or 13-digit (milliseconds) number from 2001 to
    /// 2100 as a date: shorter numbers are counts, longer ones aren't dates people have.
    static func timestamp(_ q: String, now: Date, timeZone: TimeZone, locale: Locale) -> Answer? {
        let lower = q.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if unixPhrases.contains(lower) {
            return Answer(question: String(localized: "Unix time"), value: String(Int64(now.timeIntervalSince1970.rounded(.down))),
                          note: iso8601(now, fraction: false), kind: .timestamp)
        }
        guard lower.count == 10 || lower.count == 13, lower.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int64(lower) else { return nil }
        let millis = lower.count == 13
        let seconds = millis ? Double(n) / 1000 : Double(n)
        // 2001-01-01 to 2100-01-01, UTC.
        guard (978_307_200..<4_102_444_800).contains(seconds) else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .medium
        return Answer(question: lower, value: f.string(from: date), note: iso8601(date, fraction: millis), kind: .timestamp)
    }

    /// "2026-01-15T12:00:00Z", in UTC.
    static func iso8601(_ date: Date, fraction: Bool) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = fraction ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: Dates

    static let weekPhrases: Set<String> = [
        "week number", "week no", "week no.", "week #", "week num", "what week is it", "which week is it",
        "what week is this", "current week", "iso week", "week of the year", "what week number is it",
    ]

    static let monthNames: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4, "may": 5,
        "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]

    /// "days until dec 25" (the next one, without a year), "days since jan 1", "days until
    /// 2027-01-01"; "100 days from now", "in 3 weeks", "10 days ago"; "week number".
    static func date(_ q: String, now: Date, timeZone: TimeZone, locale: Locale) -> Answer? {
        let lower = q.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        if weekPhrases.contains(lower) { return weekNumber(now: now, timeZone: timeZone, locale: locale) }
        let counts: [(String, Bool)] = [
            ("how many days until ", true), ("how many days till ", true), ("how many days since ", false),
            ("days until ", true), ("days till ", true), ("days to ", true), ("days since ", false),
        ]
        if let (prefix, ahead) = counts.first(where: { lower.hasPrefix($0.0) }) {
            return dayCount(String(lower.dropFirst(prefix.count)), ahead: ahead, now: now, calendar: calendar, locale: locale)
        }
        return dayOffset(q, lower, now: now, calendar: calendar, locale: locale)
    }

    static func dayCount(_ text: String, ahead: Bool, now: Date, calendar: Calendar, locale: Locale) -> Answer? {
        guard let (month, day, year) = dayAndMonth(text) else { return nil }
        let today = calendar.startOfDay(for: now)
        let thisYear = calendar.component(.year, from: today)
        let target: Date
        if let year {
            guard let d = validDate(year, month, day, calendar) else { return nil }
            target = d
        } else {
            // The next one ahead, or the last one behind; today counts as either. Leap days
            // come round every four years or so.
            let years = ahead ? Array(thisYear...thisYear + 8) : Array((thisYear - 8...thisYear).reversed())
            guard let d = years.lazy.compactMap({ validDate($0, month, day, calendar) })
                .first(where: { ahead ? $0 >= today : $0 <= today }) else { return nil }
            target = d
        }
        guard let days = calendar.dateComponents([.day], from: ahead ? today : target, to: ahead ? target : today).day,
              days >= 0 else { return nil }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: target) == thisYear ? "EEEEdMMMM" : "EEEEdMMMMy")
        return Answer(question: ahead ? String(localized: "Days until") : String(localized: "Days since"),
                      value: String(localized: "\(days) days"), note: f.string(from: target), kind: .date)
    }

    /// Midnight on that day, or nil if there's no such day ("feb 30").
    static func validDate(_ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar) -> Date? {
        guard let d = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: d)
        return parts.year == year && parts.month == month && parts.day == day ? d : nil
    }

    /// "dec 25", "25 december", "dec 25, 2027", "25th dec 2027", "2027-01-01", "christmas",
    /// "new year".
    static func dayAndMonth(_ text: String) -> (month: Int, day: Int, year: Int?)? {
        let s = text.trimmingCharacters(in: .whitespaces)
        switch s {
        case "christmas", "xmas": return (12, 25, nil)
        case "new year", "new years", "new year's", "new year’s", "new year's day", "new year’s day": return (1, 1, nil)
        default: break
        }
        let iso = s.split(separator: "-", omittingEmptySubsequences: false)
        if iso.count == 3, iso[0].count == 4, (1...2).contains(iso[1].count), (1...2).contains(iso[2].count),
           let y = Int(iso[0]), let m = Int(iso[1]), let d = Int(iso[2]), (1...12).contains(m) {
            return (m, d, y)
        }
        let words = s.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        guard (2...3).contains(words.count) else { return nil }
        func day(_ w: String) -> Int? {
            var t = w
            for suffix in ["st", "nd", "rd", "th"] where t.hasSuffix(suffix) { t.removeLast(2); break }
            guard t.count <= 2, let d = Int(t), (1...31).contains(d) else { return nil }
            return d
        }
        var year: Int?
        if words.count == 3 {
            guard words[2].count == 4, let y = Int(words[2]), (1900...2200).contains(y) else { return nil }
            year = y
        }
        if let m = monthNames[words[0]], let d = day(words[1]) { return (m, d, year) }
        if let d = day(words[0]), let m = monthNames[words[1]] { return (m, d, year) }
        return nil
    }

    static let offsetUnits: [String: Calendar.Component] = [
        "day": .day, "days": .day, "week": .weekOfYear, "weeks": .weekOfYear, "wk": .weekOfYear, "wks": .weekOfYear,
        "month": .month, "months": .month, "year": .year, "years": .year,
    ]

    /// "in 100 days", "100 days from now", "3 weeks from today", "10 days ago": the date then.
    static func dayOffset(_ q: String, _ lower: String, now: Date, calendar: Calendar, locale: Locale) -> Answer? {
        var words = lower.split(separator: " ").map(String.init)
        var sign = 0
        if words.first == "in" {
            words.removeFirst()
            sign = 1
        } else if words.suffix(2) == ["from", "now"] || words.suffix(2) == ["from", "today"] {
            words.removeLast(2)
            sign = 1
        } else if words.last == "ago" {
            words.removeLast()
            sign = -1
        } else if words.last == "later" {
            words.removeLast()
            sign = 1
        }
        guard sign != 0, words.count == 2, words[0].count <= 5, words[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(words[0]), let unit = offsetUnits[words[1]],
              let date = calendar.date(byAdding: unit, value: sign * n, to: now) else { return nil }
        let full = DateFormatter()
        full.locale = locale
        full.timeZone = calendar.timeZone
        full.dateStyle = .full
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = calendar.timeZone
        iso.dateFormat = "yyyy-MM-dd"
        return Answer(question: q, value: full.string(from: date), note: iso.string(from: date), kind: .date)
    }

    /// The ISO 8601 week now, with the days it runs from and to.
    static func weekNumber(now: Date, timeZone: TimeZone, locale: Locale) -> Answer? {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = timeZone
        iso.locale = locale
        guard let week = iso.dateComponents([.weekOfYear], from: now).weekOfYear,
              let span = iso.dateInterval(of: .weekOfYear, for: now) else { return nil }
        let f = DateIntervalFormatter()
        f.locale = locale
        f.timeZone = timeZone
        // Written as usual: the ISO calendar writes "2026 Jan 12–18".
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        gregorian.locale = locale
        f.calendar = gregorian
        f.dateTemplate = "dMMMy"
        let range = f.string(from: span.start, to: span.end.addingTimeInterval(-1))
        return Answer(question: String(localized: "Week number"), value: String(week), note: range, kind: .date)
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
