import Foundation

enum ProviderImageBudget {
    static let defaultLimit = 5

    private static let limits: [String: Int] = [
        "anthropic": 90,
        "amazon-bedrock": 90,
        "openai": 200,
        "openai-codex": 200,
        "chatgpt-codex": 200,
        "google": 200,
        "google-vertex": 200,
        "openrouter": 90,
    ]

    private static let imageOmissionText = "[image omitted: provider image limit]"

    private static let userImageOmission = UserBlock.text(
        TextContent(text: imageOmissionText)
    )

    private static let toolResultImageOmission = ToolResultBlock.text(
        TextContent(text: imageOmissionText)
    )

    /// Devin refuses a request over 32 MiB and relays each upstream's image
    /// rules. kwwk has no byte clamp, so 40 images at the 500 KiB resize
    /// target (27.3 MB base64) stay under it. Claude rejects edges over
    /// 3,000 px past 20 images, and Devin relays images as sent. Measured by
    /// oh-my-pi (can1357/oh-my-pi#19619).
    static let devinLimit = 40
    static let devinClaudeLimit = 20

    static func limit(for provider: String) -> Int {
        limits[provider] ?? defaultLimit
    }

    static func limit(for model: Model) -> Int {
        if model.provider == "devin" {
            return model.id.hasPrefix("claude-") ? devinClaudeLimit : devinLimit
        }
        return limit(for: model.provider)
    }

    static func clamp(_ context: Context, for model: Model) -> Context {
        guard model.input.contains(.image) else { return context }

        let imageCount = countImages(in: context.messages)
        var remainingImageCountToDrop = imageCount - limit(for: model)
        guard remainingImageCountToDrop > 0 else { return context }

        var clamped = context
        clamped.messages = context.messages.map { message in
            clamp(message, remainingImageCountToDrop: &remainingImageCountToDrop)
        }
        return clamped
    }

    private static func countImages(in messages: [Message]) -> Int {
        var count = 0
        for message in messages {
            switch message {
            case .user(let user):
                count += user.content.reduce(into: 0) { count, block in
                    if case .image = block { count += 1 }
                }
            case .toolResult(let result):
                count += result.content.reduce(into: 0) { count, block in
                    if case .image = block { count += 1 }
                }
            case .assistant, .system:
                break
            }
        }
        return count
    }

    private static func clamp(
        _ message: Message,
        remainingImageCountToDrop: inout Int
    ) -> Message {
        guard remainingImageCountToDrop > 0 else { return message }

        switch message {
        case .user(var user):
            let content = droppingOldestImages(
                from: user.content,
                remainingImageCountToDrop: &remainingImageCountToDrop
            )
            guard content.count != user.content.count else { return message }
            user.content = content.isEmpty ? [userImageOmission] : content
            return .user(user)
        case .toolResult(var result):
            let content = droppingOldestImages(
                from: result.content,
                remainingImageCountToDrop: &remainingImageCountToDrop
            )
            guard content.count != result.content.count else { return message }
            result.content = content.isEmpty ? [toolResultImageOmission] : content
            return .toolResult(result)
        case .assistant, .system:
            return message
        }
    }

    private static func droppingOldestImages(
        from content: [UserBlock],
        remainingImageCountToDrop: inout Int
    ) -> [UserBlock] {
        content.filter { block in
            guard case .image = block, remainingImageCountToDrop > 0 else { return true }
            remainingImageCountToDrop -= 1
            return false
        }
    }

    private static func droppingOldestImages(
        from content: [ToolResultBlock],
        remainingImageCountToDrop: inout Int
    ) -> [ToolResultBlock] {
        content.filter { block in
            guard case .image = block, remainingImageCountToDrop > 0 else { return true }
            remainingImageCountToDrop -= 1
            return false
        }
    }
}
