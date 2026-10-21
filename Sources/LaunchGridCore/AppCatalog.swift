import Foundation
import UniformTypeIdentifiers

/// Finds application bundles on disk.
public enum AppScanner {
    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "/Applications",
            "/System/Applications",
            home.appendingPathComponent("Applications").path,
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Scans the roots (recursing into plain folders up to `maxDepth`, never into bundles)
    /// and returns one entry per app, de-duplicated by bundle ID with earlier roots winning.
    public static func scan(roots: [URL], maxDepth: Int = 3) -> [InstalledApp] {
        let fm = FileManager.default
        var visited = Set<String>()
        var results: [InstalledApp] = []
        var bundleIDs = Set<String>()

        func consider(_ url: URL) {
            guard let app = read(appAt: url) else { return }
            if let id = app.bundleID {
                guard bundleIDs.insert(id).inserted else { return }
            }
            results.append(app)
        }

        func walk(_ dir: URL, depth: Int) {
            let real = dir.resolvingSymlinksInPath().path
            guard visited.insert(real).inserted else { return } // symlink cycle or repeat
            guard let children = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentTypeKey, .isPackageKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if isApplication(child) {
                    consider(child)
                } else if depth < maxDepth, isPlainDirectory(child) {
                    walk(child, depth: depth + 1)
                }
            }
        }

        for root in roots { walk(root, depth: 1) }
        return results
    }

    static func isApplication(_ url: URL) -> Bool {
        guard url.pathExtension == "app" else { return false }
        // Use the enumerated path for identity but the target's type (e.g. Safari's symlink).
        let target = url.resolvingSymlinksInPath()
        let type = (try? target.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return type?.conforms(to: .applicationBundle) ?? false
    }

    static func isPlainDirectory(_ url: URL) -> Bool {
        let v = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }

    public static func read(appAt url: URL) -> InstalledApp? {
        let path = url.path
        let info = Bundle(url: url.resolvingSymlinksInPath())?.infoDictionary
            ?? NSDictionary(contentsOf: url.resolvingSymlinksInPath().appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let bundleID = info?["CFBundleIdentifier"] as? String
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let category = info?["LSApplicationCategoryType"] as? String
        return InstalledApp(bundleID: bundleID, path: path, name: name, category: category)
    }
}
