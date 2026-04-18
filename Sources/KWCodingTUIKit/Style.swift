import Foundation

public enum Style {
    public static let reset = "\u{1B}[0m"
    public static let dim = "\u{1B}[2m"
    public static let bold = "\u{1B}[1m"
    public static let green = "\u{1B}[32m"
    public static let yellow = "\u{1B}[33m"
    public static let red = "\u{1B}[31m"
    public static let cyan = "\u{1B}[36m"
    public static let magenta = "\u{1B}[35m"
    public static let gray = "\u{1B}[90m"

    public static func dimmed(_ s: String) -> String { "\(dim)\(s)\(reset)" }
    public static func header(_ s: String) -> String { "\(bold)\(magenta)\(s)\(reset)" }
    public static func user(_ s: String) -> String { "\(bold)\(s)\(reset)" }
    public static func prompt(_ s: String) -> String { "\(bold)\(green)\(s)\(reset)" }
    public static func tool(_ s: String) -> String { "\(cyan)\(s)\(reset)" }
    public static func running(_ s: String) -> String { "\(yellow)\(s)\(reset)" }
    public static func error(_ s: String) -> String { "\(red)\(s)\(reset)" }
}
