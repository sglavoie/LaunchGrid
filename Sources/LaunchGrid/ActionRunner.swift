import AppKit
import LaunchGridCore

/// Runs actions: opens a link, a file (optionally with a chosen app) or an Apple Shortcut, and
/// runs shell commands (the downloadable build only) and scripts from the Application Scripts
/// folder (both builds), in the background or in a terminal.
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
        /// The Mac App Store build runs in the App Sandbox, which can't run commands.
        static var commandsUnavailable: Failure {
            Failure(message: String(localized: "Commands run only in the version of LaunchGrid from its website. Use a script in the Application Scripts folder, or a Shortcut, instead."))
        }
        static var terminalUnavailable: Failure {
            Failure(message: String(localized: "This version of LaunchGrid can't open scripts in a terminal. Run it in the background instead."))
        }
        static var noCommand: Failure { Failure(message: String(localized: "No command is entered")) }
        static var noScript: Failure { Failure(message: String(localized: "No script is chosen")) }
        static func scriptNotFound(_ name: String) -> Failure {
            Failure(message: String(localized: "Script not found: \(name)"))
        }
        static func folderNotFound(_ path: String) -> Failure {
            Failure(message: String(localized: "The working folder “\(FileManager.default.displayName(atPath: path))” could not be found."))
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
        /// A command or a script, run in the background or in a terminal.
        case code(CodeJob)
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
    /// The Application Scripts folder user scripts are run from. Tests point it elsewhere.
    var scriptsDirectory: URL
    /// The terminal app commands in terminal mode open in; nil for Terminal.
    var terminalApp: @MainActor () -> URL? = { nil }

    init(system: System = .live, scriptsDirectory: URL = ActionRunner.applicationScriptsDirectory) {
        self.system = system
        self.scriptsDirectory = scriptsDirectory
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
        case .code(let job):
            switch job.mode {
            case .terminal:
                try await openInTerminal(job)
            case .background:
                let result = await runToEnd(job)
                if !result.succeeded { throw RunFailure(result: result) }
            }
            return nil
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
        case .shell(let command, let runMode, let workingDirectory, let timeoutSeconds):
            #if APP_STORE
            throw Failure.commandsUnavailable
            #else
            guard commandsAvailable else { throw Failure.commandsUnavailable }
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.noCommand }
            return .code(CodeJob(program: .shell(substitutingQuoted(command, argument: argument)), argument: argument,
                                 workingDirectory: workingDirectory.flatMap { $0.isEmpty ? nil : $0 },
                                 timeout: CodeJob.timeout(timeoutSeconds), mode: runMode))
            #endif
        case .userScript(let fileName, let arguments, let runMode):
            guard !fileName.isEmpty else { throw Failure.noScript }
            if Sandbox.isActive && runMode == .terminal { throw Failure.terminalUnavailable }
            let given = arguments.map { $0.replacingOccurrences(of: ActionKind.argumentPlaceholder, with: argument ?? "") }
            return .code(CodeJob(program: .script(fileName: fileName, arguments: given), argument: argument,
                                 workingDirectory: nil, timeout: CodeJob.timeout(nil), mode: runMode))
        }
    }

    /// Whether shell commands can run: not in the Mac App Store build, nor in any sandboxed one.
    nonisolated static var commandsAvailable: Bool {
        #if APP_STORE
        false
        #else
        !Sandbox.isActive
        #endif
    }

    /// `command` with each `{query}` replaced by the argument as one single-quoted shell word,
    /// so nothing in it (quotes, `;`, `$(…)`, newlines) is read as shell syntax.
    nonisolated static func substitutingQuoted(_ command: String, argument: String?) -> String {
        command.replacingOccurrences(of: ActionKind.argumentPlaceholder, with: shellQuoted(argument ?? ""))
    }

    /// `text` as a single-quoted shell word: `it's` becomes `'it'\''s'`.
    nonisolated static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

// MARK: - Commands and scripts

/// A command or user script to run, worked out from an action and the argument typed after
/// its keyword.
struct CodeJob: Equatable, Sendable {
    enum Program: Equatable, Sendable {
        /// Run with `/bin/zsh -l -c`, the argument already quoted in.
        case shell(String)
        /// A file in the Application Scripts folder, with its arguments.
        case script(fileName: String, arguments: [String])
    }

    static let defaultTimeout = 60
    static let maximumTimeout = 3600

    var program: Program
    /// The argument as typed, for `LAUNCHGRID_QUERY`.
    var argument: String?
    var workingDirectory: String?
    /// Seconds a background run may take before it is stopped.
    var timeout: Int
    var mode: RunMode

    /// The timeout an action asks for, within 1 s and an hour; 60 s when it sets none.
    static func timeout(_ seconds: Int?) -> Int {
        min(max(seconds ?? defaultTimeout, 1), maximumTimeout)
    }
}

/// How a command or script run ended, with the end of what it printed. Kept in `AppState`
/// only, not in the layout.
struct RunResult: Equatable, Sendable {
    enum Ending: Equatable, Sendable {
        case exited(Int32)
        /// Killed by a signal it didn't handle (its number).
        case signalled(Int32)
        /// Ran over its timeout and was stopped.
        case timedOut
        /// Stopped from the menu, or as LaunchGrid quit.
        case stopped
        /// Failed without an exit status to tell (a script the sandboxed build ran), or never
        /// started (the message says why).
        case failed(String?)
    }

    /// How much of each output is kept.
    static let tailLimit = 4096

    var ending: Ending
    var endedAt: Date
    var output: String
    var errorOutput: String

    var succeeded: Bool { ending == .exited(0) }
    var exitStatus: Int32? { if case .exited(let s) = ending { s } else { nil } }

    /// What went wrong, in a few words, with the first line of its error output.
    var summary: String {
        let reason = switch ending {
        case .exited(let s): String(localized: "exit status \(Int(s))")
        case .signalled(let n): String(localized: "ended by signal \(Int(n))")
        case .timedOut: String(localized: "timed out")
        case .stopped: String(localized: "stopped")
        case .failed(let message): message ?? String(localized: "failed")
        }
        guard let line = firstErrorLine else { return reason }
        return "\(reason): \(line)"
    }

    var firstErrorLine: String? {
        errorOutput.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

/// A background run that failed, for `perform` (the editor's Test) to throw.
struct RunFailure: LocalizedError {
    var result: RunResult
    var errorDescription: String? { result.summary }
}

/// The last `RunResult.tailLimit` bytes written to a pipe.
private struct OutputTail {
    private(set) var data = Data()

    mutating func append(_ more: Data) {
        data.append(more)
        if data.count > RunResult.tailLimit { data = Data(data.suffix(RunResult.tailLimit)) }
    }

    /// As text, starting at a whole character when the cut fell inside one.
    var text: String {
        let start = data.firstIndex { $0 & 0xC0 != 0x80 } ?? data.endIndex
        return String(decoding: data[start...], as: UTF8.self)
    }
}

/// One command or script running in the background. `stop` ends it (SIGTERM, then SIGKILL
/// 5 s later); it ends by itself at its timeout the same way. `onEnd` is called once, on the
/// main actor.
final class CodeRun: @unchecked Sendable {
    let id = UUID()
    let startedAt = Date()
    /// False in the sandboxed build, which can't signal the scripts it runs.
    let canStop: Bool

    private let lock = NSLock()
    private var out = OutputTail()
    private var err = OutputTail()
    private var openPipes = 2
    private var exit: RunResult.Ending?
    private var stopReason: RunResult.Ending?
    private var finished = false
    private var onEnd: (@MainActor @Sendable (RunResult) -> Void)?
    /// What to signal: the process and everything it started.
    private var rootPID: pid_t = 0
    /// The process, kept until the run ends (its termination handler holds the run).
    fileprivate var process: Process?
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    fileprivate init(canStop: Bool, onEnd: @escaping @MainActor @Sendable (RunResult) -> Void) {
        self.canStop = canStop
        self.onEnd = onEnd
    }

    var outputWriter: FileHandle { outPipe.fileHandleForWriting }
    var errorWriter: FileHandle { errPipe.fileHandleForWriting }

    /// Starts collecting output; call before the process starts.
    fileprivate func readOutput() {
        for (pipe, isError) in [(outPipe, false), (errPipe, true)] {
            // Holds the run until its output ends; `finish` lets go.
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self.lock.withLock { self.openPipes -= 1 }
                    self.finishIfDone()
                } else {
                    self.lock.withLock { if isError { self.err.append(data) } else { self.out.append(data) } }
                }
            }
        }
    }

    fileprivate func started(pid: pid_t, timeout: Int) {
        lock.withLock { rootPID = pid }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) { [weak self] in
            self?.end(as: .timedOut)
        }
    }

    /// The process ended: what's still in the pipes gets a moment to arrive (a child left
    /// running in the background can keep them open), then the run ends.
    fileprivate func exited(_ ending: RunResult.Ending) {
        lock.withLock { exit = ending }
        finishIfDone()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.finish() }
    }

    /// Ends the run from the menu. Nothing happens when it can't be stopped or already ended.
    func stop() { end(as: .stopped) }

    private func end(as reason: RunResult.Ending) {
        let pid: pid_t? = lock.withLock {
            guard canStop, !finished, exit == nil, stopReason == nil, rootPID > 0 else { return nil }
            stopReason = reason
            return rootPID
        }
        guard let pid else { return }
        #if !APP_STORE
        // Everything it started too: a command's own processes stay in LaunchGrid's process
        // group, so the group can't be signalled instead.
        let tree = ProcessTree.withDescendants(of: pid)
        for p in tree { kill(p, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            for p in Set(tree + ProcessTree.withDescendants(of: pid)) where kill(p, 0) == 0 { kill(p, SIGKILL) }
        }
        #endif
    }

    private func finishIfDone() {
        let done = lock.withLock { exit != nil && openPipes == 0 }
        if done { finish() }
    }

    private func finish() {
        let ended: (RunResult, @MainActor @Sendable (RunResult) -> Void)? = lock.withLock {
            guard !finished, let exit, let onEnd else { return nil }
            finished = true
            self.onEnd = nil
            let result = RunResult(ending: stopReason ?? exit, endedAt: Date(), output: out.text, errorOutput: err.text)
            return (result, onEnd)
        }
        guard let (result, onEnd) = ended else { return }
        for pipe in [outPipe, errPipe] { pipe.fileHandleForReading.readabilityHandler = nil }
        lock.withLock {
            process?.terminationHandler = nil
            process = nil
        }
        Task { @MainActor in onEnd(result) }
    }

    /// For a run that never started: it ends at once with `message`.
    fileprivate func failedToStart(_ message: String) {
        for pipe in [outPipe, errPipe] { pipe.fileHandleForReading.readabilityHandler = nil }
        lock.withLock { openPipes = 0 }
        exited(.failed(message))
    }
}

#if !APP_STORE
/// A process and those it started, from the kernel's list of child processes.
enum ProcessTree {
    static func withDescendants(of pid: pid_t) -> [pid_t] {
        var all = [pid]
        var queue = [pid]
        while let next = queue.popLast(), all.count < 4096 {
            var children = [pid_t](repeating: 0, count: 256)
            let n = proc_listchildpids(next, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            guard n > 0 else { continue }
            let found = children.prefix(Int(n)).filter { $0 > 0 }
            all += found
            queue += found
        }
        return all
    }
}
#endif

extension ActionRunner {
    /// `~/Library/Application Scripts/com.sglavoie.launchgrid`, where macOS lets even the
    /// sandboxed build run what the person put there.
    nonisolated static var applicationScriptsDirectory: URL {
        if let url = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: false) {
            return url
        }
        // A test binary has no bundle identifier to name the folder by.
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Scripts/com.sglavoie.launchgrid", isDirectory: true)
    }

    /// Whether `fileName` names a script: an AppleScript, or a file that can be run.
    nonisolated static func isScript(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return isAppleScript(url) || fm.isExecutableFile(atPath: url.path)
    }

    nonisolated static func isAppleScript(_ url: URL) -> Bool {
        ["scpt", "applescript"].contains(url.pathExtension.lowercased())
    }

    /// The scripts in the Application Scripts folder, by name.
    nonisolated static func scripts(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && isScript(directory.appendingPathComponent($0)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The script `fileName` names, which must be directly in the folder.
    func scriptURL(_ fileName: String) throws -> URL {
        guard !fileName.contains("/"), fileName != "..", fileName != "." else { throw Failure.scriptNotFound(fileName) }
        let url = scriptsDirectory.appendingPathComponent(fileName)
        guard Self.isScript(url) else { throw Failure.scriptNotFound(fileName) }
        return url
    }

    /// Starts a background run. Checks that fail at once (a missing script or working folder)
    /// throw; anything later ends the run with `.failed` and comes through `onEnd`.
    func start(_ job: CodeJob, onEnd: @escaping @MainActor @Sendable (RunResult) -> Void) throws -> CodeRun {
        switch job.program {
        case .shell(let command):
            #if APP_STORE
            _ = command
            throw Failure.commandsUnavailable
            #else
            guard Self.commandsAvailable else { throw Failure.commandsUnavailable }
            return try startProcess(URL(fileURLWithPath: "/bin/zsh"), ["-l", "-c", command], job: job, onEnd: onEnd)
            #endif
        case .script(let fileName, let arguments):
            let url = try scriptURL(fileName)
            #if APP_STORE
            return startUserScriptTask(url, arguments, onEnd: onEnd)
            #else
            // Only macOS may run what's in the folder for a sandboxed app.
            if Sandbox.isActive { return startUserScriptTask(url, arguments, onEnd: onEnd) }
            // Run here rather than through NSUserUnixTask, whose scripts run in a system
            // service LaunchGrid can't signal: this way Stop and the timeout work.
            if Self.isAppleScript(url) {
                return try startProcess(URL(fileURLWithPath: "/usr/bin/osascript"), [url.path] + arguments, job: job, onEnd: onEnd)
            }
            return try startProcess(url, arguments, job: job, onEnd: onEnd)
            #endif
        }
    }

    /// Runs `job` in the background and waits for it to end.
    func runToEnd(_ job: CodeJob) async -> RunResult {
        await withCheckedContinuation { (c: CheckedContinuation<RunResult, Never>) in
            do {
                _ = try start(job) { c.resume(returning: $0) }
            } catch {
                c.resume(returning: RunResult(ending: .failed(error.localizedDescription), endedAt: Date(), output: "", errorOutput: ""))
            }
        }
    }

    #if !APP_STORE
    private func startProcess(_ executable: URL, _ arguments: [String], job: CodeJob,
                              onEnd: @escaping @MainActor @Sendable (RunResult) -> Void) throws -> CodeRun {
        let directory = job.workingDirectory.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.folderNotFound(directory)
        }
        let run = CodeRun(canStop: true, onEnd: onEnd)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = Self.environment(argument: job.argument)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = run.outputWriter
        process.standardError = run.errorWriter
        run.process = process
        process.terminationHandler = { p in
            run.exited(p.terminationReason == .uncaughtSignal ? .signalled(p.terminationStatus) : .exited(p.terminationStatus))
        }
        run.readOutput()
        do {
            try process.run()
        } catch {
            run.failedToStart(error.localizedDescription)
            return run
        }
        // Only the child holds the write ends now, so the pipes close when it (and anything
        // it left running) is done.
        try? run.outputWriter.close()
        try? run.errorWriter.close()
        run.started(pid: process.processIdentifier, timeout: job.timeout)
        return run
    }

    /// LaunchGrid's environment (the login shell adds the person's own) without its own
    /// variables, plus the argument.
    nonisolated static func environment(argument: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("LAUNCHGRID_") }
        env["LAUNCHGRID_QUERY"] = argument ?? ""
        return env
    }
    #endif

    /// The sandboxed build: macOS runs the script for LaunchGrid, which can neither give it an
    /// environment nor stop it. The timeout stops waiting for it.
    private func startUserScriptTask(_ url: URL, _ arguments: [String],
                                     onEnd: @escaping @MainActor @Sendable (RunResult) -> Void) -> CodeRun {
        let run = CodeRun(canStop: false, onEnd: onEnd)
        run.readOutput()
        let writers = [run.outputWriter, run.errorWriter]
        // The task holds its own copies of the write ends; once it's done, LaunchGrid's go too,
        // so the pipes reach their end.
        let closeWriters: @Sendable () -> Void = { for w in writers { try? w.close() } }
        do {
            if Self.isAppleScript(url) {
                let task = try NSUserAppleScriptTask(url: url)
                task.execute(withAppleEvent: Self.runEvent(arguments)) { result, error in
                    if let text = result?.stringValue { try? run.outputWriter.write(contentsOf: Data((text + "\n").utf8)) }
                    if let error { try? run.errorWriter.write(contentsOf: Data((Self.scriptError(error) + "\n").utf8)) }
                    closeWriters()
                    run.exited(error == nil ? .exited(0) : .failed(nil))
                }
            } else {
                let task = try NSUserUnixTask(url: url)
                task.standardOutput = run.outputWriter
                task.standardError = run.errorWriter
                task.execute(withArguments: arguments) { error in
                    closeWriters()
                    // It reports a failure without the script's exit status.
                    run.exited(error == nil ? .exited(0) : .failed(nil))
                }
            }
        } catch {
            closeWriters()
            run.failedToStart(error.localizedDescription)
        }
        return run
    }

    /// The Apple event that calls an AppleScript's `on run argv` with `arguments`.
    private nonisolated static func runEvent(_ arguments: [String]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        for (i, a) in arguments.enumerated() { list.insert(NSAppleEventDescriptor(string: a), at: i + 1) }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    private nonisolated static func scriptError(_ error: Error) -> String {
        let info = (error as NSError).userInfo
        return (info[NSAppleScript.errorMessage] as? String) ?? (info[NSLocalizedFailureReasonErrorKey] as? String)
            ?? error.localizedDescription
    }

    // MARK: Terminal

    /// Writes the job to a `.command` file only the person can read, which deletes itself as
    /// it starts, and opens it in the terminal app chosen in Settings.
    func openInTerminal(_ job: CodeJob) async throws {
        #if APP_STORE
        throw Failure.terminalUnavailable
        #else
        guard !Sandbox.isActive else { throw Failure.terminalUnavailable }
        let command: String
        switch job.program {
        case .shell(let c): command = c
        case .script(let fileName, let arguments):
            let url = try scriptURL(fileName)
            let words = (Self.isAppleScript(url) ? ["/usr/bin/osascript", url.path] : [url.path]) + arguments
            command = words.map(Self.shellQuoted).joined(separator: " ")
        }
        let directory = job.workingDirectory.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
        let file = try Self.writeCommandFile(command, directory: directory, argument: job.argument)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let terminal = terminalApp() ?? Self.defaultTerminal
        do {
            _ = try await system.openWith(file, terminal, config)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        // In case the terminal never ran it (it only opened the file, say).
        Task.detached {
            try? await Task.sleep(for: .seconds(60))
            try? FileManager.default.removeItem(at: file)
        }
        #endif
    }

    nonisolated static let defaultTerminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    #if !APP_STORE
    nonisolated static func commandFileContents(_ command: String, directory: String, argument: String?) -> String {
        """
        #!/bin/zsh -l
        rm -f -- "$0"
        cd -- \(shellQuoted(directory)) || exit 1
        export LAUNCHGRID_QUERY=\(shellQuoted(argument ?? ""))
        \(command)

        """
    }

    nonisolated static func writeCommandFile(_ command: String, directory: String, argument: String?) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchGrid Commands", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("\(UUID().uuidString).command")
        let data = Data(commandFileContents(command, directory: directory, argument: argument).utf8)
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o700]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }
    #endif
}

/// An action's runs in the background: usually one, more when another copy was asked for.
struct RunHandle {
    var runs: [CodeRun] = []

    var canStop: Bool { runs.contains(where: \.canStop) }
    var startedAt: Date? { runs.map(\.startedAt).min() }

    func stop() { for run in runs { run.stop() } }
}
