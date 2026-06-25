import Foundation
import Testing
@testable import KWWKAI

@Suite("Settings store")
struct SettingsStoreTests {
    // MARK: helpers

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ json: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.data(using: .utf8)!.write(to: url)
    }

    // MARK: missing-file defaults

    @Test("missing files yield empty defaults")
    func missingFilesDefault() {
        let dir = tempDir()
        let store = SettingsStore.load(
            globalPath: dir.appendingPathComponent("global.json"),
            projectPath: dir.appendingPathComponent("project.json"))
        #expect(store.merged == .empty)
        #expect(store.merged.defaultModel == nil)
        #expect(store.merged.resolvedThinkingLevel == .off)
        #expect(store.merged.resolvedTheme == nil)
        #expect(store.merged.telemetryOptOut == false)
    }

    // MARK: deep-merge precedence

    @Test("project settings override global; unset keys fall through")
    func deepMergePrecedence() {
        let dir = tempDir()
        let globalURL = dir.appendingPathComponent("global.json")
        let projectURL = dir.appendingPathComponent("project.json")
        write(#"{"defaultModel":"global-model","theme":"dark","defaultProvider":"openai"}"#, to: globalURL)
        write(#"{"defaultModel":"project-model","defaultThinkingLevel":"high"}"#, to: projectURL)

        let store = SettingsStore.load(globalPath: globalURL, projectPath: projectURL)
        // Project wins.
        #expect(store.merged.defaultModel == "project-model")
        #expect(store.merged.defaultThinkingLevel == .high)
        // Global falls through where project is silent.
        #expect(store.merged.theme == "dark")
        #expect(store.merged.defaultProvider == "openai")
    }

    @Test("nested unknown objects deep-merge recursively")
    func deepMergeNestedObjects() {
        let dir = tempDir()
        let globalURL = dir.appendingPathComponent("global.json")
        let projectURL = dir.appendingPathComponent("project.json")
        write(#"{"retry":{"enabled":true,"maxRetries":3}}"#, to: globalURL)
        write(#"{"retry":{"maxRetries":5}}"#, to: projectURL)

        let store = SettingsStore.load(globalPath: globalURL, projectPath: projectURL)
        guard case .object(let retry)? = store.merged.extra["retry"] else {
            Issue.record("retry not preserved as object")
            return
        }
        #expect(retry["enabled"] == .bool(true))   // from global
        #expect(retry["maxRetries"] == .int(5))     // overridden by project
    }

    @Test("typed getters: telemetry opt-out")
    func telemetryOptOut() {
        var s = Settings.empty
        #expect(s.telemetryOptOut == false)
        s.enableInstallTelemetry = false
        #expect(s.telemetryOptOut == true)
        s.enableAnalytics = true
        #expect(s.telemetryOptOut == false)
    }

    // MARK: env-var expansion

    @Test("env templates expand from the provided environment")
    func envExpansion() {
        let env = ["TOKEN": "abc123", "HOST": "example.com"]
        #expect(ConfigValue.resolve("${TOKEN}", env: env) == "abc123")
        #expect(ConfigValue.resolve("$TOKEN", env: env) == "abc123")
        #expect(ConfigValue.resolve("https://$HOST/api", env: env) == "https://example.com/api")
        #expect(ConfigValue.resolve("Bearer ${TOKEN}", env: env) == "Bearer abc123")
    }

    @Test("missing env var makes the template resolve to nil")
    func envMissing() {
        #expect(ConfigValue.resolve("${NOPE_NOT_SET}", env: [:]) == nil)
        #expect(ConfigValue.resolve("prefix-${NOPE}", env: [:]) == nil)
    }

    @Test("dollar escapes and literals")
    func envEscapes() {
        #expect(ConfigValue.resolve("$$5.00", env: [:]) == "$5.00")
        #expect(ConfigValue.resolve("plain literal", env: [:]) == "plain literal")
        #expect(ConfigValue.envVarNames("${A}-${B}-${A}") == ["A", "B"])
    }

    // MARK: !shell expansion

    @Test("bang prefix runs a shell command and uses trimmed stdout")
    func shellExpansion() {
        #expect(ConfigValue.isCommand("!echo hi"))
        #expect(ConfigValue.resolve("!echo hello-world") == "hello-world")
        // Trimming of trailing newline.
        #expect(ConfigValue.resolve("!printf '  spaced  \n'") == "spaced")
    }

    @Test("failing command resolves to nil")
    func shellFailure() {
        #expect(ConfigValue.resolve("!exit 1") == nil)
        #expect(ConfigValue.resolve("!true") == nil) // empty stdout -> nil
    }

    @Test("shell command resolution times out")
    func shellTimeout() {
        let start = Date()
        let output = ConfigValue.runCommand("while true; do :; done", timeoutSeconds: 0.05)
        #expect(output == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
