import Foundation

enum Style {
    static let reset = "\u{1B}[0m"
    static let dim = "\u{1B}[2m"
    static let bold = "\u{1B}[1m"
    static let green = "\u{1B}[32m"
    static let yellow = "\u{1B}[33m"
    static let red = "\u{1B}[31m"
    static let cyan = "\u{1B}[36m"
    static let magenta = "\u{1B}[35m"
    static let gray = "\u{1B}[90m"

    static func badge(_ s: String, fg: Int = 255, bg: Int) -> String {
        "\u{1B}[38;5;\(fg);48;5;\(bg)m \(s) \(reset)"
    }

    static func dimmed(_ s: String) -> String { "\(dim)\(s)\(reset)" }
    static func header(_ s: String) -> String { "\(bold)\(magenta)\(s)\(reset)" }
    static func user(_ s: String) -> String { "\(bold)\(s)\(reset)" }
    static func prompt(_ s: String) -> String { "\(bold)\(green)\(s)\(reset)" }
    static func tool(_ s: String) -> String { "\(cyan)\(s)\(reset)" }
    static func running(_ s: String) -> String { "\(yellow)\(s)\(reset)" }
    static func error(_ s: String) -> String { "\(red)\(s)\(reset)" }
}
