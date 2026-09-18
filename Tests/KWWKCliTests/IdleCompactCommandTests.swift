import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

@MainActor
private final class NotifyBox {
    private(set) var lines: [String] = []
    func append(_ s: String) { lines.append(s) }
    var joined: String { lines.joined(separator: "\n") }
}

@MainActor
private func makeStubModalHost() -> ModalHost {
    ModalHost(renderModalLines: { _ in }, restoreTranscript: {}, requestRender: {})
}

private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kwwk-idle-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("/idle-compact command")
struct IdleCompactCommandTests {

    @Test("threshold and delay arguments parse without ambiguity")
    func parsing() {
        #expect(parseIdleThreshold("50%") == .ratio(0.5))
        #expect(parseIdleThreshold("50") == .ratio(0.5))
        #expect(parseIdleThreshold("0.4") == .ratio(0.4))
        #expect(parseIdleThreshold("150k") == .tokens(150_000))
        #expect(parseIdleThreshold("1.5K") == .tokens(1_500))
        #expect(parseIdleThreshold("0k") == nil)
        #expect(parseIdleThreshold("300") == nil)
        #expect(parseIdleThreshold("5m") == nil)
        #expect(parseIdleDelay("300") == 300)
        #expect(parseIdleDelay("90s") == 90)
        #expect(parseIdleDelay("5m") == 300)
        #expect(parseIdleDelay("1h") == 3600)
        #expect(parseIdleDelay("0") == nil)
        #expect(parseIdleDelay("soon") == nil)
        #expect(IdleCompactionSettings(delaySeconds: 5).delaySeconds == 60)
        #expect(IdleCompactionSettings(delaySeconds: 99_999).delaySeconds == 3600)
    }

    @MainActor
    @Test("toggles and retunes the agent's idle compaction, keeping the host veto")
    func togglesAgentOptions() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(model: faux.getModel(), messages: []))
        defer { agent.retire() }
        let notifier = NotifyBox()
        let ctx = SlashContext(
            agent: agent,
            modal: makeStubModalHost(),
            backgroundManager: BackgroundTaskManager(outputDir: makeTempDir()),
            sessionId: "test-session",
            notifyBlock: { lines in for l in lines { notifier.append(l) } },
            commitScrollback: { _ in },
            refreshTranscript: {}
        )
        ctx.idleCompactVeto = { false }
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)
        let command = registry.find("idle-compact")
        #expect(command != nil)

        await command?.handler(ctx, "")
        #expect(notifier.joined.contains("/idle-compact: off"))
        #expect(agent.idleCompact == nil)

        await command?.handler(ctx, "on 40% 10m")
        #expect(agent.idleCompact?.threshold == .ratio(0.4))
        #expect(agent.idleCompact?.delay == 600)
        #expect(await agent.idleCompact?.canCompact?() == false)
        #expect(notifier.joined.contains("on · at 40% ctx · after 10m idle"))

        await command?.handler(ctx, "200k")
        #expect(agent.idleCompact?.threshold == .tokens(200_000))
        #expect(agent.idleCompact?.delay == 600)
        #expect(notifier.joined.contains("on · at 200k tokens · after 10m idle"))

        await command?.handler(ctx, "bogus")
        #expect(notifier.joined.contains("usage"))
        #expect(agent.idleCompact != nil)

        await command?.handler(ctx, "off")
        #expect(agent.idleCompact == nil)
    }
}
