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

        /// `realPath` is the bundle's symlink-free path, its identity for de-duplication.
        func consider(_ url: URL, realPath: String) {
            guard paths.insert(realPath).inserted, let app = read(appAt: url) else { return }
            results.append(app)
        }

        func walk(_ dir: URL, depth: Int) {
            let real = dir.resolvingSymlinksInPath().path
            if let seen = visited[real], seen <= depth { return } // symlink cycle or repeat
            visited[real] = depth
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(scanKeys)) else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if child.lastPathComponent.hasPrefix(".") { continue }
                // Answered from the values prefetched with the listing. Only a symlink is
                // resolved, to ask about its target (e.g. Safari's).
                guard let own = try? child.resourceValues(forKeys: scanKeys) else { continue }
                let target = own.isSymbolicLink == true ? child.resolvingSymlinksInPath() : nil
                guard let v = target.map({ try? $0.resourceValues(forKeys: scanKeys) }) ?? own else { continue }
                // Apps flagged hidden still count: /Applications/Safari.app is a hidden symlink.
                if child.pathExtension == "app", v.contentType?.conforms(to: .applicationBundle) == true {
                    consider(child, realPath: target?.path ?? (real as NSString).appendingPathComponent(child.lastPathComponent))
                } else if depth < maxDepth, own.isHidden != true, v.isDirectory == true, v.isPackage != true {
                    walk(child, depth: depth + 1)
                }
            }
        }

        for root in roots { walk(root, depth: 1) }
        return results
    }

    static let scanKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentTypeKey, .isPackageKey, .isHiddenKey]

    /// A bundle's Info.plist, read from disk every time: `Bundle` caches it per path for the
    /// life of the process, so a rescan would miss an updated bundle ID or category.
    static func infoDictionary(ofBundleAt url: URL) -> [String: Any]? {
        let real = url.resolvingSymlinksInPath()
        if let info = NSDictionary(contentsOf: real.appendingPathComponent("Contents/Info.plist")) as? [String: Any] {
            return info
        }
        // Odd layouts (e.g. Info.plist at the bundle's root) are left to Bundle.
        return Bundle(url: real)?.infoDictionary.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func read(appAt url: URL) -> InstalledApp? {
        let path = url.path
        // Not an app without an Info.plist (e.g. a half-copied bundle or a stray folder).
        guard let info = infoDictionary(ofBundleAt: url) else { return nil }
        let bundleID = info["CFBundleIdentifier"] as? String
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let category = info["LSApplicationCategoryType"] as? String
        return InstalledApp(bundleID: bundleID, path: path, name: name, category: category)
    }
}
