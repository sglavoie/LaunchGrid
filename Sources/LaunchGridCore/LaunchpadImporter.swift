import Foundation
import SQLite3

/// Reads a Launchpad-schema SQLite database: Apple's legacy Dock Launchpad DB,
/// AppGrid's own `db`, or an `.agrid` file (the same format). Read-only, best effort.
public enum LaunchpadImporter {
    public struct Result: Sendable {
        public var grid: Grid
        public var imported: Int
        public var skipped: [String]
    }

    public enum ImportError: Error, LocalizedError {
        case cannotOpen(String)
        case notALaunchpadDatabase
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let why): "Could not open the database: \(why)"
            case .notALaunchpadDatabase: "This file is not a Launchpad or AppGrid database."
            case .readFailed(let why): "Could not read the database: \(why)"
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
        let dir = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let url = URL(fileURLWithPath: "/private" + dir + "com.apple.dock.launchpad/db/db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// AppGrid's database inside its sandbox container, if present.
    public static var appGridDatabaseURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.zekalogic.appgrid.app/Data/Library/Application Support/db")
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
    }

    /// - Parameter resolve: maps a bundle ID to an installed path (normally via NSWorkspace).
    public static func importDatabase(
        at url: URL,
        rows: Int,
        columns: Int,
        resolve: (String) -> String?
    ) throws -> Result {
        // Copy first so a live database is never touched. Its write-ahead log comes along:
        // recent changes may live only there. The shared-memory index is left behind and
        // rebuilt from the log, which needs a writable connection to the copy.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("launchgrid-import-\(UUID().uuidString).db")
        try fm.copyItem(at: url, to: tmp)
        defer {
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: tmp.path + suffix) }
        }
        let wal = URL(fileURLWithPath: url.path + "-wal")
        if fm.fileExists(atPath: wal.path) {
            try fm.copyItem(at: wal, to: URL(fileURLWithPath: tmp.path + "-wal"))
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let why = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw ImportError.cannotOpen(why)
        }
        defer { sqlite3_close(db) }

        guard tableExists(db, "items"), tableExists(db, "apps") else { throw ImportError.notALaunchpadDatabase }
        let hasCustomPath = columnExists(db, table: "apps", column: "custom_path")

        var items: [Row] = []
        try query(db, "SELECT rowid, type, parent_id, ordering FROM items ORDER BY parent_id, ordering") { st in
            items.append(Row(id: Int(sqlite3_column_int64(st, 0)), type: Int(sqlite3_column_int(st, 1)),
                             parent: Int(sqlite3_column_int64(st, 2)), ordering: Int(sqlite3_column_int(st, 3))))
        }
        var apps: [Int: AppRow] = [:]
        let appSQL = "SELECT item_id, title, bundleid\(hasCustomPath ? ", custom_path" : "") FROM apps"
        try query(db, appSQL) { st in
            apps[Int(sqlite3_column_int64(st, 0))] = AppRow(
                title: text(st, 1), bundleID: text(st, 2), customPath: hasCustomPath ? text(st, 3) : nil)
        }
        var groupTitles: [Int: String] = [:]
        if tableExists(db, "groups") {
            try query(db, "SELECT item_id, title FROM groups") { st in
                if let t = text(st, 1), !t.isEmpty { groupTitles[Int(sqlite3_column_int64(st, 0))] = t }
            }
        }

        return build(items: items, apps: apps, groupTitles: groupTitles, rows: rows, columns: columns, resolve: resolve)
    }

    static func build(
        items: [Row], apps: [Int: AppRow], groupTitles: [Int: String],
        rows: Int, columns: Int, resolve: (String) -> String?
    ) -> Result {
        let children = Dictionary(grouping: items, by: \.parent).mapValues { $0.sorted { $0.ordering < $1.ordering } }
        var skipped: [String] = []
        var imported = 0
        var seen = Set<String>()

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
            let title = row.title ?? row.bundleID ?? "App"
            // AppGrid invents `manual_app_<hash>` IDs for apps it added by path.
            let bundleID = row.bundleID.flatMap { $0.hasPrefix("manual_app_") || $0.isEmpty ? nil : $0 }
            var path: String?
            if let p = row.customPath, FileManager.default.fileExists(atPath: p) { path = p }
            if path == nil, let b = bundleID { path = resolve(b) }
            guard let path else {
                skipped.append(title)
                return nil
            }
            var ref = AppRef(bundleID: bundleID, path: path, name: title)
            if bundleID == nil, let real = Bundle(path: path)?.bundleIdentifier { ref.bundleID = real }
            guard seen.insert(ref.key).inserted else { return nil }
            imported += 1
            return ref
        }

        /// Apps inside a folder: directly or through the folder's own pages.
        func folderApps(_ id: Int, visited: inout Set<Int>) -> [AppRef] {
            guard visited.insert(id).inserted else { return [] }
            var out: [AppRef] = []
            for child in children[id] ?? [] {
                switch ItemType(rawValue: child.type) {
                case .app: out += makeApp(child.id).map { [$0] } ?? []
                case .page: out += folderApps(child.id, visited: &visited)
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
                    return .folder(Folder(name: groupTitles[child.id] ?? "Folder", apps: contents))
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
            grid.pages = pageRows.map { Page(title: groupTitles[$0.id], items: pageItems($0.id)) }.filter { !$0.items.isEmpty }
        }
        grid.normalize()
        return Result(grid: grid, imported: imported, skipped: skipped)
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
