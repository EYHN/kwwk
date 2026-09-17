import KWWKAI

struct ProviderContextOverflow: Error, Sendable {
    let assistant: AssistantMessage
    let emittedStart: Bool
}
