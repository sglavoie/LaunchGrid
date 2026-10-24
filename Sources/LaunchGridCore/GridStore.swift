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

    /// Saves `grid`. With `refreshingBackup`, the file it replaces becomes the backup first;
    /// without, the backup stays as it is, so it can be older than the save before this one.
    /// Returns whether the backup was refreshed.
    @discardableResult
    public func save(_ grid: Grid, refreshingBackup: Bool = true) throws -> Bool {
        // Write through a symlink: an atomic write to the link itself would replace it with a file.
        let target = fileURL
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        GridStore.removeLeftoverTemporaryFiles(beside: target)
        var refreshed = false
        if refreshingBackup && fm.fileExists(atPath: target.path) {
            // A clone on APFS, so it costs next to nothing, renamed over the old backup so there
            // is always one. Best effort: the save matters more.
            let backup = backupURL
            let tmp = backup.deletingLastPathComponent()
                .appendingPathComponent(".\(backup.lastPathComponent).\(UUID().uuidString).tmp")
            if (try? fm.copyItem(at: target, to: tmp)) != nil {
                refreshed = rename(tmp.path, backup.path) == 0
                if !refreshed { unlink(tmp.path) }
            }
        }
        try GridStore.writeDurably(GridStore.encode(grid), to: target)
        return refreshed
    }

    /// Deletes temporary files an earlier save left beside `url` when it was cut short (by a
    /// crash or a power cut), which nothing else would ever remove.
    static func removeLeftoverTemporaryFiles(beside url: URL) {
        let folder = url.deletingLastPathComponent()
        let prefixes = [".\(url.lastPathComponent).", ".\(url.lastPathComponent).bak."]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".tmp") && prefixes.contains(where: name.hasPrefix) {
            unlink(folder.appendingPathComponent(name).path)
        }
    }

    /// Writes `data` to a temporary file beside `url`, flushes it to the disk itself, then
    /// renames it over `url` and flushes the folder. A power cut leaves the old file or the
    /// new one, whole: `Data.write(options: .atomic)` renames without flushing, so both the
    /// file and the backup cloned from it could come back empty.
    static func writeDurably(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent().path
        let tmp = folder + "/.\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o644)
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
            // F_FULLFSYNC also empties the drive's own cache, which fsync leaves to the drive.
            // Some file systems don't support it; fsync is the most they offer.
            guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw posixError() }
        }
        guard rename(tmp, url.path) == 0 else { throw posixError() }
        renamed = true
        // The rename itself lives in the folder.
        let dir = open(folder, O_RDONLY)
        if dir >= 0 {
            _ = fcntl(dir, F_FULLFSYNC) == 0 || fsync(dir) == 0
            close(dir)
        }
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
            enum CodingKeys: String, CodingKey { case version }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                version = (try? c.decodeIfPresent(Int.self, forKey: .version))
                    ?? (try? c.decodeIfPresent(String.self, forKey: .version)).flatMap { $0.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
            }
        }
        let version = (try? JSONDecoder().decode(Header.self, from: data))?.version ?? 1
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
        if skipped.count > 0 && grid.allApps.isEmpty {
            throw GridFileError.invalid("none of its \(skipped.count) entries could be read")
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
    /// earlier one already has, so a hand-edited or merged file can't make `locate` and `detach`
    /// disagree about which item an ID means.
    static func freshenRepeatedIDs(in grid: inout Grid) {
        var seen = Set<UUID>()
        func fresh(_ id: inout UUID) {
            if !seen.insert(id).inserted { id = UUID() }
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
    }
}
