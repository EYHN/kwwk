import ApplicationServices
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import KWWKAgent
import KWWKAI
import KWWKCli
import KWWKComputerUse

@main
struct KwwkComputerUseCLI {
    static func main() async {
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        let code = await runTopLevel(
            arguments: rawArguments,
            promptOverride: nil
        )
        Foundation.exit(code)
    }

    private static func runTopLevel(
        arguments: [String],
        promptOverride: String?
    ) async -> Int32 {
        do {
            let invocation = try parseInvocation(arguments)
            if invocation.showHelp {
                printUsage()
                return 0
            }
            if invocation.listModels {
                try await printAvailableModels()
                return 0
            }

            let prompt = try promptOverride ?? readPrompt(invocation.promptParts)
            promptForAccessibilityIfNeeded()
            return try await run(prompt: prompt, invocation: invocation)
        } catch let error as InvocationError {
            FileHandle.standardError.write(Data("kwwk-cu: \(error.description)\n\n".utf8))
            printUsage(toStderr: true)
            return 2
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            FileHandle.standardError.write(Data("kwwk-cu: \(msg)\n".utf8))
            return 1
        }
    }

    fileprivate static func run(
        prompt: String,
        invocation: Invocation
    ) async throws -> Int32 {
        let resolved = try await resolveAgentAuth()
        var modelRouting = try resolveDefaultComputerUseModelRouting(
            current: resolved.model,
            thinkingLevel: invocation.thinkingLevel
        )
        let initialModel: Model
        if let modelID = invocation.modelID {
            initialModel = try resolveSelectedModel(current: resolved.model, requestedID: modelID)
            modelRouting.textModel = initialModel
            modelRouting.textThinkingLevel = invocation.thinkingLevel
        } else {
            initialModel = modelRouting.textModel
        }
        if invocation.debugFocus {
            ComputerUseDebug.focusEnabled = true
            writeStderr("[debug] focus tracing enabled\n")
        }
        writeStderr(
            "[model] text=\(modelRouting.textModel.id) thinking=\(modelRouting.textThinkingLevel.rawValue) · image=\(modelRouting.imageModel.id) thinking=\(modelRouting.imageThinkingLevel.rawValue)\n"
        )
        writeStderr(
            "[screenshot] max_long_edge=\(invocation.screenshotCompression.maxLongEdgePixels) max_pixels=\(invocation.screenshotCompression.maxPixelArea) quality=\(String(format: "%.2f", invocation.screenshotCompression.jpegQuality))\n"
        )
        let toolTraceLogger = try invocation.debugToolLogPath.map { path in
            try ToolTraceLogger(path: path)
        }
        if let path = invocation.debugToolLogPath {
            writeStderr("[debug] tool trace log=\(path)\n")
        }
        let computerUseSession = ComputerUseSession()
        defer {
            computerUseSession.finish()
        }
        let sessionId = UUID().uuidString
        let systemPrompt = ComputerUseAgent.systemPromptWithStartupInventory()
        let agent = Agent(options: AgentOptions(
            initialState: AgentInitialState(
                systemPrompt: systemPrompt,
                model: initialModel,
                thinkingLevel: modelRouting.textThinkingLevel,
                thinkingDisplay: .collapsed,
                tools: [
                    ComputerUseAgent.makeTool(
                        session: computerUseSession,
                        modelRouting: modelRouting,
                        screenshotCompression: invocation.screenshotCompression
                    ),
                ]
            ),
            toolExecution: .sequential,
            parallelToolCalls: false,
            sessionId: sessionId,
            maxTurns: invocation.maxTurns,
            autoCompact: AgentAutoCompactOptions(threshold: 0.75),
            authResolver: resolved.authResolver
        ))

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var finalStopReason: StopReason?
            var needsTrailingNewline = false
        }
        let box = Box()

        let unsubscribe = agent.subscribe { event, _ in
            switch event {
            case .messageUpdate(_, let inner):
                if case .textDelta(_, let delta, _) = inner {
                    writeStdout(delta)
                    box.lock.withLock {
                        box.needsTrailingNewline = !delta.hasSuffix("\n")
                    }
                }
            case .messageEnd(.assistant):
                let needs = box.lock.withLock { () -> Bool in
                    let value = box.needsTrailingNewline
                    box.needsTrailingNewline = false
                    return value
                }
                if needs { writeStdout("\n") }
            case .toolExecutionStart(let toolCallId, let toolName, let args):
                writeStderr("[tool] \(toolName) \(compactJSON(args))\n")
                toolTraceLogger?.writeStart(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    args: args
                )
            case .toolExecutionEnd(let toolCallId, let toolName, let result, let isError):
                let marker = isError ? "error" : "ok"
                let summary = result.uiDisplay?.joined(separator: " · ") ?? marker
                writeStderr("[tool:\(marker)] \(toolName): \(summary)\n")
                toolTraceLogger?.writeEnd(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    result: result,
                    isError: isError
                )
            case .streamRetry(let attempt, let delayMs, let reason):
                writeStderr("[retry] attempt \(attempt + 1), delay \(delayMs)ms: \(reason)\n")
            case .agentEnd(_, let summary):
                box.lock.withLock { box.finalStopReason = summary.finalStopReason }
                if summary.finalStopReason != .stop,
                   let err = agent.state.errorMessage {
                    writeStderr("kwwk-cu: \(err)\n")
                }
            default:
                break
            }
        }
        defer { unsubscribe() }

        try await agent.prompt(prompt)
        let stop = box.lock.withLock { box.finalStopReason }
        return stop == .stop ? 0 : 1
    }

    private static func promptForAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [
            "AXTrustedCheckOptionPrompt": true as CFBoolean,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        writeStderr("kwwk-cu: Accessibility permission may be required for this process before direct in-process actions can run.\n")
    }

    private static func readPrompt(_ parts: [String]) throws -> String {
        let prompt: String
        if parts.isEmpty || parts == ["-"] {
            #if canImport(Darwin)
            if isatty(0) != 0 {
                throw InvocationError.missingPrompt
            }
            #endif
            let data = FileHandle.standardInput.readDataToEndOfFile()
            prompt = String(data: data, encoding: .utf8) ?? ""
        } else {
            prompt = parts.joined(separator: " ")
        }

        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw InvocationError.missingPrompt
        }
        return prompt
    }

    private static func parseInvocation(_ argv: [String]) throws -> Invocation {
        var out = Invocation()
        var index = 0
        while index < argv.count {
            let value = argv[index]
            switch value {
            case "-h", "--help":
                out.showHelp = true
                index += 1
            case "--thinking":
                guard index + 1 < argv.count,
                      let level = ThinkingLevel(rawValue: argv[index + 1])
                else {
                    throw InvocationError.invalidThinking
                }
                out.thinkingLevel = level
                index += 2
            case "--model", "-m":
                guard index + 1 < argv.count else {
                    throw InvocationError.missingModel
                }
                out.modelID = argv[index + 1]
                index += 2
            case "--models", "models", "list-models", "--list-models":
                out.listModels = true
                index += 1
            case "--max-turns":
                guard index + 1 < argv.count,
                      let maxTurns = Int(argv[index + 1]),
                      maxTurns > 0
                else {
                    throw InvocationError.invalidMaxTurns
                }
                out.maxTurns = maxTurns
                index += 2
            case "--screenshot-limit", "--screenshot-max-long-edge":
                guard index + 1 < argv.count,
                      let maxLongEdge = Int(argv[index + 1]),
                      maxLongEdge > 0
                else {
                    throw InvocationError.invalidScreenshotLimit
                }
                out.screenshotCompression.maxLongEdgePixels = maxLongEdge
                index += 2
            case "--screenshot-max-pixels":
                guard index + 1 < argv.count,
                      let maxPixelArea = Int(argv[index + 1]),
                      maxPixelArea > 0
                else {
                    throw InvocationError.invalidScreenshotLimit
                }
                out.screenshotCompression.maxPixelArea = maxPixelArea
                index += 2
            case "--screenshot-quality":
                guard index + 1 < argv.count,
                      let quality = Double(argv[index + 1]),
                      quality > 0,
                      quality <= 1
                else {
                    throw InvocationError.invalidScreenshotQuality
                }
                out.screenshotCompression.jpegQuality = quality
                index += 2
            case "--debug-focus":
                out.debugFocus = true
                index += 1
            case "--debug-tool-log":
                guard index + 1 < argv.count else {
                    throw InvocationError.missingDebugToolLogPath
                }
                out.debugToolLogPath = argv[index + 1]
                index += 2
            default:
                out.promptParts.append(contentsOf: argv[index...])
                index = argv.count
            }
        }
        return out
    }

    private static func printUsage(toStderr: Bool = false) {
        let text = """
        kwwk-cu — local macOS computer-use CLI

        usage:
          kwwk-cu "帮我用slack给老板发一条消息"
          kwwk-cu -                    read prompt from stdin
          kwwk-cu --models             list models for the logged-in provider

        options:
          --model, -m <id>             model id for the current provider
          --thinking <level>           off, minimal, low (default), medium, high, xhigh
          --max-turns <n>              cap assistant/tool turns (default: 80)
          --screenshot-limit <px>      screenshot max long edge (default: 1568)
          --screenshot-max-pixels <n>  screenshot max pixel area (default: 629145)
          --screenshot-quality <0-1>   JPEG quality for screenshots (default: 0.82)
          --debug-focus                log frontmost/focus transitions during clicks
          --debug-tool-log <path>      write full tool calls/results as JSONL
          -h, --help                   show help

        Credentials are read from the same store as kwwk. Run `kwwk login`
        first if no provider is configured.
        """
        if toStderr {
            writeStderr(text + "\n")
        } else {
            print(text)
        }
    }

    private static func compactJSON(_ value: JSONValue) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func printAvailableModels() async throws {
        let resolved = try await resolveAgentAuth()
        let current = resolved.model
        let providerKey = catalogProviderKey(forAgentProvider: current.provider)
        let available = ModelsCatalog.models(for: providerKey)
            .sorted { $0.id < $1.id }

        if available.isEmpty {
            print("No catalog models for provider \(current.provider). Current model: \(current.id)")
            return
        }

        print("Models for \(current.provider):")
        for model in available {
            let marker = model.id == current.id ? "*" : " "
            let reasoning = model.reasoning ? "reasoning" : "no-reasoning"
            let image = model.input.contains(.image) ? "image" : "text"
            print("\(marker) \(model.id)  \(model.name)  [\(reasoning), \(image)]")
        }
    }

    private static func resolveSelectedModel(
        current: Model,
        requestedID: String?
    ) throws -> Model {
        guard let requestedID, !requestedID.isEmpty else {
            return current
        }

        let providerKey = catalogProviderKey(forAgentProvider: current.provider)
        if let picked = ModelsCatalog.model(provider: providerKey, id: requestedID) {
            return adoptFields(from: current, into: picked)
        }

        // OpenAI-compatible endpoints commonly use user-defined model ids
        // that are not in the bundled catalog.
        if current.provider == "openai-compatible" {
            var custom = current
            custom.id = requestedID
            custom.name = requestedID
            return custom
        }

        let suggestions = ModelsCatalog.models(for: providerKey)
            .map(\.id)
            .filter { $0.localizedCaseInsensitiveContains(requestedID) }
            .prefix(8)
            .joined(separator: ", ")
        let hint = suggestions.isEmpty ? "Run `kwwk-cu --models` to list available ids." : "Similar ids: \(suggestions)"
        throw InvocationError.unknownModel(requestedID, provider: current.provider, hint: hint)
    }
}

private struct Invocation {
    var showHelp = false
    var listModels = false
    var thinkingLevel: ThinkingLevel = .low
    var modelID: String?
    var maxTurns = 80
    var screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    var debugFocus = false
    var debugToolLogPath: String?
    var promptParts: [String] = []
}

private enum InvocationError: Error, CustomStringConvertible {
    case missingPrompt
    case missingModel
    case unknownModel(String, provider: String, hint: String)
    case invalidThinking
    case invalidMaxTurns
    case invalidScreenshotLimit
    case invalidScreenshotQuality
    case missingDebugToolLogPath

    var description: String {
        switch self {
        case .missingPrompt:
            return "missing prompt"
        case .missingModel:
            return "--model needs a model id"
        case let .unknownModel(id, provider, hint):
            return "unknown model '\(id)' for provider '\(provider)'. \(hint)"
        case .invalidThinking:
            return "--thinking needs one of: off, minimal, low, medium, high, xhigh"
        case .invalidMaxTurns:
            return "--max-turns needs a positive integer"
        case .invalidScreenshotLimit:
            return "screenshot limits need positive integers"
        case .invalidScreenshotQuality:
            return "--screenshot-quality needs a number greater than 0 and less than or equal to 1"
        case .missingDebugToolLogPath:
            return "--debug-tool-log needs a path"
        }
    }
}

private final class ToolTraceLogger: @unchecked Sendable {
    private struct StartEvent: Codable {
        let type: String
        let timestamp: String
        let toolCallId: String
        let toolName: String
        let args: JSONValue
    }

    private struct EndEvent: Codable {
        let type: String
        let timestamp: String
        let toolCallId: String
        let toolName: String
        let isError: Bool
        let uiDisplay: [String]?
        let details: JSONValue?
        let content: [ToolResultBlock]
    }

    private let lock = NSLock()
    private let handle: FileHandle
    private let encoder: JSONEncoder

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    deinit {
        try? handle.close()
    }

    func writeStart(toolCallId: String, toolName: String, args: JSONValue) {
        let event = StartEvent(
            type: "tool_start",
            timestamp: isoTimestamp(),
            toolCallId: toolCallId,
            toolName: toolName,
            args: args
        )
        write(event)
    }

    func writeEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool) {
        let event = EndEvent(
            type: "tool_end",
            timestamp: isoTimestamp(),
            toolCallId: toolCallId,
            toolName: toolName,
            isError: isError,
            uiDisplay: result.uiDisplay,
            details: result.details,
            content: result.content
        )
        write(event)
    }

    private func write<T: Encodable>(_ event: T) {
        guard let data = try? encoder.encode(event) else { return }
        lock.withLock {
            handle.write(data)
            handle.write(Data("\n".utf8))
        }
    }

    private func isoTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private func writeStdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

private func writeStderr(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

private func catalogProviderKey(forAgentProvider provider: String) -> String {
    switch provider {
    case "chatgpt-codex": return "openai-codex"
    default: return provider
    }
}

private func resolveDefaultComputerUseModelRouting(
    current: Model,
    thinkingLevel: ThinkingLevel
) throws -> ComputerUseModelRouting {
    let textModel = try resolveCatalogModel(current: current, id: "gpt-5.3-codex-spark")
    let imageModel = try resolveCatalogModel(current: current, id: "gpt-5.5")
    return ComputerUseModelRouting(
        textModel: textModel,
        textThinkingLevel: thinkingLevel,
        imageModel: imageModel,
        imageThinkingLevel: thinkingLevel
    )
}

private func resolveCatalogModel(current: Model, id: String) throws -> Model {
    let providerKey = catalogProviderKey(forAgentProvider: current.provider)
    guard let picked = ModelsCatalog.model(provider: providerKey, id: id) else {
        throw InvocationError.unknownModel(
            id,
            provider: current.provider,
            hint: "The computer-use preset requires this id in the \(providerKey) catalog."
        )
    }
    return adoptFields(from: current, into: picked)
}

private func adoptFields(from current: Model, into picked: Model) -> Model {
    if current.provider == picked.provider {
        return Model(
            id: picked.id,
            name: picked.name,
            api: picked.api,
            provider: picked.provider,
            baseUrl: current.baseUrl,
            reasoning: picked.reasoning,
            input: picked.input,
            cost: picked.cost,
            contextWindow: picked.contextWindow,
            maxTokens: picked.maxTokens,
            headers: picked.headers
        )
    }

    let resolvedMaxTokens = current.maxTokens == 0 ? 0 : picked.maxTokens
    return Model(
        id: picked.id,
        name: picked.name,
        api: current.api,
        provider: current.provider,
        baseUrl: current.baseUrl,
        reasoning: picked.reasoning,
        input: picked.input,
        cost: picked.cost,
        contextWindow: picked.contextWindow,
        maxTokens: resolvedMaxTokens,
        headers: current.headers
    )
}
