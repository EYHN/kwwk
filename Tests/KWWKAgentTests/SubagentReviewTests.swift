import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// Independent review probes for agent_send / resume / history. Each
/// "regression:" test pins a defect found in review of the first cut.
@Suite("Subagent review probes")
struct SubagentReviewTests {
    // MARK: - Store-level races

    @Test("regression: a follow-up that lands between the run's final detach and finish is reported delivered, then dropped")
    func bugSteerBetweenDetachAndFinishIsLost() {
        let store = SubagentHistoryStore()
        store.begin(
            childSessionId: "c1", parentSessionId: "p", agentId: "mini-1",
            subagentType: "mini", prompt: "task", model: "m"
        )
        // runChild's final `detachLiveIfSettled` has returned true (live == nil)
        // but `run()` has not yet called `finish`: the entry is still running.
        #expect(store.detachLiveIfSettled(childSessionId: "c1"))
        let claim = store.claimFollowUp(agentId: "mini-1", parentSessionId: "p", message: "late steer")
        // The settling run cannot take it; agent_send waits this out.
        guard case .busy = claim else {
            Issue.record("expected the settling run to report busy, got \(claim)")
            return
        }
        store.finish(childSessionId: "c1", status: .completed)

        // The parent was told the message was delivered into the run...
        if case .delivered = claim {
            // ...but finish() wiped pendingSteers, and no run will ever read
            // it. The next send resumes without it.
            guard case .resume(let ticket) = store.claimFollowUp(
                agentId: "mini-1", parentSessionId: "p", message: "next"
            ) else {
                Issue.record("expected a resume claim")
                return
            }
            let texts = ticket.messages.flatMap(reviewMessageTexts)
            #expect(texts.contains { $0.contains("late steer") },
                    "a follow-up acknowledged as delivered was silently discarded")
        }
    }

    @Test("regression: abandonFollowUp drops a second follow-up that was acknowledged as delivered into the queued resume")
    func bugAbandonDropsRacingDeliveredMessage() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let store = SubagentHistoryStore()
        store.begin(
            childSessionId: "c1", parentSessionId: "p", agentId: "mini-1",
            subagentType: "mini", prompt: "task", model: "m"
        )
        store.finish(childSessionId: "c1", status: .completed)

        guard case .resume(let first) = store.claimFollowUp(
            agentId: "mini-1", parentSessionId: "p", message: "A"
        ) else {
            Issue.record("expected resume")
            return
        }
        let second = store.claimFollowUp(agentId: "mini-1", parentSessionId: "p", message: "B")
        guard case .delivered = second else {
            Issue.record("expected the racing send to be delivered into the queued resume")
            return
        }
        // A's launch fails (e.g. concurrency limit): the claim is undone.
        store.abandonFollowUp(first, errorMessage: "limit")
        #expect(store.snapshot(agentId: "mini-1", parentSessionId: "p")?.status == .completed)

        // B was acknowledged as delivered. The next resume carries it, ahead
        // of its own message.
        guard case .resume(let next) = store.claimFollowUp(agentId: "mini-1", parentSessionId: "p", message: "C") else {
            Issue.record("expected resume")
            return
        }
        #expect(next.carriedMessages == ["B"],
                "follow-up B was acknowledged as delivered but abandonFollowUp discarded it")
    }

    @Test("regression: a late second finish() of the previous run clobbers a resumed run that is already live")
    func bugLateFinishClobbersResumedRun() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let store = SubagentHistoryStore()
        let oldRun = UUID()
        let newRun = UUID()
        store.begin(
            childSessionId: "c1", parentSessionId: "p", agentId: "mini-1",
            subagentType: "mini", prompt: "task", model: "m", runToken: oldRun
        )
        // run() finishes the entry...
        store.finish(childSessionId: "c1", runToken: oldRun, status: .failed, errorMessage: "boom")
        // ...the parent resumes it right away...
        guard case .resume = store.claimFollowUp(agentId: "mini-1", parentSessionId: "p", message: "retry") else {
            Issue.record("expected resume")
            return
        }
        store.begin(childSessionId: "c1", parentSessionId: "p", subagentType: "mini", prompt: "retry", model: "m", runToken: newRun)
        let agent = Agent(options: AgentOptions(initialState: AgentInitialState(model: faux.getModel())))
        defer { agent.retire() }
        store.attachLive(childSessionId: "c1", runToken: newRun, live: SubagentLiveChild(agent: agent))
        // ...then subagentBackgroundFailure (background runner catch, or the
        // flip path's manager waiter) calls finish() for the OLD run again.
        store.finish(childSessionId: "c1", runToken: oldRun, status: .failed, errorMessage: "boom")

        let snapshot = store.snapshot(agentId: "mini-1", parentSessionId: "p")
        #expect(snapshot?.status == .running, "the resumed, live run is now recorded as failed")
        // A follow-up now starts a second concurrent run of the same child
        // instead of steering the live one.
        let claim = store.claimFollowUp(agentId: "mini-1", parentSessionId: "p", message: "steer")
        if case .resume = claim {
            Issue.record("a second concurrent resume was granted while the resumed run is live")
        }
    }

    @Test("resume claim is exclusive: a racing second send is steered, not resumed twice")
    func resumeClaimIsExclusive() {
        let store = SubagentHistoryStore()
        store.begin(
            childSessionId: "c1", parentSessionId: "p", agentId: "mini-1",
            subagentType: "mini", prompt: "task", model: "m"
        )
        store.finish(childSessionId: "c1", status: .completed)
        let results = ReviewBox<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            let kind: String
            switch store.claimFollowUp(agentId: "mini-1", parentSessionId: "p", message: "m\(index)") {
            case .resume: kind = "resume"
            case .delivered: kind = "delivered"
            case .notFound: kind = "notFound"
            case .busy: kind = "busy"
            }
            results.mutate { $0.append(kind) }
        }
        #expect(results.value.filter { $0 == "resume" }.count == 1)
        #expect(results.value.filter { $0 == "delivered" }.count == 15)
        let snapshot = store.snapshot(agentId: "mini-1", parentSessionId: "p")
        #expect(snapshot?.runs.count == 2)
        #expect(snapshot?.status == .queued)
    }

    @Test("eviction keeps queued resumes and frees evicted names; auto ids never repeat")
    func evictionAndReservedIds() throws {
        let store = SubagentHistoryStore(maxTerminalEntries: 1)
        let firstId = try store.reserveAgentId(parentSessionId: "p", requested: "keep", subagentType: "mini")
        store.begin(childSessionId: "c1", parentSessionId: "p", agentId: firstId, subagentType: "mini", prompt: "a", model: "m")
        store.finish(childSessionId: "c1", status: .completed)
        // Claim a resume: the entry is queued and must survive pruning.
        guard case .resume = store.claimFollowUp(agentId: "keep", parentSessionId: "p", message: "go") else {
            Issue.record("expected resume")
            return
        }
        for index in 0..<3 {
            let id = try store.reserveAgentId(parentSessionId: "p", requested: nil, subagentType: "mini")
            #expect(id == "mini-\(index + 1)")
            store.begin(childSessionId: "x\(index)", parentSessionId: "p", agentId: id, subagentType: "mini", prompt: "b", model: "m")
            store.finish(childSessionId: "x\(index)", status: .completed)
        }
        #expect(store.snapshot(agentId: "keep", parentSessionId: "p")?.status == .queued)
        #expect(store.snapshot(agentId: "mini-1", parentSessionId: "p") == nil)
        // An auto id is not handed out again after its child was evicted.
        let next = try store.reserveAgentId(parentSessionId: "p", requested: nil, subagentType: "mini")
        #expect(next == "mini-4")
        // A reserved-but-unlaunched name blocks reuse until released.
        _ = try store.reserveAgentId(parentSessionId: "p", requested: "pending", subagentType: "mini")
        #expect(throws: CodingToolError.self) {
            _ = try store.reserveAgentId(parentSessionId: "p", requested: "PENDING", subagentType: "mini")
        }
        store.releaseAgentId("Pending", parentSessionId: "p")
        _ = try store.reserveAgentId(parentSessionId: "p", requested: "pending", subagentType: "mini")
    }

    // MARK: - End-to-end races

    @Test("regression: a cancelled run that is still settling detaches the resumed run's live child, so a steer is lost")
    func bugStaleRunDetachesResumedRun() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let oldEntered = ReviewLatch()
        let oldRelease = ReviewLatch()
        let newEntered = ReviewLatch()
        let newRelease = ReviewLatch()
        let steerSeen = ReviewBox(false)
        faux.setResponses([
            // First run: provider ignores cancellation until released.
            .factory { _, _, _, _ in
                oldEntered.open()
                await oldRelease.wait()
                return reviewYield("stale")
            },
            // Resumed run's first step, held so a steer can arrive mid-run.
            .factory { _, _, _, _ in
                newEntered.open()
                await newRelease.wait()
                return reviewYield("fresh")
            },
            // Any step that reads the steer.
            .factory { context, _, _, _ in
                if context.messages.flatMap(reviewMessageTexts).contains(where: { $0.contains("steer-after-stale") }) {
                    steerSeen.mutate { $0 = true }
                }
                return reviewYield("fresh with steer")
            },
            .factory { context, _, _, _ in
                if context.messages.flatMap(reviewMessageTexts).contains(where: { $0.contains("steer-after-stale") }) {
                    steerSeen.mutate { $0 = true }
                }
                return reviewYield("fresh with steer 2")
            },
        ])
        let toolset = reviewToolset(model: faux.getModel(), sessionId: "stale-parent")
        let cancel = CancellationHandle()
        let launch = Task {
            try await reviewTool(toolset, "agent").execute("launch", reviewLaunchArgs(), cancel, nil)
        }
        await oldEntered.wait()
        cancel.cancel(reason: "user interrupt")
        _ = try? await launch.value

        // Parent resumes the aborted child while the old run is still stuck
        // in its provider call.
        let resume = Task {
            try await reviewTool(toolset, "agent_send").execute(
                "resume",
                .object(["agent_id": .string("mini-1"), "message": .string("try again")]),
                nil, nil
            )
        }
        await newEntered.wait()

        // The old run finally returns and runs its cleanup, including
        // `detachLiveIfSettled(childSessionId:)` on the shared entry.
        oldRelease.open()
        try await Task.sleep(nanoseconds: 300_000_000)

        let delivered = try await reviewTool(toolset, "agent_send").execute(
            "steer",
            .object(["agent_id": .string("mini-1"), "message": .string("steer-after-stale")]),
            nil, nil
        )
        #expect(reviewDetail(delivered, "status") == "delivered")
        newRelease.open()
        let result = try await resume.value
        #expect(steerSeen.value, "the steer acknowledged as delivered was never read by the resumed run")
        #expect(reviewText(result).contains("fresh with steer"))
    }

    @Test("regression: a reopened task whose child never yields again returns the stale first result as success")
    func bugReopenedTaskReturnsStaleYield() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let entered = ReviewLatch()
        let release = ReviewLatch()
        var responses: [FauxResponseStep] = [
            .factory { _, _, _, _ in
                entered.open()
                await release.wait()
                return reviewYield("OLD RESULT before the follow-up")
            },
        ]
        // The reopened run answers in plain text and never calls
        // subagent_yield again, through every reminder.
        for _ in 0..<6 {
            responses.append(.message(fauxAssistantMessage("I handled the follow-up: NEW ANSWER.")))
        }
        faux.setResponses(responses)
        let toolset = reviewToolset(model: faux.getModel(), sessionId: "stale-yield-parent")
        let launch = Task {
            try await reviewTool(toolset, "agent").execute("launch", reviewLaunchArgs(), nil, nil)
        }
        await entered.wait()
        let delivered = try await reviewTool(toolset, "agent_send").execute(
            "steer",
            .object(["agent_id": .string("mini-1"), "message": .string("also do X")]),
            nil, nil
        )
        #expect(reviewDetail(delivered, "status") == "delivered")
        release.open()

        do {
            let result = try await launch.value
            #expect(!reviewText(result).contains("OLD RESULT"),
                    "the result submitted before the follow-up was returned as the answer to the reopened task")
        } catch {
            // Failing with missing_yield would be an acceptable outcome.
        }
    }

    @Test("two sends race on a stopped child held in the capacity queue: both reach the resumed run")
    func twoSendsOnQueuedResume() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let holderEntered = ReviewLatch()
        let holderRelease = ReviewLatch()
        let contexts = ReviewBox<[Context]>([])
        faux.setResponses([
            .message(reviewYield("first run")),
            .factory { _, _, _, _ in
                holderEntered.open()
                await holderRelease.wait()
                return reviewYield("holder done")
            },
            .factory { context, _, _, _ in
                contexts.mutate { $0.append(context) }
                return reviewYield("resumed one")
            },
            .factory { context, _, _, _ in
                contexts.mutate { $0.append(context) }
                return reviewYield("resumed two")
            },
        ])
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let toolset = reviewToolset(
            model: faux.getModel(),
            sessionId: "queue-parent",
            manager: manager,
            limits: SubagentLimits(maxConcurrent: 1)
        )
        _ = try await reviewTool(toolset, "agent").execute("first", reviewLaunchArgs(name: "target"), nil, nil)
        let holder = try await reviewTool(toolset, "agent").execute(
            "holder", reviewLaunchArgs(name: "holder", background: true), nil, nil
        )
        await holderEntered.wait()

        let resumed = try await reviewTool(toolset, "agent_send").execute(
            "resume",
            .object([
                "agent_id": .string("target"),
                "message": .string("follow-up one"),
                "run_in_background": .bool(true),
            ]),
            nil, nil
        )
        #expect(reviewDetail(resumed, "runner_state") == "queued")
        let steered = try await reviewTool(toolset, "agent_send").execute(
            "steer",
            .object(["agent_id": .string("target"), "message": .string("follow-up two")]),
            nil, nil
        )
        #expect(reviewDetail(steered, "status") == "delivered")
        #expect(reviewDetail(steered, "child_status") == "queued")
        holderRelease.open()

        let resumedTask = try #require(reviewDetail(resumed, "task_id"))
        let holderTask = try #require(reviewDetail(holder, "task_id"))
        #expect(resumedTask != holderTask)
        #expect(await awaitUntil(5_000) { await manager.get(resumedTask)?.status == .completed })
        let seen = contexts.value.flatMap { $0.messages.flatMap(reviewMessageTexts) }
        #expect(seen.contains(subagentFollowUpMessageText("follow-up one")))
        #expect(seen.contains(subagentSteerMessageText("follow-up two")))
    }

    @Test("regression: resuming after an errored run misplaces the run boundary in agent_history")
    func bugResumeAfterErrorMisplacesRunBoundary() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let resumedContext = ReviewBox<Context?>(nil)
        faux.setResponses([
            .message(fauxAssistantMessage("partial", stopReason: .aborted, errorMessage: "stream cut")),
            .factory { context, _, _, _ in
                resumedContext.mutate { $0 = context }
                return reviewYield("recovered")
            },
        ])
        let toolset = reviewToolset(model: faux.getModel(), sessionId: "err-parent")
        await #expect(throws: (any Error).self) {
            _ = try await reviewTool(toolset, "agent").execute("launch", reviewLaunchArgs(), nil, nil)
        }
        let resumed = try await reviewTool(toolset, "agent_send").execute(
            "resume",
            .object(["agent_id": .string("mini-1"), "message": .string("please retry")]),
            nil, nil
        )
        #expect(reviewText(resumed).contains("recovered"))
        // The provider never sees the aborted turn.
        let sent = try #require(resumedContext.value).messages
        #expect(!sent.contains { message in
            if case .assistant(let assistant) = message { return assistant.stopReason == .aborted }
            return false
        })

        let history = reviewText(try await reviewTool(toolset, "agent_history").execute(
            "history", .object(["agent_id": .string("mini-1")]), nil, nil
        ))
        #expect(history.contains("run foreground · agent_send\n\nplease retry"),
                "run.firstMessageIndex counts the trimmed aborted turn, so the resumed prompt is rendered as a plain user message")
        #expect(!history.contains(subagentFollowUpMessageHeader),
                "the follow-up header leaks into the transcript")
    }

    @Test("regression: a foreground resume keeps the previous run's task_id on the snapshot")
    func bugForegroundResumeKeepsStaleTaskId() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let entered = ReviewLatch()
        let release = ReviewLatch()
        faux.setResponses([
            .message(reviewYield("bg one")),
            .factory { _, _, _, _ in
                entered.open()
                await release.wait()
                return reviewYield("fg two")
            },
            .message(reviewYield("fg two with steer")),
        ])
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let toolset = reviewToolset(model: faux.getModel(), sessionId: "taskid-parent", manager: manager)
        let started = try await reviewTool(toolset, "agent").execute(
            "bg", reviewLaunchArgs(background: true), nil, nil
        )
        let firstTask = try #require(reviewDetail(started, "task_id"))
        #expect(await awaitUntil(5_000) { await manager.get(firstTask)?.status == .completed })

        let resume = Task {
            try await reviewTool(toolset, "agent_send").execute(
                "fg-resume",
                .object(["agent_id": .string("mini-1"), "message": .string("again, in the foreground")]),
                nil, nil
            )
        }
        await entered.wait()
        let delivered = try await reviewTool(toolset, "agent_send").execute(
            "steer",
            .object(["agent_id": .string("mini-1"), "message": .string("note")]),
            nil, nil
        )
        release.open()
        _ = try? await resume.value
        #expect(reviewDetail(delivered, "task_id") != firstTask,
                "the delivered notice names the completed first run's task as the running child's task")
        #expect(!reviewText(delivered).contains(firstTask))
    }

    @Test("regression: with a BackgroundTaskManager, a follow-up that lands after the yield can fail the child with alreadyRunning")
    func bugSteerAfterYieldRacesBackgroundAutoContinue() async throws {
        var failures: [String] = []
        for iteration in 0..<10 {
            let faux = await registerFauxProvider()
            let entered = ReviewLatch()
            let release = ReviewLatch()
            faux.setResponses([
                .factory { _, _, _, _ in
                    entered.open()
                    await release.wait()
                    return reviewYield("before the follow-up")
                },
                .message(reviewYield("after the follow-up")),
                .message(reviewYield("spare")),
            ])
            let outputDir = makeTempDir()
            let manager = BackgroundTaskManager(outputDir: outputDir)
            let toolset = reviewToolset(model: faux.getModel(), sessionId: "auto-\(iteration)", manager: manager)
            let launch = Task {
                try await reviewTool(toolset, "agent").execute("launch", reviewLaunchArgs(), nil, nil)
            }
            await entered.wait()
            _ = try await reviewTool(toolset, "agent_send").execute(
                "steer",
                .object(["agent_id": .string("mini-1"), "message": .string("one more thing")]),
                nil, nil
            )
            release.open()
            do {
                let result = try await launch.value
                if !reviewText(result).contains("after the follow-up") {
                    failures.append("iteration \(iteration): wrong result \(reviewText(result).prefix(120))")
                }
            } catch {
                failures.append("iteration \(iteration): \(String(describing: error).prefix(160))")
            }
            faux.unregister()
            await manager.closeSession(sessionId: "auto-\(iteration)")
            try? FileManager.default.removeItem(at: outputDir)
        }
        #expect(failures.isEmpty, "\(failures.count)/10 runs failed: \(failures.first ?? "")")
    }

    // MARK: - agent_history rendering

    @Test("regression: agent_history pages count invisible tool results, and one wide message exceeds the 64 KiB cap")
    func bugHistoryCapWithManyToolCalls() async throws {
        let store = SubagentHistoryStore()
        store.begin(childSessionId: "c1", parentSessionId: "p", agentId: "wide", subagentType: "mini", prompt: "p", model: "m")
        var blocks: [AssistantBlock] = []
        var messages: [Message] = [.user(UserMessage(text: "go"))]
        for index in 0..<800 {
            let path = "src/" + String(repeating: "d", count: 100) + "/file\(index).swift"
            blocks.append(fauxToolCall(name: "read", arguments: .object(["path": .string(path)]), id: "call-\(index)"))
        }
        messages.append(.assistant(fauxAssistantMessage(blocks: blocks, stopReason: .toolUse)))
        for index in 0..<800 {
            messages.append(.toolResult(ToolResultMessage(
                toolCallId: "call-\(index)", toolName: "read", content: [.text(TextContent(text: "x"))]
            )))
        }
        store.finish(childSessionId: "c1", status: .completed, messages: messages)
        let tool = createSubagentHistoryTool(store: store, sessionId: "p")
        // Default view: the newest 20 "messages" are all tool results, which
        // render nothing, so the page is empty.
        let defaultView = reviewText(try await tool.execute("h", .object(["agent_id": .string("wide")]), nil, nil))
        #expect(defaultView.contains("## ["), "the default page rendered no message at all:\n\(defaultView)")
        // The wide assistant message itself.
        let result = try await tool.execute(
            "h2", .object(["agent_id": .string("wide"), "offset": .int(1), "limit": .int(1)]), nil, nil
        )
        let body = reviewText(result)
        #expect(body.utf8.count <= 64 * 1_024 + 512, "agent_history returned \(body.utf8.count) bytes")
    }

    @Test("regression: tool_call detail exceeds the 64 KiB cap when the result is one long line")
    func bugToolCallDetailSingleHugeLine() async throws {
        let store = SubagentHistoryStore()
        store.begin(childSessionId: "c1", parentSessionId: "p", agentId: "json", subagentType: "mini", prompt: "p", model: "m")
        store.finish(childSessionId: "c1", status: .completed, messages: [
            .user(UserMessage(text: "go")),
            .assistant(fauxAssistantMessage(blocks: [
                fauxToolCall(name: "bash", arguments: .object(["command": .string("cat big.json")]), id: "b1"),
            ], stopReason: .toolUse)),
            .toolResult(ToolResultMessage(
                toolCallId: "b1", toolName: "bash",
                content: [.text(TextContent(text: String(repeating: "{\"k\":1},", count: 30_000)))]
            )),
        ])
        let tool = createSubagentHistoryTool(store: store, sessionId: "p")
        let body = reviewText(try await tool.execute(
            "d", .object(["agent_id": .string("json"), "tool_call": .string("2.1")]), nil, nil
        ))
        #expect(body.utf8.count <= 64 * 1_024 + 512, "tool_call detail returned \(body.utf8.count) bytes")
    }

    @Test("tool_call numbering skips thinking and text, counts yield calls, and matches detail addressing")
    func historyToolCallNumbering() async throws {
        let store = SubagentHistoryStore()
        store.begin(childSessionId: "c1", parentSessionId: "p", agentId: "num", subagentType: "mini", prompt: "p", model: "m")
        let messages: [Message] = [
            .user(UserMessage(text: "go")),
            .assistant(fauxAssistantMessage(blocks: [
                fauxThinking("private reasoning"),
                fauxText("Looking."),
                fauxToolCall(name: "read", arguments: .object(["path": .string("a.txt")]), id: "r1"),
                fauxToolCall(name: "grep", arguments: .object(["pattern": .string("<tag>&"), "path": .string("src")]), id: "g1"),
            ], stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: "r1", toolName: "read", content: [.text(TextContent(text: "one\ntwo"))])),
            .toolResult(ToolResultMessage(toolCallId: "g1", toolName: "grep", content: [.text(TextContent(text: "bad things\nmore"))], isError: true)),
            .assistant(fauxAssistantMessage(blocks: [fauxThinking("only thinking")], stopReason: .stop)),
            .assistant(fauxAssistantMessage(blocks: [
                fauxToolCall(name: "subagent_yield", arguments: .object(["status": .string("complete"), "result": .string("done")]), id: "y1"),
            ], stopReason: .toolUse)),
            .toolResult(ToolResultMessage(toolCallId: "y1", toolName: "subagent_yield", content: [.text(TextContent(text: "ok"))])),
        ]
        store.finish(childSessionId: "c1", status: .completed, messages: messages)
        let tool = createSubagentHistoryTool(store: store, sessionId: "p")
        let body = reviewText(try await tool.execute("h", .object(["agent_id": .string("num")]), nil, nil))
        #expect(body.contains("→ [2.1] read(a.txt) ⇒ ok · 2 lines"))
        // Content stays literal inside the untrusted wrapper.
        #expect(body.contains("→ [2.2] grep(<tag>& @ src) ⇒ error · 2 lines — bad things"))
        #expect(!body.contains("private reasoning"))
        #expect(body.contains("## [6] result · complete\n\ndone"))

        let detail = reviewText(try await tool.execute(
            "d", .object(["agent_id": .string("num"), "tool_call": .string("[2.2]")]), nil, nil
        ))
        #expect(detail.contains("[2.2] grep · error"))
        let yieldDetail = reviewText(try await tool.execute(
            "y", .object(["agent_id": .string("num"), "tool_call": .string("6.1")]), nil, nil
        ))
        #expect(yieldDetail.contains("[6.1] subagent_yield · ok"))
        await #expect(throws: CodingToolError.self) {
            _ = try await tool.execute("x", .object(["agent_id": .string("num"), "tool_call": .string("2.3")]), nil, nil)
        }
        await #expect(throws: CodingToolError.self) {
            _ = try await tool.execute("x", .object(["agent_id": .string("num"), "tool_call": .string("99.1")]), nil, nil)
        }
    }

    @Test("regression: an offset past the end renders an inverted range")
    func bugHistoryOffsetPastEnd() async throws {
        let store = SubagentHistoryStore()
        store.begin(childSessionId: "c1", parentSessionId: "p", agentId: "short", subagentType: "mini", prompt: "p", model: "m")
        store.finish(childSessionId: "c1", status: .completed, messages: [
            .user(UserMessage(text: "a")),
            .assistant(fauxAssistantMessage("b")),
        ])
        let tool = createSubagentHistoryTool(store: store, sessionId: "p")
        let body = reviewText(try await tool.execute(
            "h", .object(["agent_id": .string("short"), "offset": .int(10)]), nil, nil
        ))
        #expect(!body.contains("messages 3–2 of 2"))
    }

    @Test("tail with offset 0 is the tail; tail with a real offset is rejected; blank ids list children")
    func historyArgumentSemantics() async throws {
        let store = SubagentHistoryStore()
        store.begin(childSessionId: "c1", parentSessionId: "p", agentId: "sem", subagentType: "mini", prompt: "p", model: "m")
        let messages: [Message] = (0..<30).map { index in
            index % 2 == 0 ? .user(UserMessage(text: "u\(index)")) : .assistant(fauxAssistantMessage("a\(index)"))
        }
        store.finish(childSessionId: "c1", status: .completed, messages: messages)
        let tool = createSubagentHistoryTool(store: store, sessionId: "p")
        let tail = try await tool.execute("t", .object(["agent_id": .string("sem"), "tail": .int(3), "offset": .int(0)]), nil, nil)
        #expect(reviewText(tail).contains("messages 28–30 of 30"))
        await #expect(throws: CodingToolError.self) {
            _ = try await tool.execute("t", .object(["agent_id": .string("sem"), "tail": .int(3), "offset": .int(2)]), nil, nil)
        }
        let index = reviewText(try await tool.execute("i", .object(["agent_id": .string("  "), "task_id": .null]), nil, nil))
        #expect(index.contains("| sem | mini | completed | 1 |"))
    }

    // MARK: - Blank-argument normalization

    @Test("normalization drops only optional top-level blanks, leaves required and nested values, and ignores non-objects")
    func blankNormalizationBoundaries() {
        var tool = AgentTool(
            name: "probe",
            label: "probe",
            description: "probe",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "req": .object(["type": .string("string")]),
                    "opt": .object(["type": .string("string")]),
                    "nested": .object(["type": .string("object")]),
                    "flag": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("req")]),
            ]),
            execute: { _, _, _, _ in AgentToolResult(content: []) }
        )
        let args: JSONValue = .object([
            "req": .string("  "),
            "opt": .string(" \n"),
            "nested": .object(["inner": .null, "s": .string("")]),
            "flag": .bool(false),
            "extra": .null,
        ])
        #expect(tool.normalizingBlankOptionalArguments(args) == args, "tools that did not opt in are untouched")
        tool.omitsBlankOptionalArguments = true
        let normalized = tool.normalizingBlankOptionalArguments(args)
        #expect(normalized == .object([
            "req": .string("  "),
            "nested": .object(["inner": .null, "s": .string("")]),
            "flag": .bool(false),
        ]))
        #expect(tool.normalizingBlankOptionalArguments(.string("")) == .string(""))
        #expect(tool.normalizingBlankOptionalArguments(.null) == .null)
    }

    @Test("agent_send with a blank required message fails instead of being normalized away")
    func agentSendBlankRequiredMessage() async throws {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(reviewYield("done"))])
        let toolset = reviewToolset(model: faux.getModel(), sessionId: "blank-parent")
        _ = try await reviewTool(toolset, "agent").execute("launch", reviewLaunchArgs(), nil, nil)
        let send = try reviewTool(toolset, "agent_send")
        let normalized = send.normalizingBlankOptionalArguments(.object([
            "agent_id": .string("mini-1"),
            "message": .string("   "),
            "timeout": .string(""),
            "run_in_background": .null,
        ]))
        #expect(normalized == .object(["agent_id": .string("mini-1"), "message": .string("   ")]))
        await #expect(throws: CodingToolError.self) {
            _ = try await send.execute("s", normalized, nil, nil)
        }
        // The failed send must not leave the child claimed as queued.
        let snapshot = try await reviewTool(toolset, "agent_history").execute(
            "h", .object(["agent_id": .string("mini-1")]), nil, nil
        )
        #expect(reviewDetail(snapshot, "status") == "completed")
    }
}

// MARK: - Helpers

private func reviewToolset(
    model: Model,
    sessionId: String,
    manager: BackgroundTaskManager? = nil,
    limits: SubagentLimits = SubagentLimits()
) -> SubagentToolset {
    createSubagentToolset(
        cwd: FileManager.default.currentDirectoryPath,
        model: model,
        childTools: .readOnly,
        subagents: [SubagentDefinition(
            name: "mini",
            description: "Review probe child.",
            prompt: "Complete the test and use the required yield tool.",
            tools: .readOnly
        )],
        backgroundManager: manager,
        sessionId: sessionId,
        limits: limits,
        bashEnvironment: testBashEnvironment
    )
}

private func reviewTool(_ toolset: SubagentToolset, _ name: String) throws -> AgentTool {
    try #require(toolset.tools.first { $0.name == name })
}

private func reviewLaunchArgs(name: String? = nil, background: Bool = false) -> JSONValue {
    var args: [String: JSONValue] = [
        "description": .string("review probe"),
        "prompt": .string("do the review probe"),
        "subagent_type": .string("mini"),
    ]
    if let name { args["name"] = .string(name) }
    if background { args["run_in_background"] = .bool(true) }
    return .object(args)
}

private func reviewYield(_ result: String) -> AssistantMessage {
    fauxAssistantMessage(
        blocks: [fauxToolCall(
            name: "subagent_yield",
            arguments: .object(["status": .string("complete"), "result": .string(result)]),
            id: UUID().uuidString
        )],
        stopReason: .toolUse
    )
}

private func reviewText(_ result: AgentToolResult) -> String {
    result.content.compactMap { block -> String? in
        guard case .text(let text) = block else { return nil }
        return text.text
    }.joined(separator: "\n")
}

private func reviewDetail(_ result: AgentToolResult, _ key: String) -> String? {
    guard case .object(let details) = result.details ?? .null,
          case .string(let value) = details[key] ?? .null else { return nil }
    return value
}

private func reviewMessageTexts(_ message: Message) -> [String] {
    switch message {
    case .user(let user):
        return user.content.compactMap { block in
            if case .text(let text) = block { return text.text }
            return nil
        }
    case .assistant(let assistant):
        return assistant.content.compactMap { block in
            switch block {
            case .text(let text): return text.text
            case .toolCall(let call):
                if case .object(let args) = call.arguments,
                   case .string(let result) = args["result"] ?? .null { return result }
                return nil
            default: return nil
            }
        }
    case .toolResult(let result):
        return result.content.compactMap { block in
            if case .text(let text) = block { return text.text }
            return nil
        }
    }
}

private final class ReviewBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

private final class ReviewLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
