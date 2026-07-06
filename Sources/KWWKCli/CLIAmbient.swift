import Foundation
import KWWKAgent

func cliShellPath(environment: [String: String]) -> String {
    guard let shell = environment["SHELL"],
          shell.hasPrefix("/"),
          FileManager.default.isExecutableFile(atPath: shell) else {
        return kwwkDefaultShellPath
    }
    return shell
}

func cliTmuxManager(environment: [String: String]) throws -> TmuxSessionManager {
    guard let tmuxPath = executableNamed("tmux", environment: environment) else {
        throw CLIAmbientError.tmuxNotFound
    }
    return TmuxSessionManager(tmuxPath: tmuxPath, environment: environment)
}

private func executableNamed(_ name: String, environment: [String: String]) -> String? {
    let path = environment["PATH"] ?? ""
    for dir in path.split(separator: ":").map(String.init) {
        let candidate = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

enum CLIAmbientError: Error, LocalizedError {
    case tmuxNotFound

    var errorDescription: String? {
        switch self {
        case .tmuxNotFound:
            return "tmux tools were requested, but no executable named `tmux` was found in PATH."
        }
    }
}
