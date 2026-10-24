import Foundation
import UniformTypeIdentifiers

/// Finds application bundles on disk.
public enum AppScanner {
    public static var defaultRoots: [URL] {
        // ~/Applications is readable in the sandbox through a temporary-exception entitlement.
        let home = Sandbox.realHome
        return [
            "/Applications",
            "/System/Applications",
            home.appendingPathComponent("Applications").path,
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Scans the roots (recursing into plain folders up to `maxDepth`, never into bundles)
    /// and returns one entry per app bundle on disk, de-duplicated by resolved path with
    /// earlier roots winning. Copies sharing a bundle ID (Xcode and Xcode-beta) are all kept.
    /// Apps flagged `LSDefaultSystemHidden` (e.g. the two bundles both named Siri) are left
    /// out, as macOS leaves them out of its own app list; they can still be added by hand.
    public static func scan(roots: [URL], maxDepth: Int = 3) -> [InstalledApp] {
        scanReporting(roots: roots, maxDepth: maxDepth).apps
    }

    /// What a scan found, and the folders it couldn't list.
    public struct ScanResult: Sendable {
        public var apps: [InstalledApp]
        /// Folders (roots included) that couldn't be listed: missing, denied by privacy
        /// controls, a stalled network volume or a lapsed sandbox bookmark. Their apps went
        /// unseen, which says nothing about whether they are still there.
        public var unlisted: [String]
        /// The real paths of the apps found through a symlink, each mapped to the path the scan
        /// lists it at: /System/Cryptexes/…/Safari.app to /Applications/Safari.app. An open
        /// panel gives the first, so this tells it is an app already found.
        public var aliases: [String: String]

        public init(apps: [InstalledApp], unlisted: [String] = [], aliases: [String: String] = [:]) {
            self.apps = apps
            self.unlisted = unlisted
            self.aliases = aliases
        }
    }

    /// `scan(roots:maxDepth:)`, also reporting the folders it couldn't list.
    public static func scanReporting(roots: [URL], maxDepth: Int = 3) -> ScanResult {
        let fm = FileManager.default
        // Shallowest depth each directory was walked at: a root nested in another root's
        // depth limit is walked again from its own, shallower, depth.
        var visited: [String: Int] = [:]
        var results: [InstalledApp] = []
        var paths = Set<String>()
        var unlisted: [String] = []
        var aliases: [String: String] = [:]

        /// `realPath` is the bundle's symlink-free path, its identity for de-duplication.
        func consider(_ url: URL, realPath: String) {
            guard paths.insert(realPath).inserted, let info = infoDictionary(ofBundleAt: url),
                  info["LSDefaultSystemHidden"] as? Bool != true else { return }
            results.append(read(appAt: url, info: info))
            if realPath != url.path { aliases[realPath] = url.path }
        }

        func walk(_ dir: URL, depth: Int) {
            let real = dir.resolvingSymlinksInPath().path
            if let seen = visited[real], seen <= depth { return } // symlink cycle or repeat
            visited[real] = depth
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(scanKeys)) else {
                unlisted.append(dir.path)
                return
            }
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
        return ScanResult(apps: results, unlisted: unlisted, aliases: aliases)
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
        // Not an app without an Info.plist (e.g. a half-copied bundle or a stray folder).
        guard let info = infoDictionary(ofBundleAt: url) else { return nil }
        return read(appAt: url, info: info)
    }

    static func read(appAt url: URL, info: [String: Any]) -> InstalledApp {
        let path = url.path
        let bundleID = info["CFBundleIdentifier"] as? String
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        let category = info["LSApplicationCategoryType"] as? String
        return InstalledApp(bundleID: bundleID, path: path, name: name, category: category)
    }
}
