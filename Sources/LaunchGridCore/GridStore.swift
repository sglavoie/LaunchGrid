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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GridStore.encode(grid).write(to: url, options: .atomic)
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
        grid.normalize()
        return grid
    }
}
