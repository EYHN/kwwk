import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import KWWKComputerUse

@Suite("Computer use input")
struct ComputerUseInputTests {
    @Test("test target is available")
    func testTargetIsAvailable() {
        #expect(Bool(true))
    }

    @Test("frame visibility uses window intersection")
    func frameVisibilityUsesWindowIntersection() {
        let window = CGRect(x: 100, y: 100, width: 500, height: 400)

        #expect(cuFrameIsVisible(CGRect(x: 120, y: 140, width: 40, height: 30), in: window))
        #expect(cuFrameIsVisible(CGRect(x: 90, y: 90, width: 20, height: 20), in: window))
        #expect(!cuFrameIsVisible(CGRect(x: 0, y: 0, width: 50, height: 50), in: window))
        #expect(!cuFrameIsVisible(CGRect(x: 120, y: 140, width: 0, height: 30), in: window))
        #expect(!cuFrameIsVisible(nil, in: window))
    }

    @Test("meaningful frame visibility rejects barely clipped leaves")
    func meaningfulFrameVisibilityRejectsBarelyClippedLeaves() {
        let window = CGRect(x: 100, y: 100, width: 500, height: 400)

        #expect(cuFrameIsMeaningfullyVisible(CGRect(x: 120, y: 140, width: 40, height: 30), in: window))
        #expect(cuFrameIsMeaningfullyVisible(CGRect(x: 90, y: 90, width: 20, height: 20), in: window))
        #expect(!cuFrameIsMeaningfullyVisible(CGRect(x: 120, y: 495, width: 200, height: 28), in: window))
        #expect(!cuFrameIsMeaningfullyVisible(CGRect(x: 120, y: 140, width: 0, height: 30), in: window))
        #expect(!cuFrameIsMeaningfullyVisible(nil, in: window))
    }

    @Test("structural roles may contain visible descendants")
    func structuralRolesMayContainVisibleDescendants() {
        #expect(roleCanContainVisibleDescendants(kAXGroupRole as String))
        #expect(roleCanContainVisibleDescendants(kAXScrollAreaRole as String))
        #expect(roleCanContainVisibleDescendants(kAXOutlineRole as String))
        #expect(!roleCanContainVisibleDescendants(kAXStaticTextRole as String))
        #expect(!roleCanContainVisibleDescendants(kAXButtonRole as String))
    }

    @Test("descendant clipping falls back when container frame is unreliable")
    func descendantClippingFallsBackWhenContainerFrameIsUnreliable() throws {
        let window = CGRect(x: 100, y: 100, width: 500, height: 400)
        let scrollArea = CGRect(x: 150, y: 150, width: 200, height: 120)
        let outside = CGRect(x: 0, y: 0, width: 50, height: 50)

        #expect(cuDescendantVisibleClip(
            role: kAXScrollAreaRole as String,
            frame: scrollArea,
            inheritedClip: window
        ) == scrollArea)
        #expect(cuDescendantVisibleClip(
            role: kAXScrollAreaRole as String,
            frame: outside,
            inheritedClip: window
        ) == window)
        #expect(cuDescendantVisibleClip(
            role: kAXGroupRole as String,
            frame: outside,
            inheritedClip: window
        ) == window)
    }

    @Test("harness candidates use stable descriptions")
    func harnessCandidatesUseStableDescriptions() {
        let metadata = makeHarnessMetadata(
            id: "snapshot-a",
            signatures: [
                signature(role: kAXWindowRole as String, title: "Main"),
                signature(role: kAXGroupRole as String, description: "Yanyu to You: hello. Apr 29th at 11:40 PM."),
                signature(role: kAXButtonRole as String, title: "Send"),
                signature(role: kAXStaticTextRole as String, title: "Visible message text"),
            ]
        )

        let lines = harnessCandidateLines(from: metadata)

        #expect(lines.contains { $0.contains("element_index=1 group \"Yanyu to You: hello.") })
        #expect(lines.contains { $0.contains("element_index=2 button \"Send\"") })
        #expect(!lines.contains { $0.contains("element_index=3") })
    }

    @Test("harness annotation reports action history and deltas")
    func harnessAnnotationReportsActionHistoryAndDeltas() {
        let first = makeHarnessMetadata(
            id: "snapshot-a",
            signatures: [
                signature(role: kAXGroupRole as String, description: "Alice to You: initial"),
                signature(role: kAXButtonRole as String, title: "Send"),
            ]
        )
        let second = makeHarnessMetadata(
            id: "snapshot-b",
            signatures: [
                signature(role: kAXGroupRole as String, description: "Bob to You: new"),
                signature(role: kAXButtonRole as String, title: "Send"),
            ]
        )
        let session = ComputerUseSession()

        _ = session.annotateObservation(ComputerUseCommandOutput(text: "state", metadata: first))
        session.recordAction("click element_index=1 group \"Alice to You: initial\"")
        let output = session.annotateObservation(ComputerUseCommandOutput(text: "state", metadata: second))

        #expect(output.text.contains("<computer_use_harness>"))
        #expect(output.text.contains("<recent_actions>"))
        #expect(output.text.contains("Bob to You: new"))
        #expect(output.text.contains("Alice to You: initial"))
    }

    @Test("app list format includes usage and running state")
    func appListFormatIncludesUsageAndRunningState() {
        let app = ComputerUseAppDescriptor(
            name: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            pid: 123,
            isRunning: true,
            isFrontmost: true,
            lastUsedDate: Date(timeIntervalSince1970: 1_772_755_200),
            useCount: 435
        )

        #expect(
            ComputerUseCore.formatAppListLine(app) ==
                "Slack — com.tinyspeck.slackmacgap [frontmost, running, last-used=2026-03-06, uses=435]"
        )
    }

    @Test("stale resolver handles menu bar as a second root")
    func staleResolverHandlesMenuBarAsSecondRoot() {
        let cached = [
            signature(depth: 0, role: kAXWindowRole as String, title: "Old Window"),
            signature(depth: 0, role: kAXMenuBarRole as String),
            signature(depth: 1, role: kAXMenuBarItemRole as String, title: "File"),
            signature(depth: 1, role: kAXMenuBarItemRole as String, title: "Help", childIndexAmongSameRole: 1),
        ]
        let fresh = [
            runtimeNode(index: 0, depth: 0, role: kAXWindowRole as String, title: "New Window"),
            runtimeNode(index: 1, depth: 0, role: kAXMenuBarRole as String),
            runtimeNode(index: 2, depth: 1, role: kAXMenuBarItemRole as String, title: "File"),
            runtimeNode(index: 3, depth: 1, role: kAXMenuBarItemRole as String, title: "Help"),
        ]

        #expect(resolveFreshElementIndex(cachedIndex: 3, cached: cached, fresh: fresh) == 3)
    }
}

private func makeHarnessMetadata(
    id: String,
    signatures: [CachedNodeSignature]
) -> ComputerUseSnapshotMetadata {
    ComputerUseSnapshotMetadata(
        id: id,
        createdAt: Date(timeIntervalSince1970: 0),
        appName: "Probe",
        bundleID: "com.example.Probe",
        pid: 123,
        windowTitle: "Probe",
        windowID: 456,
        windowFrame: CGRectCodable(CGRect(x: 0, y: 0, width: 400, height: 300)),
        screenshotPath: nil,
        screenshotSize: nil,
        fingerprint: id,
        nodeSignatures: signatures
    )
}

private func signature(
    depth: Int = 1,
    role: String,
    title: String = "",
    description: String? = nil,
    childIndexAmongSameRole: Int = 0
) -> CachedNodeSignature {
    CachedNodeSignature(
        depth: depth,
        role: role,
        subrole: "",
        title: title,
        description: description,
        identifier: "",
        childIndexAmongSameRole: childIndexAmongSameRole
    )
}

private func runtimeNode(
    index: Int,
    depth: Int,
    role: String,
    title: String = ""
) -> RuntimeAXNode {
    RuntimeAXNode(
        index: index,
        depth: depth,
        element: AXUIElementCreateSystemWide(),
        role: role,
        subrole: "",
        title: title,
        description: "",
        value: nil,
        help: "",
        identifier: "",
        url: nil,
        enabled: nil,
        selected: nil,
        expanded: nil,
        focused: nil,
        frame: nil,
        actions: [],
        isValueSettable: false,
        valueTypeDescription: nil
    )
}
