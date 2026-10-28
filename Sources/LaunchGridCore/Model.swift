import Foundation

/// The whole layout. A value type, so any state can be snapshotted for undo/redo.
public struct Grid: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int = Grid.currentVersion
    /// Setup was completed, even if the user later removes every app. False also covers
    /// older files, whose apps or restoration records identify an existing layout.
    public var hasCreatedLayout = false
    /// At least 1, so `capacity` is never 0. Change through `resize(rows:columns:)`.
    public internal(set) var rows: Int { didSet { rows = max(1, rows) } }
    public internal(set) var columns: Int { didSet { columns = max(1, columns) } }
    public var pages: [Page]
    /// Apps the user removed; the reconciler never re-adds these automatically. Holds bundle
    /// IDs (every copy) and, for a copy sharing its bundle ID with another, its path.
    public var removedBundleIDs: Set<String> = []
    /// Apps the reconciler pruned lately, so one that comes back (an updater deletes, then
    /// re-copies the bundle) returns to its old slot instead of the end of the grid.
    public var recentlyPruned: [PrunedApp] = []

    public init(rows: Int = 5, columns: Int = 7, pages: [Page] = [Page()], removedBundleIDs: Set<String> = [],
                recentlyPruned: [PrunedApp] = []) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.pages = pages.isEmpty ? [Page()] : pages
        self.removedBundleIDs = removedBundleIDs
        self.recentlyPruned = recentlyPruned
    }

    public var capacity: Int { rows * columns }
}

public struct Page: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String?
    public var items: [GridItem]

    public init(id: UUID = UUID(), title: String? = nil, items: [GridItem] = []) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public enum GridItem: Equatable, Identifiable, Sendable {
    case app(AppRef)
    case folder(Folder)

    public var id: UUID {
        switch self {
        case .app(let a): a.id
        case .folder(let f): f.id
        }
    }

    public var app: AppRef? {
        if case .app(let a) = self { return a }
        return nil
    }

    public var folder: Folder? {
        if case .folder(let f) = self { return f }
        return nil
    }

    /// Name used for sorting and display.
    public var title: String {
        switch self {
        case .app(let a): a.title
        case .folder(let f): f.name
        }
    }

    /// Every app this item represents (one for an app, all contents for a folder).
    public var apps: [AppRef] {
        switch self {
        case .app(let a): [a]
        case .folder(let f): f.apps
        }
    }
}

extension GridItem: Codable {
    private enum CodingKeys: String, CodingKey { case type, app, folder }
    private enum Kind: String, Codable { case app, folder }

    /// An unknown `type` fails the item, which is skipped like any other unreadable entry, so a
    /// new item kind needs a `Grid.currentVersion` bump: older builds then say the file is from
    /// a newer version instead of dropping what they can't read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .app: self = .app(try c.decode(AppRef.self, forKey: .app))
        case .folder: self = .folder(try c.decode(Folder.self, forKey: .folder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let a):
            try c.encode(Kind.app, forKey: .type)
            try c.encode(a, forKey: .app)
        case .folder(let f):
            try c.encode(Kind.folder, forKey: .type)
            try c.encode(f, forKey: .folder)
        }
    }
}

public struct AppRef: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// nil for the odd app without one.
    public var bundleID: String?
    /// Last known location of the bundle.
    public var path: String
    /// Last known name of the app, refreshed by the reconciler.
    public var name: String
    /// User rename; nil means use `name`.
    public var displayName: String?

    public init(id: UUID = UUID(), bundleID: String?, path: String, name: String? = nil, displayName: String? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.path = path
        self.name = name ?? AppRef.defaultName(forPath: path)
        self.displayName = displayName
    }

    public var title: String { displayName ?? name }

    /// Identity used for matching against installed apps: bundle ID first, path otherwise.
    public var key: String { bundleID ?? path }

    public static func defaultName(forPath path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.lowercased().hasSuffix(".app") ? String(last.dropLast(4)) : last
    }
}

/// Where a pruned app used to be. Indices are those before pruning, a fallback for when
/// none of the remembered neighbours is left; restoring in the order the apps were pruned
/// puts neighbours back side by side.
public struct PrunedApp: Codable, Equatable, Sendable {
    public var app: AppRef
    public var prunedAt: Date
    public var pageID: UUID
    public var index: Int
    /// Set when the app was inside a folder, which is recreated if pruning emptied it.
    public var folderID: UUID?
    public var folderName: String?
    public var folderIndex: Int?
    /// The prune itself emptied the folder; otherwise a vanished folder was the user's doing.
    public var folderEmptied: Bool?
    /// The prune emptied its page, which went too; it comes back at `pageIndex` with `pageTitle`.
    public var pageEmptied: Bool?
    public var pageIndex: Int?
    public var pageTitle: String?
    /// IDs of the items just before it on its page (and in its folder), nearest last. It goes
    /// back after the nearest one still there, so neighbours that never return don't shift it.
    public var before: [UUID]?
    public var folderBefore: [UUID]?
    /// IDs of the pages before its emptied page, nearest last, so that page comes back after
    /// the nearest one still there, even when pages pruned with it return in another order.
    public var pageBefore: [UUID]?

    public init(app: AppRef, prunedAt: Date, pageID: UUID, index: Int,
                folderID: UUID? = nil, folderName: String? = nil, folderIndex: Int? = nil,
                folderEmptied: Bool? = nil, pageEmptied: Bool? = nil, pageIndex: Int? = nil, pageTitle: String? = nil,
                before: [UUID]? = nil, folderBefore: [UUID]? = nil, pageBefore: [UUID]? = nil) {
        self.app = app
        self.prunedAt = prunedAt
        self.pageID = pageID
        self.index = index
        self.folderID = folderID
        self.folderName = folderName
        self.folderIndex = folderIndex
        self.folderEmptied = folderEmptied
        self.pageEmptied = pageEmptied
        self.pageIndex = pageIndex
        self.pageTitle = pageTitle
        self.before = before
        self.folderBefore = folderBefore
        self.pageBefore = pageBefore
    }
}

public struct Folder: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var apps: [AppRef]

    public init(id: UUID = UUID(), name: String, apps: [AppRef] = []) {
        self.id = id
        self.name = name
        self.apps = apps
    }
}

/// An application found on disk by `AppCatalog`.
public struct InstalledApp: Equatable, Hashable, Sendable {
    public var bundleID: String?
    public var path: String
    public var name: String
    /// `LSApplicationCategoryType`, e.g. `public.app-category.developer-tools`.
    public var category: String?

    public init(bundleID: String?, path: String, name: String, category: String? = nil) {
        self.bundleID = bundleID
        self.path = path
        self.name = name
        self.category = category
    }

    public var key: String { bundleID ?? path }

    public func makeRef() -> AppRef {
        AppRef(bundleID: bundleID, path: path, name: name)
    }
}

// Lenient decoding: missing or malformed optional keys (an ID that isn't a UUID, a number for a
// title) fall back to defaults so hand-edited or older files still load, and an entry that can't
// be read (an app without a path) is skipped, not the whole file.
extension Grid {
    private enum CodingKeys: String, CodingKey { case version, hasCreatedLayout, rows, columns, pages, removedBundleIDs, recentlyPruned }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Without it, any JSON object (`{}`, another app's settings) would read as an empty
        // layout. Null isn't a page list either and must trigger backup recovery. An empty
        // list stays valid: a file may hold only exclusions.
        guard c.contains(.pages), try !c.decodeNil(forKey: .pages) else {
            throw DecodingError.keyNotFound(CodingKeys.pages, .init(codingPath: c.codingPath, debugDescription: "No pages"))
        }
        self.init(
            rows: (try? c.decodeIfPresent(Int.self, forKey: .rows)) ?? 5,
            columns: (try? c.decodeIfPresent(Int.self, forKey: .columns)) ?? 7,
            pages: try c.decodeLossily(Page.self, forKey: .pages) ?? [],
            removedBundleIDs: Set(try c.decodeLossily(String.self, forKey: .removedBundleIDs, countingLayoutEntries: false) ?? []),
            // Disposable: an unreadable list is dropped rather than failing the whole file.
            recentlyPruned: (try? c.decodeIfPresent([PrunedApp].self, forKey: .recentlyPruned)) ?? []
        )
        // GridStore reads the version first, also when written as text, and rejects bad ones.
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        hasCreatedLayout = (try? c.decodeIfPresent(Bool.self, forKey: .hasCreatedLayout)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        if hasCreatedLayout { try c.encode(true, forKey: .hasCreatedLayout) }
        try c.encode(rows, forKey: .rows)
        try c.encode(columns, forKey: .columns)
        try c.encode(pages, forKey: .pages)
        // Sorted, so saving the same grid twice writes the same bytes.
        try c.encode(removedBundleIDs.sorted(), forKey: .removedBundleIDs)
        try c.encode(recentlyPruned, forKey: .recentlyPruned)
    }
}

extension Page {
    private enum CodingKeys: String, CodingKey { case id, title, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            title: try? c.decodeIfPresent(String.self, forKey: .title),
            items: try c.decodeLossily(GridItem.self, forKey: .items) ?? []
        )
    }
}

extension AppRef {
    private enum CodingKeys: String, CodingKey { case id, bundleID, path, name, displayName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            bundleID: try? c.decodeIfPresent(String.self, forKey: .bundleID),
            path: try c.decode(String.self, forKey: .path),
            name: try? c.decodeIfPresent(String.self, forKey: .name),
            displayName: try? c.decodeIfPresent(String.self, forKey: .displayName)
        )
    }
}

extension Folder {
    private enum CodingKeys: String, CodingKey { case id, name, apps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? String(localized: "Folder"),
            apps: try c.decodeLossily(AppRef.self, forKey: .apps) ?? []
        )
    }
}

extension KeyedDecodingContainer {
    /// The array's elements that decode; the others are skipped and logged, so one bad entry
    /// (an app without a path) doesn't make the whole layout unreadable.
    func decodeLossily<T: Decodable>(_ type: T.Type, forKey key: Key, countingLayoutEntries: Bool = true) throws -> [T]? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) {
            // A missing list can use an older format's default; an explicit null layout
            // list is damaged, not empty. Let its containing entry be counted as skipped
            // so loading preserves the original file or recovers the backup.
            guard !countingLayoutEntries else {
                throw DecodingError.valueNotFound([T].self, .init(
                    codingPath: codingPath + [key], debugDescription: "Null layout list"))
            }
            return nil
        }
        var c = try nestedUnkeyedContainer(forKey: key)
        let decoder = try superDecoder(forKey: key)
        var out: [T] = []
        while !c.isAtEnd {
            do {
                out.append(try c.decode(T.self))
            } catch {
                NSLog("LaunchGrid: skipped an unreadable \(T.self) in the layout: \(error)")
                if let skipped = decoder.userInfo[SkippedEntries.key] as? SkippedEntries {
                    skipped.count += 1
                    if countingLayoutEntries { skipped.layoutCount += 1 }
                }
                _ = try c.decode(SkippedEntry.self) // a failed decode doesn't move past the entry
            }
        }
        return out
    }
}

/// Decodes any value without reading it, to move past an entry that failed.
private struct SkippedEntry: Decodable {
    init(from decoder: Decoder) {}
}

/// Counts the entries `decodeLossily` skipped, when passed in the decoder's `userInfo`.
final class SkippedEntries: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "skippedEntries")!
    var count = 0
    /// Excludes malformed exclusions: an exclusions-only file has no app entries to recover.
    var layoutCount = 0
}
