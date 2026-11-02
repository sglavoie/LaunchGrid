import Foundation

/// The whole layout. A value type, so any state can be snapshotted for undo/redo.
public struct Grid: Codable, Equatable, Sendable {
    public static let currentVersion = 2

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
    /// Search-only actions (`showsOnGrid == false`): kept in the layout, but on no page.
    public var hiddenActions: [Action] = []

    public init(rows: Int = 5, columns: Int = 7, pages: [Page] = [Page()], removedBundleIDs: Set<String> = [],
                recentlyPruned: [PrunedApp] = [], hiddenActions: [Action] = []) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.pages = pages.isEmpty ? [Page()] : pages
        self.removedBundleIDs = removedBundleIDs
        self.recentlyPruned = recentlyPruned
        self.hiddenActions = hiddenActions
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
    case action(Action)

    public var id: UUID {
        switch self {
        case .app(let a): a.id
        case .folder(let f): f.id
        case .action(let a): a.id
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

    public var action: Action? {
        if case .action(let a) = self { return a }
        return nil
    }

    /// Name used for sorting and display.
    public var title: String {
        switch self {
        case .app(let a): a.title
        case .folder(let f): f.name
        case .action(let a): a.name
        }
    }

    /// Every app this item represents (one for an app, all contents for a folder, none for
    /// an action).
    public var apps: [AppRef] {
        switch self {
        case .app(let a): [a]
        case .folder(let f): f.apps
        case .action: []
        }
    }

    /// What this item adds to a folder: itself, or a folder's members (folders don't nest).
    public var members: [FolderMember] {
        switch self {
        case .app(let a): [.app(a)]
        case .folder(let f): f.items
        case .action(let a): [.action(a)]
        }
    }
}

extension GridItem: Codable {
    private enum CodingKeys: String, CodingKey { case type, app, folder, action }
    private enum Kind: String, Codable { case app, folder, action }

    /// An unknown `type` fails the item, which is skipped like any other unreadable entry, so a
    /// new item kind needs a `Grid.currentVersion` bump: older builds then say the file is from
    /// a newer version instead of dropping what they can't read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .app: self = .app(try c.decode(AppRef.self, forKey: .app))
        case .folder: self = .folder(try c.decode(Folder.self, forKey: .folder))
        case .action: self = .action(try c.decode(Action.self, forKey: .action))
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
        case .action(let a):
            try c.encode(Kind.action, forKey: .type)
            try c.encode(a, forKey: .action)
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
    /// What the folder holds, in order: apps and actions. Positions in a folder
    /// (`ItemLocation.folderIndex`, `PrunedApp.folderIndex`) count every member.
    public var items: [FolderMember]

    public init(id: UUID = UUID(), name: String, items: [FolderMember]) {
        self.id = id
        self.name = name
        self.items = items
    }

    public init(id: UUID = UUID(), name: String, apps: [AppRef] = []) {
        self.init(id: id, name: name, items: apps.map(FolderMember.app))
    }

    /// Only the apps, in order: what the reconciler, importers and `Grid.allApps` deal in.
    public var apps: [AppRef] { items.compactMap(\.app) }

    /// Only the actions, in order.
    public var actions: [Action] { items.compactMap(\.action) }

    /// The member IDs, in order.
    public var itemIDs: [UUID] { items.map(\.id) }
}

/// Something inside a folder: an app or an action. Folders don't nest.
public enum FolderMember: Equatable, Identifiable, Sendable {
    case app(AppRef)
    case action(Action)

    public var id: UUID {
        switch self {
        case .app(let a): a.id
        case .action(let a): a.id
        }
    }

    public var app: AppRef? {
        if case .app(let a) = self { return a }
        return nil
    }

    public var action: Action? {
        if case .action(let a) = self { return a }
        return nil
    }

    public var title: String {
        switch self {
        case .app(let a): a.title
        case .action(let a): a.name
        }
    }

    /// The member as a grid item, as it is shown, searched and dragged.
    public var gridItem: GridItem {
        switch self {
        case .app(let a): .app(a)
        case .action(let a): .action(a)
        }
    }

    /// An app or an action as a folder member; nil for a folder, as folders don't nest.
    public init?(_ item: GridItem) {
        switch item {
        case .app(let a): self = .app(a)
        case .action(let a): self = .action(a)
        case .folder: return nil
        }
    }
}

/// Written as a grid item is: `{"type":"app","app":{…}}` or `{"type":"action","action":{…}}`.
extension FolderMember: Codable {
    private enum CodingKeys: String, CodingKey { case type, app, action }
    private enum Kind: String, Codable { case app, action }

    /// An unknown `type` (a folder, or a kind from a newer build) fails this member alone.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .app: self = .app(try c.decode(AppRef.self, forKey: .app))
        case .action: self = .action(try c.decode(Action.self, forKey: .action))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let a):
            try c.encode(Kind.app, forKey: .type)
            try c.encode(a, forKey: .app)
        case .action(let a):
            try c.encode(Kind.action, forKey: .type)
            try c.encode(a, forKey: .action)
        }
    }
}

/// A user-defined grid item that does something other than open an app: open a URL or a
/// file, run a Shortcut, a shell command or a user script. Not an `AppRef`, so the reconciler,
/// bookmarks and icon scanning, which deal in bundles on disk, never see one.
public struct Action: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Exact-match search keywords, kept trimmed, lowercased and without repeats or blanks.
    public var keywords: [String] { didSet { keywords = Action.normalizedKeywords(keywords) } }
    public var icon: ActionIcon
    public var kind: ActionKind
    /// False for a search-only action, which lives in `Grid.hiddenActions` instead of on a page.
    public var showsOnGrid: Bool
    /// True for an action that came from a grid file someone opened: it doesn't run until it
    /// has been looked at, and saved, in the editor.
    public var needsReview: Bool

    public init(id: UUID = UUID(), name: String, keywords: [String] = [], icon: ActionIcon? = nil,
                kind: ActionKind, showsOnGrid: Bool = true, needsReview: Bool = false) {
        self.id = id
        self.name = name
        self.keywords = Action.normalizedKeywords(keywords)
        self.icon = icon ?? kind.defaultIcon
        self.kind = kind
        self.showsOnGrid = showsOnGrid
        self.needsReview = needsReview
    }

    public var title: String { name }

    static func normalizedKeywords(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        return keywords.compactMap { word in
            let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !w.isEmpty && seen.insert(w).inserted ? w : nil
        }
    }
}

public enum ActionIcon: Codable, Equatable, Sendable {
    /// An SF Symbol name.
    case symbol(String)
    case emoji(String)
    case image(path: String)

    private enum CodingKeys: String, CodingKey { case type, name, value, path }
    private enum Kind: String, Codable { case symbol, emoji, image }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .symbol: self = .symbol(try c.decode(String.self, forKey: .name))
        case .emoji: self = .emoji(try c.decode(String.self, forKey: .value))
        case .image: self = .image(path: try c.decode(String.self, forKey: .path))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let name):
            try c.encode(Kind.symbol, forKey: .type)
            try c.encode(name, forKey: .name)
        case .emoji(let value):
            try c.encode(Kind.emoji, forKey: .type)
            try c.encode(value, forKey: .value)
        case .image(let path):
            try c.encode(Kind.image, forKey: .type)
            try c.encode(path, forKey: .path)
        }
    }
}

public enum RunMode: String, Codable, CaseIterable, Sendable {
    case background, terminal
}

public enum ActionKind: Equatable, Sendable {
    /// `template` may contain `{query}`, replaced by the search argument.
    case openURL(template: String)
    /// `appPath` nil opens the file with its default app.
    case openFile(path: String, appPath: String?)
    case shortcut(name: String, input: String?)
    case shell(command: String, runMode: RunMode, workingDirectory: String?, timeoutSeconds: Int?)
    /// A script in the app's Application Scripts folder.
    case userScript(fileName: String, arguments: [String], runMode: RunMode)

    /// The placeholder replaced by the argument typed after a keyword in search.
    public static let argumentPlaceholder = "{query}"

    /// The environment variable commands and scripts get the argument in.
    public static let argumentVariable = "LAUNCHGRID_QUERY"

    /// Whether `{query}` appears where it is substituted, or a command reads
    /// `$LAUNCHGRID_QUERY` (where the editor asks for it instead of `{query}`), so search hands
    /// this action the text typed after its keyword.
    public var takesArgument: Bool {
        let p = Self.argumentPlaceholder
        return switch self {
        case .openURL(let template): template.contains(p)
        case .openFile: false
        case .shortcut(_, let input): input?.contains(p) ?? false
        case .shell(let command, _, _, _): command.contains(p) || command.contains(Self.argumentVariable)
        case .userScript(_, let arguments, _): arguments.contains { $0.contains(p) }
        }
    }

    public var defaultIcon: ActionIcon {
        switch self {
        case .openURL: .symbol("link")
        case .openFile: .symbol("doc")
        case .shortcut: .symbol("square.stack.3d.up")
        case .shell: .symbol("terminal")
        case .userScript: .symbol("scroll")
        }
    }
}

extension ActionKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, template, path, appPath, name, input, command, runMode, workingDirectory, timeoutSeconds, fileName, arguments
    }
    private enum Kind: String, Codable { case openURL, openFile, shortcut, shell, userScript }

    /// An unknown `type` fails the kind, and with it only its action, which is skipped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let runMode = { (try? c.decodeIfPresent(RunMode.self, forKey: .runMode)) ?? .background }
        switch try c.decode(Kind.self, forKey: .type) {
        case .openURL:
            self = .openURL(template: try c.decode(String.self, forKey: .template))
        case .openFile:
            self = .openFile(path: try c.decode(String.self, forKey: .path),
                             appPath: try? c.decodeIfPresent(String.self, forKey: .appPath))
        case .shortcut:
            self = .shortcut(name: try c.decode(String.self, forKey: .name),
                             input: try? c.decodeIfPresent(String.self, forKey: .input))
        case .shell:
            self = .shell(command: try c.decode(String.self, forKey: .command), runMode: runMode(),
                          workingDirectory: try? c.decodeIfPresent(String.self, forKey: .workingDirectory),
                          timeoutSeconds: try? c.decodeIfPresent(Int.self, forKey: .timeoutSeconds))
        case .userScript:
            self = .userScript(fileName: try c.decode(String.self, forKey: .fileName),
                               arguments: (try? c.decodeIfPresent([String].self, forKey: .arguments)) ?? [],
                               runMode: runMode())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .openURL(let template):
            try c.encode(Kind.openURL, forKey: .type)
            try c.encode(template, forKey: .template)
        case .openFile(let path, let appPath):
            try c.encode(Kind.openFile, forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(appPath, forKey: .appPath)
        case .shortcut(let name, let input):
            try c.encode(Kind.shortcut, forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(input, forKey: .input)
        case .shell(let command, let runMode, let workingDirectory, let timeoutSeconds):
            try c.encode(Kind.shell, forKey: .type)
            try c.encode(command, forKey: .command)
            try c.encode(runMode, forKey: .runMode)
            try c.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
            try c.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        case .userScript(let fileName, let arguments, let runMode):
            try c.encode(Kind.userScript, forKey: .type)
            try c.encode(fileName, forKey: .fileName)
            try c.encode(arguments, forKey: .arguments)
            try c.encode(runMode, forKey: .runMode)
        }
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
    private enum CodingKeys: String, CodingKey { case version, hasCreatedLayout, rows, columns, pages, removedBundleIDs, recentlyPruned, hiddenActions }

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
            // Keep readable restoration records even when another one is damaged.
            recentlyPruned: try c.decodeLossily(PrunedApp.self, forKey: .recentlyPruned, allowNull: true) ?? [],
            hiddenActions: try c.decodeLossily(Action.self, forKey: .hiddenActions, allowNull: true) ?? []
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
        if !hiddenActions.isEmpty { try c.encode(hiddenActions, forKey: .hiddenActions) }
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
    private enum CodingKeys: String, CodingKey { case id, name, apps, items }

    /// `items` when present; otherwise the older `apps` list, every entry an app.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let items: [FolderMember] = if c.contains(.items) {
            try c.decodeLossily(FolderMember.self, forKey: .items) ?? []
        } else {
            (try c.decodeLossily(AppRef.self, forKey: .apps) ?? []).map(FolderMember.app)
        }
        self.init(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? String(localized: "Folder"),
            items: items
        )
    }

    /// Writes `items`, and `apps` too while every member is an app, so a build that only
    /// knows `apps` still opens app-only folders.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        if items.allSatisfy({ $0.app != nil }) { try c.encode(apps, forKey: .apps) }
        try c.encode(items, forKey: .items)
    }
}

extension Action {
    private enum CodingKeys: String, CodingKey { case id, name, keywords, icon, kind, showsOnGrid, needsReview }

    /// Only `kind` is required; a kind this build doesn't know fails the action alone.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(ActionKind.self, forKey: .kind)
        self.init(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? String(localized: "Action"),
            keywords: ((try? c.decodeIfPresent([String?].self, forKey: .keywords)) ?? []).compactMap { $0 },
            icon: try? c.decodeIfPresent(ActionIcon.self, forKey: .icon),
            kind: kind,
            showsOnGrid: (try? c.decodeIfPresent(Bool.self, forKey: .showsOnGrid)) ?? true,
            needsReview: (try? c.decodeIfPresent(Bool.self, forKey: .needsReview)) ?? false
        )
    }

    /// `needsReview` is written only when set, so layouts without it stay as they were.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(keywords, forKey: .keywords)
        try c.encode(icon, forKey: .icon)
        try c.encode(kind, forKey: .kind)
        try c.encode(showsOnGrid, forKey: .showsOnGrid)
        if needsReview { try c.encode(true, forKey: .needsReview) }
    }
}

extension KeyedDecodingContainer {
    /// The array's elements that decode; the others are skipped and logged, so one bad entry
    /// (an app without a path) doesn't make the whole layout unreadable.
    func decodeLossily<T: Decodable>(_ type: T.Type, forKey key: Key,
                                    countingLayoutEntries: Bool = true, allowNull: Bool = false) throws -> [T]? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) {
            // A missing list can use an older format's default; an explicit null layout
            // list is damaged, not empty. Let its containing entry be counted as skipped
            // so loading preserves the original file or recovers the backup.
            guard allowNull || !countingLayoutEntries else {
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
