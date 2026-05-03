import AppKit
import Foundation

public final class ComputerUseSession: @unchecked Sendable {
    private struct ObservationKey: Hashable {
        let pid: pid_t
        let windowID: Int
    }

    private struct Observation {
        let sequence: Int
        let labels: [HarnessLabelEntry]
    }

    private struct ActiveTarget {
        let pid: pid_t
        let windowNumber: Int
        let activation: BackgroundActivationSession

        func matches(_ snapshot: RuntimeAppSnapshot) -> Bool {
            pid == snapshot.app.processIdentifier && windowNumber == snapshot.windowID
        }
    }

    private let lock = NSLock()
    private var activeTarget: ActiveTarget?
    private var observationSequence = 0
    private var initialObservations: [ObservationKey: Observation] = [:]
    private var previousObservations: [ObservationKey: Observation] = [:]
    private var recentActions: [String] = []
    private var finished = false

    public init() {}

    deinit {
        finish()
    }

    public func finish() {
        let target: ActiveTarget? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let target = activeTarget
            activeTarget = nil
            return target
        }
        restoreAndFinish(target)
    }

    func performWithBackgroundActivation<T>(
        on snapshot: RuntimeAppSnapshot,
        _ body: () throws -> T
    ) throws -> T {
        try lock.withLock {
            guard !finished else {
                throw ComputerUseError.invalidArgument("computer use session is already finished")
            }

            let target = try activeTarget(matching: snapshot)
            target.activation.beginTargetDelivery()
            defer {
                target.activation.holdFocusSuppressionUntilFinish()
            }
            return try body()
        }
    }

    func recordAction(_ description: String) {
        lock.withLock {
            guard !finished else { return }
            recentActions.append(description)
            if recentActions.count > 12 {
                recentActions.removeFirst(recentActions.count - 12)
            }
        }
    }

    func annotateObservation(_ output: ComputerUseCommandOutput) -> ComputerUseCommandOutput {
        guard let metadata = output.metadata else {
            return output
        }

        let annotation = lock.withLock {
            guard !finished else { return "" }
            observationSequence += 1
            let key = ObservationKey(pid: metadata.pid, windowID: metadata.windowID)
            let labels = harnessLabelEntries(from: metadata)
            let observation = Observation(
                sequence: observationSequence,
                labels: labels
            )
            let initial = initialObservations[key] ?? observation
            let previous = previousObservations[key]
            initialObservations[key] = initial
            previousObservations[key] = observation

            return harnessAnnotation(
                metadata: metadata,
                observationSequence: observation.sequence,
                initialLabels: initial.labels,
                previousLabels: previous?.labels,
                recentActions: recentActions
            )
        }

        guard annotation.isEmpty == false else {
            return output
        }

        return ComputerUseCommandOutput(
            text: output.text + "\n" + annotation,
            metadata: metadata
        )
    }

    private func activeTarget(matching snapshot: RuntimeAppSnapshot) throws -> ActiveTarget {
        if let activeTarget, activeTarget.matches(snapshot) {
            return activeTarget
        }

        let previousTarget = activeTarget
        activeTarget = nil
        restoreAndFinish(previousTarget)

        let activation = try BackgroundActivationSession.start(
            targetPID: snapshot.app.processIdentifier
        )
        activation.beginTargetDelivery()
        activation.activateWindow(
            windowNumber: snapshot.windowID,
            windowFrame: snapshot.windowFrame
        )

        let next = ActiveTarget(
            pid: snapshot.app.processIdentifier,
            windowNumber: snapshot.windowID,
            activation: activation
        )
        activeTarget = next
        return next
    }

    private func restoreAndFinish(_ target: ActiveTarget?) {
        guard let target else { return }
        target.activation.restoreBackgroundActivationIfNeeded(
            windowNumber: target.windowNumber
        )
        target.activation.finish()
    }
}

struct HarnessLabelEntry: Equatable, Sendable {
    var key: String
    var display: String
}

func harnessAnnotation(
    metadata: ComputerUseSnapshotMetadata,
    observationSequence: Int,
    initialLabels: [HarnessLabelEntry],
    previousLabels: [HarnessLabelEntry]?,
    recentActions: [String]
) -> String {
    let candidateLines = harnessCandidateLines(from: metadata)
    let sincePrevious = harnessDeltaLines(
        current: harnessLabelEntries(from: metadata),
        baseline: previousLabels
    )
    let sinceInitial = harnessDeltaLines(
        current: harnessLabelEntries(from: metadata),
        baseline: initialLabels
    )

    var lines: [String] = [
        "<computer_use_harness>",
        "Observation #\(observationSequence) for \(metadata.appName) window_id=\(metadata.windowID).",
        "For traversal, keep your own visited set using stable visible labels/descriptions, not element indexes.",
        "If the task requires clicking/opening rows, count a row as visited only after a successful action result or current selected/opened state confirms it.",
    ]

    if recentActions.isEmpty == false {
        lines.append("<recent_actions>")
        lines.append(contentsOf: recentActions.suffix(8).map { "- \($0)" })
        lines.append("</recent_actions>")
    }

    if candidateLines.isEmpty == false {
        lines.append("<candidate_targets>")
        lines.append(contentsOf: candidateLines)
        lines.append("</candidate_targets>")
    }

    lines.append("<state_delta since=\"previous\">")
    lines.append("The following is an incremental difference from the previous element tree, with + and - representing added and removed stable labels.")
    lines.append(contentsOf: sincePrevious)
    lines.append("</state_delta>")

    lines.append("<state_delta since=\"initial\">")
    lines.append("The following is a cumulative difference from the initial element tree, with + and - representing added and removed stable labels.")
    lines.append(contentsOf: sinceInitial)
    lines.append("</state_delta>")
    lines.append("</computer_use_harness>")
    return lines.joined(separator: "\n")
}

func harnessLabelEntries(from metadata: ComputerUseSnapshotMetadata) -> [HarnessLabelEntry] {
    var seen = Set<String>()
    var entries: [HarnessLabelEntry] = []
    for signature in metadata.nodeSignatures {
        let display = harnessDisplayLabel(for: signature)
        guard display.isEmpty == false else { continue }
        let key = harnessStableKey(display)
        guard key.isEmpty == false, seen.insert(key).inserted else { continue }
        entries.append(HarnessLabelEntry(key: key, display: display))
    }
    return entries
}

func harnessCandidateLines(
    from metadata: ComputerUseSnapshotMetadata,
    limit: Int = 64
) -> [String] {
    var seen = Set<String>()
    var lines: [String] = []
    for (index, signature) in metadata.nodeSignatures.enumerated() {
        let display = harnessDisplayLabel(for: signature)
        guard display.isEmpty == false,
              harnessIsCandidateTarget(signature),
              seen.insert(harnessStableKey(display)).inserted
        else {
            continue
        }

        let role = harnessRoleName(signature.role)
        lines.append("- element_index=\(index) \(role) \"\(harnessTruncate(display, maxLength: 160))\"")
        if lines.count >= limit { break }
    }
    return lines
}

private func harnessDeltaLines(
    current: [HarnessLabelEntry],
    baseline: [HarnessLabelEntry]?
) -> [String] {
    guard let baseline else {
        return ["initial observation for this window."]
    }

    let currentKeys = Set(current.map(\.key))
    let baselineKeys = Set(baseline.map(\.key))
    let added = current.filter { !baselineKeys.contains($0.key) }
    let removed = baseline.filter { !currentKeys.contains($0.key) }

    guard added.isEmpty == false || removed.isEmpty == false else {
        return ["no stable label changes."]
    }

    var lines: [String] = []
    if added.isEmpty == false {
        lines.append("+ added:")
        lines.append(contentsOf: added.prefix(16).map {
            "+ \"\(harnessTruncate($0.display, maxLength: 160))\""
        })
        if added.count > 16 {
            lines.append("+ ... \(added.count - 16) more")
        }
    }
    if removed.isEmpty == false {
        lines.append("- removed:")
        lines.append(contentsOf: removed.prefix(16).map {
            "- \"\(harnessTruncate($0.display, maxLength: 160))\""
        })
        if removed.count > 16 {
            lines.append("- ... \(removed.count - 16) more")
        }
    }
    return lines
}

func harnessDisplayLabel(for signature: CachedNodeSignature) -> String {
    let title = harnessNormalizeDisplay(signature.title)
    let description = harnessNormalizeDisplay(signature.description ?? "")
    let identifier = harnessNormalizeDisplay(signature.identifier)

    if description.isEmpty == false,
       (title.isEmpty || description.count > title.count + 8 || description.localizedCaseInsensitiveContains(title)) {
        return description
    }
    if title.isEmpty == false {
        return title
    }
    if description.isEmpty == false {
        return description
    }
    return identifier
}

private func harnessIsCandidateTarget(_ signature: CachedNodeSignature) -> Bool {
    switch signature.role {
    case "AXButton",
         "AXRadioButton",
         "AXCheckBox",
         "AXPopUpButton",
         "AXMenuButton",
         "AXMenuItem",
         "AXLink",
         "AXTextField",
         "AXTextArea",
         "AXComboBox",
         "AXGroup",
         "AXRow",
         "AXCell",
         "AXList",
         "AXOutline",
         "AXTable",
         "AXTabGroup":
        return true
    default:
        return false
    }
}

private func harnessNormalizeDisplay(_ value: String) -> String {
    value
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { $0.isEmpty == false }
        .joined(separator: " ")
}

private func harnessStableKey(_ value: String) -> String {
    harnessNormalizeDisplay(value).lowercased()
}

func harnessRoleName(_ role: String) -> String {
    let stripped = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    return stripped.isEmpty ? "element" : stripped.lowercased()
}

func harnessTruncate(_ value: String, maxLength: Int) -> String {
    guard value.count > maxLength else { return value }
    let end = value.index(value.startIndex, offsetBy: maxLength)
    return String(value[..<end]) + "..."
}
