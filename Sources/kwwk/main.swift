import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import KWWKAI
import KWWKAgent
import KWWKCli

/// What `kwwk` accepts on its command line. Declaration only: `KwwkCLI.main`
/// parses it and acts on the result.
struct KwwkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kwwk",
        abstract: "Coding-agent CLI: an interactive TUI, or a one-shot prompt with -p.",
        discussion: """
        Sessions are persisted to ~/.kwwk/sessions/<id>.jsonl as an append-only log and replayed on resume.

        MCP servers are read from ~/.kwwk/mcp.json (project servers in .kwwk/mcp.json need \
        KWWK_ALLOW_PROJECT_MCP=1); manage them with `kwwk mcp` and see their status with /mcp.

        Credentials are read from the OAuth store at ~/.kwwk/oauth.json, with supported API-key environment \
        variables as a fallback. With neither configured, launch kwwk and run /login to sign in to a provider.

        `kwwk mcp <command>` manages MCP servers: add, add-json, list, get, remove, login, logout.
        """
    )

    @Flag(
        name: [.customShort("p"), .customLong("print")],
        help: "Run a one-shot prompt and print the reply (read from stdin when no prompt or `-` is given)."
    )
    var printMode = false

    @Flag(name: .customLong("self-test"), help: "Verify bundled installation resources.")
    var selfTest = false

    @Option(
        help: ArgumentHelp("Reasoning effort: off, minimal, low, medium, high, xhigh, max.", valueName: "level"),
        transform: KwwkCommand.thinkingLevel
    )
    var thinking: ThinkingLevel = .medium

    @Option(help: ArgumentHelp("Override the provider's default model id (e.g. --model claude-opus-4-5).", valueName: "id"))
    var model: String?

    @Flag(
        name: .customLong("context-1m"),
        help: "Opt into the Anthropic 1M-context beta (long-context billing must be on)."
    )
    var context1m = false

    @Option(
        name: .customLong("subagents"),
        help: ArgumentHelp("Built-in subagents to enable: \(BuiltinSubagentSelection.validNames).", valueName: "list"),
        transform: KwwkCommand.subagentList
    )
    var subagents: BuiltinSubagentSelection?

    @Flag(name: .customLong("no-subagents"), help: "Disable built-in CLI subagents.")
    var noSubagents = false

    @Flag(
        name: .customLong("idle-compact"),
        help: """
        Compact the conversation while the TUI sits idle (default: after 5m at 50% of the context window; \
        tune in-session, e.g. /idle-compact 150k 10m).
        """
    )
    var idleCompact = false

    @Flag(name: .customLong("continue"), help: "Resume the latest session for this directory (replays its transcript).")
    var continueLatest = false

    @Flag(name: .customLong("resume"), help: "Interactively pick any session to resume (across all projects).")
    var pickSession = false

    @Option(name: .customLong("session"), help: ArgumentHelp("Resume (or create) a specific session id.", valueName: "id"))
    var sessionID: String?

    /// The prompt words of `-p`. Unknown options land here too, so a prompt
    /// may contain words that look like flags, as it always could.
    @Argument(parsing: .allUnrecognized, help: "The prompt for -p; read from stdin when omitted or `-`.")
    var prompt: [String] = []

    func validate() throws {
        if !printMode, !selfTest, let first = prompt.first {
            throw ValidationError("unknown subcommand '\(first)'")
        }
    }

    /// `--subagents` and `--no-subagents` may both appear (an alias plus a
    /// one-off override); the later one wins.
    func builtinSubagents(_ argv: [String]) -> BuiltinSubagentSelection {
        guard let subagents else { return noSubagents ? .none : .all }
        guard noSubagents else { return subagents }
        return Self.lastIndex(of: "--no-subagents", in: argv) > Self.lastIndex(of: "--subagents", in: argv)
            ? .none
            : subagents
    }

    /// `--continue`, `--resume` and `--session <id>` pick how to resume; when
    /// more than one is given, the later one wins.
    func resume(_ argv: [String]) -> SessionResume {
        var picks: [(index: Int, resume: SessionResume)] = []
        if continueLatest { picks.append((Self.lastIndex(of: "--continue", in: argv), .latestForCwd)) }
        if pickSession { picks.append((Self.lastIndex(of: "--resume", in: argv), .pickInteractive)) }
        if let sessionID { picks.append((Self.lastIndex(of: "--session", in: argv), .id(sessionID))) }
        return picks.max { $0.index < $1.index }?.resume ?? .none
    }

    static func lastIndex(of flag: String, in argv: [String]) -> Int {
        argv.lastIndex { $0 == flag || $0.hasPrefix(flag + "=") } ?? -1
    }

    static func thinkingLevel(_ raw: String) throws -> ThinkingLevel {
        guard let level = ThinkingLevel(rawValue: raw) else {
            throw ValidationError("--thinking needs one of: off, minimal, low, medium, high, xhigh, max")
        }
        return level
    }

    static func subagentList(_ raw: String) throws -> BuiltinSubagentSelection {
        guard let selection = BuiltinSubagentSelection.parseList(raw) else {
            throw ValidationError("--subagents needs one of: \(BuiltinSubagentSelection.validNames)")
        }
        return selection
    }
}

/// `kwwk` — coding-agent CLI entry point. Flags are declared on
/// `KwwkCommand`; `kwwk --help` prints them.
///
/// `--context-1m` adds `context-1m-2025-08-07` to the `anthropic-beta` header,
/// so it only works for accounts with long-context billing enabled.
@main
struct KwwkCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        // Keep provider error bodies verbatim next to the logins, so a
        // refusal can be read again and become a fixture
        // (`KWWK_PROVIDER_ERROR_DIR` redirects it, `off` disables it).
        ProviderErrorCapture.enable(
            directory: OAuthStore.defaultURL().deletingLastPathComponent().appendingPathComponent("provider-errors")
        )
        // `kwwk mcp` parses its own arguments: a stdio server's flags (after
        // `--`) must never be read as kwwk's global options.
        if args.first == "mcp" {
            Foundation.exit(await KWWK.runMCPCommand(Array(args.dropFirst())))
        }
        let command: KwwkCommand
        do {
            command = try KwwkCommand.parse(args)
        } catch {
            // Help is a clean exit to stdout; any other parse error is a bad
            // invocation (exit 2, as `-p` documents).
            guard KwwkCommand.exitCode(for: error) == .success else {
                FileHandle.standardError.write(Data((KwwkCommand.fullMessage(for: error) + "\n").utf8))
                Foundation.exit(2)
            }
            print(KwwkCommand.fullMessage(for: error))
            Foundation.exit(0)
        }

        let thinkingLevel = command.thinking
        let builtinSubagents = command.builtinSubagents(args)
        let resume = command.resume(args)

        if command.selfTest {
            runSelfTest()
        } else if command.printMode {
            await runPrint(
                rest: command.prompt,
                thinkingLevel: thinkingLevel,
                modelOverride: command.model,
                context1m: command.context1m,
                builtinSubagents: builtinSubagents,
                resume: resume
            )
        } else {
            await runOrExit { try await KWWK.runCodingTUI(
                builtinSubagents: builtinSubagents,
                idleCompact: command.idleCompact,
                thinkingLevel: thinkingLevel,
                modelOverride: command.model,
                context1m: command.context1m,
                resume: resume
            ) }
        }
    }

    /// Exercise the SwiftPM resource catalogs through `Bundle.module` without
    /// resolving credentials or constructing a provider. Homebrew runs this
    /// against the installed executable so a bottle missing its sidecar
    /// `kwwk_KWWKAI.bundle` fails before publication.
    static func runSelfTest() -> Never {
        guard !ModelsCatalog.models(for: "anthropic").isEmpty else {
            FileHandle.standardError.write(Data(
                "kwwk: self-test failed: primary model catalog is empty\n".utf8
            ))
            Foundation.exit(1)
        }
        guard ModelsCatalog.model(provider: "cursor", id: "default") != nil else {
            FileHandle.standardError.write(Data(
                "kwwk: self-test failed: Cursor model catalog is missing\n".utf8
            ))
            Foundation.exit(1)
        }
        guard ModelsCatalog.model(provider: "devin", id: DevinModels.defaultModelId) != nil else {
            FileHandle.standardError.write(Data(
                "kwwk: self-test failed: Devin model catalog is missing\n".utf8
            ))
            Foundation.exit(1)
        }
        guard ModelsCatalog.model(provider: "kiro", id: KiroModels.defaultModelId) != nil else {
            FileHandle.standardError.write(Data(
                "kwwk: self-test failed: Kiro model catalog is missing\n".utf8
            ))
            Foundation.exit(1)
        }
        guard ModelsCatalog.model(provider: "antigravity", id: AntigravityModels.defaultModelId) != nil else {
            FileHandle.standardError.write(Data(
                "kwwk: self-test failed: Antigravity model catalog is missing\n".utf8
            ))
            Foundation.exit(1)
        }
        guard ModelsCatalog.model(provider: "qoder", id: QoderModels.defaultModelId) != nil else {
            FileHandle.standardError.write(Data(
                "kwwk: self-test failed: Qoder model catalog is missing\n".utf8
            ))
            Foundation.exit(1)
        }
        print("resources: ok")
        Foundation.exit(0)
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
        resume: SessionResume
    ) async {
        // A picker can't run under -p (non-interactive). Use --session or
        // --continue instead.
        if resume == .pickInteractive {
            FileHandle.standardError.write(Data(
                "kwwk: --resume requires an interactive terminal; use --continue or --session <id> with -p\n".utf8
            ))
            Foundation.exit(2)
        }

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

        await runOrExit { Foundation.exit(try await KWWK.runHeadless(
            prompt: prompt,
            builtinSubagents: builtinSubagents,
            thinkingLevel: thinkingLevel,
            modelOverride: modelOverride,
            context1m: context1m,
            resume: resume
        )) }
    }

    /// Run the async body and surface any thrown error on stderr before
    /// exiting with a non-zero code. Swift async `@main` has no throwing
    /// overload, so this is the workaround.
    static func runOrExit(_ body: @Sendable () async throws -> Void) async {
        do {
            try await body()
        } catch {
            let msg = error.displayDescription
            FileHandle.standardError.write(Data("kwwk: \(msg)\n".utf8))
            Foundation.exit(1)
        }
    }
}
