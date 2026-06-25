import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import KWWKAgent
import KWWKCli

/// `kwwk` — coding-agent CLI. Dispatches on argv:
///
///   kwwk                    → interactive coding TUI (uses creds from `kwwk login`)
///   kwwk login              → TUI-driven OAuth / API-key login
///   kwwk -p <prompt>        → one-shot, non-interactive run (stdout = reply)
///   kwwk --help             → usage
///
/// Global flags (apply to both TUI and headless `-p`):
///   `--thinking <off|minimal|low|medium|high|xhigh>` — reasoning effort, default `medium`.
///   `--model <id>`     — override the resolved provider's default model id
///                        (e.g. `--model claude-opus-4-5`). Catalog metadata
///                        is looked up by id; unknown ids fall back to sane
///                        defaults for `contextWindow` / `maxTokens`.
///   `--context-1m`     — opt into Anthropic's 1M-context beta. Adds
///                        `context-1m-2025-08-07` to the `anthropic-beta`
///                        header and bumps `contextWindow` to 1_000_000.
///                        Requires the account to have long-context billing
///                        enabled. Ignored for non-Anthropic providers.
///   `--subagents <list>` — comma-separated built-in subagents to enable:
///                        general, Explore, Plan, all, none.
///   `--no-subagents`    — disable built-in CLI subagents.
@main
struct KwwkCLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let thinkingLevel: ThinkingLevel
        (args, thinkingLevel) = extractThinking(args)
        let modelOverride: String?
        (args, modelOverride) = extractStringFlag(args, "--model")
        let context1m: Bool
        (args, context1m) = extractBoolFlag(args, "--context-1m")
        let builtinSubagents: BuiltinSubagentSelection
        (args, builtinSubagents) = extractBuiltinSubagents(args)
        let resume: SessionResume
        (args, resume) = extractResume(args)

        let subcommand = args.first

        switch subcommand {
        case nil:
            await runOrExit { try await KWWK.runCodingTUI(
                builtinSubagents: builtinSubagents,
                thinkingLevel: thinkingLevel,
                modelOverride: modelOverride,
                context1m: context1m,
                resume: resume
            ) }
        case "login":
            await runOrExit { try await KWWK.runLogin() }
        case "-p", "--print":
            await runPrint(
                rest: Array(args.dropFirst()),
                thinkingLevel: thinkingLevel,
                modelOverride: modelOverride,
                context1m: context1m,
                builtinSubagents: builtinSubagents,
                resume: resume
            )
        case "-h", "--help":
            printUsage()
        default:
            FileHandle.standardError.write(Data("kwwk: unknown subcommand '\(subcommand!)'\n\n".utf8))
            printUsage()
            Foundation.exit(2)
        }
    }

    static func printUsage() {
        print("""
        kwwk — coding-agent CLI

        usage:
          kwwk                        launch the interactive coding TUI
          kwwk login                  log in to an OAuth provider
          kwwk -p <prompt>            run a one-shot prompt and print the reply
          kwwk -p                     read the prompt from stdin
          kwwk --help                 show this message

        global options:
          --thinking <level>          reasoning effort: off, minimal, low,
                                      medium (default), high, xhigh
          --model <id>                override the provider's default model id
                                      (e.g. --model claude-opus-4-5)
          --context-1m                opt into Anthropic 1M-context beta
                                      (long-context billing must be on)
          --subagents <list>          built-in subagents to enable:
                                      general,Explore,Plan,all, or none
          --no-subagents              disable built-in CLI subagents
          --resume, --continue        resume the latest session for this
                                      directory (replays its transcript)
          --session <id>              resume (or create) a specific session id

        Sessions are persisted to ~/.kwwk/sessions/<id>.jsonl as an
        append-only log and replayed on resume.

        Credentials are read from the OAuth store at ~/.kwwk/oauth.json.
        Run `kwwk login` once to register a provider (OAuth subscription
        or API key).
        """)
    }

    /// Pull `--thinking <level>` out of argv and return the remaining args
    /// plus the parsed level. A missing flag defaults to `.medium`; an
    /// invalid value exits with usage.
    static func extractThinking(_ argv: [String]) -> ([String], ThinkingLevel) {
        var out: [String] = []
        var level: ThinkingLevel = .medium
        var i = 0
        while i < argv.count {
            if argv[i] == "--thinking" {
                guard i + 1 < argv.count, let parsed = ThinkingLevel(rawValue: argv[i + 1]) else {
                    FileHandle.standardError.write(Data(
                        "kwwk: --thinking needs one of: off, minimal, low, medium, high, xhigh\n".utf8
                    ))
                    Foundation.exit(2)
                }
                level = parsed
                i += 2
            } else {
                out.append(argv[i])
                i += 1
            }
        }
        return (out, level)
    }

    /// Pull `<flag> <value>` out of argv and return the remaining args plus
    /// the (optional) value. Missing flag → `nil`. Flag without a value →
    /// usage error.
    static func extractStringFlag(_ argv: [String], _ flag: String) -> ([String], String?) {
        var out: [String] = []
        var value: String? = nil
        var i = 0
        while i < argv.count {
            if argv[i] == flag {
                guard i + 1 < argv.count else {
                    FileHandle.standardError.write(Data(
                        "kwwk: \(flag) needs an argument\n".utf8
                    ))
                    Foundation.exit(2)
                }
                value = argv[i + 1]
                i += 2
            } else {
                out.append(argv[i])
                i += 1
            }
        }
        return (out, value)
    }

    /// Pull a boolean `<flag>` out of argv. Returns `(remaining, true)` if
    /// present, `(argv, false)` if not.
    static func extractBoolFlag(_ argv: [String], _ flag: String) -> ([String], Bool) {
        var out: [String] = []
        var seen = false
        for arg in argv {
            if arg == flag { seen = true } else { out.append(arg) }
        }
        return (out, seen)
    }

    /// Pull session resume flags out of argv:
    ///   `--resume` / `--continue` → latest session for the current cwd;
    ///   `--session <id>`          → a specific session id.
    /// Later flags win if more than one is present. Missing → `.none`.
    static func extractResume(_ argv: [String]) -> ([String], SessionResume) {
        var out: [String] = []
        var resume: SessionResume = .none
        var i = 0
        while i < argv.count {
            switch argv[i] {
            case "--resume", "--continue":
                resume = .latestForCwd
                i += 1
            case "--session":
                guard i + 1 < argv.count else {
                    FileHandle.standardError.write(Data(
                        "kwwk: --session needs a session id\n".utf8
                    ))
                    Foundation.exit(2)
                }
                resume = .id(argv[i + 1])
                i += 2
            default:
                out.append(argv[i])
                i += 1
            }
        }
        return (out, resume)
    }

    /// Pull built-in subagent selection flags out of argv. `--subagents`
    /// accepts a comma-separated list; `--no-subagents` is equivalent to
    /// `--subagents none`. If both are present, the later flag wins.
    static func extractBuiltinSubagents(_ argv: [String]) -> ([String], BuiltinSubagentSelection) {
        var out: [String] = []
        var selection: BuiltinSubagentSelection = .all
        var i = 0
        while i < argv.count {
            switch argv[i] {
            case "--no-subagents":
                selection = .none
                i += 1
            case "--subagents":
                guard i + 1 < argv.count else {
                    FileHandle.standardError.write(Data(
                        "kwwk: --subagents needs one of: \(BuiltinSubagentSelection.validNames)\n".utf8
                    ))
                    Foundation.exit(2)
                }
                guard let parsed = BuiltinSubagentSelection.parseList(argv[i + 1]) else {
                    FileHandle.standardError.write(Data(
                        "kwwk: --subagents needs one of: \(BuiltinSubagentSelection.validNames)\n".utf8
                    ))
                    Foundation.exit(2)
                }
                selection = parsed
                i += 2
            default:
                out.append(argv[i])
                i += 1
            }
        }
        return (out, selection)
    }

    /// Handle `-p` / `--print`. Everything after the flag is joined into
    /// the prompt; if nothing is supplied (or the token is a bare `-`),
    /// the prompt is read from stdin until EOF.
    ///
    /// `-p` is quiet by design: on a successful run stdout carries only
    /// the assistant reply and stderr stays empty. Failures (no prompt,
    /// missing credentials, stream error) still print a one-line message
    /// to stderr so a non-zero exit isn't mysterious. Exit codes: 2 = bad
    /// invocation, 1 = runtime/auth failure, 0 = success.
    static func runPrint(
        rest: [String],
        thinkingLevel: ThinkingLevel,
        modelOverride: String?,
        context1m: Bool,
        builtinSubagents: BuiltinSubagentSelection,
        resume: SessionResume = .none
    ) async {
        let prompt: String
        if rest.isEmpty || rest == ["-"] {
            // Use fd 0 directly instead of `fileno(stdin)` — on Linux
            // Glibc exposes `stdin` as a non-Sendable mutable var that
            // Swift 6 strict concurrency rejects. stdin's fd is always 0.
            if isatty(0) != 0 {
                FileHandle.standardError.write(Data(
                    "kwwk: -p requires a prompt argument when stdin is a terminal\n".utf8
                ))
                Foundation.exit(2)
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            prompt = String(data: data, encoding: .utf8) ?? ""
        } else {
            prompt = rest.joined(separator: " ")
        }

        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            FileHandle.standardError.write(Data(
                "kwwk: -p requires a non-empty prompt (as argument or via stdin)\n".utf8
            ))
            Foundation.exit(2)
        }

        do {
            let code = try await KWWK.runHeadless(
                prompt: prompt,
                builtinSubagents: builtinSubagents,
                thinkingLevel: thinkingLevel,
                modelOverride: modelOverride,
                context1m: context1m,
                resume: resume
            )
            Foundation.exit(code)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            FileHandle.standardError.write(Data("kwwk: \(msg)\n".utf8))
            Foundation.exit(1)
        }
    }

    /// Run the async body and surface any thrown error on stderr before
    /// exiting with a non-zero code. Swift async `@main` has no throwing
    /// overload, so this is the workaround.
    static func runOrExit(_ body: @Sendable () async throws -> Void) async {
        do {
            try await body()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            FileHandle.standardError.write(Data("kwwk: \(msg)\n".utf8))
            Foundation.exit(1)
        }
    }
}
