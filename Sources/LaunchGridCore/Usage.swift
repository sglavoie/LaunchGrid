import Foundation

/// How often and how recently each item was opened ("frecency"), so search puts what you open
/// first among equally good matches. Each open adds 1 to a score that halves every
/// `halfLife`: an app opened daily outranks one opened often a month ago.
/// Kept by a key that survives rebuilding the layout (an app's bundle ID or path, an action's ID),
/// with the time of its last open only: nothing from the disk, just when LaunchGrid opened it.
public struct Usage: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var score: Double
        /// Seconds since the reference date, when `score` was last brought up to date.
        public var at: Double

        public init(score: Double, at: Double) {
            self.score = score
            self.at = at
        }
    }

    public static let halfLife: TimeInterval = 10 * 24 * 3600
    /// Entries kept; the weakest go first.
    public static let limit = 400

    public private(set) var entries: [String: Entry]

    /// When in the day each item is opened: eight three-hour buckets, decaying as the score
    /// does, so what the grid suggests follows the time of day (`suggestions`).
    public struct Hours: Equatable, Sendable {
        public var buckets: [Double]
        /// Seconds since the reference date, when `buckets` were last brought up to date.
        public var at: Double

        public init(buckets: [Double], at: Double) {
            self.buckets = buckets
            self.at = at
        }
    }

    public static let bucketCount = 8
    public private(set) var hours: [String: Hours]

    public init(entries: [String: Entry] = [:], hours: [String: Hours] = [:]) {
        self.entries = entries
        self.hours = hours
    }

    /// The key for an item: apps by bundle ID (or path when there is none), actions by ID.
    /// Folders aren't opened from search, so they have none.
    public static func key(for item: GridItem) -> String? {
        switch item {
        case .app(let app): "app:" + (app.bundleID ?? app.path)
        case .action(let action): "action:" + action.id.uuidString
        case .folder: nil
        }
    }

    public mutating func record(_ item: GridItem, at date: Date = Date(), calendar: Calendar = .current) {
        guard let key = Self.key(for: item) else { return }
        let now = date.timeIntervalSinceReferenceDate
        let old = entries[key].map { Self.decayed($0, to: now) } ?? 0
        entries[key] = Entry(score: old + 1, at: now)
        var buckets = hours[key].map { Self.decayed($0, to: now) } ?? Array(repeating: 0, count: Self.bucketCount)
        buckets[Self.bucket(date, calendar: calendar)] += 1
        hours[key] = Hours(buckets: buckets, at: now)
        if entries.count > Self.limit {
            let weakest = entries.min { Self.decayed($0.value, to: now) < Self.decayed($1.value, to: now) }
            if let weakest {
                entries[weakest.key] = nil
                hours[weakest.key] = nil
            }
        }
    }

    /// The three-hour stretch of the day `date` falls in, 0 to 7.
    static func bucket(_ date: Date, calendar: Calendar) -> Int {
        min(bucketCount - 1, max(0, calendar.component(.hour, from: date) / 3))
    }

    /// The keys of what's opened most around this time of day, best first: the stretch `date`
    /// falls in, and half as much the ones either side. Only what's been opened at this time
    /// often enough lately to be a habit (`minimum`), at most `limit` of them.
    public func suggestions(at date: Date = Date(), calendar: Calendar = .current, limit: Int = 5,
                            minimum: Double = 1.5) -> [String] {
        let now = date.timeIntervalSinceReferenceDate
        let b = Self.bucket(date, calendar: calendar), n = Self.bucketCount
        let scored = hours.compactMap { key, value -> (String, Double)? in
            let d = Self.decayed(value, to: now)
            guard d.count == n else { return nil }
            let s = d[b] + 0.5 * (d[(b + n - 1) % n] + d[(b + 1) % n])
            return s >= minimum ? (key, s) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map(\.0)
    }

    /// The keys of what was opened last, latest first, at most `limit` of them.
    public func recent(limit: Int = 8) -> [String] {
        entries.sorted { $0.value.at != $1.value.at ? $0.value.at > $1.value.at : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    /// When LaunchGrid last opened `item`, if it has.
    public func lastOpened(_ item: GridItem) -> Date? {
        guard let key = Self.key(for: item), let entry = entries[key] else { return nil }
        return Date(timeIntervalSinceReferenceDate: entry.at)
    }

    public func score(_ item: GridItem, at date: Date = Date()) -> Double {
        guard let key = Self.key(for: item), let entry = entries[key] else { return 0 }
        return Self.decayed(entry, to: date.timeIntervalSinceReferenceDate)
    }

    static func decayed(_ hours: Hours, to now: Double) -> [Double] {
        let factor = pow(0.5, max(0, now - hours.at) / halfLife)
        return hours.buckets.map { $0 * factor }
    }

    static func decayed(_ entry: Entry, to now: Double) -> Double {
        // A clock set back doesn't make a score grow.
        let age = max(0, now - entry.at)
        return entry.score * pow(0.5, age / halfLife)
    }

    // MARK: Storage, as a property list

    public var propertyList: [String: [Double]] {
        entries.mapValues { [$0.score, $0.at] }
    }

    /// The time-of-day buckets, kept apart from `propertyList` so builds before them still
    /// read the scores: each key's buckets, then when they were brought up to date.
    public var hoursPropertyList: [String: [Double]] {
        hours.mapValues { $0.buckets + [$0.at] }
    }

    public init(propertyList: Any?, hours hoursList: Any? = nil) {
        var entries: [String: Entry] = [:]
        for (key, value) in (propertyList as? [String: Any]) ?? [:] {
            guard let pair = value as? [Double], pair.count == 2, pair[0].isFinite, pair[0] > 0, pair[1].isFinite else { continue }
            entries[key] = Entry(score: pair[0], at: pair[1])
        }
        var hours: [String: Hours] = [:]
        for (key, value) in (hoursList as? [String: Any]) ?? [:] {
            guard entries[key] != nil, let list = value as? [Double], list.count == Self.bucketCount + 1,
                  list.allSatisfy({ $0.isFinite }), list.dropLast().allSatisfy({ $0 >= 0 }) else { continue }
            hours[key] = Hours(buckets: Array(list.dropLast()), at: list[Self.bucketCount])
        }
        self.entries = entries
        self.hours = hours
    }
}
