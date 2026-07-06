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
