import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

@Suite("/compact-model command")
struct CompactionModelCommandTests {
    @MainActor
    @Test("command is registered, reports status, and clears an override")
    func registeredStatusAndClear() async {
        let main = testModel(id: "main", provider: "main-provider")
        let summary = testModel(id: "summary", provider: "summary-provider")
        let (ctx, harness) = makeContext(main: main)
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)

        #expect(registry.find("compact-model") != nil)
        #expect(registry.find("compaction-model")?.name == "compact-model")

        await registry.find("compact-model")?.handler(ctx, "status")
        #expect(harness.notified.contains("main"))
        #expect(harness.notified.contains("follows /model"))

        ctx.agent.compactionModel = summary
        harness.notifiedLines.removeAll()
        await registry.find("compact-model")?.handler(ctx, "status")
        #expect(harness.notified.contains("summary"))
        #expect(harness.notified.contains("override"))

        harness.notifiedLines.removeAll()
        await registry.find("compact-model")?.handler(ctx, "clear")
        #expect(ctx.agent.compactionModel == nil)
        #expect(ctx.agent.state.model.id == main.id)
        #expect(harness.notified.contains("now following /model"))
    }

    @MainActor
    @Test("picker selects a routed model from another provider without changing the chat model")
    func pickerSelectsCrossProviderModel() async {
        let main = testModel(
            id: "main",
            provider: "main-provider",
            baseURL: "https://main.example/v1"
        )
        let summary = testModel(
            id: "summary",
            provider: "summary-provider",
            baseURL: "https://summary.example/v1"
        )
        let providers = SessionProviders([
            ProviderSlot(
                storeId: "main-login",
                catalogProvider: "test-main-catalog",
                displayName: "Main Provider",
                template: main
            ),
            ProviderSlot(
                storeId: "summary-login",
                catalogProvider: "test-summary-catalog",
                displayName: "Summary Provider",
                template: summary
            ),
        ])
        let (ctx, harness) = makeContext(main: main, providers: providers)
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)

        await registry.find("compact-model")?.handler(ctx, "")
        #expect(ctx.modal.isOpen)
        #expect((harness.modalLines ?? []).joined().contains("Select a compaction model"))

        ctx.modal.routeDown()
        ctx.modal.routeConfirm()

        #expect(!ctx.modal.isOpen)
        #expect(ctx.agent.state.model.id == main.id)
        #expect(ctx.agent.state.model.provider == main.provider)
        #expect(ctx.agent.compactionModel?.id == summary.id)
        #expect(ctx.agent.compactionModel?.provider == summary.provider)
        #expect(ctx.agent.compactionModel?.baseURL == summary.baseURL)
        #expect(harness.notified.contains("summaries now use summary"))
        #expect(harness.notified.contains("summary-provider"))
    }

    @MainActor
    @Test("logged-out picker points to login")
    func loggedOutPicker() async {
        let (ctx, harness) = makeContext(main: loggedOutModel)
        let registry = SlashCommandRegistry()
        registerBuiltinSlashCommands(registry)

        await registry.find("compact-model")?.handler(ctx, "set")

        #expect(!ctx.modal.isOpen)
        #expect(harness.notified.contains("/login to sign in"))
    }

    @MainActor
    private func makeContext(
        main: Model,
        providers: SessionProviders = SessionProviders()
    ) -> (SlashContext, CompactionModelCommandHarness) {
        let harness = CompactionModelCommandHarness()
        let modal = ModalHost(
            renderModalLines: { harness.modalLines = $0 },
            restoreTranscript: {},
            requestRender: {}
        )
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-compact-model-\(UUID().uuidString.prefix(8))")
        let context = SlashContext(
            agent: Agent(initialState: AgentInitialState(model: main)),
            modal: modal,
            backgroundManager: BackgroundTaskManager(outputDir: outputDir),
            sessionId: "compact-model-command",
            notifyBlock: { harness.notifiedLines.append(contentsOf: $0) },
            commitScrollback: { _ in },
            refreshTranscript: {},
            sessionProviders: providers
        )
        return (context, harness)
    }

    private func testModel(
        id: String,
        provider: String,
        baseURL: String = ""
    ) -> Model {
        Model(
            id: id,
            name: id,
            api: "test-api",
            provider: provider,
            baseURL: baseURL,
            contextWindow: 8_000,
            maxTokens: 1_000
        )
    }
}

@MainActor
private final class CompactionModelCommandHarness {
    var modalLines: [String]?
    var notifiedLines: [String] = []
    var notified: String { notifiedLines.joined(separator: "\n") }
}
