import Foundation

public enum GridFileError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): "This grid file was made by a newer version (format \(v))."
        case .invalid(let why): "The grid file is not valid: \(why)"
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

    public func load() throws -> Grid {
        try GridStore.decode(Data(contentsOf: url))
    }

    public func save(_ grid: Grid) throws {
        // Write through a symlink: an atomic write to the link itself would replace it with a file.
        let target = GridStore.followingSymlinks(url)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GridStore.encode(grid).write(to: target, options: .atomic)
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
        struct Header: Decodable { var version: Int? }
        let version = (try? JSONDecoder().decode(Header.self, from: data))?.version ?? 1
        guard version <= Grid.currentVersion else { throw GridFileError.unsupportedVersion(version) }
        // Future migrations go here, keyed on `version`.
        var grid: Grid
        do {
            grid = try JSONDecoder().decode(Grid.self, from: data)
        } catch {
            throw GridFileError.invalid(error.localizedDescription)
        }
        guard (1...50).contains(grid.rows), (1...50).contains(grid.columns) else {
            throw GridFileError.invalid("grid size \(grid.rows)×\(grid.columns) is out of range")
        }
        grid.version = Grid.currentVersion
        freshenRepeatedIDs(in: &grid)
        grid.normalize()
        return grid
    }

    /// Gives a fresh ID to each item (app or folder, inside folders too) whose ID an earlier
    /// item already has, so a hand-edited or merged file can't make `locate` and `detach`
    /// disagree about which item an ID means.
    static func freshenRepeatedIDs(in grid: inout Grid) {
        var seen = Set<UUID>()
        func fresh(_ id: inout UUID) {
            if !seen.insert(id).inserted { id = UUID() }
        }
        for p in grid.pages.indices {
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
