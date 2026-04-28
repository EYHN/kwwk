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
/// `--thinking <off|minimal|low|medium|high|xhigh>` is a global flag that
/// applies to both the TUI and headless modes. Default is `medium`.
@main
struct KwwkCLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let thinkingLevel: ThinkingLevel
        (args, thinkingLevel) = extractThinking(args)

        let subcommand = args.first

        switch subcommand {
        case nil:
            await runOrExit { try await KWWK.runCodingTUI(thinkingLevel: thinkingLevel) }
        case "login":
            await runOrExit { try await KWWK.runLogin() }
        case "-p", "--print":
            await runPrint(rest: Array(args.dropFirst()), thinkingLevel: thinkingLevel)
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

    /// Handle `-p` / `--print`. Everything after the flag is joined into
    /// the prompt; if nothing is supplied (or the token is a bare `-`),
    /// the prompt is read from stdin until EOF.
    ///
    /// `-p` is quiet by design: on a successful run stdout carries only
    /// the assistant reply and stderr stays empty. Failures (no prompt,
    /// missing credentials, stream error) still print a one-line message
    /// to stderr so a non-zero exit isn't mysterious. Exit codes: 2 = bad
    /// invocation, 1 = runtime/auth failure, 0 = success.
    static func runPrint(rest: [String], thinkingLevel: ThinkingLevel) async {
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
            let code = try await KWWK.runHeadless(prompt: prompt, thinkingLevel: thinkingLevel)
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
