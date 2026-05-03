import ApplicationServices
import Foundation

private let chromiumAXObserverNoopCallback: AXObserverCallbackWithInfo = { _, _, _, _, _ in }

final class ChromiumAccessibilityActivation: @unchecked Sendable {
    static let shared = ChromiumAccessibilityActivation()

    private typealias AddNotificationAndCheckRemoteFn = @convention(c) (
        AXObserver,
        AXUIElement,
        CFString,
        UnsafeMutableRawPointer?
    ) -> AXError

    private static let addNotificationAndCheckRemote: AddNotificationAndCheckRemoteFn? = {
        _ = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY
        )

        for name in [
            "_AXObserverAddNotificationAndCheckRemote",
            "AXObserverAddNotificationAndCheckRemote",
        ] {
            if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
                return unsafeBitCast(symbol, to: AddNotificationAndCheckRemoteFn.self)
            }
        }
        return nil
    }()

    private let lock = NSLock()
    private var activatedPIDs = Set<pid_t>()
    private var observers: [pid_t: AXObserver] = [:]

    func activateIfNeeded(pid: pid_t, root: AXUIElement) {
        lock.lock()
        let alreadyActivated = activatedPIDs.contains(pid)
        lock.unlock()

        guard assertChromiumAccessibility(root: root) else {
            return
        }

        guard !alreadyActivated else {
            return
        }

        lock.lock()
        let inserted = activatedPIDs.insert(pid).inserted
        lock.unlock()
        guard inserted else {
            return
        }

        registerObserver(pid: pid, root: root)
        pumpRunLoopForActivation(duration: 0.5)
    }

    private func assertChromiumAccessibility(root: AXUIElement) -> Bool {
        let attributes = [
            "AXManualAccessibility",
            "AXEnhancedUserInterface",
        ]

        var accepted = false
        for attribute in attributes {
            let result = AXUIElementSetAttributeValue(
                root,
                attribute as CFString,
                kCFBooleanTrue
            )
            accepted = accepted || result == .success
        }
        return accepted
    }

    private func registerObserver(pid: pid_t, root: AXUIElement) {
        var observer: AXObserver?
        guard AXObserverCreateWithInfoCallback(
            pid,
            chromiumAXObserverNoopCallback,
            &observer
        ) == .success, let observer else {
            return
        }

        if let source = AXObserverGetRunLoopSource(observer) as CFRunLoopSource? {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
        }

        for notification in notifications {
            _ = addNotification(observer: observer, element: root, notification: notification)
        }

        lock.lock()
        observers[pid] = observer
        lock.unlock()
    }

    private func addNotification(
        observer: AXObserver,
        element: AXUIElement,
        notification: CFString
    ) -> AXError {
        if let fn = Self.addNotificationAndCheckRemote {
            return fn(observer, element, notification, nil)
        }
        return AXObserverAddNotification(observer, element, notification, nil)
    }

    private func pumpRunLoopForActivation(duration: CFTimeInterval) {
        let deadline = CFAbsoluteTimeGetCurrent() + duration
        while CFAbsoluteTimeGetCurrent() < deadline {
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, remaining, false)
        }
    }

    private let notifications: [CFString] = [
        kAXFocusedUIElementChangedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXApplicationActivatedNotification as CFString,
        kAXApplicationDeactivatedNotification as CFString,
        kAXApplicationHiddenNotification as CFString,
        kAXApplicationShownNotification as CFString,
        kAXWindowCreatedNotification as CFString,
        kAXWindowMovedNotification as CFString,
        kAXWindowResizedNotification as CFString,
        kAXValueChangedNotification as CFString,
        kAXTitleChangedNotification as CFString,
        kAXSelectedChildrenChangedNotification as CFString,
        kAXLayoutChangedNotification as CFString,
    ]
}
