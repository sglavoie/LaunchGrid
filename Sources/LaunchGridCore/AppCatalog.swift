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
    /// and returns one entry per app bundle on disk, de-duplicated by resolved path with
    /// earlier roots winning. Copies sharing a bundle ID (Xcode and Xcode-beta) are all kept.
    public static func scan(roots: [URL], maxDepth: Int = 3) -> [InstalledApp] {
        let fm = FileManager.default
        // Shallowest depth each directory was walked at: a root nested in another root's
        // depth limit is walked again from its own, shallower, depth.
        var visited: [String: Int] = [:]
        var results: [InstalledApp] = []
        var paths = Set<String>()

        func consider(_ url: URL) {
            guard paths.insert(url.resolvingSymlinksInPath().path).inserted, let app = read(appAt: url) else { return }
            results.append(app)
        }

        func walk(_ dir: URL, depth: Int) {
            let real = dir.resolvingSymlinksInPath().path
            if let seen = visited[real], seen <= depth { return } // symlink cycle or repeat
            visited[real] = depth
            guard let children = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentTypeKey, .isPackageKey, .isHiddenKey]
            ) else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if child.lastPathComponent.hasPrefix(".") { continue }
                // Apps flagged hidden still count: /Applications/Safari.app is a hidden symlink.
                if isApplication(child) {
                    consider(child)
                } else if depth < maxDepth, !isHidden(child), isPlainDirectory(child) {
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

    static func isHidden(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
    }

    static func isPlainDirectory(_ url: URL) -> Bool {
        let v = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }

    public static func read(appAt url: URL) -> InstalledApp? {
        let path = url.path
        let real = url.resolvingSymlinksInPath()
        // Not an app without an Info.plist (e.g. a half-copied bundle or a stray folder).
        guard let info = Bundle(url: real)?.infoDictionary.flatMap({ $0.isEmpty ? nil : $0 })
            ?? NSDictionary(contentsOf: real.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        else { return nil }
        let bundleID = info["CFBundleIdentifier"] as? String
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let category = info["LSApplicationCategoryType"] as? String
        return InstalledApp(bundleID: bundleID, path: path, name: name, category: category)
    }
}
