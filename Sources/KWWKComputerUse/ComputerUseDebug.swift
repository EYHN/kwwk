import Foundation

public enum ComputerUseDebug {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var focusEnabled = environmentBool("KWWK_CU_DEBUG_FOCUS")
    }

    private static let state = State()

    public static var focusEnabled: Bool {
        get {
            state.lock.withLock { state.focusEnabled }
        }
        set {
            state.lock.withLock { state.focusEnabled = newValue }
        }
    }
}

private func environmentBool(_ key: String) -> Bool {
    guard let raw = ProcessInfo.processInfo.environment[key] else {
        return false
    }
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on":
        return true
    default:
        return false
    }
}
