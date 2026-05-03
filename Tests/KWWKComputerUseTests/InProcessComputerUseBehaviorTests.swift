import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation
import KWWKAI
import Testing
@testable import KWWKComputerUse

@_silgen_name("GetProcessForPID")
private func testGetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

@_silgen_name("SetFrontProcessWithOptions")
private func testSetFrontProcessWithOptions(_ psn: UnsafePointer<ProcessSerialNumber>, _ options: UInt32) -> OSStatus

@Suite("Computer use in-process background behavior", .serialized)
struct InProcessComputerUseBehaviorTests {
    @Test("direct product actions preserve background focus invariants")
    func directProductActionsPreserveBackgroundFocusInvariants() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_CU_RUN_GUI_PROBE_TESTS"] == "1" else {
            return
        }
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility permission is required for GUI Probe tests.")
            return
        }
        guard ProbeHarness.bundleExists("A"),
              ProbeHarness.bundleExists("B"),
              ProbeHarness.bundleExists("C")
        else {
            Issue.record("Probe apps are missing under /private/tmp/kwwk-activation-probe.")
            return
        }

        try await verifyClickByElement()
        try await verifyClickByCoordinate()
        try await verifyTypeText()
        try await verifyAXValueAndPress()
        try await verifySessionSwitchingRestoresPreviousBackgroundTarget()
    }

    @Test("coordinate clicks land at requested Probe window locations")
    func coordinateClicksLandAtRequestedProbeWindowLocations() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_CU_RUN_GUI_PROBE_TESTS"] == "1" else {
            return
        }
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility permission is required for GUI Probe tests.")
            return
        }
        guard ProbeHarness.bundleExists("A"),
              ProbeHarness.bundleExists("B"),
              ProbeHarness.bundleExists("C")
        else {
            Issue.record("Probe apps are missing under /private/tmp/kwwk-activation-probe.")
            return
        }

        try await verifyCoordinateClickLocation(
            windowLocalPoint: CGPoint(x: 355, y: 200),
            eventPrefix: "root.mouseDown",
            expectedClickDelta: 0
        )
        try await verifyCoordinateClickLocation(
            windowLocalPoint: CGPoint(x: 108, y: 53),
            eventPrefix: "button.mouseDown",
            expectedClickDelta: 1
        )
    }

    @Test("Probe global menu bar click returns menu AX tree")
    func probeGlobalMenuBarClickReturnsMenuAXTree() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_CU_RUN_GUI_PROBE_TESTS"] == "1" else {
            return
        }
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility permission is required for GUI Probe tests.")
            return
        }
        guard ProbeHarness.bundleExists("A"),
              ProbeHarness.bundleExists("B"),
              ProbeHarness.bundleExists("C")
        else {
            Issue.record("Probe apps are missing under /private/tmp/kwwk-activation-probe.")
            return
        }

        try await verifyGlobalMenuBarClickReturnsMenuAXTree()
    }

    @Test("Probe window menu button click returns menu AX tree")
    func probeWindowMenuButtonClickReturnsMenuAXTree() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_CU_RUN_GUI_PROBE_TESTS"] == "1" else {
            return
        }
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility permission is required for GUI Probe tests.")
            return
        }
        guard ProbeHarness.bundleExists("A"),
              ProbeHarness.bundleExists("B"),
              ProbeHarness.bundleExists("C")
        else {
            Issue.record("Probe apps are missing under /private/tmp/kwwk-activation-probe.")
            return
        }

        try await verifyWindowMenuButtonClickReturnsMenuAXTree()
    }

    private func verifyClickByElement() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = ComputerUseSession()
        defer { session.finish() }
        let snapshot = try await getProbeBState(includeScreenshot: false)
        let buttonIndex = try index(containingIdentifier: "probe-button", in: snapshot.text)

        _ = try await ComputerUseAgent.executeAction(
            action: "click",
            args: [
                "snapshot_id": .string(try #require(snapshot.metadata?.id)),
                "element_index": .int(buttonIndex),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        try ProbeHarness.expectInvariant(
            baseline: baseline,
            context: context,
            expectedClicks: baseline.clicks + 1
        )
    }

    private func verifyClickByCoordinate() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = ComputerUseSession()
        defer { session.finish() }
        let snapshot = try await getProbeBState(includeScreenshot: true)
        let metadata = try #require(snapshot.metadata)
        let buttonFrame = try ProbeHarness.axFrame(
            try ProbeHarness.findElement(inProbeB: context) {
                ProbeHarness.axString($0, kAXIdentifierAttribute as String) == "probe-button"
            }
        )
        let coordinate = screenshotCoordinate(
            screenPoint: CGPoint(x: buttonFrame.midX, y: buttonFrame.midY),
            windowFrame: metadata.windowFrame.cgRect,
            screenshotSize: try #require(metadata.screenshotSize).cgSize
        )

        _ = try await ComputerUseAgent.executeAction(
            action: "click",
            args: [
                "snapshot_id": .string(metadata.id),
                "x": .double(coordinate.x),
                "y": .double(coordinate.y),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        try ProbeHarness.expectInvariant(
            baseline: baseline,
            context: context,
            expectedClicks: baseline.clicks + 1
        )
    }

    private func verifyTypeText() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = ComputerUseSession()
        defer { session.finish() }
        let snapshot = try await getProbeBState(includeScreenshot: false)
        let inputIndex = try index(containingIdentifier: "probe-input", in: snapshot.text)

        _ = try await ComputerUseAgent.executeAction(
            action: "type-text",
            args: [
                "snapshot_id": .string(try #require(snapshot.metadata?.id)),
                "element_index": .int(inputIndex),
                "text": .string("ip"),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        let input = try ProbeHarness.findElement(inProbeB: context) {
            ProbeHarness.axString($0, kAXIdentifierAttribute as String) == "probe-input"
        }
        #expect(ProbeHarness.axString(input, kAXValueAttribute as String) == "ip")
        try ProbeHarness.expectInvariant(
            baseline: baseline,
            context: context,
            expectedClicks: baseline.clicks
        )
    }

    private func verifyAXValueAndPress() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = ComputerUseSession()
        defer { session.finish() }
        let snapshot = try await getProbeBState(includeScreenshot: false)
        let inputIndex = try index(containingIdentifier: "probe-input", in: snapshot.text)
        let buttonIndex = try index(containingIdentifier: "probe-button", in: snapshot.text)

        _ = try await ComputerUseAgent.executeAction(
            action: "set-value",
            args: [
                "snapshot_id": .string(try #require(snapshot.metadata?.id)),
                "element_index": .int(inputIndex),
                "value": .string("ax"),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        let postSetSnapshot = try await getProbeBState(includeScreenshot: false)
        _ = try await ComputerUseAgent.executeAction(
            action: "perform-secondary-action",
            args: [
                "snapshot_id": .string(try #require(postSetSnapshot.metadata?.id)),
                "element_index": .int(buttonIndex),
                "action": .string("Press"),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        let input = try ProbeHarness.findElement(inProbeB: context) {
            ProbeHarness.axString($0, kAXIdentifierAttribute as String) == "probe-input"
        }
        #expect(ProbeHarness.axString(input, kAXValueAttribute as String) == "ax")
        try ProbeHarness.expectInvariant(
            baseline: baseline,
            context: context,
            expectedClicks: baseline.clicks + 1
        )
    }

    private func verifyCoordinateClickLocation(
        windowLocalPoint expectedPoint: CGPoint,
        eventPrefix: String,
        expectedClickDelta: Int
    ) async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = ComputerUseSession()
        defer { session.finish() }
        let beforeLog = ProbeHarness.logText("ProbeB")
        let snapshot = try await getProbeBState(includeScreenshot: true)
        let metadata = try #require(snapshot.metadata)
        let coordinate = screenshotCoordinate(
            windowLocalPoint: expectedPoint,
            windowFrame: metadata.windowFrame.cgRect,
            screenshotSize: try #require(metadata.screenshotSize).cgSize
        )

        _ = try await ComputerUseAgent.executeAction(
            action: "click",
            args: [
                "snapshot_id": .string(metadata.id),
                "x": .double(coordinate.x),
                "y": .double(coordinate.y),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        let newLog = String(ProbeHarness.logText("ProbeB").dropFirst(beforeLog.count))
        let actualPoint = try #require(ProbeHarness.latestLoggedPoint(in: newLog, prefix: eventPrefix))
        #expect(ProbeHarness.distance(actualPoint, expectedPoint) <= 2)
        try ProbeHarness.expectInvariant(
            baseline: baseline,
            context: context,
            expectedClicks: baseline.clicks + expectedClickDelta
        )
    }

    private func verifySessionSwitchingRestoresPreviousBackgroundTarget() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = ComputerUseSession()
        defer { session.finish() }

        let probeBSnapshot = try await getProbeState("B", includeScreenshot: false)
        let probeBButton = try index(containingIdentifier: "probe-button", in: probeBSnapshot.text)
        _ = try await ComputerUseAgent.executeAction(
            action: "click",
            args: [
                "snapshot_id": .string(try #require(probeBSnapshot.metadata?.id)),
                "element_index": .int(probeBButton),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        try ProbeHarness.expectInvariant(
            baseline: baseline,
            context: context,
            expectedClicks: baseline.clicks + 1
        )

        let probeCSnapshot = try await getProbeState("C", includeScreenshot: false)
        let probeCButton = try index(containingIdentifier: "probe-button", in: probeCSnapshot.text)
        _ = try await ComputerUseAgent.executeAction(
            action: "click",
            args: [
                "snapshot_id": .string(try #require(probeCSnapshot.metadata?.id)),
                "element_index": .int(probeCButton),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        ProbeHarness.pump(0.35)
        #expect(ProbeHarness.lastState("ProbeB")?.contains("isActive=false") == true)
        #expect(ProbeHarness.lastState("ProbeC")?.contains("isActive=true") == true)
        #expect(ProbeHarness.stack(ids: context.ids) == baseline.stack)
        #expect(ProbeHarness.frontmost() == baseline.frontmost)

        session.finish()
        ProbeHarness.pump(0.35)
        #expect(ProbeHarness.lastState("ProbeC")?.contains("isActive=false") == true)
        #expect(ProbeHarness.stack(ids: context.ids) == baseline.stack)
        #expect(ProbeHarness.frontmost() == baseline.frontmost)
    }

    private func verifyGlobalMenuBarClickReturnsMenuAXTree() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = ComputerUseSession()
        defer { session.finish() }

        let snapshot = try await getProbeBState(includeScreenshot: false)
        #expect(snapshot.text.contains("\n\t") && snapshot.text.contains("ProbeB"))
        #expect(!snapshot.text.contains("Apple, Secondary Actions"))
        let appMenuIndex = try index(containingAll: ["ProbeB", "Secondary Actions: Cancel, Pick"], in: snapshot.text)

        let output = try await ComputerUseAgent.executeAction(
            action: "click",
            args: [
                "snapshot_id": .string(try #require(snapshot.metadata?.id)),
                "element_index": .int(appMenuIndex),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        #expect(output.text.contains("0 ProbeB"))
        #expect(output.text.contains("\n\t1 menu"))
        #expect(output.text.contains("ProbeB Probe About"))
        #expect(output.text.contains("The focused UI element") == false || output.text.contains("menu"))

        if let metadata = output.metadata {
            _ = try? await ComputerUseAgent.executeAction(
                action: "press-key",
                args: [
                    "snapshot_id": .string(metadata.id),
                    "key": .string("Escape"),
                    "include_screenshot_after": .bool(false),
                ],
                screenshotCompression: .foregroundDefault,
                session: session
            )
        }

        ProbeHarness.pump(0.35)
        #expect(ProbeHarness.clicks("ProbeB") == baseline.clicks)
    }

    private func verifyWindowMenuButtonClickReturnsMenuAXTree() async throws {
        let context = try ProbeHarness.reset()
        let baseline = ProbeHarness.captureBaseline(context)
        let session = ComputerUseSession()
        defer { session.finish() }

        let snapshot = try await getProbeBState(includeScreenshot: false)
        let menuButtonIndex = try index(containingIdentifier: "probe-menu-button", in: snapshot.text)

        let output = try await ComputerUseAgent.executeAction(
            action: "click",
            args: [
                "snapshot_id": .string(try #require(snapshot.metadata?.id)),
                "element_index": .int(menuButtonIndex),
                "include_screenshot_after": .bool(false),
            ],
            screenshotCompression: .foregroundDefault,
            session: session
        )

        #expect(output.text.contains("0 menu"))
        #expect(output.text.contains("First Choice"))
        #expect(output.text.contains("Second Choice"))

        if let metadata = output.metadata {
            _ = try? await ComputerUseAgent.executeAction(
                action: "press-key",
                args: [
                    "snapshot_id": .string(metadata.id),
                    "key": .string("Escape"),
                    "include_screenshot_after": .bool(false),
                ],
                screenshotCompression: .foregroundDefault,
                session: session
            )
        }

        ProbeHarness.pump(0.35)
        #expect(ProbeHarness.clicks("ProbeB") == baseline.clicks)
    }

    private func getProbeBState(includeScreenshot: Bool) async throws -> ComputerUseCommandOutput {
        try await getProbeState("B", includeScreenshot: includeScreenshot)
    }

    private func getProbeState(_ key: String, includeScreenshot: Bool) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAgent.executeAction(
            action: "get-app-state",
            args: [
                "app": .string("com.kwwk.activationprobe.\(key.lowercased())"),
                "window_title": .string("Probe\(key) AppKit Activation Probe"),
                "include_screenshot": .bool(includeScreenshot),
            ],
            screenshotCompression: .foregroundDefault
        )
    }

    private func index(containingIdentifier identifier: String, in state: String) throws -> Int {
        try index(containingAll: ["ID: \(identifier)"], in: state)
    }

    private func index(containingAll fragments: [String], in state: String) throws -> Int {
        for rawLine in state.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard fragments.allSatisfy({ line.contains($0) }) else { continue }
            let token = line.split(separator: " ").first ?? ""
            if let value = Int(token) {
                return value
            }
        }
        throw ComputerUseError.invalidArgument("missing element containing \(fragments.joined(separator: ", "))")
    }

    private func screenshotCoordinate(
        screenPoint: CGPoint,
        windowFrame: CGRect,
        screenshotSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: ((screenPoint.x - windowFrame.minX) / windowFrame.width) * screenshotSize.width,
            y: ((screenPoint.y - windowFrame.minY) / windowFrame.height) * screenshotSize.height
        )
    }

    private func screenshotCoordinate(
        windowLocalPoint: CGPoint,
        windowFrame: CGRect,
        screenshotSize: CGSize
    ) -> CGPoint {
        screenshotCoordinate(
            screenPoint: CGPoint(
                x: windowFrame.minX + windowLocalPoint.x,
                y: windowFrame.maxY - windowLocalPoint.y
            ),
            windowFrame: windowFrame,
            screenshotSize: screenshotSize
        )
    }
}

private enum ProbeHarness {
    struct Context {
        let a: NSRunningApplication
        let b: NSRunningApplication
        let c: NSRunningApplication
        let ids: [String: Int]
    }

    struct Baseline {
        let stack: String
        let frontmost: String
        let cursor: CGPoint
        let clicks: Int
    }

    private static let root = URL(fileURLWithPath: "/private/tmp/kwwk-activation-probe", isDirectory: true)
    private static let bundles = [
        "A": ("com.kwwk.activationprobe.a", root.appendingPathComponent("ProbeA.app", isDirectory: true)),
        "B": ("com.kwwk.activationprobe.b", root.appendingPathComponent("ProbeB.app", isDirectory: true)),
        "C": ("com.kwwk.activationprobe.c", root.appendingPathComponent("ProbeC.app", isDirectory: true)),
    ]

    static func bundleExists(_ key: String) -> Bool {
        guard let url = bundles[key]?.1 else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func reset() throws -> Context {
        terminateAll()
        try launch("B")
        pump(0.25)
        try launch("C")
        pump(0.25)
        try launch("A")
        pump(0.45)
        guard let a = app("A"), let b = app("B"), let c = app("C") else {
            throw ComputerUseError.invalidArgument("Probe apps did not launch")
        }
        try setFront(a.processIdentifier)
        pump(0.35)
        let windowIDB = try windowID(pid: b.processIdentifier)
        return Context(
            a: a,
            b: b,
            c: c,
            ids: [
                "A": try windowID(pid: a.processIdentifier),
                "B": windowIDB,
                "C": try windowID(pid: c.processIdentifier),
            ]
        )
    }

    static func captureBaseline(_ context: Context) -> Baseline {
        Baseline(
            stack: stack(ids: context.ids),
            frontmost: frontmost(),
            cursor: CGEvent(source: nil)?.location ?? .zero,
            clicks: clicks()
        )
    }

    static func expectInvariant(
        baseline: Baseline,
        context: Context,
        expectedClicks: Int
    ) throws {
        let currentState = lastState("ProbeB") ?? ""
        #expect(stack(ids: context.ids) == baseline.stack)
        #expect(frontmost() == baseline.frontmost)
        #expect(distance(CGEvent(source: nil)?.location ?? .zero, baseline.cursor) <= 1)
        #expect(clicks() == expectedClicks)
        #expect(currentState.contains("isActive=true"))
        #expect(currentState.contains("isKey=true"))
        #expect(currentState.contains("isMain=true"))
        #expect(currentState.contains("front=ProbeA"))
    }

    static func findElement(
        inProbeB context: Context,
        matches: (AXUIElement) -> Bool
    ) throws -> AXUIElement {
        try findElement(root: firstWindow(of: AXUIElementCreateApplication(context.b.processIdentifier)), matches: matches)
    }

    static func axFrame(_ element: AXUIElement) throws -> CGRect {
        guard let rawPosition = rawAttribute(element, kAXPositionAttribute as String),
              let rawSize = rawAttribute(element, kAXSizeAttribute as String)
        else {
            throw ComputerUseError.invalidArgument("missing AX frame")
        }
        let position = rawPosition as! AXValue
        let size = rawSize as! AXValue
        var point = CGPoint.zero
        var cgSize = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &cgSize)
        return CGRect(origin: point, size: cgSize)
    }

    static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        rawAttribute(element, attribute) as? String
    }

    static func logText(_ appName: String) -> String {
        (try? String(
            contentsOf: URL(fileURLWithPath: "/private/tmp/\(appName).activation.log"),
            encoding: .utf8
        )) ?? ""
    }

    static func latestLoggedPoint(in logText: String, prefix: String) -> CGPoint? {
        for line in logText.split(separator: "\n").reversed() {
            guard line.contains(prefix),
                  let start = line.range(of: "loc=(")?.upperBound,
                  let end = line[start...].firstIndex(of: ")")
            else {
                continue
            }
            let coordinates = line[start ..< end].split(separator: ",")
            guard coordinates.count == 2,
                  let x = Double(coordinates[0]),
                  let y = Double(coordinates[1])
            else {
                continue
            }
            return CGPoint(x: x, y: y)
        }
        return nil
    }

    static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private static func terminateAll() {
        for (_, (bundleID, _)) in bundles {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                app.terminate()
            }
        }
        pump(0.8)
        for (_, (bundleID, _)) in bundles {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                app.forceTerminate()
            }
        }
        pump(0.15)
    }

    private static func launch(_ key: String) throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let semaphore = DispatchSemaphore(value: 0)
        final class LaunchResultBox: @unchecked Sendable {
            let lock = NSLock()
            var error: Error?
        }
        let box = LaunchResultBox()
        NSWorkspace.shared.openApplication(at: bundles[key]!.1, configuration: config) { _, error in
            box.lock.withLock {
                box.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        let error = box.lock.withLock { box.error }
        if let error {
            throw error
        }
    }

    private static func app(_ key: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundles[key]!.0).first
    }

    private static func setFront(_ pid: pid_t) throws {
        var psn = ProcessSerialNumber()
        guard testGetProcessForPID(pid, &psn) == noErr else {
            throw ComputerUseError.invalidArgument("failed to resolve process serial number")
        }
        _ = testSetFrontProcessWithOptions(&psn, UInt32(kSetFrontProcessFrontWindowOnly | kSetFrontProcessCausedByUser))
    }

    private static func firstWindow(of app: AXUIElement) throws -> AXUIElement {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement], let window = windows.first else {
            throw ComputerUseError.invalidArgument("failed to resolve ProbeB window")
        }
        return window
    }

    private static func findElement(
        root: AXUIElement,
        matches: (AXUIElement) -> Bool
    ) throws -> AXUIElement {
        if matches(root) {
            return root
        }
        for attribute in [kAXChildrenAttribute as String, kAXContentsAttribute as String] {
            guard let rawValue = rawAttribute(root, attribute) else { continue }
            if let children = rawValue as? [AXUIElement] {
                for child in children {
                    if let found = try? findElement(root: child, matches: matches) {
                        return found
                    }
                }
            } else {
                let child = rawValue as! AXUIElement
                if let found = try? findElement(root: child, matches: matches) {
                    return found
                }
            }
        }
        throw ComputerUseError.invalidArgument("failed to find AX element")
    }

    private static func rawAttribute(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func windowID(pid: pid_t) throws -> Int {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw ComputerUseError.invalidArgument("failed to read CG windows")
        }
        for window in windows where
            (window[kCGWindowOwnerPID as String] as? pid_t) == pid &&
            (window[kCGWindowLayer as String] as? Int) == 0 {
            if let id = window[kCGWindowNumber as String] as? Int {
                return id
            }
        }
        throw ComputerUseError.invalidArgument("failed to find Probe window id")
    }

    static func stack(ids: [String: Int]) -> String {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return "unavailable"
        }
        var order: [String] = []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let id = window[kCGWindowNumber as String] as? Int ?? 0
            for (key, target) in ids where target == id {
                order.append(key)
            }
        }
        return order.joined(separator: ">")
    }

    static func frontmost() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "nil" }
        return "\(app.localizedName ?? "?"):\(app.processIdentifier)"
    }

    static func clicks(_ appName: String = "ProbeB") -> Int {
        guard let state = lastState(appName),
              let match = state.split(separator: " ").first(where: { $0.hasPrefix("clicks=") }),
              let value = Int(match.dropFirst("clicks=".count))
        else {
            return 0
        }
        return value
    }

    static func lastState(_ appName: String) -> String? {
        let url = URL(fileURLWithPath: "/private/tmp/\(appName).activation.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let line = text.split(separator: "\n").reversed().first(where: { $0.contains("isActive=") }),
              let range = line.range(of: "isActive=")
        else {
            return nil
        }
        return String(line[range.lowerBound...])
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
