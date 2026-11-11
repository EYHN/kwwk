import Foundation
import KWWKAgent

/// Environment variable that moves the CLI's session transcripts (and their
/// `subagents/` directory) out of `~/.kwwk/sessions`. `--session-dir` sets it.
let kwwkSessionDirEnvironmentKey = "KWWK_SESSION_DIR"

/// Where the CLI keeps session transcripts: `KWWK_SESSION_DIR` when set to a
/// non-empty path (relative paths resolve against the working directory),
/// else `~/.kwwk/sessions`.
func cliSessionDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    cwd: String = FileManager.default.currentDirectoryPath
) -> URL {
    guard let raw = environment[kwwkSessionDirEnvironmentKey], !raw.isEmpty else {
        return SessionStore.defaultDirectory()
    }
    let expanded = (raw as NSString).expandingTildeInPath
    let path = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
}

func cliShellPath(environment: [String: String]) -> String {
    guard let shell = environment["SHELL"],
          shell.hasPrefix("/"),
          FileManager.default.isExecutableFile(atPath: shell) else {
        return kwwkDefaultShellPath
    }
    return shell
}

/// The user's home directory. iOS Foundation has no
/// `homeDirectoryForCurrentUser`; `NSHomeDirectory()` is how the rest of the
/// package reaches the same path there (`SessionStore.defaultDirectory`).
func cliHomeDirectory() -> String {
    #if targetEnvironment(macCatalyst) || os(iOS)
    return NSHomeDirectory()
    #else
    return FileManager.default.homeDirectoryForCurrentUser.path
    #endif
}
