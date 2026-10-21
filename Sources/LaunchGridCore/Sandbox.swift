import Foundation

/// The Mac App Store build runs in the App Sandbox; the downloadable one doesn't.
public enum Sandbox {
    /// The container's ID (the bundle ID) when sandboxed.
    public static let containerID = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]

    public static var isActive: Bool { containerID != nil }

    /// The user's real home folder. Inside the sandbox, `homeDirectoryForCurrentUser`
    /// is the app's container instead.
    public static let realHome: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
}
