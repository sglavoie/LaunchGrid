import Foundation

/// The whole layout. A value type, so any state can be snapshotted for undo/redo.
public struct Grid: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int = Grid.currentVersion
    public var rows: Int
    public var columns: Int
    public var pages: [Page]
    /// Apps the user removed; the reconciler never re-adds these automatically.
    public var removedBundleIDs: Set<String> = []

    public init(rows: Int = 5, columns: Int = 7, pages: [Page] = [Page()], removedBundleIDs: Set<String> = []) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.pages = pages.isEmpty ? [Page()] : pages
        self.removedBundleIDs = removedBundleIDs
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
    private enum CodingKeys: String, CodingKey { case version, rows, columns, pages, removedBundleIDs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rows: try c.decodeIfPresent(Int.self, forKey: .rows) ?? 5,
            columns: try c.decodeIfPresent(Int.self, forKey: .columns) ?? 7,
            pages: try c.decodeIfPresent([Page].self, forKey: .pages) ?? [],
            removedBundleIDs: try c.decodeIfPresent(Set<String>.self, forKey: .removedBundleIDs) ?? []
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
