import AppKit
import LaunchGridCore

/// Runs actions: opens a link, a file (optionally with a chosen app) or an Apple Shortcut.
/// Shell commands and user scripts come in a later step.
///
/// Running happens in two parts. `plan` works out what to open from the action and the
/// argument typed after its keyword, and fails at once on a bad link, while the grid is still
/// up to say so. `perform` then hands it to the system.
@MainActor
final class ActionRunner {
    struct Failure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }

        static var invalidLink: Failure { Failure(message: String(localized: "Not a valid link")) }
        static var notAvailable: Failure {
            Failure(message: String(localized: "Running commands and scripts is not available yet"))
        }
        static var noShortcut: Failure { Failure(message: String(localized: "No Shortcut is chosen")) }
        static var noFile: Failure { Failure(message: String(localized: "No file is chosen")) }
        static func fileNotFound(_ path: String) -> Failure {
            Failure(message: String(localized: "“\(FileManager.default.displayName(atPath: path))” could not be found."))
        }
        static func noAccess(_ path: String) -> Failure {
            Failure(message: String(localized: "LaunchGrid has no access to “\(FileManager.default.displayName(atPath: path))”. Choose it again."))
        }
        static func appNotFound(_ path: String) -> Failure {
            Failure(message: String(localized: "The app chosen to open it, “\(FileManager.default.displayName(atPath: path))”, is no longer on this Mac."))
        }
    }

    /// What running an action opens.
    enum Plan: Equatable {
        /// A link, a deep link or a `shortcuts://` URL.
        case open(URL)
        case openFile(path: String, appPath: String?)
    }

    /// The system calls `perform` makes. Tests swap in their own.
    struct System {
        var open: @MainActor (URL, NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication?
        var openWith: @MainActor (URL, URL, NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication?
        /// The URL to open a path through: in the sandbox, its bookmark's, whose access is in use.
        var access: @MainActor (String) -> URL
        /// Whether LaunchGrid lacks sandbox access to a path, rather than the path being gone.
        var lacksAccess: @MainActor (String) -> Bool
        var exists: @Sendable (String) -> Bool

        static var live: System { System(
            open: { url, config in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<SendableApp, Error>) in
                    NSWorkspace.shared.open(url, configuration: config) { app, error in Self.resume(c, app, error) }
                }.app
            },
            openWith: { url, app, config in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<SendableApp, Error>) in
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { app, error in Self.resume(c, app, error) }
                }.app
            },
            access: { FileAccess.url(for: $0) },
            lacksAccess: { Sandbox.isActive && !FileAccess.isGranted($0) },
            exists: { FileManager.default.fileExists(atPath: $0) }
        ) }

        /// Through the completion handler, whose app can be nil (a link handed to an app
        /// already running), which the async form of these calls doesn't allow for.
        private nonisolated static func resume(_ c: CheckedContinuation<SendableApp, Error>, _ app: NSRunningApplication?, _ error: Error?) {
            if let error { c.resume(throwing: error) } else { c.resume(returning: SendableApp(app: app)) }
        }
    }

    fileprivate struct SendableApp: @unchecked Sendable { var app: NSRunningApplication? }

    var system: System

    init(system: System = .live) {
        self.system = system
    }

    /// Runs `action`, with `argument` in place of `{query}`.
    /// - Parameter activates: false leaves what opens behind the grid, which stays up.
    @discardableResult
    func run(_ action: Action, argument: String?, activates: Bool = true) async throws -> NSRunningApplication? {
        try await perform(Self.plan(action.kind, argument: argument), activates: activates)
    }

    /// Opens what `plan` names; returns the app that opened it, when the system says.
    @discardableResult
    func perform(_ plan: Plan, activates: Bool = true) async throws -> NSRunningApplication? {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activates
        switch plan {
        case .open(let url):
            return try await system.open(url, config)
        case .openFile(let path, let appPath):
            let url = system.access(path)
            let appURL = appPath.map(system.access)
            // Looked at off the main thread, so a stalled volume doesn't hang the app.
            let exists = system.exists
            let (fileThere, appThere) = await Disk.run { (exists(path), appPath.map(exists) ?? true) }
            if !fileThere { throw system.lacksAccess(path) ? Failure.noAccess(path) : Failure.fileNotFound(path) }
            if let appPath, !appThere { throw system.lacksAccess(appPath) ? Failure.noAccess(appPath) : Failure.appNotFound(appPath) }
            do {
                guard let appURL else { return try await system.open(url, config) }
                return try await system.openWith(url, appURL, config)
            } catch {
                // The sandbox can let LaunchGrid see a file it may not hand on, and the system
                // then only says the app "could not be launched": say what's missing instead.
                if system.lacksAccess(path), !Launcher.isUserCancel(error) { throw Failure.noAccess(path) }
                throw error
            }
        }
    }

    /// What running `kind` with `argument` opens. Throws for a template that isn't a link once
    /// the argument is in, and for the kinds that can't run yet.
    nonisolated static func plan(_ kind: ActionKind, argument: String?) throws -> Plan {
        switch kind {
        case .openURL(let template):
            let text = template.replacingOccurrences(of: ActionKind.argumentPlaceholder, with: encoded(argument ?? ""))
            return .open(try link(text))
        case .openFile(let path, let appPath):
            guard !path.isEmpty else { throw Failure.noFile }
            return .openFile(path: path, appPath: appPath.flatMap { $0.isEmpty ? nil : $0 })
        case .shortcut(let name, let input):
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.noShortcut }
            var text = "shortcuts://run-shortcut?name=\(encoded(name))"
            // The argument stands in for {query} in the input; with no input set, it is the input.
            let given = input.map { $0.replacingOccurrences(of: ActionKind.argumentPlaceholder, with: argument ?? "") } ?? argument
            if let given, !given.isEmpty { text += "&input=text&text=\(encoded(given))" }
            return .open(try link(text))
        case .shell, .userScript:
            throw Failure.notAvailable
        }
    }

    /// Only unreserved characters stay as they are, so an argument can't end the query value
    /// it goes in (`&`, `#`, `+`) or reach into the path.
    nonisolated static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private nonisolated static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A URL with a scheme, as typed: nothing is encoded for the person, so a space or another
    /// character a link can't hold means it isn't one.
    private nonisolated static func link(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed, encodingInvalidCharacters: false),
              let scheme = url.scheme, !scheme.isEmpty else { throw Failure.invalidLink }
        return url
    }
}
