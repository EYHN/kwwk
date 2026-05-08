import ApplicationServices
import Foundation

public enum ComputerUseAction {
    public static func getAppState(
        appIdentifier: String,
        windowTitle: String?,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) throws -> ComputerUseCommandOutput {
        do {
            let snapshot = try ComputerUseCore.captureSnapshot(
                appIdentifier: appIdentifier,
                selection: WindowSelection(titleSubstring: windowTitle),
                includeScreenshot: includeScreenshot,
                screenshotCompression: screenshotCompression
            )
            return try ComputerUseCore.persistAndFormat(snapshot: snapshot)
        } catch let error as ComputerUseError {
            guard case .windowNotFound = error,
                  let windowTitle,
                  windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                throw error
            }

            let snapshot = try ComputerUseCore.captureSnapshot(
                appIdentifier: appIdentifier,
                includeScreenshot: includeScreenshot,
                screenshotCompression: screenshotCompression
            )
            let output = try ComputerUseCore.persistAndFormat(snapshot: snapshot)
            return ComputerUseCommandOutput(
                text: """
                Requested window_title "\(windowTitle)" was not found; returned the current \(appIdentifier) window instead. After navigation, prefer omitting window_title unless you need a specific stable window.

                \(output.text)
                """,
                metadata: output.metadata
            )
        }
    }

    public static func listApps() -> ComputerUseCommandOutput {
        let lines = ComputerUseCore.listApps().map(ComputerUseCore.formatAppListLine)
        return ComputerUseCommandOutput(text: lines.joined(separator: "\n"))
    }

    public static func openApp(appIdentifier: String) async throws -> ComputerUseCommandOutput {
        let result = try await ComputerUseCore.openApp(appIdentifier: appIdentifier)
        let status = result.didLaunch ? "Opened app:" : "App already running:"
        return ComputerUseCommandOutput(text: """
        \(status)
        \(ComputerUseCore.formatAppListLine(result.app))
        """)
    }

    public static func listWindows(appIdentifier: String) throws -> ComputerUseCommandOutput {
        let windows = try ComputerUseCore.listWindows(appIdentifier: appIdentifier)
        guard let first = windows.first else {
            return ComputerUseCommandOutput(text: "No windows found for \(appIdentifier).")
        }

        var lines = [
            "\(first.appName) — \(first.bundleID) [pid \(first.pid)]",
            "<windows>",
        ]
        for (index, window) in windows.enumerated() {
            var flags: [String] = []
            if window.isMain { flags.append("main") }
            let flagText = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
            lines.append(
                "[\(index)] window_id=\(window.windowID) title=\"\(window.title)\"\(flagText)"
            )
        }
        lines.append("</windows>")
        return ComputerUseCommandOutput(text: lines.joined(separator: "\n"))
    }

    public static func click(
        snapshotID: String,
        elementIndex: Int?,
        x: Double?,
        y: Double?,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        return try session.performWithBackgroundActivation(on: current) {
            if let elementIndex {
                let node = try ComputerUseCore.resolveCachedElement(
                    cachedIndex: elementIndex,
                    metadata: metadata,
                    fresh: current
                )
                if !performDefaultAXActionIfAvailable(on: node, in: current) {
                    let point = try localPoint(node: node, in: current)
                    try clickAtLocalPoint(point, in: current)
                }
            } else if let x, let y {
                try ComputerUseCore.ensureStableFrameForCoordinateAction(
                    metadata: metadata,
                    fresh: current
                )
                let point = try screenshotPointToWindowLocal(
                    screenshotSize: metadata.screenshotSize,
                    windowFrame: current.windowFrame,
                    x: x,
                    y: y
                )
                try clickAtLocalPoint(point, in: current)
            } else {
                throw ComputerUseError.invalidArgument("click requires either element_index or x/y")
            }

            return try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
        }
    }

    public static func typeText(
        snapshotID: String,
        text: String,
        elementIndex: Int?,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        return try session.performWithBackgroundActivation(on: current) {
            let node = try editableNode(
                in: current,
                metadata: metadata,
                explicitIndex: elementIndex
            )

            if cuIsAttributeSettable(node.element, name: kAXFocusedAttribute as String) {
                _ = AXUIElementSetAttributeValue(
                    node.element,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
            }

            let keyboard = BackgroundKeyboardDispatcher(
                targetPID: current.app.processIdentifier,
                windowNumber: current.windowID
            )
            try keyboard.typeText(text)

            return try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
        }
    }

    public static func setValue(
        snapshotID: String,
        elementIndex: Int,
        value: String,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let node = try ComputerUseCore.resolveCachedElement(
            cachedIndex: elementIndex,
            metadata: metadata,
            fresh: current
        )

        guard node.isValueSettable else {
            throw ComputerUseError.elementNotSettable(elementIndex)
        }

        return try session.performWithBackgroundActivation(on: current) {
            if cuIsAttributeSettable(node.element, name: kAXFocusedAttribute as String) {
                _ = AXUIElementSetAttributeValue(
                    node.element,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
            }

            let result = AXUIElementSetAttributeValue(
                node.element,
                kAXValueAttribute as CFString,
                value as CFTypeRef
            )
            guard result == .success else {
                throw UIElementError.axError(result, action: "set AXValue")
            }

            return try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
        }
    }

    public static func pressKey(
        snapshotID: String,
        key: String,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        return try session.performWithBackgroundActivation(on: current) {
            let dispatcher = BackgroundKeyboardDispatcher(
                targetPID: current.app.processIdentifier,
                windowNumber: current.windowID
            )
            try dispatcher.press(keyCombination: key)

            return try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
        }
    }

    public static func scroll(
        snapshotID: String,
        elementIndex: Int,
        direction: String,
        pages: Double,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let node = try ComputerUseCore.resolveCachedElement(
            cachedIndex: elementIndex,
            metadata: metadata,
            fresh: current
        )
        return try session.performWithBackgroundActivation(on: current) {
            let point = try localPoint(node: node, in: current)
            let dispatcher = BackgroundMouseDispatcher(
                targetPID: current.app.processIdentifier,
                windowNumber: current.windowID,
                windowFrame: current.windowFrame,
                modifierFlags: []
            )
            let didAXScroll = performAXScroll(
                startingAt: node.element,
                fallbackRoot: current.windowElement,
                direction: direction,
                pages: pages
            )
            if !didAXScroll {
                try dispatcher.scroll(at: point, direction: direction, pages: pages)
            }

            let output = try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
            guard output.metadata?.fingerprint == current.fingerprint else {
                return output
            }

            let delivery = didAXScroll ? "AX scroll action" : "postToPid wheel fallback"
            return ComputerUseCommandOutput(
                text: """
                Scroll delivery note: \(delivery) produced no observable state change. Do not treat this alone as proof that the list reached its end; if exhaustive traversal is required, try another scrollable container or a keyboard/list-navigation path.

                \(output.text)
                """,
                metadata: output.metadata
            )
        }
    }

    public static func performSecondaryAction(
        snapshotID: String,
        elementIndex: Int,
        action: String,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let node = try ComputerUseCore.resolveCachedElement(
            cachedIndex: elementIndex,
            metadata: metadata,
            fresh: current
        )
        let rawAction = try resolveSecondaryAction(node: node, requestedAction: action)
        return try session.performWithBackgroundActivation(on: current) {
            let result = AXUIElementPerformAction(node.element, rawAction as CFString)
            guard result == .success else {
                throw UIElementError.axError(result, action: rawAction)
            }

            return try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
        }
    }

    public static func drag(
        snapshotID: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        includeScreenshotAfter: Bool,
        session: ComputerUseSession,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) async throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        return try session.performWithBackgroundActivation(on: current) {
            try ComputerUseCore.ensureStableFrameForCoordinateAction(
                metadata: metadata,
                fresh: current
            )
            let fromLocal = try screenshotPointToWindowLocal(
                screenshotSize: metadata.screenshotSize,
                windowFrame: current.windowFrame,
                x: fromX,
                y: fromY
            )
            let toLocal = try screenshotPointToWindowLocal(
                screenshotSize: metadata.screenshotSize,
                windowFrame: current.windowFrame,
                x: toX,
                y: toY
            )

            let dispatcher = BackgroundMouseDispatcher(
                targetPID: current.app.processIdentifier,
                windowNumber: current.windowID,
                windowFrame: current.windowFrame,
                modifierFlags: []
            )

            var handle = try dispatcher.startDrag(at: fromLocal, button: .left)
            let steps = 16
            for step in 1 ... steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(
                    x: fromLocal.x + ((toLocal.x - fromLocal.x) * t),
                    y: fromLocal.y + ((toLocal.y - fromLocal.y) * t)
                )
                try handle.move(to: point)
                usleep(12_000)
            }
            try handle.release(at: toLocal)

            return try settledOutput(
                afterActionOn: current,
                includeScreenshot: includeScreenshotAfter,
                screenshotCompression: screenshotCompression
            )
        }
    }

    private static func localPoint(
        node: RuntimeAXNode,
        in snapshot: RuntimeAppSnapshot
    ) throws -> CGPoint {
        guard let frame = clickFrame(for: node, in: snapshot) else {
            throw ComputerUseError.elementFrameUnavailable(node.index)
        }

        let screenPoint = CGPoint(x: frame.midX, y: frame.midY)
        return translatedWindowLocalPoint(
            screenPoint: screenPoint,
            windowFrame: snapshot.windowFrame
        )
    }

    private static func clickFrame(
        for node: RuntimeAXNode,
        in snapshot: RuntimeAppSnapshot
    ) -> CGRect? {
        if shouldPreferDescendantClickFrame(for: node),
           let descendantFrame = descendantClickFrame(for: node, in: snapshot) {
            return descendantFrame
        }
        return node.frame ?? descendantClickFrame(for: node, in: snapshot)
    }

    private static func shouldPreferDescendantClickFrame(for node: RuntimeAXNode) -> Bool {
        let structuralRoles: Set<String> = [
            kAXGroupRole as String,
            kAXRowRole as String,
            kAXCellRole as String,
        ]
        return structuralRoles.contains(node.role)
    }

    private static func descendantClickFrame(
        for node: RuntimeAXNode,
        in snapshot: RuntimeAppSnapshot
    ) -> CGRect? {
        let start = node.index + 1
        guard start < snapshot.nodes.count else { return nil }

        var frames: [CGRect] = []
        for index in start ..< snapshot.nodes.count {
            let candidate = snapshot.nodes[index]
            guard candidate.depth > node.depth else { break }
            guard let frame = candidate.frame,
                  frame.width >= 2,
                  frame.height >= 2,
                  cuFrameIsVisible(frame, in: snapshot.windowFrame)
            else {
                continue
            }

            if candidate.role == kAXStaticTextRole as String ||
                candidate.role == kAXImageRole as String ||
                candidate.title.isEmpty == false ||
                candidate.description.isEmpty == false {
                frames.append(frame)
            }
        }

        guard frames.isEmpty == false else { return nil }
        let union = frames.dropFirst().reduce(frames[0]) { partial, frame in
            partial.union(frame)
        }
        guard union.height <= max(24, snapshot.windowFrame.height * 0.35),
              union.width <= max(24, snapshot.windowFrame.width * 0.95)
        else {
            return nil
        }
        return union
    }

    private static func clickAtLocalPoint(
        _ localPoint: CGPoint,
        in snapshot: RuntimeAppSnapshot
    ) throws {
        let dispatcher = BackgroundMouseDispatcher(
            targetPID: snapshot.app.processIdentifier,
            windowNumber: snapshot.windowID,
            windowFrame: snapshot.windowFrame,
            modifierFlags: []
        )
        try dispatcher.click(at: localPoint)
    }

    private static func performDefaultAXActionIfAvailable(
        on node: RuntimeAXNode,
        in snapshot: RuntimeAppSnapshot
    ) -> Bool {
        let preferredActions = if node.role == (kAXMenuBarItemRole as String) ||
            node.role == (kAXMenuItemRole as String)
        {
            [kAXPressAction as String, "AXPick"]
        } else {
            [kAXPressAction as String]
        }

        guard let action = preferredActions.first(where: { node.actions.contains($0) }) else {
            return false
        }
        FocusDebug.log("ax \(displayName(forAction: action)) start element=\(node.index): \(focusTargetDescription(snapshot))")
        let succeeded = AXUIElementPerformAction(node.element, action as CFString) == .success
        FocusDebug.log("ax \(displayName(forAction: action)) end success=\(succeeded): \(focusTargetDescription(snapshot))")
        return succeeded
    }

    private static func focusTargetDescription(_ snapshot: RuntimeAppSnapshot) -> String {
        let appName = snapshot.app.localizedName ?? snapshot.app.bundleIdentifier ?? "unknown"
        let target = "\(appName) pid=\(snapshot.app.processIdentifier) bundle=\(snapshot.app.bundleIdentifier ?? "-") active=\(snapshot.app.isActive) hidden=\(snapshot.app.isHidden)"
        return "frontmost=\(FocusDebug.frontmostDescription()) target=\(target) window=\(snapshot.windowID) \(FocusDebug.windowStackDescription(windowNumber: snapshot.windowID, targetPID: snapshot.app.processIdentifier))"
    }

    private static func editableNode(
        in snapshot: RuntimeAppSnapshot,
        metadata: ComputerUseSnapshotMetadata,
        explicitIndex: Int?
    ) throws -> RuntimeAXNode {
        if let explicitIndex {
            let node = try ComputerUseCore.resolveCachedElement(
                cachedIndex: explicitIndex,
                metadata: metadata,
                fresh: snapshot
            )
            guard node.isValueSettable else {
                throw ComputerUseError.elementNotSettable(explicitIndex)
            }
            return node
        }

        guard let focusedIndex = snapshot.focusedElementIndex else {
            throw ComputerUseError.focusedElementUnavailable
        }
        let focused = try snapshot.node(index: focusedIndex)
        guard focused.isValueSettable else {
            throw ComputerUseError.elementNotSettable(focusedIndex)
        }
        return focused
    }

    private static func performAXScroll(
        startingAt element: AXUIElement,
        fallbackRoot: AXUIElement,
        direction: String,
        pages: Double
    ) -> Bool {
        let canonical = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wantsVertical = canonical == "up" || canonical == "down"
        let wantsIncrement = canonical == "down" || canonical == "right"
        let action = wantsIncrement ? (kAXIncrementAction as String) : (kAXDecrementAction as String)
        let roots = [element, fallbackRoot]
        let foundScrollBars = roots.flatMap { scrollBars(in: $0) }
        let matching = foundScrollBars.filter { bar in
            guard let orientation = cuAttribute(bar, name: kAXOrientationAttribute as String) as String? else {
                return true
            }
            if wantsVertical {
                return orientation == (kAXVerticalOrientationValue as String)
            }
            return orientation == (kAXHorizontalOrientationValue as String)
        }

        let repetitions = max(1, Int((max(0.05, pages) * 3).rounded(.up)))
        for bar in matching {
            var performed = false
            for _ in 0 ..< repetitions {
                let result = AXUIElementPerformAction(bar, action as CFString)
                if result != AXError.success { break }
                performed = true
                usleep(20_000)
            }
            if performed {
                return true
            }

            if setScrollBarValue(bar, increment: wantsIncrement, pages: pages) {
                return true
            }
        }
        return false
    }

    private static func scrollBars(in root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var stack = [root]
        var visited = Set<ObjectIdentifier>()
        let relationshipAttributes = [
            kAXChildrenAttribute as String,
            kAXContentsAttribute as String,
            kAXVerticalScrollBarAttribute as String,
            kAXHorizontalScrollBarAttribute as String,
        ]
        while let current = stack.popLast() {
            let identifier = ObjectIdentifier(current as AnyObject)
            if visited.contains(identifier) { continue }
            visited.insert(identifier)

            let role = cuAttribute(current, name: kAXRoleAttribute as String) as String? ?? ""
            if role == (kAXScrollBarRole as String) {
                result.append(current)
                continue
            }

            for attribute in relationshipAttributes {
                if let child = cuAttribute(current, name: attribute) as AXUIElement? {
                    stack.append(child)
                } else if let children = cuAttribute(current, name: attribute) as [AXUIElement]? {
                    stack.append(contentsOf: children)
                }
            }
        }
        return result
    }

    private static func setScrollBarValue(
        _ scrollBar: AXUIElement,
        increment: Bool,
        pages: Double
    ) -> Bool {
        guard cuIsAttributeSettable(scrollBar, name: kAXValueAttribute as String),
              let rawValue = cuRawAttribute(scrollBar, name: kAXValueAttribute as String),
              let current = numericValue(rawValue)
        else {
            return false
        }

        let minValue = numericValue(cuRawAttribute(scrollBar, name: kAXMinValueAttribute as String)) ?? 0
        let maxValue = numericValue(cuRawAttribute(scrollBar, name: kAXMaxValueAttribute as String)) ?? 1
        let span = max(maxValue - minValue, 0.01)
        let delta = span * 0.18 * max(0.05, pages)
        let target = min(max(current + (increment ? delta : -delta), minValue), maxValue)
        guard abs(target - current) > 0.0001 else { return false }

        let number = NSNumber(value: target)
        return AXUIElementSetAttributeValue(
            scrollBar,
            kAXValueAttribute as CFString,
            number
        ) == .success
    }

    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let int as Int:
            return Double(int)
        default:
            return nil
        }
    }

    private static func screenshotPointToWindowLocal(
        screenshotSize: CGSizeCodable?,
        windowFrame: CGRect,
        x: Double,
        y: Double
    ) throws -> CGPoint {
        guard let screenshotSize = screenshotSize?.cgSize else {
            throw ComputerUseError.coordinateActionRequiresScreenshot
        }

        return windowLocalPoint(
            fromScreenshotPixel: CGPoint(x: x, y: y),
            screenshotSize: screenshotSize,
            windowFrame: windowFrame
        )
    }

    private static func resolveSecondaryAction(
        node: RuntimeAXNode,
        requestedAction: String
    ) throws -> String {
        if let raw = node.actions.first(where: {
            $0.caseInsensitiveCompare(requestedAction) == .orderedSame
        }) {
            return raw
        }

        if let display = node.actions.first(where: {
            displayName(forAction: $0).caseInsensitiveCompare(requestedAction) == .orderedSame
        }) {
            return display
        }

        throw ComputerUseError.secondaryActionNotFound(
            elementIndex: node.index,
            action: requestedAction
        )
    }

    private static func settledOutput(
        afterActionOn snapshot: RuntimeAppSnapshot,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression
    ) throws -> ComputerUseCommandOutput {
        let updated = try ComputerUseCore.captureSettledSnapshot(
            afterActionOn: snapshot,
            includeScreenshot: includeScreenshot,
            screenshotCompression: screenshotCompression
        )
        return try ComputerUseCore.persistAndFormat(snapshot: updated)
    }
}
