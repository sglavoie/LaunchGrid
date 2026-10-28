import Foundation

public enum GridFileError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): String(localized: "This grid file was made by a newer version (format \(v)).")
        case .invalid(let why): String(localized: "The grid file is not valid: \(why)")
        }
    }
}

/// Reads and writes the grid as versioned JSON.
public struct GridStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LaunchGrid", isDirectory: true).appendingPathComponent("grid.json")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The file itself: `url` with symlinks followed, so moving it aside leaves a link in place.
    public var fileURL: URL { GridStore.followingSymlinks(url) }

    /// An earlier save, to fall back on when the last didn't make it to disk whole (a power
    /// cut right after writing can leave an empty file) or turned out to be one to regret.
    public var backupURL: URL { fileURL.appendingPathExtension("bak") }

    public func load() throws -> Grid {
        try GridStore.decode(Data(contentsOf: url))
    }

    /// `load()`, also telling how many entries (apps, folders, pages) couldn't be read and were left out.
    public func loadCountingSkipped() throws -> (grid: Grid, skipped: Int) {
        try GridStore.decodeCountingSkipped(Data(contentsOf: url))
    }

    public func loadBackup() throws -> Grid {
        try GridStore.decode(Data(contentsOf: backupURL))
    }

    /// How many daily copies of the backup are kept.
    public static let dailyBackupsKept = 3

    /// The backup as it was before the first refresh on `day` (`yyyy-MM-dd`): one regretted
    /// change saved, quit and saved again after relaunching soon replaces the backup itself.
    /// Named `.json`, so Load Grid File opens it.
    public func dailyBackupURL(day: String) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("backup-\(day).json")
    }

    /// The daily copies kept, oldest first.
    public var dailyBackups: [URL] {
        let folder = fileURL.deletingLastPathComponent()
        let prefix = fileURL.deletingPathExtension().lastPathComponent + ".backup-"
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
        // Only the dated files we create belong to the rotation. A manual backup or a
        // directory with a similar name must never be deleted as an old daily copy.
        // The date in the name sorts them; no file dates are read.
        return files.filter { file in
            let name = file.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return false }
            let day = String(name.dropFirst(prefix.count).dropLast(5))
            guard day.count == 10,
                  day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
                  Self.isCalendarDay(day),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isCalendarDay(_ day: String) -> Bool {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        let date = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        return date.isValidDate(in: Calendar(identifier: .gregorian))
    }

    /// The day `date` falls on here, as daily backups are named.
    public static func day(of date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Copies the backup aside the first time it's refreshed on `day`, and lets the oldest
    /// copies go. Best effort, as the backup is.
    private func keepDailyCopy(day: String) {
        let fm = FileManager.default
        let daily = dailyBackupURL(day: day)
        guard fm.fileExists(atPath: backupURL.path), !fm.fileExists(atPath: daily.path) else { return }
        guard (try? fm.copyItem(at: backupURL, to: daily)) != nil else { return }
        for old in dailyBackups.dropLast(Self.dailyBackupsKept) { try? fm.removeItem(at: old) }
    }

    /// Saves `grid`. With `refreshingBackup`, the file it replaces becomes the backup after
    /// the new file is safely written;
    /// without, the backup stays as it is, so it can be older than the save before this one.
    /// Returns whether the backup was refreshed. The first refresh on each day (`now`'s) keeps
    /// a copy of the backup it replaces (`dailyBackups`).
    @discardableResult
    public func save(_ grid: Grid, refreshingBackup: Bool = true, now: Date = Date()) throws -> Bool {
        try save(grid, refreshingBackup: refreshingBackup, now: now, write: GridStore.writeDurably)
    }

    @discardableResult
    func save(_ grid: Grid, refreshingBackup: Bool, now: Date,
              flushBackup: (URL) throws -> Void = GridStore.flushFile,
              write: (Data, URL) throws -> Void) throws -> Bool {
        // Write through a symlink: an atomic write to the link itself would replace it with a file.
        let target = fileURL
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        GridStore.removeLeftoverTemporaryFiles(beside: target)
        var stagedBackup: URL?
        defer { if let stagedBackup { unlink(stagedBackup.path) } }
        // A partly readable file can be repaired and saved, but it must not replace the
        // last complete backup. AppState keeps the damaged original separately.
        if refreshingBackup && fm.fileExists(atPath: target.path),
           let current = try? GridStore.decodeCountingSkipped(Data(contentsOf: target)),
           current.skipped == 0 {
            // Stage the old layout before writing, but leave the existing backup alone until
            // the new layout is safely on disk. A failed save must not erase an older backup.
            let backup = backupURL
            let tmp = backup.deletingLastPathComponent()
                .appendingPathComponent(".\(backup.lastPathComponent).\(UUID().uuidString).tmp")
            // The main writer flushes its temporary file before renaming it. Do the
            // same here: a copied backup can otherwise reappear empty after a power cut.
            if (try? fm.copyItem(at: target, to: tmp)) != nil,
               (try? flushBackup(tmp)) != nil { stagedBackup = tmp }
            else { unlink(tmp.path) }
        }
        try write(GridStore.encode(grid), target)
        guard let stagedBackup else { return false }
        keepDailyCopy(day: GridStore.day(of: now))
        guard rename(stagedBackup.path, backupURL.path) == 0 else { return false }
        // The new backup's contents are flushed above. Some filesystems refuse directory
        // syncing; the backup was still replaced, so count this refresh only once.
        _ = GridStore.flushDirectory(at: target.deletingLastPathComponent())
        return true
    }

    /// Deletes temporary files an earlier save left beside `url` when it was cut short (by a
    /// crash or a power cut), which nothing else would ever remove.
    static func removeLeftoverTemporaryFiles(beside url: URL) {
        let folder = url.deletingLastPathComponent()
        let prefixes = [".\(url.lastPathComponent).", ".\(url.lastPathComponent).bak."]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: Array(keys)) else { return }
        for file in files {
            let name = file.lastPathComponent
            // Both writers use a UUID, not an arbitrary suffix. Nearby editor or manual
            // temporary files belong to their owners, as do links and directories.
            guard name.hasSuffix(".tmp"), prefixes.contains(where: { prefix in
                name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil
            }), let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            unlink(file.path)
        }
    }

    /// Writes `data` to a temporary file beside `url`, flushes it to the disk itself, then
    /// renames it over `url` and flushes the folder. A power cut leaves the old file or the
    /// new one, whole: `Data.write(options: .atomic)` renames without flushing, so both the
    /// file and the backup cloned from it could come back empty.
    static func writeDurably(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent().path
        let tmp = folder + "/.\(url.lastPathComponent).\(UUID().uuidString).tmp"
        // Keep a private new file private, and preserve permissions someone set on an
        // existing layout. Replacing it by rename otherwise resets its mode on every save.
        var existing = stat()
        let mode: mode_t = stat(url.path, &existing) == 0 ? existing.st_mode & 0o777 : 0o600
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw posixError() }
        var renamed = false
        defer { if !renamed { unlink(tmp) } }
        do {
            defer { close(fd) }
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var written = 0
                while written < buffer.count {
                    let n = write(fd, base + written, buffer.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw posixError()
                    }
                    written += n
                }
            }
            guard fchmod(fd, mode) == 0 else { throw posixError() }
            // F_FULLFSYNC also empties the drive's own cache, which fsync leaves to the drive.
            // Some file systems don't support it; fsync is the most they offer.
            try flushDescriptor(fd)
        }
        guard rename(tmp, url.path) == 0 else { throw posixError() }
        renamed = true
        // The rename itself lives in the folder.
        _ = flushDirectory(at: url.deletingLastPathComponent())
    }

    private static func flushDescriptor(_ fd: Int32) throws {
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw posixError() }
    }

    /// Flushes a copied file before it becomes the recovery copy.
    static func flushFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        try flushDescriptor(fd)
    }

    @discardableResult
    private static func flushDirectory(at url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return (try? flushDescriptor(fd)) != nil
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// `url` with symlinks followed, including a last one whose target doesn't exist yet
    /// (which `resolvingSymlinksInPath()` leaves alone).
    static func followingSymlinks(_ url: URL) -> URL {
        var url = url.resolvingSymlinksInPath()
        for _ in 0..<32 { // bounded, in case of a link loop
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { break }
            url = URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
        return url
    }

    public static func encode(_ grid: Grid) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(grid)
    }

    /// Decodes, migrates and validates a grid.
    public static func decode(_ data: Data) throws -> Grid {
        try decodeCountingSkipped(data).grid
    }

    /// `decode(_:)`, also telling how many entries couldn't be read and were left out.
    public static func decodeCountingSkipped(_ data: Data) throws -> (grid: Grid, skipped: Int) {
        /// The version, also when written as text ("2"), so a newer file is told apart from a broken one.
        struct Header: Decodable {
            var version: Int?
            /// A version that is there but isn't a whole number ("2.1", 1.5, an object), as a
            /// number when it reads as one.
            var unreadable: Double??
            enum CodingKeys: String, CodingKey { case version }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let text = (try? c.decodeIfPresent(String.self, forKey: .version)).flatMap { $0?.trimmingCharacters(in: .whitespaces) }
                version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? text.flatMap { Int($0) }
                if version == nil, c.contains(.version), (try? c.decodeNil(forKey: .version)) != true {
                    unreadable = .some((try? c.decode(Double.self, forKey: .version)) ?? text.flatMap { Double($0) })
                }
            }
        }
        let header = try? JSONDecoder().decode(Header.self, from: data)
        // Treated as version 1 it would be saved over as one, losing what a newer version wrote.
        if let unreadable = header?.unreadable {
            if let v = unreadable, v.isFinite, v > Double(Grid.currentVersion) {
                throw GridFileError.unsupportedVersion(Int(min(v, 1_000_000)))
            }
            throw GridFileError.invalid("its format version isn't a whole number")
        }
        let version = header?.version ?? 1
        guard version <= Grid.currentVersion else { throw GridFileError.unsupportedVersion(version) }
        guard version >= 1 else { throw GridFileError.invalid("version \(version) is not a format version") }
        // Future migrations go here, keyed on `version`.
        var grid: Grid
        let skipped = SkippedEntries()
        do {
            let decoder = JSONDecoder()
            decoder.userInfo[SkippedEntries.key] = skipped
            grid = try decoder.decode(Grid.self, from: data)
        } catch {
            throw GridFileError.invalid(error.localizedDescription)
        }
        // A few bad entries are dropped; with nothing left, the file is broken, not empty.
        if skipped.layoutCount > 0 && grid.allApps.isEmpty && grid.recentlyPruned.isEmpty {
            throw GridFileError.invalid("none of its \(skipped.layoutCount) entries could be read")
        }
        guard (1...50).contains(grid.rows), (1...50).contains(grid.columns) else {
            throw GridFileError.invalid("grid size \(grid.rows)×\(grid.columns) is out of range")
        }
        grid.version = Grid.currentVersion
        freshenRepeatedIDs(in: &grid)
        grid.normalize()
        return (grid, skipped.count)
    }

    /// Gives a fresh ID to each page and item (app or folder, inside folders too) whose ID an
    /// earlier one already has, including apps waiting for restoration, so a hand-edited or
    /// merged file can't make `locate` and `detach` disagree about which item an ID means.
    static func freshenRepeatedIDs(in grid: inout Grid) {
        var seen = Set<UUID>()
        func fresh(_ id: inout UUID) {
            while !seen.insert(id).inserted { id = UUID() }
        }
        for p in grid.pages.indices {
            fresh(&grid.pages[p].id)
            for i in grid.pages[p].items.indices {
                switch grid.pages[p].items[i] {
                case .app(var a):
                    fresh(&a.id)
                    grid.pages[p].items[i] = .app(a)
                case .folder(var f):
                    fresh(&f.id)
                    for k in f.apps.indices { fresh(&f.apps[k].id) }
                    grid.pages[p].items[i] = .folder(f)
                }
            }
        }
        // Restored containers become ordinary pages and folders without another decode.
        // Reuse a live container only of the right kind; otherwise reserve one fresh ID
        // per remembered container, shared by every app waiting to return to it.
        var pages = Dictionary(uniqueKeysWithValues: grid.pages.map { ($0.id, $0.id) })
        var folders = Dictionary(uniqueKeysWithValues: grid.pages.flatMap {
            $0.items.compactMap(\.folder).map { ($0.id, $0.id) }
        })
        func container(_ id: UUID, in mapping: inout [UUID: UUID]) -> UUID {
            if let known = mapping[id] { return known }
            var replacement = id
            fresh(&replacement)
            mapping[id] = replacement
            return replacement
        }
        for i in grid.recentlyPruned.indices {
            grid.recentlyPruned[i].pageID = container(grid.recentlyPruned[i].pageID, in: &pages)
        }
        for i in grid.recentlyPruned.indices {
            if let id = grid.recentlyPruned[i].folderID {
                grid.recentlyPruned[i].folderID = container(id, in: &folders)
            }
            grid.recentlyPruned[i].pageBefore = grid.recentlyPruned[i].pageBefore?.map { pages[$0] ?? $0 }
        }
        for i in grid.recentlyPruned.indices { fresh(&grid.recentlyPruned[i].app.id) }
    }
}
