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

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
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

    public mutating func record(_ item: GridItem, at date: Date = Date()) {
        guard let key = Self.key(for: item) else { return }
        let now = date.timeIntervalSinceReferenceDate
        let old = entries[key].map { Self.decayed($0, to: now) } ?? 0
        entries[key] = Entry(score: old + 1, at: now)
        if entries.count > Self.limit {
            let weakest = entries.min { Self.decayed($0.value, to: now) < Self.decayed($1.value, to: now) }
            if let weakest { entries[weakest.key] = nil }
        }
    }

    public func score(_ item: GridItem, at date: Date = Date()) -> Double {
        guard let key = Self.key(for: item), let entry = entries[key] else { return 0 }
        return Self.decayed(entry, to: date.timeIntervalSinceReferenceDate)
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

    public init(propertyList: Any?) {
        var entries: [String: Entry] = [:]
        for (key, value) in (propertyList as? [String: Any]) ?? [:] {
            guard let pair = value as? [Double], pair.count == 2, pair[0].isFinite, pair[0] > 0, pair[1].isFinite else { continue }
            entries[key] = Entry(score: pair[0], at: pair[1])
        }
        self.entries = entries
    }
}
