import Foundation
import Testing
@testable import KWWKCli

@Suite("BgNotificationSummary")
struct BgNotificationSummaryTests {

    @Test("parses a completed notification")
    func completed() {
        let text = """
        A background task completed:
        <task-notification>
          <task-id>bg_abc123</task-id>
          <kind>bash</kind>
          <label>install deps</label>
          <status>completed</status>
          <summary>exit 0</summary>
          <exit-code>0</exit-code>
          <duration-ms>2345</duration-ms>
          <output-file>/tmp/kwwk-bg-99/bg_abc123.log</output-file>
          <output-tail>
        + npm install
        added 42 packages in 2s
          </output-tail>
        </task-notification>
        """
        let summary = BgNotificationSummary.parse(text)
        #expect(summary != nil)
        #expect(summary?.label == "install deps")
        #expect(summary?.status == "completed")
        #expect(summary?.summary == "exit 0")
        #expect(summary?.durationMs == 2345)
        #expect(summary?.outputTail == ["+ npm install", "added 42 packages in 2s"])
        #expect(summary?.isError == false)
        #expect(summary?.isStalled == false)
    }

    @Test("parses a stalled notification")
    func stalled() {
        let text = """
        A background task appears stuck and may need attention:
        <task-notification>
          <task-id>bg_xyz</task-id>
          <kind>bash</kind>
          <label>waiting</label>
          <status>stalled</status>
          <duration-ms>60000</duration-ms>
          <output-tail>
        Enter password:
          </output-tail>
        </task-notification>
        """
        let summary = BgNotificationSummary.parse(text)
        #expect(summary?.isStalled == true)
        #expect(summary?.isError == true)  // stalled is rendered as error too
        #expect(summary?.outputTail == ["Enter password:"])
    }

    @Test("non-bg user text returns nil")
    func notBgNotification() {
        #expect(BgNotificationSummary.parse("hello world") == nil)
        #expect(BgNotificationSummary.parse("") == nil)
        // Even if it contains a task-notification tag, without the lead-in
        // we treat it as a real user prompt. (User might be asking about
        // notification formatting.)
        #expect(BgNotificationSummary.parse("<task-notification>hi</task-notification>") == nil)
    }

    @Test("render produces header + body with arms")
    func rendersLikeToolResult() {
        let text = """
        A background task completed:
        <task-notification>
          <task-id>bg_z</task-id>
          <kind>bash</kind>
          <label>echo</label>
          <status>completed</status>
          <summary>exit 0</summary>
          <duration-ms>5</duration-ms>
          <output-tail>
        hi
          </output-tail>
        </task-notification>
        """
        let summary = BgNotificationSummary.parse(text)!
        let lines = summary.render()
        #expect(lines.count >= 2, "expected header + at least one body line, got \(lines)")
        // Header: starts with ● and mentions label + status.
        let header = lines[0]
        #expect(header.contains("bg(echo)"))
        #expect(header.contains("completed"))
        #expect(header.contains("exit 0"))
        #expect(header.contains("5ms"))
        // Body: one `⎿` line with "hi".
        let body = lines.dropFirst().joined()
        #expect(body.contains("⎿"))
        #expect(body.contains("hi"))
    }

    @Test("large output tail gets truncated with a 'more lines' note")
    func truncatesLongTail() {
        let tailLines = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let text = """
        A background task completed:
        <task-notification>
          <label>noisy</label>
          <status>completed</status>
          <summary>exit 0</summary>
          <duration-ms>10</duration-ms>
          <output-tail>
        \(tailLines)
          </output-tail>
        </task-notification>
        """
        let summary = BgNotificationSummary.parse(text)!
        let lines = summary.render()
        // 1 header + 4 preview + 1 "more lines" = 6 lines.
        #expect(lines.count == 6)
        #expect(lines.last?.contains("8 more") == true)
    }
}
