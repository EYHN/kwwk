import Foundation

public final class ComputerUseClient: @unchecked Sendable {
    public let session: ComputerUseSession
    public var screenshotCompression: ComputerUseScreenshotCompression

    public init(
        session: ComputerUseSession = ComputerUseSession(),
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault
    ) {
        self.session = session
        self.screenshotCompression = screenshotCompression
    }

    deinit {
        finish()
    }

    public func finish() {
        session.finish()
    }

    public func listApps() -> ComputerUseCommandOutput {
        ComputerUseAction.listApps()
    }

    public func openApp(_ appIdentifier: String) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.openApp(appIdentifier: appIdentifier)
    }

    public func listWindows(app appIdentifier: String) throws -> ComputerUseCommandOutput {
        try ComputerUseAction.listWindows(appIdentifier: appIdentifier)
    }

    public func getAppState(
        app appIdentifier: String,
        windowTitle: String? = nil,
        includeScreenshot: Bool = false
    ) throws -> ComputerUseCommandOutput {
        try ComputerUseAction.getAppState(
            appIdentifier: appIdentifier,
            windowTitle: windowTitle,
            includeScreenshot: includeScreenshot,
            screenshotCompression: screenshotCompression
        )
    }

    public func click(
        snapshotID: String,
        elementIndex: Int,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.click(
            snapshotID: snapshotID,
            elementIndex: elementIndex,
            x: nil,
            y: nil,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    public func click(
        snapshotID: String,
        x: Double,
        y: Double,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.click(
            snapshotID: snapshotID,
            elementIndex: nil,
            x: x,
            y: y,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    public func typeText(
        snapshotID: String,
        text: String,
        elementIndex: Int? = nil,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.typeText(
            snapshotID: snapshotID,
            text: text,
            elementIndex: elementIndex,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    public func setValue(
        snapshotID: String,
        elementIndex: Int,
        value: String,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.setValue(
            snapshotID: snapshotID,
            elementIndex: elementIndex,
            value: value,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    public func pressKey(
        snapshotID: String,
        key: String,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.pressKey(
            snapshotID: snapshotID,
            key: key,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    public func scroll(
        snapshotID: String,
        elementIndex: Int,
        direction: String,
        pages: Double = 1,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.scroll(
            snapshotID: snapshotID,
            elementIndex: elementIndex,
            direction: direction,
            pages: pages,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    public func performSecondaryAction(
        snapshotID: String,
        elementIndex: Int,
        action: String,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.performSecondaryAction(
            snapshotID: snapshotID,
            elementIndex: elementIndex,
            action: action,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }

    public func drag(
        snapshotID: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        includeScreenshotAfter: Bool = false
    ) async throws -> ComputerUseCommandOutput {
        try await ComputerUseAction.drag(
            snapshotID: snapshotID,
            fromX: fromX,
            fromY: fromY,
            toX: toX,
            toY: toY,
            includeScreenshotAfter: includeScreenshotAfter,
            session: session,
            screenshotCompression: screenshotCompression
        )
    }
}
