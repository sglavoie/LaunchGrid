import Foundation
import Testing
@testable import LaunchGrid
@testable import LaunchGridCore

/// Commands and user scripts: planning, quoting, running in the background, timeouts and output.
@MainActor
@Suite struct ActionRunnerTests {
    private func shell(_ command: String, timeout: Int? = nil, directory: String? = nil,
                       mode: RunMode = .background) -> ActionKind {
        .shell(command: command, runMode: mode, workingDirectory: directory, timeoutSeconds: timeout)
    }

    // MARK: Planning

    @Test func aTimeoutIsKeptWithinAnHour() {
        #expect(CodeJob.timeout(nil) == 60)
        #expect(CodeJob.timeout(0) == 1)
        #expect(CodeJob.timeout(5000) == 3600)
        #expect(CodeJob.timeout(90) == 90)
    }

    @Test func aScriptTakesTheArgumentInItsArgumentsAsTheyAre() throws {
        let plan = try ActionRunner.plan(.userScript(fileName: "tag.sh", arguments: ["--name", "{query}", "x{query}y"], runMode: .background),
                                         argument: "it's; $(x)")
        #expect(plan == .code(CodeJob(program: .script(fileName: "tag.sh", arguments: ["--name", "it's; $(x)", "xit's; $(x)y"]),
                                      argument: "it's; $(x)", workingDirectory: nil, timeout: 60, mode: .background)))
        #expect(throws: ActionRunner.Failure.noScript) {
            try ActionRunner.plan(.userScript(fileName: "", arguments: [], runMode: .background), argument: nil)
        }
    }

    @Test func aScriptOutsideTheFolderIsNotFound() throws {
        let runner = ActionRunner(scriptsDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        for name in ["../x.sh", "/bin/ls", "..", "missing.sh"] {
            #expect(throws: ActionRunner.Failure.scriptNotFound(name)) { try runner.scriptURL(name) }
        }
        #expect(ActionRunner.Failure.scriptNotFound("tag.sh").localizedDescription == "Script not found: tag.sh")
    }

    @Test func theScriptsAreTheFolderRunnableFiles() throws {
        let dir = try temporaryFolder()
        try script(dir, "b.sh", "#!/bin/sh\n")
        try script(dir, "A.sh", "#!/bin/sh\n")
        try Data("not run".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data().write(to: dir.appendingPathComponent("Hello.applescript"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try script(dir, ".hidden.sh", "#!/bin/sh\n")
        #expect(ActionRunner.scripts(in: dir) == ["A.sh", "b.sh", "Hello.applescript"])
        #expect(ActionRunner.scripts(in: dir.appendingPathComponent("missing")) == [])
    }

    #if APP_STORE
    @Test func commandsAreUnavailableInTheSandboxedBuild() {
        #expect(throws: ActionRunner.Failure.commandsUnavailable) { try ActionRunner.plan(shell("ls"), argument: nil) }
    }
    #else
    @Test func commandsRunWithTheirArgumentQuoted() throws {
        let plan = try ActionRunner.plan(shell("echo {query}", timeout: 9000, directory: "", mode: .terminal), argument: "a b")
        #expect(plan == .code(CodeJob(program: .shell(#"echo "${LAUNCHGRID_QUERY}""#), argument: "a b", workingDirectory: nil, timeout: 3600, mode: .terminal)))
        #expect(throws: ActionRunner.Failure.noCommand) { try ActionRunner.plan(shell("  \n"), argument: nil) }
    }

    // MARK: Quoting

    @Test(arguments: ["it's", "a; rm -rf /tmp/nothing", "$(echo pwned)", "`echo pwned`", "two\nlines", "  spaced  out ",
                      "'", "''", "\\'", "$HOME", "*", "", "end\\"])
    func anArgumentReachesTheCommandAsOneWord(_ argument: String) async throws {
        let runner = ActionRunner()
        let plan = try ActionRunner.plan(shell("printf '%s|' {query}; printf '%s' \"$#\""), argument: argument)
        guard case .code(let job) = plan else { Issue.record("not code"); return }
        let result = await runner.runToEnd(job)
        #expect(result.ending == .exited(0), "\(result.errorOutput)")
        #expect(result.output == "\(argument)|0")
    }

    @Test func quotingEscapesEmbeddedQuotes() throws {
        #expect(ActionRunner.shellQuoted("it's") == #"'it'\''s'"#)
        #expect(try ActionRunner.substitutingArgument(in: "open {query} {query}") == #"open "${LAUNCHGRID_QUERY}" "${LAUNCHGRID_QUERY}""#)
    }

    /// `{query}` inside '…', "…" or $'…' still delivers the argument as text, never as shell
    /// syntax, in the background and in a terminal; where it can't, the command is refused
    /// before it runs, in the editor too.
    @Test func quotedCommandPlaceholdersCannotExecuteArgumentSyntax() async throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ran")
        let m = ActionRunner.shellQuoted(marker.path)
        let arguments = ["$(touch \(m))", "`touch \(m)`", "x; touch \(m)", "it's \"quoted\" 'twice'",
                         "a'; touch \(m); echo '", "a\"; touch \(m); echo \"", "two\nlines; touch \(m)",
                         "  spaced  out ", "$HOME ${HOME} \\$(touch \(m))", "*", ""]
        // Each prints [what {query} became], which must be the argument exactly.
        let templates = [
            "printf '[%s]' {query}",
            "printf '[%s]' '{query}'",
            "printf '[%s]' \"{query}\"",
            "printf '[%s]' $'{query}'",
            "printf '[%s]' x{query}y | cut -c1-1 >/dev/null; printf '[%s]' \"$(printf '%s' {query})\"",
            "printf '[%s]' \"$(printf '%s' \"{query}\")\"",
            "printf '[%s]' '<{query}>' | tr -d '<>'",
            "printf '[%s]' \"<{query}>\" | tr -d '<>'",
            "printf '[' # {query}\nprintf '%s]' {query}",
        ]
        let runner = ActionRunner()
        for template in templates {
            for argument in arguments {
                // What the shell sees doesn't depend on the argument at all.
                let plan = try ActionRunner.plan(shell(template), argument: argument)
                guard case .code(let job) = plan, case .shell(let command) = job.program else {
                    Issue.record("not a command: \(template)"); continue
                }
                #expect(!command.contains("{query}") || template.contains("# {query}"), "\(command)")
                #expect(argument.isEmpty || !command.contains(argument), "the argument is in the command: \(command)")
                let expected = template.contains("<") ? "[\(argument.filter { !"<>".contains($0) })]" : "[\(argument)]"
                let background = await runner.runToEnd(job)
                #expect(background.ending == .exited(0), "\(template) \(argument): \(background.errorOutput)")
                #expect(background.output == expected, "\(template) with \(argument)")
                #expect(!FileManager.default.fileExists(atPath: marker.path), "\(template) ran \(argument)")

                // The terminal runs the same command from a file that exports the argument first.
                let terminalPlan = try ActionRunner.plan(shell(template, mode: .terminal), argument: argument)
                guard case .code(let terminalJob) = terminalPlan, case .shell(let terminalCommand) = terminalJob.program else {
                    Issue.record("not a command: \(template)"); continue
                }
                #expect(terminalCommand == command)
                let file = try ActionRunner.writeCommandFile(terminalCommand, directory: dir.path, argument: argument)
                let terminal = try runZsh(file)
                #expect(terminal.status == 0, "\(template) \(argument) in a terminal")
                #expect(terminal.output == expected, "\(template) with \(argument) in a terminal")
                #expect(!FileManager.default.fileExists(atPath: file.path), "the command file stayed")
                #expect(!FileManager.default.fileExists(atPath: marker.path), "\(template) ran \(argument) in a terminal")
            }
        }

        // Where the shell would read the value as code, or the reference can't fit, nothing runs.
        let refused: [(String, ActionRunner.Failure)] = [
            ("echo `printf %s {query}`", .placeholderInBackticks),
            ("echo \"`printf %s {query}`\"", .placeholderInBackticks),
            ("echo ${x:-{query}}", .placeholderInParameter),
            ("echo \"${x:-{query}}\"", .placeholderInParameter),
            ("echo $(( {query} + 1 ))", .placeholderInArithmetic),
            ("(( {query} > 1 )) && echo big", .placeholderInArithmetic),
            ("cat <<EOF\n{query}\nEOF", .placeholderAfterHereDocument),
            ("cat <<'EOF'\n'{query}'\nEOF", .placeholderAfterHereDocument),
        ]
        for (template, failure) in refused {
            for mode in [RunMode.background, .terminal] {
                #expect(throws: failure, "\(template)") { try ActionRunner.plan(shell(template, mode: mode), argument: "$(touch \(m))") }
            }
            let model = ActionEditorModel(action: nil, pageID: nil, others: [])
            model.fill("name", "Refused")
            model.fill("kind", "command")
            model.fill("command", template)
            #expect(model.errors == [failure.message], "\(template)")
        }
        // Here-strings, escaped braces, comments and a `#` inside a word are not refused.
        #expect(try ActionRunner.substitutingArgument(in: "cat <<< {query}") == #"cat <<< "${LAUNCHGRID_QUERY}""#)
        #expect(try ActionRunner.substitutingArgument(in: "echo a#{query}") == #"echo a#"${LAUNCHGRID_QUERY}""#)
        #expect(try ActionRunner.substitutingArgument(in: #"echo \{query} # {query}"#) == #"echo \{query} # {query}"#)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// zsh evaluates arithmetic even on a quoted value, and on the output of a `$(…)` inside it,
    /// and a subscript in it runs `$(…)`: `{query}` anywhere inside `$((…))`, `((…))`, `$[…]`, a
    /// subscript or a `[[ … ]]` that compares numbers is refused before anything runs, in the
    /// background, in a terminal and in the editor. Next to them, text uses still run, with the
    /// argument delivered as it is.
    @Test func arithmeticCommandPlaceholdersCannotExecuteArgumentSyntax() async throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let arguments = ["a[$(printf INJECTED >&2)0]", "a[`printf INJECTED >&2`0]"]
        let refused: [(String, ActionRunner.Failure)] = [
            ("a=(0); echo $(( \"{query}\" ))", .placeholderInArithmetic),
            ("a=(0); [[ 1 -eq {query} ]]", .placeholderInNumericTest),
            ("a=(0); echo $(( '{query}' + 1 ))", .placeholderInArithmetic),
            ("a=(0); (( \"{query}\" > 1 )) && echo big", .placeholderInArithmetic),
            ("a=(0); echo $(( $(printf %s \"{query}\") ))", .placeholderInArithmetic),
            ("a=(0); echo \"$(( \"{query}\" ))\"", .placeholderInArithmetic),
            ("a=(0); echo $[ \"{query}\" ]", .placeholderInArithmetic),
            ("a=(0); a[\"{query}\"]=1", .placeholderInArithmetic),
            ("a=(0); echo $a[\"{query}\"]", .placeholderInArithmetic),
            ("a=(0); echo \"$a[{query}]\"", .placeholderInArithmetic),
            ("a=(0); echo \"$#a[{query}]\"", .placeholderInArithmetic),
            ("a=(0); echo \"$+a[{query}]\"", .placeholderInArithmetic),
            ("a=(0); echo \"$=a[{query}]\"", .placeholderInArithmetic),
            ("a=(0); echo \"$~a[{query}]\"", .placeholderInArithmetic),
            ("a=(0); echo \"$^a[{query}]\"", .placeholderInArithmetic),
            ("a=(0); echo \"$^=a[{query}]\"", .placeholderInArithmetic),
            ("a=(0); [[ \"{query}\" -eq 1 ]]", .placeholderInNumericTest),
            ("a=(0); [[ 1 -lt $(printf %s \"{query}\") ]] && echo less", .placeholderInNumericTest),
            ("a=(0); [[ -n {query} && 1 -ge {query} ]]", .placeholderInNumericTest),
            // Subscripts on special parameters, ((…)) and [[ … ]] right after {, and -v or -t.
            ("a=(0); echo \"$#[{query}]\"", .placeholderInArithmetic),
            ("a=(0); echo $*[{query}]", .placeholderInArithmetic),
            ("a=(0); echo \"$?[{query}]\"", .placeholderInArithmetic),
            ("a=(0); echo \"$@[{query}]\"", .placeholderInArithmetic),
            ("a=(0); echo \"$$[{query}]\"", .placeholderInArithmetic),
            ("a=(0); {(({query}))}", .placeholderInArithmetic),
            ("a=(0); { (( {query} )) }", .placeholderInArithmetic),
            ("a=(0); {[[ 1 -eq {query} ]]}", .placeholderInNumericTest),
            ("a=(0); [[ -v {query} ]]", .placeholderInNumericTest),
            ("a=(0); [[ -t \"{query}\" ]]", .placeholderInNumericTest),
        ]
        for (template, failure) in refused {
            for argument in arguments {
                for mode in [RunMode.background, .terminal] {
                    #expect(throws: failure, "\(template) \(mode)") {
                        try ActionRunner.plan(shell(template, mode: mode), argument: argument)
                    }
                }
            }
            let model = ActionEditorModel(action: nil, pageID: nil, others: [])
            model.fill("name", "Refused")
            model.fill("kind", "command")
            model.fill("command", template)
            #expect(model.errors == [failure.message], "\(template)")
            #expect(!failure.message.isEmpty)
        }

        // Text uses next to them: the argument arrives as it is and nothing in it runs.
        let accepted = [
            "exec 2>&1; a=(0); printf '[%s]' {query}",
            "exec 2>&1; a=(0); printf '[%s]' \"{query}\"",
            "exec 2>&1; a=(0); echo $(( 1 + 1 )) >/dev/null; printf '[%s]' '{query}'",
            "exec 2>&1; a=(0); [[ -n {query} ]] && printf '[%s]' \"{query}\"",
            "exec 2>&1; a=(0); [[ {query} == x ]] || printf '[%s]' {query}",
            "exec 2>&1; a=(0); [[ 1 -eq 1 ]] && printf '[%s]' \"{query}\"",
            "exec 2>&1; a=(0); b=x; printf '[%s]' \"$b{query}\" | sed 's/^\\[x/[/'",
        ]
        let runner = ActionRunner()
        for template in accepted {
            for argument in arguments {
                let expected = "[\(argument)]"
                let plan = try ActionRunner.plan(shell(template), argument: argument)
                guard case .code(let job) = plan, case .shell(let command) = job.program else {
                    Issue.record("not a command: \(template)"); continue
                }
                #expect(!command.contains(argument))
                let background = await runner.runToEnd(job)
                #expect(background.ending == .exited(0), "\(template) \(argument): \(background.output)")
                #expect(background.output == expected, "\(template) with \(argument)")
                // Its output is the argument once, so the marker printed nowhere else.
                #expect(!background.output.replacingOccurrences(of: expected, with: "").contains("INJECTED"))
                #expect(!background.errorOutput.contains("INJECTED"))

                let terminalPlan = try ActionRunner.plan(shell(template, mode: .terminal), argument: argument)
                guard case .code(let terminalJob) = terminalPlan, case .shell(let terminalCommand) = terminalJob.program else {
                    Issue.record("not a command: \(template)"); continue
                }
                #expect(terminalCommand == command)
                let file = try ActionRunner.writeCommandFile(terminalCommand, directory: dir.path, argument: argument)
                let terminal = try runZsh(file)
                #expect(terminal.status == 0, "\(template) \(argument) in a terminal")
                #expect(terminal.output == expected, "\(template) with \(argument) in a terminal")
                #expect(!terminal.output.replacingOccurrences(of: expected, with: "").contains("INJECTED"))
            }
        }
    }

    /// Text that another program runs as code (`sh -c '…'`, `osascript -e '…'`, `eval`, `ssh`)
    /// would run the argument as that program's code even though zsh hands it over as text:
    /// `{query}` mixed into such code is refused. On its own, as that program's whole code or
    /// as an ordinary argument, it is still delivered as it is.
    @Test func placeholdersInsideAnotherProgramsCodeAreRefused() async throws {
        let refused = [
            "osascript -e 'display notification \"{query}\"'",
            "sh -c 'echo {query}'",
            "bash -lc \"echo {query}\"",
            "/bin/zsh -c 'echo x{query}'",
            "python3 -c 'print(\"{query}\")'",
            "sed -e 's/a/{query}/' file",
            "find . -name x -exec sh -c 'echo {query}' \\;",
            "eval \"echo {query}\"",
            "ssh host 'ls {query}'",
            "echo $(sh -c 'echo {query}')",
            "if true; then sh -c 'echo {query}'; fi",
            "LANG=C sh -c 'echo {query}'",
            "echo foo | perl -pe 's/foo/{query}/'",
            "perl -lne 'print \"{query}\"' file",
            "node -pe '\"x{query}\"'",
            "php -r 'echo \"{query}\";'",
            "echo a | sed 's/a/{query}/'",
            "sed -n 's/a/{query}/p' file",
            "echo a | awk '/{query}/'",
            "gawk -v x=1 '{ print \"{query}\" }'",
            "trap \"echo {query}\" EXIT",
        ]
        for template in refused {
            #expect(throws: ActionRunner.Failure.placeholderInCode, "\(template)") {
                try ActionRunner.plan(shell(template), argument: "$(touch x)")
            }
            let model = ActionEditorModel(action: nil, pageID: nil, others: [])
            model.fill("name", "Refused")
            model.fill("kind", "command")
            model.fill("command", template)
            #expect(model.errors == [ActionRunner.Failure.placeholderInCode.message], "\(template)")
        }

        // Options that aren't code, programs that aren't interpreters, the placeholder as a
        // whole argument, and a comment: the argument arrives as it is.
        let argument = "\"; touch ran; echo \""
        let accepted = [
            "printf '[%s]' -e '{query}'",
            "echo -e '[{query}]'",
            "printf '%s' '[{query}]' | grep -e '{query}'",
            "printf '[%s]' {query} | sed -e 's/=/=/'",
            "printf '%s' {query} | awk '{ printf \"[%s]\", $0 }'",
            "sh -c 'printf \"[%s]\" \"$1\"' sh {query}",
            "sh -c 'printf \"[%s]\" \"$LAUNCHGRID_QUERY\"'; # sh -c 'echo {query}'",
            "sh -c 'true'; printf '%s' \"[{query}]\"",
        ]
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = ActionRunner()
        for template in accepted {
            let plan = try ActionRunner.plan(shell("cd \(ActionRunner.shellQuoted(dir.path)); " + template), argument: argument)
            guard case .code(let job) = plan else { Issue.record("not code: \(template)"); continue }
            let result = await runner.runToEnd(job)
            #expect(result.ending == .exited(0), "\(template): \(result.errorOutput)")
            #expect(result.output.trimmingCharacters(in: .newlines).hasSuffix("[\(argument)]"), "\(template): \(result.output)")
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("ran").path), "\(template) ran it")
        }
        // Data, not code: files and text after the program, input to a program given its script,
        // a file read by a program that isn't run, `||`, and a shift in arithmetic.
        for template in ["sed 's/a/b/' {query}.txt", "sed -n 's/a/b/p' notes-{query}", "awk '{print}' notes-{query}.log",
                         "gawk -v x=1 '{print}' {query}.log", "perl -e 'print 1' {query}.txt",
                         "echo {query} | python3 script.py", "echo {query} || sh", "diff <(echo {query}) file",
                         "echo $((1<<2)) {query}", "x=$((n << 1)); open {query}", "cat <<< {query}",
                         "ssh host {query}", "ssh -p 22 host {query}", "eval {query}", "watch -n 1 {query}"] {
            #expect(throws: Never.self, "\(template)") { try ActionRunner.substitutingArgument(in: template) }
        }
        // A whole program given as the argument is what the command asks for.
        #expect(try ActionRunner.substitutingArgument(in: "sh -c {query}") == #"sh -c "${LAUNCHGRID_QUERY}""#)
        #expect(try ActionRunner.substitutingArgument(in: "osascript -e \"{query}\"") == #"osascript -e "${LAUNCHGRID_QUERY}""#)
    }

    /// A glob qualifier (`*(e:'…':)`) is code zsh runs for each file: `{query}` in one is
    /// refused. Function definitions, arrays and `$(…)` still take it.
    @Test func placeholdersInGlobQualifiersAreRefused() async throws {
        for template in ["print -l *(e:'[[ $REPLY == {query}* ]]':)", "ls *(N.e:'true {query}':)",
                         "echo $(print *(e:\"[[ $REPLY == {query} ]]\":))", "ls x(a|{query})"] {
            #expect(throws: ActionRunner.Failure.placeholderInGlobQualifier, "\(template)") {
                try ActionRunner.plan(shell(template), argument: "x$(touch ran)")
            }
        }
        let argument = "a b$(touch ran)"
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = ActionRunner()
        for template in ["f() { printf '[%s]' \"$1\" }; f {query}", "a=(x {query}); printf '[%s]' \"${a[2]}\"",
                         "printf '[%s]' \"$(printf %s {query})\""] {
            let plan = try ActionRunner.plan(shell("cd \(ActionRunner.shellQuoted(dir.path)); " + template), argument: argument)
            guard case .code(let job) = plan else { Issue.record("not code: \(template)"); continue }
            let result = await runner.runToEnd(job)
            #expect(result.output == "[\(argument)]", "\(template): \(result.errorOutput)")
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("ran").path), "\(template) ran it")
        }
    }

    /// zsh builtins that evaluate their arguments as arithmetic, or as variable names with a
    /// subscript, run `$(…)` in what's typed even from a quoted reference: `{query}` there is
    /// refused. Text uses of the same builtins still deliver the argument as it is.
    @Test func placeholdersInEvaluatingBuiltinsAreRefused() async throws {
        let refused = [
            "let {query}", "let x=\"{query}\"", "integer x={query}", "float x=\"{query}\"",
            "repeat {query} true", "shift {query}", "exit {query}", "f() { return \"{query}\" }; f",
            "read -t {query} x", "read {query}", "read -A '{query}'", "unset {query}", "vared {query}",
            "typeset {query}", "declare \"{query}\"", "export {query}", "typeset -i x={query}",
            "print -v {query} hi", "printf -v \"{query}\" hi", "printf '%d' {query}", "printf '%5.2f\\n' {query}",
            "printf '%*s' {query} x", "builtin let {query}", "true && let {query}",
            "let x=$(printf %s {query})", "echo $(let {query})", "LANG=C let \"{query}\"",
            "let x=$(printf %s {query} # note\n)", "let x=\"$(true; printf %s {query})\"",
            "typeset -i n; n={query}", "integer n; n=\"{query}\"", "n={query}; local -i n",
            "typeset -i n; n+={query}", "SECONDS={query}", "HISTSIZE=\"{query}\" true", "export UID={query}",
        ]
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ran")
        for template in refused {
            #expect(throws: ActionRunner.Failure.placeholderInBuiltin, "\(template)") {
                try ActionRunner.plan(shell(template), argument: "PATH[$(touch \(ActionRunner.shellQuoted(marker.path)))]")
            }
            let model = ActionEditorModel(action: nil, pageID: nil, others: [])
            model.fill("name", "Refused")
            model.fill("kind", "command")
            model.fill("command", template)
            #expect(model.errors == [ActionRunner.Failure.placeholderInBuiltin.message], "\(template)")
        }

        let argument = "PATH[$(touch \(ActionRunner.shellQuoted(marker.path)))]"
        let accepted = [
            "export X={query}; printf '[%s]' \"$X\"",
            "typeset x=\"{query}\"; printf '[%s]' \"$x\"",
            "read -r y <<< {query}; printf '[%s]' \"$y\"",
            "printf '%s' {query} > out.txt 2>&1; printf '[%s]' \"$(cat out.txt)\"",
            "printf '[%s]' {query}",
            "print -rn -- '[{query}]'",
            "x=$(printf %s {query}); printf '[%s]' \"$x\"",
            "let n=1; printf '[%s]' {query}",
            "typeset -i n=1; m={query}; printf '[%s]' \"$m\"",
            "s={query}; printf '[%s]' \"$s\"",
        ]
        let runner = ActionRunner()
        for template in accepted {
            let command = "cd \(ActionRunner.shellQuoted(dir.path)); " + template
            let plan = try ActionRunner.plan(shell(command), argument: argument)
            guard case .code(let job) = plan, case .shell(let substituted) = job.program else { Issue.record("not code: \(template)"); continue }
            let result = await runner.runToEnd(job)
            #expect(result.ending == .exited(0), "\(template): \(result.errorOutput)")
            #expect(result.output == "[\(argument)]", "\(template)")
            let file = try ActionRunner.writeCommandFile(substituted, directory: dir.path, argument: argument)
            let terminal = try runZsh(file)
            #expect(terminal.output == "[\(argument)]", "\(template) in a terminal")
            #expect(!FileManager.default.fileExists(atPath: marker.path), "\(template) ran it")
        }
    }

    /// The shell joins a backslash-newline before it reads tokens, so an operator or delimiter
    /// split across lines that way is the same operator: `{query}` there is refused just like on
    /// one line, in the background, in a terminal and in the editor. A plain continuation next
    /// to `{query}` still delivers the argument as it is.
    @Test func lineContinuedArithmeticCommandPlaceholdersCannotExecuteArgumentSyntax() async throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let arguments = ["a[$(printf INJECTED >&2)0]", "a[`printf INJECTED >&2`0]"]
        // Each backslash-n after a backslash in these literals is a real backslash, then a real newline.
        let refused: [(String, ActionRunner.Failure)] = [
            ("a=(0); [[ 1 -e\\\nq {query} ]]", .placeholderInNumericTest),
            ("a=(0); [\\\n[ 1 -eq {query} ]]", .placeholderInNumericTest),
            ("a=(0); echo $(\\\n( \"{query}\" ))", .placeholderInArithmetic),
            ("a=(0); echo \"$(\\\n( {query} ))\"", .placeholderInArithmetic),
            ("a=(0); echo $\\\n[ {query} ]", .placeholderInArithmetic),
            ("a=(0); [[ 1 -l\\\nt {query} ]] && echo less", .placeholderInNumericTest),
            ("a=(0); [[ 1 -\\\ne\\\nq {query} ]]", .placeholderInNumericTest),
            ("a=(0); a\\\n[\"{query}\"]=1", .placeholderInArithmetic),
        ]
        for (template, failure) in refused {
            #expect(template.contains("\\\n"))
            for argument in arguments {
                for mode in [RunMode.background, .terminal] {
                    #expect(throws: failure, "\(template) \(mode)") {
                        try ActionRunner.plan(shell(template, mode: mode), argument: argument)
                    }
                }
            }
            let model = ActionEditorModel(action: nil, pageID: nil, others: [])
            model.fill("name", "Refused")
            model.fill("kind", "command")
            model.fill("command", template)
            #expect(model.errors == [failure.message], "\(template)")
        }

        // Continuations that join ordinary text: the argument arrives once, as it is.
        let accepted = [
            "exec 2>&1; a=(0); printf '[%s]' \\\n{query}",
            "exec 2>&1; a=(0); printf '[%s]' \"\\\n{query}\"",
            "exec 2>&1; a=(0); [[ -n {query} ]] \\\n&& printf '[%s]' {query}",
        ]
        let runner = ActionRunner()
        for template in accepted {
            for argument in arguments {
                let expected = "[\(argument)]"
                let plan = try ActionRunner.plan(shell(template), argument: argument)
                guard case .code(let job) = plan, case .shell(let command) = job.program else {
                    Issue.record("not a command: \(template)"); continue
                }
                #expect(!command.contains(argument))
                let background = await runner.runToEnd(job)
                #expect(background.ending == .exited(0), "\(template) \(argument): \(background.output)")
                #expect(background.output == expected, "\(template) with \(argument)")
                #expect(!background.output.replacingOccurrences(of: expected, with: "").contains("INJECTED"))
                #expect(!background.errorOutput.contains("INJECTED"))

                let terminalPlan = try ActionRunner.plan(shell(template, mode: .terminal), argument: argument)
                guard case .code(let terminalJob) = terminalPlan, case .shell(let terminalCommand) = terminalJob.program else {
                    Issue.record("not a command: \(template)"); continue
                }
                #expect(terminalCommand == command)
                let file = try ActionRunner.writeCommandFile(terminalCommand, directory: dir.path, argument: argument)
                let terminal = try runZsh(file)
                #expect(terminal.status == 0, "\(template) \(argument) in a terminal")
                #expect(terminal.output == expected, "\(template) with \(argument) in a terminal")
                #expect(!terminal.output.replacingOccurrences(of: expected, with: "").contains("INJECTED"))
            }
        }
        // Inside '…' a backslash-newline is kept as typed.
        #expect(try ActionRunner.substitutingArgument(in: "echo 'a\\\nb' {query}") == "echo 'a\\\nb' \"${LAUNCHGRID_QUERY}\"")
    }

    /// Runs a terminal command file the way the terminal would, through zsh.
    private func runZsh(_ file: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", file.path]
        process.environment = ActionRunner.environment(argument: nil).filter { $0.key != "LAUNCHGRID_QUERY" }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Running

    private func run(_ command: String, timeout: Int? = nil, directory: String? = nil, argument: String? = nil) async throws -> RunResult {
        guard case .code(let job) = try ActionRunner.plan(shell(command, timeout: timeout, directory: directory), argument: argument) else {
            throw CocoaError(.featureUnsupported)
        }
        return await ActionRunner().runToEnd(job)
    }

    @Test func trueSucceeds() async throws {
        let result = try await run("true")
        #expect(result.ending == .exited(0))
        #expect(result.succeeded)
    }

    @Test func falseFailsWithItsExitStatus() async throws {
        let result = try await run("echo 'went wrong' >&2; echo more >&2; false")
        #expect(result.ending == .exited(1))
        #expect(result.exitStatus == 1)
        #expect(!result.succeeded)
        #expect(result.errorOutput == "went wrong\nmore\n")
        #expect(result.summary == "exit status 1: went wrong")
    }

    @Test func outputIsCapturedAndKeptToItsLast4KB() async throws {
        let short = try await run("printf hello")
        #expect(short.output == "hello")
        let long = try await run("printf 'a%.0s' {1..5000}; printf END; printf 'e%.0s' {1..6000} >&2")
        #expect(long.output.utf8.count == RunResult.tailLimit)
        #expect(long.output.hasSuffix("aaaEND"))
        #expect(long.errorOutput.utf8.count == RunResult.tailLimit)
    }

    @Test func aCutInsideACharacterStartsAtTheNextOne() async throws {
        // 4097 bytes, "é" then 2048 more: keeping 4096 starts inside the first; it's dropped.
        let result = try await run(#"printf '\303\251%.0s' {1..2049}"#)
        #expect(result.output.count == 2048, "\(result.output.count) \(result.ending)")
        #expect(result.output == String(repeating: "é", count: 2048))
    }

    /// A child the command leaves running keeps its output pipes: once the run ends, what it
    /// prints is read and dropped, so it isn't killed for writing to a closed pipe.
    @Test func aChildLeftRunningOutlivesTheRunAndKeepsPrinting() async throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("after")
        let result = try await run("(sleep 2; echo late; echo late >&2; touch \(ActionRunner.shellQuoted(marker.path))) & exit 0")
        #expect(result.ending == .exited(0))
        try await Task.sleep(for: .seconds(3))
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func aRunOverItsTimeoutIsStopped() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await run("sleep 5", timeout: 1)
        #expect(result.ending == .timedOut)
        #expect(clock.now - start < .seconds(4))
        #expect(result.summary == "timed out")
    }

    @Test func stoppingEndsWhatTheCommandStartedToo() async throws {
        let marker = try temporaryFolder().appendingPathComponent("survived")
        let runner = ActionRunner()
        guard case .code(let job) = try ActionRunner.plan(shell("(sleep 2; touch \(ActionRunner.shellQuoted(marker.path))) & wait"), argument: nil) else {
            Issue.record("not code"); return
        }
        let result = await withCheckedContinuation { (c: CheckedContinuation<RunResult, Never>) in
            do {
                let run = try runner.start(job) { c.resume(returning: $0) }
                #expect(run.canStop)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run.stop() }
            } catch { Issue.record(error) }
        }
        #expect(result.ending == .stopped)
        try await Task.sleep(for: .seconds(2.5))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the background child kept running")
    }

    @Test func theArgumentIsInTheEnvironment() async throws {
        let result = try await run("printf '%s' \"$LAUNCHGRID_QUERY\"", argument: "it's $(x)")
        #expect(result.output == "it's $(x)")
        let none = try await run("printf '[%s]' \"${LAUNCHGRID_QUERY-unset}\"")
        #expect(none.output == "[]")
    }

    @Test func itRunsInTheWorkingFolderOrHome() async throws {
        let dir = try temporaryFolder()
        let inFolder = try await run("pwd", directory: dir.path)
        #expect(inFolder.output.hasSuffix("/\(dir.lastPathComponent)\n"), "\(inFolder)")
        let inHome = try await run("pwd")
        #expect(inHome.output == NSHomeDirectory() + "\n", "\(inHome)")
        let missing = try await run("pwd", directory: dir.appendingPathComponent("gone").path)
        #expect(missing.ending == .failed(ActionRunner.Failure.folderNotFound(dir.appendingPathComponent("gone").path).message))
    }

    @Test func aTerminalCommandFileDeletesItselfAndKeepsTheArgumentQuoted() throws {
        let file = try ActionRunner.writeCommandFile("echo {query}", directory: "/tmp/it's", argument: "a'b")
        defer { try? FileManager.default.removeItem(at: file) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(file.pathExtension == "command")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(#"rm -f -- "$0""#))
        #expect(text.contains(#"cd -- '/tmp/it'\''s'"#))
        #expect(text.contains(#"export LAUNCHGRID_QUERY='a'\''b'"#))
    }
    #endif

    // MARK: User scripts (both builds)

    @Test func aUserScriptRunsFromTheScriptsFolderWithItsArguments() async throws {
        let dir = try temporaryFolder()
        try script(dir, "greet.sh", "#!/bin/sh\nprintf '%s|' \"$@\"\necho oops >&2\nexit 0\n")
        try script(dir, "fail.sh", "#!/bin/sh\necho 'no luck' >&2\nexit 4\n")
        let runner = ActionRunner(scriptsDirectory: dir)
        let plan = try ActionRunner.plan(.userScript(fileName: "greet.sh", arguments: ["hi", "{query}"], runMode: .background), argument: "it's me")
        guard case .code(let job) = plan else { Issue.record("not code"); return }
        let result = await runner.runToEnd(job)
        #expect(result.ending == .exited(0))
        #expect(result.output == "hi|it's me|")
        #expect(result.errorOutput == "oops\n")

        let failed = await runner.runToEnd(CodeJob(program: .script(fileName: "fail.sh", arguments: []), argument: nil,
                                                    workingDirectory: nil, timeout: 60, mode: .background))
        #expect(!failed.succeeded)
        #expect(failed.firstErrorLine == "no luck")

        let missing = await runner.runToEnd(CodeJob(program: .script(fileName: "gone.sh", arguments: []), argument: nil,
                                                     workingDirectory: nil, timeout: 60, mode: .background))
        #expect(missing.ending == .failed("Script not found: gone.sh"))
    }

    /// The sandboxed build can't stop a script macOS runs for it, but stops waiting at its
    /// timeout: the run ends once, as timed out, whether the task never calls back or calls
    /// back (with more output) afterwards.
    @Test func sandboxUserScriptTimeoutCompletesExactlyOnce() async throws {
        let dir = try temporaryFolder()
        try script(dir, "hang.sh", "#!/bin/sh\n")
        try Data().write(to: dir.appendingPathComponent("hang.applescript"))
        let tasks = FakeScriptTasks()
        let runner = ActionRunner(scriptsDirectory: dir)
        runner.scriptTasks = tasks.tasks
        defer { tasks.closeAll() }
        let clock = ContinuousClock()

        for name in ["hang.sh", "hang.applescript"] {
            for callsBackLate in [false, true] {
                tasks.callBackAfter = callsBackLate ? 0.4 : nil
                let ends = EndCount()
                let start = clock.now
                var started: CodeRun?
                let result = await withCheckedContinuation { (c: CheckedContinuation<RunResult, Never>) in
                    let run = runner.startUserScriptTask(dir.appendingPathComponent(name), ["a"], waitingAtMost: .milliseconds(150)) { r in
                        ends.count += 1
                        ends.results.append(r)
                        if ends.count == 1 { c.resume(returning: r) }
                    }
                    #expect(!run.canStop)
                    run.stop()
                    started = run
                }
                let label = "\(name) late: \(callsBackLate)"
                #expect(result.ending == .timedOut, "\(label)")
                #expect(result.summary == "timed out", "\(label)")
                #expect(clock.now - start < .seconds(2), "\(label)")
                if name == "hang.sh" { #expect(result.output == "early\n", "\(label)") }
                // Past the late callback (and the 1 s grace an exit allows for output).
                try await Task.sleep(for: .seconds(1.6))
                #expect(ends.count == 1, "\(label)")
                #expect(ends.results.allSatisfy { $0.ending == .timedOut && !$0.output.contains("late") }, "\(label)")
                #expect(tasks.lateCallbacks == (callsBackLate ? 1 : 0), "\(label)")
                tasks.lateCallbacks = 0
                started?.stop()
            }
        }

        // A task that ends before the deadline keeps its own ending; the deadline does nothing.
        tasks.callBackAfter = 0
        let quick = await withCheckedContinuation { (c: CheckedContinuation<RunResult, Never>) in
            _ = runner.startUserScriptTask(dir.appendingPathComponent("hang.applescript"), [], waitingAtMost: .milliseconds(300)) { c.resume(returning: $0) }
        }
        #expect(quick.ending == .exited(0))
        #expect(quick.output == "late result\n")

        #if APP_STORE
        // Through `start`, as the sandboxed build runs every script, with the job's timeout.
        tasks.callBackAfter = nil
        let job = CodeJob(program: .script(fileName: "hang.sh", arguments: []), argument: nil,
                          workingDirectory: nil, timeout: 1, mode: .background)
        let waited = await runner.runToEnd(job)
        #expect(waited.ending == .timedOut)
        #endif
    }

    // MARK: Helpers

    private func temporaryFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ActionRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func script(_ dir: URL, _ name: String, _ text: String) throws {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// How many times a run ended, and with what.
@MainActor private final class EndCount {
    var count = 0
    var results: [RunResult] = []
}

/// Script tasks that never call back, or call back after a delay; a Unix one prints `early`
/// at once and `late` as it calls back, through its own copy of the output pipe.
private final class FakeScriptTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var _callBackAfter: Double?
    private var _lateCallbacks = 0
    private var descriptors: [Int32] = []

    var callBackAfter: Double? {
        get { lock.withLock { _callBackAfter } }
        set { lock.withLock { _callBackAfter = newValue } }
    }
    var lateCallbacks: Int {
        get { lock.withLock { _lateCallbacks } }
        set { lock.withLock { _lateCallbacks = newValue } }
    }

    private func later(_ body: @escaping @Sendable () -> Void) {
        guard let delay = callBackAfter else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            if delay > 0 { self.lock.withLock { self._lateCallbacks += 1 } }
            body()
        }
    }

    var tasks: UserScriptTasks {
        UserScriptTasks(
            unix: { _, _, output, _, done in
                let fd = dup(output.fileDescriptor)
                self.lock.withLock { self.descriptors.append(fd) }
                _ = "early\n".withCString { write(fd, $0, strlen($0)) }
                self.later {
                    _ = "late\n".withCString { write(fd, $0, strlen($0)) }
                    self.close(fd)
                    done(nil)
                }
            },
            appleScript: { _, _, done in
                self.later { done("late result", nil) }
            })
    }

    private func close(_ fd: Int32) {
        let open = lock.withLock { () -> Bool in
            guard let i = descriptors.firstIndex(of: fd) else { return false }
            descriptors.remove(at: i)
            return true
        }
        if open { Darwin.close(fd) }
    }

    /// What never called back lets go of its pipes.
    func closeAll() {
        for fd in lock.withLock({ descriptors }) { close(fd) }
    }
}

/// What `AppState` keeps and says about commands and scripts running in the background.
@MainActor @Suite(.tempDir) struct RunStateTests {
    private func state(with actions: [Action]) -> AppState {
        let state = makeState(["Notes"])
        state.apply { g in for a in actions { g.appendToFirstFree([.action(a)]) } }
        state.toastDuration = .seconds(60)
        return state
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: Double = 10) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out waiting"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aMissingScriptShowsAsUnavailable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RunState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("here.sh")
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let here = Action(name: "Here", kind: .userScript(fileName: "here.sh", arguments: [], runMode: .background))
        let gone = Action(name: "Gone", kind: .userScript(fileName: "gone.sh", arguments: [], runMode: .background))
        let s = state(with: [here, gone])
        s.actionRunner = ActionRunner(scriptsDirectory: dir)
        #expect(s.unavailableReason(gone) == nil, "not looked at yet")
        await s.refreshScripts()
        #expect(s.unavailableReason(here) == nil)
        #expect(s.unavailableReason(gone) == "Script not found: gone.sh")
    }

    #if APP_STORE
    @Test func aCommandStaysInTheLayoutButCannotRun() {
        let ls = Action(name: "List", kind: .shell(command: "ls", runMode: .background, workingDirectory: nil, timeoutSeconds: nil))
        let s = state(with: [ls])
        #expect(s.grid.allActions.map(\.name) == ["List"])
        #expect(s.unavailableReason(ls) != nil)
        s.isShown = true
        s.run(ls, argument: nil)
        #expect(s.toast?.hasPrefix("Could not run List: Commands run only") == true)
        #expect(s.runningActions.isEmpty)
    }
    #else
    private func command(_ name: String, _ command: String, timeout: Int? = nil) -> Action {
        Action(name: name, kind: .shell(command: command, runMode: .background, workingDirectory: nil, timeoutSeconds: timeout))
    }

    @Test func aRunIsFollowedToItsEndAndKept() async throws {
        let ok = command("Fine", "sleep 0.3; printf done")
        let s = state(with: [ok])
        s.isShown = true
        s.run(ok, argument: nil)
        #expect(s.runningActions[ok.id]?.runs.count == 1)
        try await waitUntil { s.runningActions.isEmpty }
        #expect(s.lastRun[ok.id]?.ending == .exited(0))
        #expect(s.lastRun[ok.id]?.output == "done")
        #expect(s.toast == "Fine finished")
        #expect(MenuEntry.item(.action(ok), state: s).map(\.title).contains("Show Last Output…"))
        #expect(!MenuEntry.item(.action(ok), state: s).map(\.title).contains("Stop"))
    }

    @Test func aSuccessWhileHiddenSaysNothing() async throws {
        let ok = command("Fine", "true")
        let s = state(with: [ok])
        var errors: [String] = []
        s.onError = { title, _ in errors.append(title) }
        s.run(ok, argument: nil)
        try await waitUntil { s.lastRun[ok.id] != nil }
        #expect(s.toast == nil)
        #expect(errors.isEmpty)
    }

    @Test func aFailureSaysTheFirstLineOfItsErrors() async throws {
        let bad = command("Broken", "echo 'no such thing' >&2; echo second >&2; exit 2")
        let s = state(with: [bad])
        s.isShown = true
        s.run(bad, argument: nil)
        try await waitUntil { s.lastRun[bad.id] != nil }
        #expect(s.toast == "Broken failed: exit status 2: no such thing")
        // Hidden: an alert instead.
        var errors: [(String, String)] = []
        s.onError = { errors.append(($0, $1)) }
        s.isShown = false
        s.run(bad, argument: nil)
        try await waitUntil { !errors.isEmpty }
        #expect(errors.first?.0 == "Broken failed")
        #expect(errors.first?.1 == "exit status 2: no such thing")
    }

    @Test func stopFromTheMenuEndsItAsStopped() async throws {
        let long = command("Long", "sleep 30")
        let s = state(with: [long])
        s.isShown = true
        s.run(long, argument: nil)
        let menu = MenuEntry.item(.action(long), state: s)
        guard case .action(let stop)? = menu.first(where: { $0.title == "Stop" })?.kind else {
            Issue.record("no Stop in \(menu.map(\.title))"); return
        }
        stop()
        try await waitUntil { s.runningActions.isEmpty }
        #expect(s.lastRun[long.id]?.ending == .stopped)
        #expect(s.toast == "Stopped Long")
    }

    @Test func runningAgainAsksFirst() async throws {
        let long = command("Long", "sleep 30")
        let s = state(with: [long])
        var asked = 0
        var answer = false
        s.onConfirmRunAgain = { _ in asked += 1; return answer }
        s.run(long, argument: nil)
        s.run(long, argument: nil)
        #expect(asked == 1)
        #expect(s.runningActions[long.id]?.runs.count == 1)
        answer = true
        s.run(long, argument: nil)
        #expect(asked == 2)
        #expect(s.runningActions[long.id]?.runs.count == 2)
        s.stopAllRuns()
        try await waitUntil { s.runningActions.isEmpty }
        #expect(s.lastRun[long.id]?.ending == .stopped)
    }

    @Test func aTimeoutIsAFailure() async throws {
        let slow = command("Slow", "sleep 5", timeout: 1)
        let s = state(with: [slow])
        s.isShown = true
        s.run(slow, argument: nil)
        try await waitUntil { s.lastRun[slow.id] != nil }
        #expect(s.lastRun[slow.id]?.ending == .timedOut)
        #expect(s.toast == "Slow failed: timed out")
    }

    @Test func theEditorTestWaitsForABackgroundRun() async throws {
        let s = state(with: [])
        let error = await s.test(command("Bad", "exit 3"), argument: nil)
        #expect(error?.localizedDescription == "exit status 3")
        #expect(await s.test(command("Good", "true"), argument: nil) == nil)
    }

    /// The pids a long command wrote: its child `sleep` and the shell itself.
    private func longTestCommand(_ pidFile: URL) -> String {
        "sleep 60 & echo $! > '\(pidFile.path)'; echo $$ >> '\(pidFile.path)'; wait"
    }

    private func pids(in file: URL) -> [pid_t] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    @Test func editorTestRunsAreStoppedOnShutdown() async throws {
        let s = state(with: [])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A draft never saved, tested straight from the state.
        let direct = dir.appendingPathComponent("direct")
        let waiting = Task { await s.test(command("Long", longTestCommand(direct)), argument: nil) }
        // A new action in an editor that's closed while its Test waits.
        let fromEditor = dir.appendingPathComponent("editor")
        var model: ActionEditorModel? = ActionEditorModel(action: nil, pageID: nil, others: [])
        model?.fill("name", "Long Too")
        model?.fill("kind", "command")
        model?.fill("command", longTestCommand(fromEditor))
        let editorTest = Task { [model] in await model?.test(with: s); return model?.testResult }
        model = nil
        s.actionEditor = nil

        try await waitUntil { s.testRuns.count == 2 && pids(in: direct).count == 2 && pids(in: fromEditor).count == 2 }
        let all = pids(in: direct) + pids(in: fromEditor)
        #expect(all.allSatisfy { kill($0, 0) == 0 })

        s.stopAllRuns()
        let error = await waiting.value
        #expect(error?.localizedDescription == "stopped")
        #expect(await editorTest.value == "Could not run it: stopped")
        #expect(s.testRuns.isEmpty)
        try await waitUntil { all.allSatisfy { kill($0, 0) != 0 } }
        // Nothing was saved along the way.
        #expect(s.grid.allActions.isEmpty)
        #expect(s.lastRun.isEmpty)
    }
    #endif
}

/// The editor's Command and Script kinds.
@MainActor @Suite struct CodeEditorTests {
    @Test func aScriptIsChosenWithItsArgumentsOnePerLine() {
        let model = ActionEditorModel(action: nil, pageID: nil, others: [])
        model.fill("name", "Tag")
        model.fill("kind", "script")
        #expect(model.errors == ["Choose a script."])
        model.fill("script", "tag.sh")
        model.fill("arguments", "--name\\n{query}\\n\\n")
        #expect(model.errors.isEmpty)
        #expect(model.draft?.kind == .userScript(fileName: "tag.sh", arguments: ["--name", "{query}"], runMode: .background))
        #expect(model.draft?.kind.takesArgument == true)
        model.scripts = ["other.sh"]
        model.scriptsLoaded = true
        #expect(model.warnings == ["Script not found: tag.sh"])
        let reopened = ActionEditorModel(action: model.draft, pageID: nil, others: [])
        #expect(reopened.kind == .script)
        #expect(reopened.argumentsText == "--name\n{query}")
    }

    #if APP_STORE
    @Test func aCommandCannotBeMadeButOneInTheLayoutIsKept() {
        let model = ActionEditorModel(action: nil, pageID: nil, others: [])
        model.fill("name", "List")
        model.fill("kind", "command")
        #expect(model.errors.contains(ActionRunner.Failure.commandsUnavailable.message))
        let existing = Action(name: "List", kind: .shell(command: "ls", runMode: .terminal, workingDirectory: nil, timeoutSeconds: 5))
        let editing = ActionEditorModel(action: existing, pageID: nil, others: [])
        editing.fill("name", "List All")
        #expect(editing.errors.isEmpty)
        #expect(editing.draft?.kind == existing.kind)
        editing.fill("runmode", "terminal")
        editing.fill("kind", "script")
        editing.fill("script", "a.sh")
        // The test runner isn't sandboxed, so a terminal is still on offer here.
        #expect(editing.errors == (Sandbox.isActive ? [ActionRunner.Failure.terminalUnavailable.message] : []))
    }
    #else
    @Test func aCommandKeepsItsFields() {
        let model = ActionEditorModel(action: nil, pageID: nil, others: [])
        model.fill("name", "Build")
        model.fill("kind", "command")
        #expect(model.errors == ["Enter a command."])
        model.fill("command", "make {query}")
        model.fill("runmode", "terminal")
        model.fill("workdir", "/tmp")
        model.fill("timeout", "120")
        #expect(model.errors.isEmpty)
        let kind = ActionKind.shell(command: "make {query}", runMode: .terminal, workingDirectory: "/tmp", timeoutSeconds: 120)
        #expect(model.draft?.kind == kind)
        model.fill("timeout", "60")
        model.fill("workdir", "")
        #expect(model.draft?.kind == .shell(command: "make {query}", runMode: .terminal, workingDirectory: nil, timeoutSeconds: nil))
        let reopened = ActionEditorModel(action: Action(name: "Build", kind: kind), pageID: nil, others: [])
        #expect((reopened.command, reopened.runMode, reopened.workingDirectory, reopened.timeout) == ("make {query}", .terminal, "/tmp", 120))
    }
    #endif
}
