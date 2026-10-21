import Foundation

/// The whole layout. A value type, so any state can be snapshotted for undo/redo.
public struct Grid: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int = Grid.currentVersion
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
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
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
    /// IDs of the items just before it on its page (and in its folder), nearest last. It goes
    /// back after the nearest one still there, so neighbours that never return don't shift it.
    public var before: [UUID]?
    public var folderBefore: [UUID]?

    public init(app: AppRef, prunedAt: Date, pageID: UUID, index: Int,
                folderID: UUID? = nil, folderName: String? = nil, folderIndex: Int? = nil,
                folderEmptied: Bool? = nil, before: [UUID]? = nil, folderBefore: [UUID]? = nil) {
        self.app = app
        self.prunedAt = prunedAt
        self.pageID = pageID
        self.index = index
        self.folderID = folderID
        self.folderName = folderName
        self.folderIndex = folderIndex
        self.folderEmptied = folderEmptied
        self.before = before
        self.folderBefore = folderBefore
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

// Lenient decoding: missing optional keys fall back to defaults so hand-edited
// or older files still load.
extension Grid {
    private enum CodingKeys: String, CodingKey { case version, rows, columns, pages, removedBundleIDs, recentlyPruned }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rows: try c.decodeIfPresent(Int.self, forKey: .rows) ?? 5,
            columns: try c.decodeIfPresent(Int.self, forKey: .columns) ?? 7,
            pages: try c.decodeIfPresent([Page].self, forKey: .pages) ?? [],
            removedBundleIDs: try c.decodeIfPresent(Set<String>.self, forKey: .removedBundleIDs) ?? [],
            // Disposable: an unreadable list is dropped rather than failing the whole file.
            recentlyPruned: (try? c.decodeIfPresent([PrunedApp].self, forKey: .recentlyPruned)) ?? []
        )
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }
}

extension Page {
    private enum CodingKeys: String, CodingKey { case id, title, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            items: try c.decodeIfPresent([GridItem].self, forKey: .items) ?? []
        )
    }
}

extension AppRef {
    private enum CodingKeys: String, CodingKey { case id, bundleID, path, name, displayName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            bundleID: try c.decodeIfPresent(String.self, forKey: .bundleID),
            path: try c.decode(String.self, forKey: .path),
            name: try c.decodeIfPresent(String.self, forKey: .name),
            displayName: try c.decodeIfPresent(String.self, forKey: .displayName)
        )
    }
}

extension Folder {
    private enum CodingKeys: String, CodingKey { case id, name, apps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Folder",
            apps: try c.decodeIfPresent([AppRef].self, forKey: .apps) ?? []
        )
    }
}
