import Foundation
import KWWKAgent
import KWWKAI

public struct ComputerUseModelRouting: Sendable {
    public var textModel: Model
    public var imageModel: Model
    public var textThinkingLevel: ThinkingLevel
    public var imageThinkingLevel: ThinkingLevel

    public init(textModel: Model, imageModel: Model, thinkingLevel: ThinkingLevel = .minimal) {
        self.textModel = textModel
        self.imageModel = imageModel
        self.textThinkingLevel = thinkingLevel
        self.imageThinkingLevel = thinkingLevel
    }

    public init(
        textModel: Model,
        textThinkingLevel: ThinkingLevel,
        imageModel: Model,
        imageThinkingLevel: ThinkingLevel
    ) {
        self.textModel = textModel
        self.textThinkingLevel = textThinkingLevel
        self.imageModel = imageModel
        self.imageThinkingLevel = imageThinkingLevel
    }
}

public enum ComputerUseAgent {
    private static let availableActions = [
        "list-apps",
        "open-app",
        "list-windows",
        "get-app-state",
        "click",
        "type-text",
        "set-value",
        "press-key",
        "scroll",
        "perform-secondary-action",
        "drag",
    ]

    public static let systemPrompt = """
    You control local macOS apps through the computer_use tool.

    Use the startup inventory below to choose app names, bundle ids, and window_title values.
    Use open-app when the target app is installed but not running.
    Begin by calling get-app-state every turn you want to use Computer Use; it returns app_state and snapshot_id for subsequent actions.
    After navigation changes a window title, omit window_title unless the user explicitly asked for a specific window.
    Computer Use actions run in the background; avoid disrupting the user's active app, clipboard, or foreground workflow.
    Prefer accessibility: call get-app-state with include_screenshot=false first, and use element_index whenever possible.
    Element indexes are the sequential integers from the latest accessibility tree and become stale after navigation, scrolling, or layout changes.
    Request screenshots only when accessibility is missing/incomplete, when the target is canvas/WebGL/game-like, or when the task truly requires visual/pixel inspection.
    For list traversal tasks, keep an explicit visited set from stable labels/descriptions, use the harness candidate targets and diffs after every action, and scroll only after all relevant visible rows are visited.
    If a scroll result says there was no observable state change, do not infer that the list ended by itself; try a different scrollable container or keyboard/list navigation if more items are expected.
    If the user asks to click, open, inspect, or traverse items, do not count a visible row as visited until a successful action result shows you actually selected/opened it.
    After each action, use the action result or fetch the latest state to verify the UI changed as expected.
    Ask the user before destructive or externally visible actions such as sending, deleting, purchasing, or posting.
    """

    public static func startupInventoryText() -> String {
        ComputerUseCore.startupInventoryText()
    }

    public static func systemPromptWithStartupInventory() -> String {
        systemPromptWithStartupInventory(inventory: startupInventoryText())
    }

    public static func systemPromptWithStartupInventory(inventory: String) -> String {
        guard inventory.isEmpty == false else {
            return systemPrompt
        }
        return "\(systemPrompt)\n\n\(inventory)"
    }

    public static func makeTool(
        session: ComputerUseSession,
        modelRouting: ComputerUseModelRouting? = nil,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) -> AgentTool {
        AgentTool(
            name: "computer_use",
            label: "Computer Use",
            description: """
            Control local macOS applications using accessibility snapshots and background input.

            Input object: {"action":"<name>","args":{...},"thinking":"optional short note"}

            Actions:
            - list-apps: args {}; returns currently running apps plus apps used in the last 14 days, with frontmost/running/last-used/uses flags when available
            - open-app: args {"app": string}; launches an app by name, bundle id, or .app path if needed, without activating it, and returns the app-list line for the app
            - list-windows: args {"app": string}
            - get-app-state: args {"app": string, "window_title"?: string, "include_screenshot"?: boolean}; returns app_state and snapshot_id; default include_screenshot=false
            - click: args {"snapshot_id": string, "element_index"?: integer, "x"?: number, "y"?: number, "include_screenshot_after"?: boolean}; use element_index or x/y
            - type-text: args {"snapshot_id": string, "text": string, "element_index"?: integer, "include_screenshot_after"?: boolean}
            - set-value: args {"snapshot_id": string, "element_index": integer, "value": string, "include_screenshot_after"?: boolean}
            - press-key: args {"snapshot_id": string, "key": string, "include_screenshot_after"?: boolean}
            - scroll: args {"snapshot_id": string, "element_index": integer, "direction": "up"|"down"|"left"|"right", "pages"?: number, "include_screenshot_after"?: boolean}; pages is a viewport-relative amount and supports fractions
            - perform-secondary-action: args {"snapshot_id": string, "element_index": integer, "action": string, "include_screenshot_after"?: boolean}
            - drag: args {"snapshot_id": string, "from_x": number, "from_y": number, "to_x": number, "to_y": number, "include_screenshot_after"?: boolean}

            Examples:
            - {"action":"get-app-state","args":{"app":"Slack","window_title":"Slack","include_screenshot":false}}
            - {"action":"click","args":{"snapshot_id":"...","element_index":12}}
            - {"action":"type-text","args":{"snapshot_id":"...","text":"hello"}}
            """,
            parameters: [
                "type": "object",
                "properties": [:],
                "additionalProperties": true,
            ],
            executeWithRuntime: { _, args, _, _, runtime in
                try await execute(
                    args: args,
                    runtime: runtime,
                    modelRouting: modelRouting,
                    screenshotCompression: screenshotCompression,
                    session: session
                )
            }
        )
    }

    private static func execute(
        args raw: JSONValue,
        runtime: AgentToolRuntime,
        modelRouting: ComputerUseModelRouting?,
        screenshotCompression: ComputerUseScreenshotCompression,
        session: ComputerUseSession
    ) async throws -> AgentToolResult {
        guard case let .object(payload) = raw else {
            throw ComputerUseError.invalidArgument("tool payload must be an object")
        }
        guard case let .string(action) = payload["action"] ?? .null else {
            return actionHelpResult(reason: "Missing required field 'action'.")
        }
        guard availableActions.contains(action) else {
            return actionHelpResult(reason: "Unknown action '\(action)'.")
        }
        let actionArgs: [String: JSONValue]
        if case let .object(dict) = payload["args"] ?? .object([:]) {
            actionArgs = dict
        } else {
            throw ComputerUseError.invalidArgument("args must be an object")
        }

        let output: ComputerUseCommandOutput
        do {
            output = try await executeAction(
                action: action,
                args: actionArgs,
                screenshotCompression: screenshotCompression,
                session: session
            )
        } catch let error as ComputerUseError {
            if case .staleState = error,
               let recovery = try? staleStateRecoveryOutput(
                   args: actionArgs,
                   screenshotCompression: screenshotCompression
               ) {
                return toolResult(
                    action: action,
                    output: recovery,
                    runtime: runtime,
                    modelRouting: modelRouting,
                    session: session
                )
            }
            throw error
        }
        if let actionDescription = actionDescription(action: action, args: actionArgs) {
            session.recordAction(actionDescription)
        }

        return toolResult(
            action: action,
            output: output,
            runtime: runtime,
            modelRouting: modelRouting,
            session: session
        )
    }

    private static func toolResult(
        action: String,
        output: ComputerUseCommandOutput,
        runtime: AgentToolRuntime,
        modelRouting: ComputerUseModelRouting?,
        session: ComputerUseSession
    ) -> AgentToolResult {
        let annotatedOutput = session.annotateObservation(output)

        var blocks: [ToolResultBlock] = [.text(TextContent(text: annotatedOutput.text))]
        if let path = annotatedOutput.metadata?.screenshotPath,
           let image = toolResultImage(at: path) {
            blocks.append(.image(image))
        }

        if let modelRouting {
            let nextUsesImage = blocks.contains(where: { block in
                if case .image = block { return true }
                return false
            })
            runtime.loop?.use(
                model: nextUsesImage ? modelRouting.imageModel : modelRouting.textModel,
                thinkingLevel: nextUsesImage ? modelRouting.imageThinkingLevel : modelRouting.textThinkingLevel
            )
        }

        return AgentToolResult(
            content: blocks,
            details: details(for: annotatedOutput.metadata),
            uiDisplay: [uiSummary(action: action, output: annotatedOutput)]
        )
    }

    private static func staleStateRecoveryOutput(
        args: [String: JSONValue],
        screenshotCompression: ComputerUseScreenshotCompression
    ) throws -> ComputerUseCommandOutput {
        guard let snapshotID = optionalString(args, "snapshot_id") else {
            throw ComputerUseError.invalidArgument("snapshot_id is required for stale state recovery")
        }
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let snapshot = try ComputerUseCore.captureSnapshot(
            metadata: metadata,
            includeScreenshot: false,
            screenshotCompression: screenshotCompression
        )
        let latest = try ComputerUseCore.persistAndFormat(snapshot: snapshot)
        return ComputerUseCommandOutput(
            text: """
            The element ID is no longer valid. Try to get the on-screen content again and use the latest element indexes below.

            \(latest.text)
            """,
            metadata: latest.metadata
        )
    }

    private static func actionHelpResult(reason: String) -> AgentToolResult {
        AgentToolResult(
            content: [.text(TextContent(text: actionHelpText(reason: reason)))],
            uiDisplay: ["invalid action: available actions returned"]
        )
    }

    private static func actionHelpText(reason: String) -> String {
        """
        Invalid computer_use input: \(reason)

        Tool input must be an object:
        {"action":"<action-name>","args":{...},"thinking":"optional short note"}

        Available actions:
        - list-apps
        - open-app
        - list-windows
        - get-app-state
        - click
        - type-text
        - set-value
        - press-key
        - scroll
        - perform-secondary-action
        - drag

        Minimal examples:
        - {"action":"list-apps","args":{}}
        - {"action":"open-app","args":{"app":"Slack"}}
        - {"action":"list-windows","args":{"app":"Slack"}}
        - {"action":"get-app-state","args":{"app":"Slack","include_screenshot":false}}
        - {"action":"click","args":{"snapshot_id":"...","element_index":12}}
        - {"action":"press-key","args":{"snapshot_id":"...","key":"cmd+f"}}
        """
    }

    private static func toolResultImage(at path: String) -> ImageContent? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ImageContent(data: data.base64EncodedString(), mimeType: mimeType(for: url))
    }

    private static func actionDescription(
        action: String,
        args: [String: JSONValue]
    ) -> String? {
        guard let snapshotID = optionalString(args, "snapshot_id"),
              snapshotID.isEmpty == false
        else {
            return nil
        }

        if let elementIndex = optionalInt(args, "element_index"),
           let metadata = try? ComputerUseSnapshotStore.load(snapshotID: snapshotID),
           metadata.nodeSignatures.indices.contains(elementIndex) {
            let signature = metadata.nodeSignatures[elementIndex]
            let label = harnessDisplayLabel(for: signature)
            let role = harnessRoleName(signature.role)
            if label.isEmpty == false {
                return "\(action) element_index=\(elementIndex) \(role) \"\(harnessTruncate(label, maxLength: 140))\""
            }
            return "\(action) element_index=\(elementIndex) \(role)"
        }

        if let x = optionalDouble(args, "x"),
           let y = optionalDouble(args, "y") {
            return "\(action) coordinate=(\(Int(x)),\(Int(y))) snapshot=\(snapshotID)"
        }

        if action == "press-key",
           let key = optionalString(args, "key") {
            return "\(action) key=\"\(key)\" snapshot=\(snapshotID)"
        }

        return "\(action) snapshot=\(snapshotID)"
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    public static func executeAction(
        action: String,
        args: [String: JSONValue],
        screenshotCompression: ComputerUseScreenshotCompression,
        session: ComputerUseSession? = nil
    ) async throws -> ComputerUseCommandOutput {
        switch action {
        case "list-apps":
            return ComputerUseAction.listApps()
        case "open-app":
            return try await ComputerUseAction.openApp(
                appIdentifier: try requiredString(args, "app")
            )
        case "list-windows":
            return try ComputerUseAction.listWindows(
                appIdentifier: try requiredString(args, "app")
            )
        case "get-app-state":
            return try await withComputerUseSession(session) { _ in
                try ComputerUseAction.getAppState(
                    appIdentifier: try requiredString(args, "app"),
                    windowTitle: optionalString(args, "window_title"),
                    includeScreenshot: optionalBool(args, "include_screenshot") ?? false,
                    screenshotCompression: screenshotCompression
                )
            }
        case "click":
            return try await withComputerUseSession(session) { session in
                try await ComputerUseAction.click(
                    snapshotID: try requiredString(args, "snapshot_id"),
                    elementIndex: optionalInt(args, "element_index"),
                    x: optionalDouble(args, "x"),
                    y: optionalDouble(args, "y"),
                    includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        case "type-text":
            return try await withComputerUseSession(session) { session in
                try await ComputerUseAction.typeText(
                    snapshotID: try requiredString(args, "snapshot_id"),
                    text: try requiredString(args, "text"),
                    elementIndex: optionalInt(args, "element_index"),
                    includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        case "set-value":
            return try await withComputerUseSession(session) { session in
                try await ComputerUseAction.setValue(
                    snapshotID: try requiredString(args, "snapshot_id"),
                    elementIndex: try requiredInt(args, "element_index"),
                    value: try requiredString(args, "value"),
                    includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        case "press-key":
            return try await withComputerUseSession(session) { session in
                try await ComputerUseAction.pressKey(
                    snapshotID: try requiredString(args, "snapshot_id"),
                    key: try requiredString(args, "key"),
                    includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        case "scroll":
            return try await withComputerUseSession(session) { session in
                try await ComputerUseAction.scroll(
                    snapshotID: try requiredString(args, "snapshot_id"),
                    elementIndex: try requiredInt(args, "element_index"),
                    direction: try requiredString(args, "direction"),
                    pages: optionalDouble(args, "pages") ?? 1,
                    includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        case "perform-secondary-action":
            return try await withComputerUseSession(session) { session in
                try await ComputerUseAction.performSecondaryAction(
                    snapshotID: try requiredString(args, "snapshot_id"),
                    elementIndex: try requiredInt(args, "element_index"),
                    action: try requiredString(args, "action"),
                    includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        case "drag":
            return try await withComputerUseSession(session) { session in
                try await ComputerUseAction.drag(
                    snapshotID: try requiredString(args, "snapshot_id"),
                    fromX: try requiredDouble(args, "from_x"),
                    fromY: try requiredDouble(args, "from_y"),
                    toX: try requiredDouble(args, "to_x"),
                    toY: try requiredDouble(args, "to_y"),
                    includeScreenshotAfter: optionalBool(args, "include_screenshot_after") ?? false,
                    session: session,
                    screenshotCompression: screenshotCompression
                )
            }
        default:
            throw ComputerUseError.invalidArgument("unknown action \(action)")
        }
    }

    private static func withComputerUseSession<T>(
        _ provided: ComputerUseSession?,
        _ body: (ComputerUseSession) async throws -> T
    ) async throws -> T {
        if let provided {
            return try await body(provided)
        }

        let session = ComputerUseSession()
        defer {
            session.finish()
        }
        return try await body(session)
    }

    private static func details(for metadata: ComputerUseSnapshotMetadata?) -> JSONValue? {
        guard let metadata else { return nil }
        var object: [String: JSONValue] = [
            "snapshot_id": .string(metadata.id),
            "app": .string(metadata.appName),
            "bundle_id": .string(metadata.bundleID),
            "pid": .int(Int(metadata.pid)),
            "window_title": .string(metadata.windowTitle),
            "window_id": .int(metadata.windowID),
        ]
        if let path = metadata.screenshotPath {
            object["screenshot_path"] = .string(path)
        }
        if let size = metadata.screenshotSize {
            object["screenshot_size"] = .object([
                "width": .int(Int(size.width)),
                "height": .int(Int(size.height)),
            ])
        }
        return .object(object)
    }

    private static func uiSummary(action: String, output: ComputerUseCommandOutput) -> String {
        if let metadata = output.metadata {
            var suffix = "snapshot \(metadata.id)"
            if metadata.screenshotPath != nil {
                suffix += " + screenshot"
            }
            return "\(action): \(suffix)"
        }
        let lineCount = output.text.split(separator: "\n").count
        return "\(action): \(lineCount) lines"
    }

    private static func requiredString(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = optionalString(args, key), value.isEmpty == false else {
            throw ComputerUseError.invalidArgument("\(key) is required")
        }
        return value
    }

    private static func optionalString(_ args: [String: JSONValue], _ key: String) -> String? {
        guard case let .string(value) = args[key] ?? .null else {
            return nil
        }
        return value
    }

    private static func requiredInt(_ args: [String: JSONValue], _ key: String) throws -> Int {
        guard let value = optionalInt(args, key) else {
            throw ComputerUseError.invalidArgument("\(key) is required")
        }
        return value
    }

    private static func optionalInt(_ args: [String: JSONValue], _ key: String) -> Int? {
        switch args[key] ?? .null {
        case let .int(value):
            return value
        case let .double(value):
            return Int(value)
        case let .string(value):
            return Int(value)
        default:
            return nil
        }
    }

    private static func requiredDouble(_ args: [String: JSONValue], _ key: String) throws -> Double {
        guard let value = optionalDouble(args, key) else {
            throw ComputerUseError.invalidArgument("\(key) is required")
        }
        return value
    }

    private static func optionalDouble(_ args: [String: JSONValue], _ key: String) -> Double? {
        switch args[key] ?? .null {
        case let .int(value):
            return Double(value)
        case let .double(value):
            return value
        case let .string(value):
            return Double(value)
        default:
            return nil
        }
    }

    private static func optionalBool(_ args: [String: JSONValue], _ key: String) -> Bool? {
        switch args[key] ?? .null {
        case let .bool(value):
            return value
        case let .string(value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
