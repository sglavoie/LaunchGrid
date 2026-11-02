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
        // Where the shell would read what's typed after a keyword as code, or {query} can't be
        // swapped for a reference to it.
        static var placeholderInBackticks: Failure {
            Failure(message: String(localized: "{query} can't go inside backticks. Use $(…) instead."))
        }
        static var placeholderInParameter: Failure {
            Failure(message: String(localized: "{query} can't go inside ${…}. Use $LAUNCHGRID_QUERY there instead."))
        }
        static var placeholderInArithmetic: Failure {
            Failure(message: String(localized: "{query} can't go inside $((…)), ((…)), $[…] or a subscript like a[…], even in quotes or a $(…), where the shell would run what's typed as code. Use it as plain text outside them instead."))
        }
        static var placeholderInNumericTest: Failure {
            Failure(message: String(localized: "{query} can't go inside a [[ … ]] test that compares numbers (-eq, -lt and the like) or checks -v or -t, where the shell would run what's typed as code. Compare it as text with == instead."))
        }
        static var placeholderInBuiltin: Failure {
            Failure(message: String(localized: "{query} can't be an argument of let, integer, float, repeat, shift, exit, return, read, unset or vared, a variable name for typeset, declare, local or export, or an argument of printf %d (and other number formats), print -v or printf -v, or the value of a variable that holds a number (typeset -i n and then n={query}, or zsh's own, like SECONDS), where zsh would run what's typed as code. Use it as plain text instead."))
        }
        static var placeholderInCode: Failure {
            Failure(message: String(localized: "{query} can't be part of code another program runs (after -c, -e or -pe, in a sed or awk program, with eval, trap, watch or ssh, or in input piped to a shell or osascript), where what's typed would run as code. Pass it as an argument of its own, or read $LAUNCHGRID_QUERY in that code instead."))
        }
        static var placeholderInGlobQualifier: Failure {
            Failure(message: String(localized: "{query} can't go inside parentheses that end a word, like the glob qualifier in *(e:'…':), where zsh would run what's typed as code. Use $LAUNCHGRID_QUERY there instead."))
        }
        static var placeholderAfterHereDocument: Failure {
            Failure(message: String(localized: "{query} can't go in or after a here-document (<<). Use $LAUNCHGRID_QUERY there instead."))
        }
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
    /// How the sandboxed build hands a script to macOS. Tests swap in their own.
    var scriptTasks: UserScriptTasks = .live

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
    /// - Parameter onStart: given a background run as it starts, so whoever asked can stop it
    ///   (LaunchGrid quitting while the editor's Test waits for it).
    func perform(_ plan: Plan, activates: Bool = true,
                 onStart: (@MainActor (CodeRun) -> Void)? = nil) async throws -> NSRunningApplication? {
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
                let result = await runToEnd(job, onStart: onStart)
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
            return .code(CodeJob(program: .shell(try substitutingArgument(in: command)), argument: argument,
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

    /// `command` with each `{query}` replaced by a reference to `$LAUNCHGRID_QUERY`, which both
    /// background and terminal runs set to the argument. The argument itself never becomes part
    /// of the command's text, so nothing in it (quotes, `;`, `$(…)`, newlines) is read as shell
    /// syntax: a parameter's value isn't parsed again. The reference fits where `{query}` is:
    /// unquoted, inside '…', "…" or $'…' it stays one piece of text, as typed; in a comment it is
    /// left alone. Throws for places where the shell would read the value as code or the
    /// reference can't fit: backticks, `${…}`, arithmetic (`$((…))`, `((…))`, `$[…]`, array
    /// subscripts), `[[ … ]]` tests that compare numbers, and here-documents. Each of these is
    /// refused however deeply the placeholder sits inside it, quoted or in a `$(…)`: zsh still
    /// evaluates a quoted value in arithmetic, and the output of a `$(…)` there too.
    nonisolated static func substitutingArgument(in command: String) throws -> String {
        // The shell drops a backslash-newline before reading tokens, except inside '…', $'…' and
        // comments, so `-e\⏎q` is `-eq` and `$(\⏎(` is `$((`. Join them the same way first, until
        // none is left where the shell would join it, so every check sees the shell's tokens.
        var joined = command
        while true {
            let (text, changed) = try scan(joined, joiningOnly: true)
            if !changed { break }
            joined = text
        }
        return try scan(joined, joiningOnly: false).text
    }

    /// One pass over `command`. With `joiningOnly`, only joins backslash-newlines where the shell
    /// does and returns the joined text; otherwise substitutes `{query}` or throws.
    private nonisolated static func scan(_ command: String, joiningOnly: Bool) throws -> (text: String, changed: Bool) {
        enum Context: Equatable {
            case top, substitution(depth: Int), backtick, parameter(depth: Int), arithmetic(depth: Int)
            case single, double, ansiSingle, comment
            /// `$[…]` or a subscript (`a[…]`, `$a[…]`), which zsh evaluates as arithmetic.
            case subscripted(depth: Int)
            /// `[[ … ]]`: whether it compares numbers, and whether `{query}` is in it.
            case conditional(numeric: Bool, placeholder: Bool)
            /// Parentheses opened inside a word (`*(e:'…':)`, `*(+f)`), a glob qualifier, which
            /// zsh can evaluate as code.
            case qualifier(depth: Int)

            /// Where commands' words are read: at the top or in a `$(…)`.
            var readsWords: Bool {
                switch self {
                case .top, .substitution: true
                default: false
                }
            }

            /// Where a `#` starting a word starts a comment.
            var startsCommands: Bool {
                switch self {
                case .top, .substitution, .conditional: true
                default: false
                }
            }
        }
        let placeholder = Array(ActionKind.argumentPlaceholder.unicodeScalars)
        var text = Array(command.unicodeScalars)
        var out = String.UnicodeScalarView()
        var stack: [Context] = [.top]
        var changed = false
        var afterHereDocument = false
        // The words of the command being read, outside quotes: whether `{query}` is part of code
        // another program runs (`sh -c 'echo {query}'`, `osascript -e '… "{query}"'`).
        var words = Words()
        // The words of the commands around each `$(…)` being read, outermost first.
        var outerWords: [Words] = []
        // Anywhere in the command, so the order of a declaration and an assignment doesn't matter.
        var numericNames = ActionRunner.numericVariables
        var assignedNames: Set<String> = []
        // Whether `{query}` came anywhere before, for a command reading a pipe: `echo {query} | sh`,
        // and `{ echo {query}; } | sh` too.
        var placeholderSoFar = false
        var i = 0
        func at(_ offset: Int) -> Unicode.Scalar? { i + offset < text.count ? text[i + offset] : nil }
        func copy(_ n: Int) {
            out.append(contentsOf: text[i..<min(i + n, text.count)])
            i += n
        }
        /// With `afterBrace`, a `{` before counts too: `{((…))}` and `{[[ … ]]}` are commands.
        func startsWord(afterBrace: Bool = false) -> Bool {
            guard i > 0 else { return true }
            let previous = text[i - 1]
            return ActionRunner.isBlank(previous) || ";&|()<>".unicodeScalars.contains(previous)
                || (afterBrace && previous == "{")
        }
        func isNameCharacter(_ c: Unicode.Scalar) -> Bool {
            c == "_" || c.properties.isAlphabetic || c.properties.numericType != nil
        }
        /// Whether a `[` here follows `$name`, a subscript wherever parameters expand, including
        /// after zsh's flags (`$#name`, `$+name`, `$=name`, `$~name`, `$^name`).
        /// Special parameters count too: `$#[…]`, `$*[…]`, `$?[…]` and the like.
        func afterParameterName() -> Bool {
            var j = i - 1
            while j >= 0, isNameCharacter(text[j]) { j -= 1 }
            if j == i - 1 {
                guard j >= 0, "@*#?-$!".unicodeScalars.contains(text[j]) else { return false }
                j -= 1
            }
            while j >= 0, "#+=~^".unicodeScalars.contains(text[j]) { j -= 1 }
            return j >= 0 && text[j] == "$"
        }
        /// Ends the word before `i`. A new command starts after `;`, `&`, `|`, `(`, `)` or a newline.
        func endWord(newCommand: Bool) throws {
            let word = String(String.UnicodeScalarView(text[min(words.start, i)..<i]))
            if !word.isEmpty {
                if words.redirecting {
                    // A file to read or write (`<<< {query}`, `> {query}`): data, not an argument,
                    // but what a program reading code from its input runs: `bash <<< "echo {query}"`,
                    // `sh < <(echo {query})`. A file named by `{query}` alone is like `sh {query}`.
                    if words.redirectingInput, words.hasPlaceholder, words.hereString || !ActionRunner.isAlone(word) {
                        words.stdinPlaceholder = true
                    }
                    words.redirecting = false
                    words.redirectingInput = false
                    words.hereString = false
                } else {
                    try words.add(word)
                    numericNames.formUnion(words.numericNames)
                    assignedNames.formUnion(words.assignedNames)
                    words.numericNames = []
                    words.assignedNames = []
                }
            }
            words.hasPlaceholder = false
            words.processPlaceholder = false
            words.start = i + 1
            if newCommand {
                try words.finish()
                // `|` and `|&`, not `||`; a pipe at the end of a line feeds the next one.
                let previous = i > 0 ? text[i - 1] : " "
                let piped = i < text.count && ((text[i] == "|" && at(1) != "|" && previous != "|")
                    || (text[i] == "&" && previous == "|" && (i < 2 || text[i - 2] != "|"))
                    || (text[i] == "\n" && words.command == nil && words.pipedPlaceholder))
                // Still in the same `$(…)`, whose output the word around it takes.
                let any = words.anyPlaceholder
                let process = words.isProcessSubstitution
                words = Words(start: i + 1)
                words.anyPlaceholder = any
                words.isProcessSubstitution = process
                words.pipedPlaceholder = piped && placeholderSoFar
            }
        }
        /// The innermost failure for a placeholder in a context that evaluates or can't hold it.
        func refusal() -> Failure? {
            for context in stack.reversed() {
                switch context {
                case .backtick: return .placeholderInBackticks
                case .parameter: return .placeholderInParameter
                case .arithmetic, .subscripted: return .placeholderInArithmetic
                case .qualifier: return .placeholderInGlobQualifier
                default: continue
                }
            }
            return nil
        }
        /// `$(`, `$((`, `${`, `$[` and backticks, which can start in any context that expands, and
        /// a subscript after `$name`.
        func openExpansion() -> Bool {
            switch (at(0), at(1), at(2)) {
            case ("[", _, _) where afterParameterName(): stack.append(.subscripted(depth: 0)); copy(1)
            case ("$", "[", _): stack.append(.subscripted(depth: 0)); copy(2)
            case ("$", "(", "("): stack.append(.arithmetic(depth: 0)); copy(3)
            case ("$", "(", _):
                stack.append(.substitution(depth: 0)); copy(2)
                outerWords.append(words)
                words = Words(start: i)
            case ("$", "{", _): stack.append(.parameter(depth: 0)); copy(2)
            case ("`", _, _): stack.append(.backtick); copy(1)
            default: return false
            }
            return true
        }
        /// Quotes, escapes, expansions and comments outside quotes.
        func unquoted(_ context: Context) {
            if openExpansion() { return }
            switch text[i] {
            case "\\": copy(2)
            case "'": stack.append(.single); copy(1)
            case "\"": stack.append(.double); copy(1)
            case "$" where at(1) == "'": stack.append(.ansiSingle); copy(2)
            case "#" where context.startsCommands && startsWord(): stack.append(.comment); copy(1)
            case "(" where at(1) == "(" && startsWord(afterBrace: true): stack.append(.arithmetic(depth: 0)); copy(2)
            // `a[…]` outside quotes: a subscript when assigning, otherwise a pattern, where
            // `{query}` isn't refused for being in brackets but is safer left out anyway.
            case "[" where i > 0 && isNameCharacter(text[i - 1]): stack.append(.subscripted(depth: 0)); copy(1)
            case "[" where context.startsCommands && startsWord(afterBrace: true) && at(1) == "[" && endsWord(after: 2):
                stack.append(.conditional(numeric: false, placeholder: false)); copy(2)
            default: copy(1)
            }
        }
        /// Whether a word ends `offset` characters on.
        func endsWord(after offset: Int) -> Bool {
            guard let next = at(offset) else { return true }
            return ActionRunner.isBlank(next) || ";&|()<>".unicodeScalars.contains(next)
        }
        /// Notes `{query}` in each `[[ … ]]` around it, refused at its end if it compares numbers.
        func markConditionals() {
            for index in stack.indices {
                if case .conditional(let numeric, _) = stack[index] {
                    stack[index] = .conditional(numeric: numeric, placeholder: true)
                }
            }
        }
        while i < text.count {
            let context = stack.last ?? .top
            if text[i] == "\\", at(1) == "\n", ![.single, .ansiSingle, .comment].contains(context) {
                text.removeSubrange(i...(i + 1))
                changed = true
                continue
            }
            if text[i] == placeholder[0], i + placeholder.count <= text.count,
               Array(text[i..<i + placeholder.count]) == placeholder {
                if context == .comment || joiningOnly { copy(placeholder.count); continue }
                if afterHereDocument { throw Failure.placeholderAfterHereDocument }
                if let failure = refusal() { throw failure }
                markConditionals()
                words.hasPlaceholder = true
                words.anyPlaceholder = true
                placeholderSoFar = true
                let reference: String
                switch context {
                case .comment, .backtick, .parameter, .arithmetic, .subscripted, .qualifier: throw Failure.placeholderInArithmetic // refused above
                case .top, .substitution, .conditional: reference = #""${LAUNCHGRID_QUERY}""#
                case .double: reference = "${LAUNCHGRID_QUERY}"
                case .single: reference = #"'"${LAUNCHGRID_QUERY}"'"#
                case .ansiSingle: reference = #"'"${LAUNCHGRID_QUERY}"$'"#
                }
                out.append(contentsOf: reference.unicodeScalars)
                i += placeholder.count
                continue
            }
            // `(` inside a word (`*(e:…:)`), not `f()`, `a=(…)` or `$(…)`: a glob qualifier.
            if text[i] == "(", context.readsWords, at(1) != ")", i > 0, !startsWord(afterBrace: true),
               text[i - 1] != "=", text[i - 1] != "$" {
                stack.append(.qualifier(depth: 0))
                copy(1)
                continue
            }
            // `<(…)`, `>(…)` and zsh's `=(…)`: commands whose output (or input) is a file the word
            // names. Read like `$(…)`, so the command around it carries on after.
            if context.readsWords, "<>=".unicodeScalars.contains(text[i]), at(1) == "(", startsWord() {
                stack.append(.substitution(depth: 0)); copy(2)
                outerWords.append(words)
                words = Words(start: i)
                words.isProcessSubstitution = true
                continue
            }
            if !joiningOnly, context.startsCommands {
                let c = text[i]
                let previous = i > 0 ? text[i - 1] : " "
                if c == "<" || c == ">" || (c == "&" && (previous == ">" || previous == "<" || at(1) == ">")) {
                    // A redirection (`2>&1` and `&>` too): the word after it is its file.
                    try endWord(newCommand: false)
                    if !words.redirecting { words.redirectingInput = c == "<" }
                    if c == "<", at(1) == "<", at(2) == "<" { words.hereString = true }
                    words.redirecting = true
                } else if c == "\n" || ";&|()".unicodeScalars.contains(c) {
                    try endWord(newCommand: true)
                } else if ActionRunner.isBlank(c) {
                    try endWord(newCommand: false)
                }
            }
            // `<<` but not `<<<`, outside quotes: a here-document, whose body the shell expands.
            // In arithmetic and subscripts, `<<` shifts.
            let shifts: Bool
            switch context {
            case .arithmetic, .subscripted: shifts = true
            default: shifts = false
            }
            if !shifts, [.single, .double, .ansiSingle, .comment].contains(context) == false,
               text[i] == "<", at(1) == "<", at(2) != "<", i == 0 || text[i - 1] != "<" {
                afterHereDocument = true
                copy(2)
                continue
            }
            switch context {
            case .top:
                unquoted(context)
            case .substitution(let depth):
                switch text[i] {
                case "(" where at(1) != "(" || !startsWord(afterBrace: true): stack[stack.count - 1] = .substitution(depth: depth + 1); copy(1)
                case ")" where depth == 0:
                    stack.removeLast(); copy(1)
                    // Its output is part of the word it's in: `let x=$(echo {query})` evaluates it.
                    let inner = words
                    words = outerWords.popLast() ?? Words(start: i)
                    if inner.anyPlaceholder { words.hasPlaceholder = true; words.anyPlaceholder = true }
                    if inner.anyPlaceholder && inner.isProcessSubstitution { words.processPlaceholder = true }
                case ")": stack[stack.count - 1] = .substitution(depth: depth - 1); copy(1)
                default: unquoted(context)
                }
            case .conditional(let numeric, let placeholder):
                if text[i] == "]", at(1) == "]", startsWord(), endsWord(after: 2) {
                    if numeric && placeholder { throw Failure.placeholderInNumericTest }
                    stack.removeLast()
                    copy(2)
                } else if text[i] == "-", startsWord(), endsWord(after: 3),
                          ["eq", "ne", "lt", "le", "gt", "ge"].contains(String(String.UnicodeScalarView(text[(i + 1)..<min(i + 3, text.count)]))) {
                    stack[stack.count - 1] = .conditional(numeric: true, placeholder: placeholder)
                    copy(3)
                } else if text[i] == "-", startsWord(), endsWord(after: 2), at(1) == "v" || at(1) == "t" {
                    // `-v name` evaluates a subscript in the name, `-t fd` arithmetic.
                    stack[stack.count - 1] = .conditional(numeric: true, placeholder: placeholder)
                    copy(2)
                } else {
                    unquoted(context)
                }
            case .qualifier(let depth):
                switch text[i] {
                case "(": stack[stack.count - 1] = .qualifier(depth: depth + 1); copy(1)
                case ")" where depth == 0: stack.removeLast(); copy(1)
                case ")": stack[stack.count - 1] = .qualifier(depth: depth - 1); copy(1)
                default: unquoted(context)
                }
            case .subscripted(let depth):
                switch text[i] {
                case "[": stack[stack.count - 1] = .subscripted(depth: depth + 1); copy(1)
                case "]" where depth == 0: stack.removeLast(); copy(1)
                case "]": stack[stack.count - 1] = .subscripted(depth: depth - 1); copy(1)
                default: unquoted(context)
                }
            case .backtick:
                if text[i] == "`" { stack.removeLast(); copy(1) } else { unquoted(context) }
            case .parameter(let depth):
                switch text[i] {
                case "{": stack[stack.count - 1] = .parameter(depth: depth + 1); copy(1)
                case "}" where depth == 0: stack.removeLast(); copy(1)
                case "}": stack[stack.count - 1] = .parameter(depth: depth - 1); copy(1)
                default: unquoted(context)
                }
            case .arithmetic(let depth):
                switch text[i] {
                case "(": stack[stack.count - 1] = .arithmetic(depth: depth + 1); copy(1)
                case ")" where depth == 0 && at(1) == ")": stack.removeLast(); copy(2)
                case ")": stack[stack.count - 1] = .arithmetic(depth: max(depth - 1, 0)); copy(1)
                default: unquoted(context)
                }
            case .single:
                if text[i] == "'" { stack.removeLast() }
                copy(1)
            case .ansiSingle:
                switch text[i] {
                case "\\": copy(2)
                case "'": stack.removeLast(); copy(1)
                default: copy(1)
                }
            case .double:
                if openExpansion() { continue }
                switch text[i] {
                case "\\": copy(2)
                case "\"": stack.removeLast(); copy(1)
                default: copy(1)
                }
            case .comment:
                if text[i] == "\n" {
                    stack.removeLast()
                    try words.finish()
                    let any = words.anyPlaceholder
                    let process = words.isProcessSubstitution
                    words = Words(start: i + 1)
                    words.anyPlaceholder = any
                    words.isProcessSubstitution = process
                }
                copy(1)
            }
        }
        if joiningOnly { return (String(String.UnicodeScalarView(text)), changed) }
        try endWord(newCommand: true)
        // A `[[` left open is a syntax error, but refuse it as if it were closed.
        for context in stack {
            if case .conditional(true, true) = context { throw Failure.placeholderInNumericTest }
        }
        // zsh evaluates a value given to a variable that holds a number as arithmetic, quoted too.
        if !assignedNames.isDisjoint(with: numericNames) { throw Failure.placeholderInBuiltin }
        return (String(out), changed)
    }

    /// The words of a command as `scan` reads them, outside quotes, to tell where `{query}` would
    /// be run as code by what reads it: another program (`sh -c '…{query}…'`) or a zsh builtin
    /// that evaluates its arguments (`let`, `read`, `printf %d`) even when they're quoted.
    private struct Words {
        /// Where the word being read starts.
        var start = 0
        var command: String?
        var previous: String?
        var interpreterSeen = false
        /// Whether `{query}` is in the word being read, or in a `$(…)` inside it.
        var hasPlaceholder = false
        /// Whether `{query}` was anywhere in this `$(…)` so far, for the word around it.
        var anyPlaceholder = false
        /// After `<`, `>` and the like: the next word is a file.
        var redirecting = false
        /// `print -v`, `printf -v`: an argument names a variable to assign.
        var assigns = false
        /// `printf` (or `print -f`) with a format that evaluates its arguments as numbers.
        var numericFormat = false
        /// `typeset -i` and the like: values are evaluated as numbers.
        var numericTypes = false
        /// After `sed` or `awk`: how many of the next words that aren't options may be its program,
        /// given as an argument without `-e`. Its files come after.
        var programWordsLeft = 0
        /// After `sed` or `awk`, the next word is an option's argument (`-v x=1`, `-F :`).
        var programOptionArgument = false
        /// The interpreter last named (`bash`, `node`, `pwsh`), whose options say where code goes.
        var interpreter: String?
        /// After `bash -c` and the like: the next word that isn't an option (`--`, `-x`) is code.
        var codePending = false
        /// For `eval`, `watch` and `ssh`, which join their arguments into one command that a shell
        /// reads again: arguments that aren't options so far, and whether the next is an option's.
        var joinedOperands = 0
        var joinedOptionArgument = false
        /// Whether the word being read holds a `<(…)` or `=(…)` with `{query}` in it.
        var processPlaceholder = false
        /// Whether these are the words of a `<(…)`, `>(…)` or `=(…)`.
        var isProcessSubstitution = false
        /// Input from a pipe after `{query}` (`echo {query} | sh`), or a here-string or input
        /// redirection with it (`bash <<< "echo {query}"`), which a program can read as code.
        var pipedPlaceholder = false
        var stdinPlaceholder = false
        var redirectingInput = false
        var hereString = false
        /// For a command that reads its program from its input unless given one: whether it was
        /// told to read it there anyway (`bash -s`, `python3 -`), and whether it was given one
        /// (a script file, or code after `-c`).
        var stdinForced = false
        var programGiven = false
        var stdinOptionArgument = false
        /// Variables this command declares as numbers (`integer n`, `typeset -i n`), and the ones
        /// it assigns a value with `{query}` in it (`n={query}`), which `scan` collects.
        var numericNames: [String] = []
        var assignedNames: [String] = []
        /// A program that runs the command after its own options and operands (`env`, `sudo -u
        /// me`, `xargs -I%`): while set, words are still its own, and the next that isn't is the
        /// command it runs.
        var wrapper: String?
        var wrapperOptionArgument = false
        var wrapperOperandsLeft = 0
        /// `xargs` ran the command, handing it the input as arguments: into its code with `-I`.
        var viaXargs = false
        /// `source /dev/stdin`, `. -`: the script is the input.
        var sourcesInput = false

        init(start: Int = 0) { self.start = start }

        mutating func add(_ word: String) throws {
            let alone = ActionRunner.isAlone(word)
            if hasPlaceholder, let command {
                let codeOption = previous.map { ActionRunner.runsNextWordAsCode($0, program: interpreter) } == true
                let isCode = (interpreterSeen && (codeOption || (codePending && !word.hasPrefix("-"))))
                    || (programWordsLeft > 0 && !programOptionArgument && !word.hasPrefix("-"))
                    || ["eval", "ssh", "trap", "sched", "watch"].contains(command)
                    // `env -S '…'` splits its argument into a command line.
                    || (command == "env" && wrapper != nil && previous.map { $0 == "-S" || $0 == "--split-string" } == true)
                    || (command == "env" && wrapper != nil && (word.hasPrefix("-S") || word.hasPrefix("--split-string")))
                if !alone, isCode { throw Failure.placeholderInCode }
                // `eval echo {query}` joins its arguments and reads them again, so even a whole
                // argument is code there, unless it starts the command (`ssh host {query}`).
                if alone, !joinedOptionArgument, !word.hasPrefix("-"),
                   ["eval", "watch", "ssh"].contains(command), joinedOperands > (command == "ssh" ? 1 : 0) {
                    throw Failure.placeholderInCode
                }
                if evaluates(word, command: command) { throw Failure.placeholderInBuiltin }
            }
            // A `<(…)` with `{query}` that a program runs: its script (`sh <(…)`, `source <(…)`)
            // or its program file (`awk -f <(…)`).
            if processPlaceholder, let command {
                let isProgram = ["source", "."].contains(command)
                    || (ActionRunner.readsProgramFromInput(command) && !programGiven && !stdinOptionArgument && !word.hasPrefix("-"))
                    || (interpreterSeen && previous.map { ["-f", "--file", "-E"].contains($0) } == true)
                if isProgram { throw Failure.placeholderInCode }
            }
            if command == nil {
                if !ActionRunner.precedesCommand(ActionRunner.unquoted(word)) {
                    start(command: word)
                } else if hasPlaceholder, let name = ActionRunner.assignedName(word) {
                    assignedNames.append(name)
                }
            } else if let wrapper {
                previous = word
                if !wrapperWord(word, of: wrapper) {
                    self.wrapper = nil
                    start(command: word)
                }
            } else {
                noteArgument(word)
                previous = word
                notice(option: word)
                noteDeclaration(word)
            }
            if ActionRunner.isInterpreter(word) {
                interpreterSeen = true
                interpreter = ActionRunner.programName(word)
                codePending = false
            }
            if ActionRunner.takesProgramAsArgument(word) {
                programWordsLeft = 1
                programOptionArgument = false
            }
        }

        /// Takes `word` as the command, or as a wrapper whose command comes later. A command named
        /// by a variable or a substitution (`$SHELL`, `$(which sh)`) may be any program, a shell
        /// too: its options are read as an unknown interpreter's.
        private mutating func start(command word: String) {
            let name = ActionRunner.unquoted(word)
            command = name
            if ActionRunner.wrappers.contains(ActionRunner.programName(name)) {
                wrapper = ActionRunner.programName(name)
                wrapperOptionArgument = false
                wrapperOperandsLeft = wrapper == "timeout" ? 1 : 0
                if wrapper == "xargs" { viaXargs = true }
            } else if ActionRunner.isUnknownProgram(word) {
                interpreterSeen = true
                interpreter = nil
            }
        }

        /// Whether `word` is still the wrapper's own: an option, an option's argument, a
        /// variable `env` sets, or the time `timeout` takes.
        private mutating func wrapperWord(_ word: String, of wrapper: String) -> Bool {
            if wrapperOptionArgument {
                wrapperOptionArgument = false
                return true
            }
            if word.hasPrefix("-"), word.count > 1 {
                let takesArgument: Set<String> = switch wrapper {
                case "env": ["-u", "-P", "-S", "-C", "--unset", "--chdir", "--split-string"]
                case "sudo": ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-r", "-t", "-T", "-U", "--user", "--group"]
                case "nice": ["-n"]
                case "timeout": ["-s", "-k", "--signal", "--kill-after"]
                case "caffeinate": ["-t", "-w"]
                case "arch": ["-arch"]
                case "xargs": ["-I", "-J", "-L", "-n", "-P", "-s", "-E", "-R", "-S"]
                case "exec": ["-a"]
                case "stdbuf": ["-i", "-o", "-e"]
                default: []
                }
                wrapperOptionArgument = takesArgument.contains(word)
                return true
            }
            if wrapper == "env", ActionRunner.assignedName(word) != nil { return true }
            if wrapperOperandsLeft > 0 {
                wrapperOperandsLeft -= 1
                return true
            }
            return false
        }

        /// Follows an argument through the options of the programs that read code from it.
        private mutating func noteArgument(_ word: String) {
            let isOption = word.hasPrefix("-") && word.count > 1
            // `bash -c -x -- 'code'`
            if interpreterSeen, ActionRunner.runsNextWordAsCode(word, program: interpreter) {
                codePending = true
            } else if codePending, !isOption {
                codePending = false
            }
            // sed and awk: `-e` and `-f` give the program, `-v`, `-F` and `-l` take an argument,
            // and BSD sed's `-i` takes a suffix that can look like a program (`sed -i '' 's/…/'`).
            if programWordsLeft > 0 {
                if programOptionArgument {
                    programOptionArgument = false
                } else if isOption {
                    if ["-e", "-f", "--expression", "--file", "--source"].contains(word)
                        || (!word.hasPrefix("--") && (word.hasSuffix("e") || word.hasSuffix("f"))) {
                        programWordsLeft = 0
                    } else if ["-v", "-F", "-l"].contains(word) {
                        programOptionArgument = true
                    } else if word == "-i" {
                        programWordsLeft += 1
                    }
                } else if word != "--" {
                    programWordsLeft -= 1
                }
            }
            if let command, ["eval", "watch", "ssh"].contains(command) {
                if joinedOptionArgument {
                    joinedOptionArgument = false
                } else if isOption {
                    let takesArgument: Set<String> = command == "ssh"
                        ? ["-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w", "-B"]
                        : ["-n", "--interval", "-d", "-q"]
                    joinedOptionArgument = takesArgument.contains(word)
                } else {
                    joinedOperands += 1
                }
            }
            if let command, ["source", "."].contains(command), previous == nil, ActionRunner.namesInput(word) {
                sourcesInput = true
            }
            if let command, ActionRunner.readsProgramFromInput(command) {
                let program = ActionRunner.programName(command)
                if stdinOptionArgument {
                    stdinOptionArgument = false
                } else if ActionRunner.namesInput(word) || (word == "-s" && ActionRunner.isShell(program)) {
                    stdinForced = true
                } else if ActionRunner.runsNextWordAsCode(word, program: program) || word == "-m" {
                    programGiven = true // the code, or a module, comes after
                } else if isOption {
                    let takesArgument: Set<String> = switch program {
                    case "osascript": ["-l", "-s"]
                    case "python": ["-W", "-X", "-Q"]
                    case "perl", "ruby": ["-I", "-M", "-x"]
                    case "at", "batch": ["-q", "-t", "-f"]
                    default: ["-o", "+o", "-O", "+O"]
                    }
                    stdinOptionArgument = takesArgument.contains(word)
                    // `at -f file`: its commands come from the file.
                    if (program == "at" || program == "batch") && word == "-f" { programGiven = true }
                } else if program != "at" && program != "batch" {
                    programGiven = true // a script file; at's are times
                }
            }
        }

        /// Ends the command: input with `{query}` in it, read as its program, is refused.
        func finish() throws {
            guard pipedPlaceholder || stdinPlaceholder, let command else { return }
            // `xargs sh -c '…'` hands the input to the code, into it with `-I`: refuse it whatever
            // the options, as for `sh -c` itself.
            if sourcesInput || (viaXargs && interpreterSeen) { throw Failure.placeholderInCode }
            guard ActionRunner.readsProgramFromInput(command) else { return }
            if stdinForced || !programGiven { throw Failure.placeholderInCode }
        }

        /// The names `typeset`, `integer` and the like declare as numbers or assign `{query}` to.
        private mutating func noteDeclaration(_ word: String) {
            guard let command, ActionRunner.declares.contains(command),
                  !word.hasPrefix("-"), !word.hasPrefix("+") else { return }
            let name = ActionRunner.assignedName(word) ?? word
            if numericTypes || command == "integer" || command == "float" { numericNames.append(name) }
            if hasPlaceholder, word.contains("=") { assignedNames.append(name) }
        }

        /// Options and formats that make `command` evaluate its other arguments.
        private mutating func notice(option word: String) {
            switch command {
            case "print", "printf":
                if word == "-v" || (command == "print" && word.hasPrefix("-") && !word.hasPrefix("--") && word.contains("v")) {
                    assigns = true
                }
                if ActionRunner.hasNumericConversion(word) { numericFormat = true }
            case "typeset", "declare", "local", "export", "readonly":
                if word.hasPrefix("-") || word.hasPrefix("+"), word.contains(where: { "iEF".contains($0) }) { numericTypes = true }
            default: break
            }
        }

        /// Whether zsh evaluates `{query}` in `word`, an argument of `command`, as code: arithmetic
        /// or a subscript in a variable name runs `$(…)` in what's typed.
        private func evaluates(_ word: String, command: String) -> Bool {
            switch command {
            case "let", "integer", "float", "repeat", "shift", "exit", "return", "read", "unset", "vared":
                return true
            case "typeset", "declare", "local", "export", "readonly":
                // A name (`typeset {query}`), or a number (`typeset -i x={query}`); a plain value is text.
                if numericTypes { return true }
                guard let equals = word.firstIndex(of: "=") else { return true }
                return word[..<equals].contains(ActionKind.argumentPlaceholder)
            case "print", "printf":
                return assigns || numericFormat
            default:
                return false
            }
        }
    }

    /// Whether a printf format in `word` converts an argument as a number (`%d`, `%5.2f`, `%x`,
    /// a `*` width), which zsh evaluates as arithmetic.
    nonisolated static func hasNumericConversion(_ word: String) -> Bool {
        word.range(of: #"%[-+ 0#]*(\*|[0-9]*)(\.(\*|[0-9]*))?[diouxXeEfgG]"#, options: .regularExpression) != nil
            || word.range(of: #"%[-+ 0#]*[0-9]*\.?\*"#, options: .regularExpression) != nil
    }

    /// Whether a program reads the word after `word` as code: `sh -c`, `bash -lc`, `osascript -e`,
    /// `perl -E`, `perl -pe`, `python3 -c`, `node --eval`, `php -r`, `sed -nE`. Some depend on the
    /// program: `node -p`, `php -R`, `pwsh -Command` (any abbreviation), `deno eval`.
    nonisolated static func runsNextWordAsCode(_ word: String, program: String? = nil) -> Bool {
        if ["--command", "--eval", "--expression", "--source", "--exec"].contains(word) { return true }
        switch program {
        case "node", "nodejs", "bun": if word == "-p" || word == "--print" { return true }
        case "php": if word == "-R" || word == "-B" { return true }
        case "pwsh", "powershell":
            let lower = word.lowercased()
            if lower.hasPrefix("-c") || lower.hasPrefix("-e") || lower.hasPrefix("/c") { return true }
        case "deno": if word == "eval" { return true }
        default: break
        }
        guard word.hasPrefix("-"), !word.hasPrefix("--"), let last = word.last else { return false }
        // A known interpreter's cluster of single-letter options: code follows `-c` (or `-e`)
        // wherever it is in the cluster (`bash -cx`, `perl -wlane`).
        let flags = word.dropFirst()
        if let program, isInterpreter(program), !["pwsh", "powershell"].contains(program),
           !flags.isEmpty, flags.allSatisfy({ $0.isASCII && $0.isLetter }) {
            let takesC = isShell(program) || program == "python" || program == "su"
            return (takesC && flags.contains("c")) || "ceEr".contains(last)
        }
        guard word.count <= 5 else { return false }
        return "ceEr".contains(last)
    }

    /// Programs that run a command given after their own options: `env sh`, `sudo -u me sh`.
    nonisolated static let wrappers: Set<String> = ["env", "sudo", "nice", "timeout", "gtimeout", "caffeinate", "arch",
                                                    "xargs", "exec", "command", "stdbuf", "nohup", "doas"]

    /// `word` with the quotes and backslashes zsh removes from it: `\sh` and `"bash"` run `sh`
    /// and `bash`.
    nonisolated static func unquoted(_ word: String) -> String {
        guard word.contains(where: { "\\\"'".contains($0) }) else { return word }
        var result = ""
        var escaped = false
        for c in word {
            if escaped { result.append(c); escaped = false } else if c == "\\" { escaped = true } else if c != "\"" && c != "'" { result.append(c) }
        }
        return result
    }

    /// Whether `word` names its program through an expansion (`$SHELL`, `${SHELL}`, `$(which sh)`),
    /// so it may be any program.
    nonisolated static func isUnknownProgram(_ word: String) -> Bool {
        let name = unquoted(word)
        return name.hasPrefix("$") || name.hasPrefix("`")
    }

    /// Whether `word` names the standard input as a file: `-`, `/dev/stdin`, `/dev/fd/0`.
    nonisolated static func namesInput(_ word: String) -> Bool {
        ["-", "/dev/stdin", "/dev/fd/0"].contains(unquoted(word))
    }

    /// Whether `word` is `{query}` alone, bare or in one pair of quotes: a whole argument, not
    /// part of one. `'"{query}"'` isn't: its double quotes are part of the code it's given to.
    nonisolated static func isAlone(_ word: String) -> Bool {
        let p = ActionKind.argumentPlaceholder
        return [p, "\"\(p)\"", "'\(p)'", "$'\(p)'", "$\"\(p)\""].contains(word)
    }

    /// The blanks zsh splits words at. A no-break space, say, stays part of the word.
    nonisolated static func isBlank(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n"
    }

    nonisolated static func isShell(_ program: String) -> Bool {
        ["sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "csh", "tcsh"].contains(program)
    }

    /// Whether `command` reads its program from its input when not given one: a shell or a
    /// scripting language (`echo … | sh`, `osascript <<< …`), or `at` and `batch`. Not sed or awk,
    /// whose input is text.
    nonisolated static func readsProgramFromInput(_ command: String) -> Bool {
        let name = programName(command)
        return isUnknownProgram(command) || isShell(name) || ["osascript", "perl", "python", "ruby", "node", "nodejs", "bun", "php", "lua",
                                 "tclsh", "pwsh", "powershell", "at", "batch"].contains(name)
    }

    /// Whether `word` names a program whose first argument, without `-e`, is its program:
    /// `sed 's/…/…/'`, `awk '{…}'`, which can run commands (`s/…/…/e`, `system(…)`).
    nonisolated static func takesProgramAsArgument(_ word: String) -> Bool {
        ["sed", "gsed", "awk", "gawk", "mawk", "nawk"].contains(programName(word))
    }

    /// The commands that declare variables, with options that make them numbers.
    nonisolated static let declares: Set<String> = ["typeset", "declare", "local", "export", "readonly", "integer", "float"]

    /// zsh's own variables that hold numbers, whose values it evaluates as arithmetic.
    nonisolated static let numericVariables: Set<String> = [
        "SECONDS", "RANDOM", "LINES", "COLUMNS", "HISTSIZE", "SAVEHIST", "SHLVL", "OPTIND", "ERRNO",
        "KEYTIMEOUT", "LISTMAX", "MAILCHECK", "TMOUT", "PERIOD", "DIRSTACKSIZE", "FUNCNEST", "HISTCMD",
        "UID", "GID", "EUID", "EGID", "ZLE_RPROMPT_INDENT", "TRY_BLOCK_ERROR", "TRY_BLOCK_INTERRUPT",
    ]

    /// The variable an assignment (`n=…`, `n+=…`) gives a value to.
    nonisolated static func assignedName(_ word: String) -> String? {
        guard let equals = word.firstIndex(of: "="), equals > word.startIndex else { return nil }
        var name = word[..<equals]
        if name.hasSuffix("+") { name = name.dropLast() }
        guard !name.isEmpty, name.allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }) else { return nil }
        return String(name)
    }

    private nonisolated static func programName(_ word: String) -> String {
        let word = unquoted(word)
        return (word.split(separator: "/").last.map(String.init) ?? word)
            .trimmingCharacters(in: CharacterSet(charactersIn: "0123456789."))
    }

    /// Whether `word` names a program that runs code given after `-c` or `-e`: a shell,
    /// `osascript`, `sed` or a scripting language, by path too (`/usr/bin/python3.12`).
    nonisolated static func isInterpreter(_ word: String) -> Bool {
        let name = programName(word)
        return ["sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "csh", "tcsh", "osascript", "perl",
                "python", "ruby", "node", "nodejs", "deno", "bun", "php", "lua", "tclsh", "pwsh", "powershell", "su",
                "sed", "gsed", "awk", "gawk", "mawk", "nawk"].contains(name)
    }

    /// Words that come before the command itself: `if`, `then`, `!`, `{`, `exec`, `command`,
    /// `noglob` and the like, and assignments (`LANG=C`).
    nonisolated static func precedesCommand(_ word: String) -> Bool {
        let prefixes: Set<String> = ["{", "!", "if", "then", "else", "elif", "while", "until", "do", "time",
                                     "builtin", "noglob", "nocorrect"]
        if prefixes.contains(word) { return true }
        return assignedName(word) != nil
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
        /// Run with `/bin/zsh -l -c`, `{query}` already replaced by a reference to
        /// `$LAUNCHGRID_QUERY` (see `ActionRunner.substitutingArgument(in:)`).
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
    private var writersOpen = true
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
                    // Once the run ended (a sandboxed script past its timeout), what's left is
                    // read and dropped, so the script never blocks on a full pipe.
                    self.lock.withLock {
                        guard !self.finished else { return }
                        if isError { self.err.append(data) } else { self.out.append(data) }
                    }
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

    /// For a run that can't be stopped (a script macOS runs for the sandboxed build): after
    /// `interval` it ends as `.timedOut` and LaunchGrid stops waiting, though the script may
    /// still be running in the system service. Output and an ending that come later are dropped.
    fileprivate func waitAtMost(_ interval: DispatchTimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            let timedOut = self.lock.withLock {
                guard !self.finished, self.exit == nil else { return false }
                self.exit = .timedOut
                return true
            }
            guard timedOut else { return }
            // The pipes keep being read until the script's own copies of the write ends close.
            self.closeWriters()
            self.finish(keepReading: true)
        }
    }

    /// Closes LaunchGrid's write ends of the pipes, once.
    fileprivate func closeWriters() {
        let close = lock.withLock { () -> Bool in
            defer { writersOpen = false }
            return writersOpen
        }
        guard close else { return }
        for w in [outputWriter, errorWriter] { try? w.close() }
    }

    /// Adds `text` to what the run printed, unless it already ended.
    fileprivate func append(_ text: String, isError: Bool) {
        let data = Data(text.utf8)
        lock.withLock {
            guard !finished else { return }
            if isError { err.append(data) } else { out.append(data) }
        }
    }

    /// The process ended: what's still in the pipes gets a moment to arrive (a child left
    /// running in the background can keep them open), then the run ends. An ending already
    /// set (the run timed out) is kept. Such a child's later output is read and dropped, so
    /// it never dies writing to a closed pipe or blocks on a full one.
    fileprivate func exited(_ ending: RunResult.Ending) {
        lock.withLock { if exit == nil { exit = ending } }
        finishIfDone()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.finish(keepReading: true) }
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

    private func finish(keepReading: Bool = false) {
        let ended: (RunResult, @MainActor @Sendable (RunResult) -> Void)? = lock.withLock {
            guard !finished, let exit, let onEnd else { return nil }
            finished = true
            self.onEnd = nil
            let result = RunResult(ending: stopReason ?? exit, endedAt: Date(), output: out.text, errorOutput: err.text)
            return (result, onEnd)
        }
        guard let (result, onEnd) = ended else { return }
        if !keepReading {
            for pipe in [outPipe, errPipe] { pipe.fileHandleForReading.readabilityHandler = nil }
        }
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
            return startUserScriptTask(url, arguments, waitingAtMost: .seconds(job.timeout), onEnd: onEnd)
            #else
            // Only macOS may run what's in the folder for a sandboxed app.
            if Sandbox.isActive { return startUserScriptTask(url, arguments, waitingAtMost: .seconds(job.timeout), onEnd: onEnd) }
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
    func runToEnd(_ job: CodeJob, onStart: (@MainActor (CodeRun) -> Void)? = nil) async -> RunResult {
        await withCheckedContinuation { (c: CheckedContinuation<RunResult, Never>) in
            do {
                let run = try start(job) { c.resume(returning: $0) }
                onStart?(run)
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
    /// environment nor stop it. After `interval` the run ends as timed out: LaunchGrid stops
    /// waiting, though the script may go on running in the system service.
    func startUserScriptTask(_ url: URL, _ arguments: [String], waitingAtMost interval: DispatchTimeInterval,
                             onEnd: @escaping @MainActor @Sendable (RunResult) -> Void) -> CodeRun {
        let run = CodeRun(canStop: false, onEnd: onEnd)
        run.readOutput()
        run.waitAtMost(interval)
        do {
            if Self.isAppleScript(url) {
                try scriptTasks.appleScript(url, arguments) { result, error in
                    if let result { run.append(result + "\n", isError: false) }
                    if let error { run.append(error + "\n", isError: true) }
                    run.closeWriters()
                    run.exited(error == nil ? .exited(0) : .failed(nil))
                }
            } else {
                try scriptTasks.unix(url, arguments, run.outputWriter, run.errorWriter) { error in
                    // The task holds its own copies of the write ends; once it's done,
                    // LaunchGrid's go too, so the pipes reach their end.
                    run.closeWriters()
                    // It reports a failure without the script's exit status.
                    run.exited(error == nil ? .exited(0) : .failed(nil))
                }
            }
        } catch {
            run.closeWriters()
            run.failedToStart(error.localizedDescription)
        }
        return run
    }

    fileprivate nonisolated static func scriptError(_ error: Error) -> String {
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

/// How the sandboxed build hands a user script to macOS (`NSUserUnixTask`,
/// `NSUserAppleScriptTask`), which runs it in a system service LaunchGrid can't signal.
struct UserScriptTasks: Sendable {
    /// Starts a Unix script writing to `output` and `error`; `done` gets its failure.
    var unix: @Sendable (_ url: URL, _ arguments: [String], _ output: FileHandle, _ error: FileHandle,
                         _ done: @escaping @Sendable (Error?) -> Void) throws -> Void
    /// Starts an AppleScript's `on run argv`; `done` gets what it returned and its error message.
    var appleScript: @Sendable (_ url: URL, _ arguments: [String],
                                _ done: @escaping @Sendable (_ result: String?, _ error: String?) -> Void) throws -> Void

    static let live = UserScriptTasks(
        unix: { url, arguments, output, error, done in
            let task = try NSUserUnixTask(url: url)
            task.standardOutput = output
            task.standardError = error
            task.execute(withArguments: arguments) { done($0) }
        },
        appleScript: { url, arguments, done in
            let task = try NSUserAppleScriptTask(url: url)
            task.execute(withAppleEvent: runEvent(arguments)) { result, error in
                done(result?.stringValue, error.map(ActionRunner.scriptError))
            }
        })

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
}

/// An action's runs in the background: usually one, more when another copy was asked for.
struct RunHandle {
    var runs: [CodeRun] = []

    var canStop: Bool { runs.contains(where: \.canStop) }
    var startedAt: Date? { runs.map(\.startedAt).min() }

    func stop() { for run in runs { run.stop() } }
}
