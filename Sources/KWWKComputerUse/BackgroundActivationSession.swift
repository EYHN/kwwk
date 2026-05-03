import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class BackgroundActivationSession: @unchecked Sendable {
    enum TapKind: String {
        case previous
        case target
    }

    private enum Phase {
        case deliveringToTarget
        case holding
        case finished
    }

    final class TapContext {
        let session: BackgroundActivationSession
        let kind: TapKind

        init(session: BackgroundActivationSession, kind: TapKind) {
            self.session = session
            self.kind = kind
        }
    }

    private static let sessionLock = NSLock()
    // Focus messages do not have a stable public CGEventType across apps/macOS releases.
    // Register broadly, then filter narrowly in shouldDrop(kind:type:event:).
    private static let focusSuppressionEventMask = CGEventMask.max

    private let targetPID: pid_t
    private let previousApp: NSRunningApplication?
    private let stateLock = NSLock()
    private var phase: Phase = .deliveringToTarget
    private var taps: [CFMachPort] = []
    private var contexts: [TapContext] = []
    private var finished = false

    private init(targetPID: pid_t, previousApp: NSRunningApplication?) {
        self.targetPID = targetPID
        self.previousApp = previousApp
    }

    static func start(targetPID: pid_t) throws -> BackgroundActivationSession {
        sessionLock.lock()

        let previousApp = NSWorkspace.shared.frontmostApplication
        let session = BackgroundActivationSession(targetPID: targetPID, previousApp: previousApp)

        do {
            try session.installTapsIfNeeded()
            return session
        } catch {
            session.finish()
            throw error
        }
    }

    func beginTargetDelivery() {
        guard needsSuppression else { return }
        setPhase(.deliveringToTarget)
    }

    func holdFocusSuppressionUntilFinish() {
        guard needsSuppression else { return }
        setPhase(.holding)
    }

    func activateWindow(windowNumber: Int, windowFrame: CGRect) {
        guard windowNumber != 0 else { return }
        let event = NSEvent.otherEvent(
            with: .appKitDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            subtype: Int16(1),
            data1: 0,
            data2: 0
        )?.cgEvent
        guard let event else { return }
        event.setWindowAddressingFields(windowNumber: windowNumber)
        event.postToPid(targetPID)
        usleep(20_000)
        postTitlebarPrimer(windowNumber: windowNumber, windowFrame: windowFrame)
    }

    func restoreBackgroundActivationIfNeeded(windowNumber: Int) {
        guard windowNumber != 0 else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID else {
            FocusDebug.log("skip background restore because target pid=\(targetPID) is frontmost")
            return
        }
        beginTargetDelivery()
        postApplicationFocusEvent(subtype: .applicationDeactivated, windowNumber: windowNumber)
        usleep(20_000)
    }

    private func postApplicationFocusEvent(
        subtype: NSEvent.EventSubtype,
        windowNumber: Int
    ) {
        let event = NSEvent.otherEvent(
            with: .appKitDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            subtype: subtype.rawValue,
            data1: 0,
            data2: 0
        )?.cgEvent
        guard let event else { return }
        event.setWindowAddressingFields(windowNumber: windowNumber)
        event.postToPid(targetPID)
    }

    private func postTitlebarPrimer(windowNumber: Int, windowFrame: CGRect) {
        let point = CGPoint(
            x: windowFrame.minX + min(30, max(1, windowFrame.width / 2)),
            y: windowFrame.minY + min(16, max(1, windowFrame.height / 2))
        )
        postMouse(.leftMouseDown, windowNumber: windowNumber, point: point, clickState: 1, pressure: 1)
        usleep(30_000)
        postMouse(.leftMouseUp, windowNumber: windowNumber, point: point, clickState: 1, pressure: 0)
        usleep(20_000)
    }

    private func postMouse(
        _ type: CGEventType,
        windowNumber: Int,
        point: CGPoint,
        clickState: Int64,
        pressure: Double
    ) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return
        }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.setWindowAddressingFields(windowNumber: windowNumber)
        event.postToPid(targetPID)
    }

    func finish() {
        let shouldUnlock: Bool = stateLock.withLock {
            guard !finished else { return false }
            finished = true
            phase = .finished
            return true
        }
        guard shouldUnlock else { return }

        for tap in taps {
            CFMachPortInvalidate(tap)
        }
        taps.removeAll()
        contexts.removeAll()
        Self.sessionLock.unlock()
    }

    deinit {
        finish()
    }

    private var needsSuppression: Bool {
        guard let previousApp else { return false }
        return previousApp.processIdentifier != targetPID
    }

    private func installTapsIfNeeded() throws {
        guard needsSuppression, let previousApp else { return }

        try installTap(kind: .previous, pid: previousApp.processIdentifier)
        try installTap(kind: .target, pid: targetPID)
    }

    private func installTap(kind: TapKind, pid: pid_t) throws {
        let context = TapContext(session: self, kind: kind)
        let pointer = Unmanaged.passUnretained(context).toOpaque()

        guard let tap = CGEvent.tapCreateForPid(
            pid: pid,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.focusSuppressionEventMask,
            callback: backgroundActivationEventTapCallback,
            userInfo: pointer
        ) else {
            throw ComputerUseError.invalidArgument("failed to install focus suppression event tap for pid \(pid)")
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        contexts.append(context)
        taps.append(tap)
    }

    func shouldDrop(kind: TapKind, type: CGEventType, event: CGEvent) -> Bool {
        guard isFocusMessage(type: type, event: event) else { return false }

        let currentPhase = stateLock.withLock { phase }
        switch currentPhase {
        case .deliveringToTarget:
            return kind == .previous
        case .holding:
            return true
        case .finished:
            return false
        }
    }

    private func setPhase(_ newPhase: Phase) {
        stateLock.withLock {
            phase = newPhase
        }
    }

    private func isFocusMessage(type: CGEventType, event: CGEvent) -> Bool {
        if type.rawValue == 13 || type.rawValue == 19 || type.rawValue == 20 {
            return true
        }
        guard let nsEvent = NSEvent(cgEvent: event) else {
            return false
        }
        return nsEvent.type.rawValue == 13
    }
}

private let backgroundActivationEventTapCallback: CGEventTapCallBack = { _, type, event, rawContext in
    guard let rawContext else {
        return Unmanaged.passUnretained(event)
    }

    let context = Unmanaged<BackgroundActivationSession.TapContext>
        .fromOpaque(rawContext)
        .takeUnretainedValue()

    if context.session.shouldDrop(kind: context.kind, type: type, event: event) {
        if FocusDebug.isEnabled, let nsEvent = NSEvent(cgEvent: event) {
            FocusDebug.log(
                "drop focus event kind=\(context.kind.rawValue) raw=\(type.rawValue) ns=\(nsEvent.type.rawValue) subtype=\(nsEvent.subtype.rawValue)"
            )
        }
        return nil
    }

    return Unmanaged.passUnretained(event)
}

extension CGEvent {
    // Private CGEvent fields used with postToPid to address a concrete target window
    // without posting through the global HID event tap.
    private static let targetWindowNumberField = CGEventField(rawValue: 51)
    private static let privateWindowRoutingField = CGEventField(rawValue: 58)

    func setWindowAddressingFields(windowNumber: Int) {
        if let windowNumberField = Self.targetWindowNumberField {
            setIntegerValueField(windowNumberField, value: Int64(windowNumber))
        }
        if let privateRoutingField = Self.privateWindowRoutingField {
            setIntegerValueField(privateRoutingField, value: 1)
        }
    }
}
