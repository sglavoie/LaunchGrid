import Foundation
import SQLite3

/// Reads a Launchpad-schema SQLite database: Apple's legacy Dock Launchpad DB,
/// AppGrid's own `db`, or an `.agrid` file (the same format). Read-only, best effort.
public enum LaunchpadImporter {
    public struct Result: Sendable {
        public var grid: Grid
        public var imported: Int
        /// Titles of apps left out because they aren't installed.
        public var skipped: [String]
        /// Titles of second entries for an app already imported.
        public var duplicates: [String] = []
    }

    public enum ImportError: Error, LocalizedError {
        case cannotOpen(String)
        case notALaunchpadDatabase
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let why): String(localized: "Could not open the database: \(why)")
            case .notALaunchpadDatabase: String(localized: "This file is not a Launchpad or AppGrid database.")
            case .readFailed(let why): String(localized: "Could not read the database: \(why)")
            }
        }
    }

    /// Item types in the Launchpad schema.
    enum ItemType: Int {
        case root = 1, folder = 2, page = 3, app = 4, downloading = 5, widget = 6
    }

    /// The legacy Dock Launchpad database (pre-macOS 26), if it still exists.
    public static var launchpadDatabaseURL: URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 else { return nil }
        var dir = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // Inside the sandbox the folder is the app's own subfolder of the real one.
        if let id = Sandbox.containerID, dir.hasSuffix("/\(id)/") { dir.removeLast(id.utf8.count + 1) }
        let url = URL(fileURLWithPath: "/private" + dir + "com.apple.dock.launchpad/db/db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// AppGrid's database inside its sandbox container, if present.
    public static var appGridDatabaseURL: URL? {
        #if !APP_STORE
        // For the debug scripts, on a Mac without AppGrid.
        if let path = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_APPGRID_DB"] { return URL(fileURLWithPath: path) }
        #endif
        let url = Sandbox.realHome.appendingPathComponent("Library/Containers/com.zekalogic.appgrid.app/Data/Library/Application Support/db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    struct Row {
        var id: Int
        var type: Int
        var parent: Int
        var ordering: Int
    }

    struct AppRow {
        var title: String?
        var bundleID: String?
        var customPath: String?
        /// Apple's `bookmark` column: where the app was, which tells copies sharing a bundle ID
        /// (Xcode and Xcode-beta) apart. AppGrid's copy of the schema leaves it empty.
        var bookmark: Data?
    }

    /// - Parameters:
    ///   - resolve: maps a bundle ID to an installed path (normally via NSWorkspace).
    ///   - installed: paths of the installed apps as the scan spells them. An imported app
    ///     found at another spelling of one (Launch Services gives Safari's cryptex path, the
    ///     scan its `/Applications` symlink) takes the scan's, so it matches its installed app.
    public static func importDatabase(
        at url: URL,
        rows: Int,
        columns: Int,
        installed: [String] = [],
        keeps: (String) -> Bool = { _ in true },
        resolve: (String) -> String?
    ) throws -> Result {
        // Copy first so a live database is never touched. Its write-ahead log comes along:
        // recent changes may live only there. The shared-memory index is left behind and
        // rebuilt from the log, which needs a writable connection to the copy.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("launchgrid-import-\(UUID().uuidString).db")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: tmp.path + suffix) }
        }
        try copyDatabase(at: url, to: tmp)

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let why = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw ImportError.cannotOpen(why)
        }
        defer { sqlite3_close(db) }

        guard tableExists(db, "items"), tableExists(db, "apps") else { throw ImportError.notALaunchpadDatabase }
        let hasCustomPath = columnExists(db, table: "apps", column: "custom_path")
        let hasBookmark = columnExists(db, table: "apps", column: "bookmark")

        var items: [Row] = []
        try query(db, "SELECT rowid, type, parent_id, ordering FROM items ORDER BY parent_id, ordering") { st in
            items.append(Row(id: Int(sqlite3_column_int64(st, 0)), type: Int(sqlite3_column_int(st, 1)),
                             parent: Int(sqlite3_column_int64(st, 2)), ordering: Int(sqlite3_column_int(st, 3))))
        }
        var apps: [Int: AppRow] = [:]
        let appSQL = "SELECT item_id, title, bundleid, \(hasCustomPath ? "custom_path" : "NULL"), \(hasBookmark ? "bookmark" : "NULL") FROM apps"
        try query(db, appSQL) { st in
            apps[Int(sqlite3_column_int64(st, 0))] = AppRow(
                title: text(st, 1), bundleID: text(st, 2), customPath: text(st, 3), bookmark: blob(st, 4))
        }
        var groupTitles: [Int: String] = [:]
        if tableExists(db, "groups") {
            try query(db, "SELECT item_id, title FROM groups") { st in
                if let t = text(st, 1), !t.isEmpty { groupTitles[Int(sqlite3_column_int64(st, 0))] = t }
            }
        }

        return build(items: items, apps: apps, groupTitles: groupTitles, rows: rows, columns: columns,
                     installed: installed, keeps: keeps, resolve: resolve)
    }

    /// Whether a copy Launch Services found outside the scan folders is one to put on the grid:
    /// there on disk, and not in the Trash, run from a translocated quarantine copy, or on
    /// another volume (a disk image, a backup disk), which would leave a tile behind once
    /// ejected. The old Launchpad database still lists apps deleted long since.
    public static func isLastingCopy(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if parts.contains(where: { $0 == ".Trash" || $0 == ".Trashes" || $0 == "AppTranslocation" }) { return false }
        if parts.count > 2, parts[1] == "Volumes" { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// `keeps` says whether a copy Launch Services `resolve`s to, for an app the scan didn't
    /// find, is one to import (`isLastingCopy` for a real database).
    static func build(
        items: [Row], apps: [Int: AppRow], groupTitles: [Int: String],
        rows: Int, columns: Int, installed: [String] = [],
        keeps: (String) -> Bool = { _ in true }, resolve: (String) -> String?
    ) -> Result {
        let children = Dictionary(grouping: items, by: \.parent).mapValues { $0.sorted { $0.ordering < $1.ordering } }
        var skipped: [String] = [], duplicates: [String] = []
        var imported = 0
        var seen = Set<String>()
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let spelling = Dictionary(installed.map { (real($0), $0) }, uniquingKeysWith: { a, _ in a })
        /// Installed copies by bundle ID, read the first time a row has only its bundle ID to go on.
        var copiesByID: [String: [String]]?
        func copies(of id: String) -> [String] {
            if copiesByID == nil {
                let ids = installed.compactMap { path in
                    (AppScanner.infoDictionary(ofBundleAt: URL(fileURLWithPath: path))?["CFBundleIdentifier"] as? String).map { ($0, path) }
                }
                copiesByID = Dictionary(grouping: ids, by: \.0).mapValues { $0.map(\.1) }
            }
            return copiesByID?[id] ?? []
        }

        /// `visited` guards against parent_id cycles in a damaged database.
        func countApps(under id: Int, visited: inout Set<Int>) -> Int {
            guard visited.insert(id).inserted else { return 0 }
            var n = 0
            for child in children[id] ?? [] {
                n += child.type == ItemType.app.rawValue ? 1 : countApps(under: child.id, visited: &visited)
            }
            return n
        }
        func countApps(under id: Int) -> Int {
            var visited = Set<Int>()
            return countApps(under: id, visited: &visited)
        }

        func makeApp(_ id: Int) -> AppRef? {
            guard let row = apps[id] else { return nil }
            let title = [row.title, row.bundleID].compactMap { $0 }.first { !$0.isEmpty } ?? "App"
            // AppGrid invents `manual_app_<hash>` IDs for apps it added by path.
            let bundleID = row.bundleID.flatMap { $0.hasPrefix("manual_app_") || $0.isEmpty ? nil : $0 }
            var candidate: String?
            if let p = row.customPath, FileManager.default.fileExists(atPath: p) { candidate = p }
            if candidate == nil, let data = row.bookmark, let p = path(ofBookmark: data),
               FileManager.default.fileExists(atPath: p) { candidate = p }
            if candidate == nil, let b = bundleID {
                // Launch Services gives one copy per bundle ID. Of several (Xcode and Xcode-beta,
                // in AppGrid's table, which has no bookmarks), the one named as the row is, else
                // one not imported yet.
                // Of one, that one: Launch Services may prefer a copy the scan doesn't see (on a
                // disk image, in Downloads, a build in DerivedData). Its answer only stands for an
                // app the scan didn't find, or picks among the scan's copies.
                let others = copies(of: b)
                if others.count == 1 {
                    candidate = others[0]
                } else if others.count > 1 {
                    let file = { (path: String) in URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased() }
                    let scanned = Set(others.map(real))
                    candidate = others.first { file($0) == title.lowercased() }
                        ?? resolve(b).flatMap { scanned.contains(real($0)) && !seen.contains(real($0)) ? $0 : nil }
                        ?? others.first { !seen.contains(real($0)) }
                        ?? others[0] // every copy imported already: a duplicate
                } else {
                    candidate = resolve(b).flatMap { keeps($0) ? $0 : nil }
                }
            }
            guard let found = candidate else {
                skipped.append(title)
                return nil
            }
            let resolved = real(found)
            let path = spelling[resolved] ?? found
            var ref = AppRef(bundleID: bundleID, path: path, name: title)
            if bundleID == nil, let id = AppScanner.infoDictionary(ofBundleAt: URL(fileURLWithPath: path))?["CFBundleIdentifier"] as? String {
                ref.bundleID = id
            }
            // By path: copies sharing a bundle ID (Xcode and Xcode-beta) are separate apps.
            guard seen.insert(resolved).inserted else {
                duplicates.append(title)
                return nil
            }
            imported += 1
            return ref
        }

        /// Apps inside a folder: directly, through the folder's own pages or in folders inside it.
        func folderApps(_ id: Int, visited: inout Set<Int>) -> [AppRef] {
            guard visited.insert(id).inserted else { return [] }
            var out: [AppRef] = []
            for child in children[id] ?? [] {
                switch ItemType(rawValue: child.type) {
                case .app: out += makeApp(child.id).map { [$0] } ?? []
                // A folder in a folder: the grid has one level, so its apps join this one.
                case .page, .folder: out += folderApps(child.id, visited: &visited)
                default: break
                }
            }
            return out
        }

        func pageItems(_ id: Int) -> [GridItem] {
            (children[id] ?? []).compactMap { child -> GridItem? in
                switch ItemType(rawValue: child.type) {
                case .app:
                    return makeApp(child.id).map(GridItem.app)
                case .folder:
                    var visited = Set<Int>()
                    let contents = folderApps(child.id, visited: &visited)
                    guard !contents.isEmpty else { return nil }
                    return .folder(Folder(name: groupTitles[child.id] ?? String(localized: "Folder"), apps: contents))
                default:
                    return nil
                }
            }
        }

        // Containers of top-level pages: explicit roots (type 1) and parentless items.
        // Apple's DB has several roots (holding page, apps, widgets); AppGrid's root is a
        // type-3 item with parent 0. Pick the one holding the most apps.
        let containers = items.filter { $0.type == ItemType.root.rawValue || $0.parent == 0 }
        let root = containers.max { countApps(under: $0.id) < countApps(under: $1.id) }

        var grid = Grid(rows: rows, columns: columns, pages: [])
        if let root {
            let pageRows = (children[root.id] ?? []).filter { $0.type == ItemType.page.rawValue }
            // A page fuller than this grid holds splits into several, so its overflow doesn't
            // spill onto the next imported page and shift every page after it.
            let capacity = grid.capacity
            grid.pages = pageRows.flatMap { row in
                let items = pageItems(row.id)
                return stride(from: 0, to: items.count, by: capacity).map {
                    Page(title: groupTitles[row.id], items: Array(items[$0..<min($0 + capacity, items.count)]))
                }
            }
        }
        grid.normalize()
        return Result(grid: grid, imported: imported, skipped: skipped, duplicates: duplicates)
    }

    /// Copies a database and its write-ahead log as a consistent pair. A log that grew
    /// meanwhile is fine (its new frames extend what the copy holds, and a torn last frame
    /// fails its checksum), but one reset by a checkpoint between the two copies no longer
    /// matches the database copied before it. A reset changes the log header's checkpoint
    /// sequence and salts, so the copy is retried until the header held still throughout.
    /// `betweenCopies` runs after the database is copied and before its log is, for tests.
    static func copyDatabase(at url: URL, to tmp: URL, attempts: Int = 5, betweenCopies: () -> Void = {}) throws {
        let fm = FileManager.default
        let wal = url.path + "-wal"
        let tmpWAL = tmp.path + "-wal"
        for _ in 0..<attempts {
            for path in [tmp.path, tmpWAL] { try? fm.removeItem(atPath: path) }
            let before = walHeader(wal)
            try fm.copyItem(at: url, to: tmp)
            betweenCopies()
            if fm.fileExists(atPath: wal) {
                do { try fm.copyItem(atPath: wal, toPath: tmpWAL) }
                // Checkpointed away since: the header check below sees that and tries again.
                catch where !fm.fileExists(atPath: wal) {}
            }
            if walHeader(tmpWAL) == before, walHeader(wal) == before { return }
        }
        throw ImportError.readFailed("the database kept changing while it was being copied")
    }

    /// The write-ahead log's checkpoint sequence and salts (header bytes 12..<24), empty for
    /// a log too short to have them, nil when there is no log.
    static func walHeader(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 24)) ?? Data()
        return head.count == 24 ? head.subdata(in: 12..<24) : Data()
    }

    // MARK: SQLite helpers

    /// Runs `sql`, calling `row` per result. Throws if stepping stops on an error, so a
    /// damaged database can't pass for a complete but smaller one.
    static func query(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) throws -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw ImportError.cannotOpen(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        var rc = sqlite3_step(st)
        while rc == SQLITE_ROW {
            try row(st)
            rc = sqlite3_step(st)
        }
        guard rc == SQLITE_DONE else { throw ImportError.readFailed(String(cString: sqlite3_errmsg(db))) }
    }

    private static func text(_ st: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(st, i).map { String(cString: $0) }
    }

    private static func blob(_ st: OpaquePointer, _ i: Int32) -> Data? {
        let n = Int(sqlite3_column_bytes(st, i))
        guard n > 0, let bytes = sqlite3_column_blob(st, i) else { return nil }
        return Data(bytes: bytes, count: n)
    }

    /// Where a bookmark points, without asking anything of the person or mounting a volume.
    static func path(ofBookmark data: Data) -> String? {
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale))?.path
    }

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var found = false
        try? query(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(name)'") { _ in found = true }
        return found
    }

    private static func columnExists(_ db: OpaquePointer, table: String, column: String) -> Bool {
        var found = false
        try? query(db, "PRAGMA table_info(\(table))") { st in
            if text(st, 1) == column { found = true }
        }
        return found
    }
}
