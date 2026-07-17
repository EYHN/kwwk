import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

@Suite("Subagent background failure cleanup")
struct SubagentBackgroundFailureCleanupTests {
    @Test("explicit incomplete background yield keeps warning semantics across task output")
    func incompleteBackgroundYieldKeepsSemanticStatus() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage(
            blocks: [fauxToolCall(
                name: "subagent_yield",
                arguments: .object([
                    "status": .string("incomplete"),
                    "result": .string("focused tests could not finish"),
                ]),
                id: "background-incomplete-yield"
            )],
            stopReason: .toolUse
        ))])
        let outputDirectory = makeTempDir("kw-subagent-background-incomplete")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let manager = BackgroundTaskManager(outputDir: outputDirectory)
        let runner = SubagentRunner(
            cwd: outputDirectory.path,
            subagents: [SubagentDefinition(
                name: "incomplete",
                description: "Exercise incomplete background semantics.",
                prompt: "Preserve partial evidence.",
                tools: .readOnly
            )],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            backgroundManager: manager,
            sessionId: "background-incomplete-parent",
            bashEnvironment: testBashEnvironment
        )

        let started = try await runner.startBackground(
            type: "incomplete",
            prompt: "report incomplete evidence",
            description: "incomplete background child"
        )
        #expect(await awaitUntil(2_000) {
            await manager.get(started.taskId)?.status == .failed
        })
        let snapshot = try #require(await manager.get(started.taskId))
        #expect(snapshot.outcome?.success == false)
        #expect(snapshot.outcome?.summary == "incomplete")
        #expect(snapshot.outcome?.errorMessage == nil)
        guard case .object(let outcomeDetails) = snapshot.outcome?.details ?? .null else {
            Issue.record("missing incomplete outcome details")
            return
        }
        #expect(outcomeDetails["status"] == .string("incomplete"))
        #expect(snapshot.outputTail.hasPrefix("[incomplete]"))
        #expect(!snapshot.outputTail.hasPrefix("[error]"))

        let task = createTaskPollTool(
            manager: manager,
            sessionId: "background-incomplete-parent"
        )
        let polled = try await task.execute(
            "poll-incomplete-subagent",
            .object(["task_ids": .array([.string(started.taskId)])]),
            nil,
            nil
        )
        #expect(backgroundFailureResultText(polled).contains(
            "task \(started.taskId): incomplete"
        ))
        guard case .object(let pollDetails) = polled.details ?? .null,
              case .array(let tasks) = pollDetails["tasks"] ?? .null,
              case .object(let task) = tasks.first ?? .null else {
            Issue.record("missing incomplete task details")
            return
        }
        #expect(task["status"] == .string("incomplete"))
        #expect(task["registry_status"] == .string("failed"))
    }

    @Test("provider failure closes the child session and releases background capacity")
    func providerFailureReleasesResourcesAndPermit() async throws {
        let api = "subagent-background-failure-\(UUID().uuidString)"
        let providerName = "subagent-background-failure-provider-\(UUID().uuidString)"
        let sourceId = "subagent-background-failure-source-\(UUID().uuidString)"
        let provider = FailingThenSuccessfulLifecycleProvider(
            api: api,
            providerName: providerName
        )
        await APIRegistry.shared.register(provider, sourceId: sourceId)
        defer { Task { await APIRegistry.shared.unregisterSource(sourceId) } }

        let outputDirectory = makeTempDir("kw-subagent-background-failure")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let manager = BackgroundTaskManager(outputDir: outputDirectory)
        let parentSessionId = "background-failure-parent-\(UUID().uuidString)"
        let model = Model(
            id: "background-failure-model",
            api: api,
            provider: providerName
        )
        let runner = SubagentRunner(
            cwd: outputDirectory.path,
            subagents: [SubagentDefinition(
                name: "cleanup",
                description: "Exercise background failure cleanup.",
                prompt: "Return the requested test result.",
                tools: .readOnly
            )],
            parentModel: model,
            parentTools: .readOnly,
            limits: SubagentLimits(
                maxConcurrent: 1,
                maxConcurrentMutating: 1,
                maxTotal: 2,
                maxTurns: 4,
                timeoutSeconds: 5
            ),
            backgroundManager: manager,
            sessionId: parentSessionId,
            bashEnvironment: testBashEnvironment
        )

        let failed = try await runner.startBackground(
            type: "cleanup",
            prompt: "fail this background child",
            description: "failing background child"
        )
        #expect(await awaitUntil(2_000) {
            await manager.get(failed.taskId)?.status == .failed
        })

        let failedSnapshot = try #require(await manager.get(failed.taskId))
        #expect(failedSnapshot.status == .failed)
        #expect(failedSnapshot.outcome?.success == false)
        #expect(failedSnapshot.outcome?.summary == "failed")
        #expect(failedSnapshot.outcome?.errorMessage?.contains(
            FailingThenSuccessfulLifecycleProvider.failureMessage
        ) == true)
        let failedOutput = try String(contentsOf: failed.outputFile, encoding: .utf8)
        #expect(failedOutput.contains("[error]"))
        #expect(failedOutput.contains(FailingThenSuccessfulLifecycleProvider.failureMessage))
        #expect(provider.closedSessions.contains(failed.childSessionId))

        let task = createTaskPollTool(manager: manager, sessionId: parentSessionId)
        let polledFailure = try await task.execute(
            "poll-failed-subagent",
            .object([
                "task_ids": .array([.string(failed.taskId)]),
                "timeout_seconds": .int(1),
            ]),
            nil,
            nil
        )
        #expect(backgroundFailureResultText(polledFailure).contains(
            "task \(failed.taskId): failed"
        ))
        #expect(backgroundFailureResultText(polledFailure).contains(
            FailingThenSuccessfulLifecycleProvider.failureMessage
        ))

        // With maxConcurrent=1, this launch can succeed only after the failed
        // child's active permit has been released. maxTotal=2 allows exactly
        // this second launch while retaining the lifetime launch budget.
        let succeeded = try await runner.startBackground(
            type: "cleanup",
            prompt: "succeed after the failed child",
            description: "successful background child"
        )
        #expect(await awaitUntil(2_000) {
            await manager.get(succeeded.taskId)?.status == .completed
        })
        let succeededSnapshot = try #require(await manager.get(succeeded.taskId))
        #expect(succeededSnapshot.status == .completed)
        #expect(succeededSnapshot.outputTail.contains(
            FailingThenSuccessfulLifecycleProvider.successMessage
        ))
        #expect(provider.closedSessions.contains(succeeded.childSessionId))
        #expect(provider.callCount == 2)
    }

    @Test("max-turn background failure retains telemetry and partial output")
    func maxTurnFailureRetainsTelemetry() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [
                    fauxText("bounded partial background finding"),
                    fauxToolCall(
                        name: "read",
                        arguments: ["path": .string("unused.txt")],
                        id: "forbidden-final-read"
                    ),
                ],
                stopReason: .toolUse
            )),
        ])
        let outputDirectory = makeTempDir("kw-subagent-background-max-turn")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let manager = BackgroundTaskManager(outputDir: outputDirectory)
        let runner = SubagentRunner(
            cwd: outputDirectory.path,
            subagents: [SubagentDefinition(
                name: "bounded",
                description: "Exercise terminal telemetry.",
                prompt: "Return a bounded result.",
                tools: .readOnly
            )],
            parentModel: faux.getModel(),
            parentTools: .readOnly,
            limits: SubagentLimits(maxTurns: 1, timeoutSeconds: 5),
            backgroundManager: manager,
            sessionId: "background-max-turn-parent",
            bashEnvironment: testBashEnvironment
        )

        let started = try await runner.startBackground(
            type: "bounded",
            prompt: "trigger the final-turn guard",
            description: "bounded background child"
        )
        #expect(await awaitUntil(2_000) {
            await manager.get(started.taskId)?.status == .failed
        })
        let snapshot = try #require(await manager.get(started.taskId))
        guard case .object(let details) = snapshot.outcome?.details ?? .null else {
            Issue.record("expected structured failure telemetry")
            return
        }
        #expect(details["failure_kind"] == .string("max_turns"))
        #expect(details["turns"] == .int(1))
        #expect(details["usage"] != nil)
        #expect(details["cost"] != nil)
        #expect(details["duration_ms"] != nil)
        #expect(details["partial_output"] == .string("bounded partial background finding"))
        #expect(snapshot.outputTail.contains("bounded partial background finding"))
    }
}

private final class FailingThenSuccessfulLifecycleProvider:
    APIProvider,
    APIProviderSessionLifecycle,
    @unchecked Sendable
{
    static let failureMessage = "background provider failure sentinel"
    static let successMessage = "background provider recovered"

    let api: String
    private let providerName: String
    private let lock = NSLock()
    private var calls = 0
    private var sessions: [String] = []

    init(api: String, providerName: String) {
        self.api = api
        self.providerName = providerName
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    var closedSessions: [String] {
        lock.withLock { sessions }
    }

    func stream(
        model: Model,
        context _: Context,
        options _: StreamOptions?
    ) -> AssistantMessageStream {
        let invocation = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        let failed = invocation == 1
        let content: [AssistantBlock] = failed
            ? [.text(TextContent(text: Self.failureMessage))]
            : [fauxToolCall(
                name: "subagent_yield",
                arguments: .object([
                    "status": .string("complete"),
                    "result": .string(Self.successMessage),
                ]),
                id: "background-cleanup-yield"
            )]
        let message = AssistantMessage(
            content: content,
            api: api,
            provider: providerName,
            model: model.id,
            usage: Usage(),
            stopReason: failed ? .error : .toolUse,
            errorMessage: failed ? Self.failureMessage : nil,
            timestamp: Timestamp.now()
        )
        var partial = message
        partial.content = []
        let stream = AssistantMessageStream()
        stream.push(.start(partial: partial))
        if failed {
            stream.push(.error(reason: .error, error: message))
        } else {
            stream.push(.done(reason: .toolUse, message: message))
        }
        stream.end(message)
        return stream
    }

    func closeSession(sessionId: String) async {
        lock.withLock { sessions.append(sessionId) }
    }
}

private func backgroundFailureResultText(_ result: AgentToolResult) -> String {
    result.content.compactMap { block in
        guard case .text(let text) = block else { return nil }
        return text.text
    }.joined()
}
