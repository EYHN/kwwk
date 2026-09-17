import Foundation
import KWWKAI

enum ContextLimitClassifier {
    static func isInputOverflow(_ message: String) -> Bool {
        ProviderContextLimit.isInputOverflow(message)
    }
}

struct ProviderContextOverflow: Error, Sendable {
    let assistant: AssistantMessage
    let emittedStart: Bool
}
