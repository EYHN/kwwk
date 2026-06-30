import Foundation

enum Style {
    static let reset = "\u{1B}[0m"
    static let dim = "\u{1B}[2m"
    static let bold = "\u{1B}[1m"
    static let yellow = "\u{1B}[33m"
    static let red = "\u{1B}[31m"

    static func dimmed(_ s: String) -> String { "\(dim)\(s)\(reset)" }
    static func header(_ s: String) -> String { Theme.accentText(s, bold: true) }
    static func user(_ s: String) -> String { "\(bold)\(s)\(reset)" }
    static func prompt(_ s: String) -> String { Theme.accentText(s, bold: true) }
    static func tool(_ s: String) -> String { Theme.accentText(s, bold: false) }
    static func running(_ s: String) -> String { "\(yellow)\(s)\(reset)" }
    static func error(_ s: String) -> String { "\(red)\(s)\(reset)" }
}
