import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// Agent commands must start from plain Unix signal state, whatever the thread
/// that spawns them carries. On Linux libdispatch blocks every asynchronous
/// signal on its worker threads, and a host may ignore SIGTERM/SIGPIPE for
/// itself; without an explicit reset both leak into the command through exec.
/// Each test reproduces that host state — a thread with every signal blocked,
/// SIGTERM and SIGPIPE ignored process-wide — and spawns through the runner.
@Suite("Spawned command signal state", .serialized)
struct SpawnSignalStateTests {
    private struct Run: Sendable {
        var outcome: BackgroundTaskOutcome
        var output: String
        var elapsed: TimeInterval
    }

    /// Run `command` through `BashRunnerImpl` on a dedicated thread whose mask
    /// blocks every signal, while the process ignores SIGTERM and SIGPIPE.
    private func runFromHostileThread(_ command: String) async throws -> Run {
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kw-sigstate-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: outputFile) }

        var ignore = sigaction()
        #if canImport(Darwin)
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        #else
        ignore.__sigaction_handler.sa_handler = SIG_IGN
        #endif
        sigemptyset(&ignore.sa_mask)
        var previousTerm = sigaction()
        var previousPipe = sigaction()
        sigaction(SIGTERM, &ignore, &previousTerm)
        sigaction(SIGPIPE, &ignore, &previousPipe)
        defer {
            sigaction(SIGTERM, &previousTerm, nil)
            sigaction(SIGPIPE, &previousPipe, nil)
        }

        let start = Date()
        let outcome: BackgroundTaskOutcome = await withCheckedContinuation { continuation in
            let thread = Thread {
                var all = sigset_t()
                sigfillset(&all)
                pthread_sigmask(SIG_BLOCK, &all, nil)
                let outcome = BashRunnerImpl.run(
                    command: command,
                    workDir: nil,
                    shellPath: kwwkDefaultShellPath,
                    environment: ProcessInfo.processInfo.environment,
                    extraEnv: [:],
                    outputFile: outputFile,
                    cancellation: CancellationHandle()
                )
                continuation.resume(returning: outcome)
            }
            thread.start()
        }
        let elapsed = Date().timeIntervalSince(start)
        let output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
        return Run(outcome: outcome, output: output, elapsed: elapsed)
    }

    private func exitCode(_ outcome: BackgroundTaskOutcome) -> Int? {
        guard case .object(let details) = outcome.details ?? .null,
              case .int(let code) = details["exitCode"] ?? .null else { return nil }
        return code
    }

    @Test("kill -TERM $$ ends the command")
    func selfTermKills() async throws {
        // A command that survived its own SIGTERM sleeps 30 s, so the bound
        // only has to sit under that; a loaded CI runner took 5.3 s once.
        let run = try await runFromHostileThread("kill -TERM $$; sleep 30; echo survived")
        #expect(!run.output.contains("survived"))
        #expect(run.outcome.summary == "exit \(SIGTERM) (signal)")
        #expect(exitCode(run.outcome) == Int(SIGTERM))
        #expect(run.elapsed < 15)
    }

    @Test("timeout 1 sleep 30 returns promptly")
    func timeoutFires() async throws {
        // coreutils `timeout` where there is one (macOS ships none), then the
        // same thing by hand — SIGTERM a child after a second — because some
        // `timeout` builds reset the child's signals themselves.
        let command = """
        if command -v timeout >/dev/null 2>&1; then
            timeout 1 sleep 30
            echo "timeout=$?"
        fi
        sleep 30 & child=$!
        (sleep 1; kill -TERM "$child") &
        wait "$child"
        echo "kill=$?"
        """
        let run = try await runFromHostileThread(command)
        #expect(run.elapsed < 15, "took \(run.elapsed)s")
        #expect(run.output.contains("kill=143"), "\(run.output)")
        if run.output.contains("timeout=") {
            #expect(run.output.contains("timeout=124"), "\(run.output)")
        }
    }

    @Test("A closed pipe ends the writer with SIGPIPE")
    func sigpipeIsDefault() async throws {
        let run = try await runFromHostileThread("yes | head -n 1 >/dev/null")
        // With SIGPIPE ignored `yes` would see EPIPE and print an error;
        // with the default it dies quietly.
        #expect(!run.output.lowercased().contains("broken pipe"), "\(run.output)")
        #expect(run.elapsed < 15)
    }
}
