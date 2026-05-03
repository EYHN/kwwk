import AppKit
import Carbon.HIToolbox
import Foundation

extension MouseButton {
    var cgMouseButton: CGMouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
    }

    var downEventType: CGEventType {
        switch self {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .middle: .otherMouseDown
        }
    }

    var draggedEventType: CGEventType {
        switch self {
        case .left: .leftMouseDragged
        case .right: .rightMouseDragged
        case .middle: .otherMouseDragged
        }
    }

    var upEventType: CGEventType {
        switch self {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .middle: .otherMouseUp
        }
    }
}

struct BackgroundMouseDispatcher {
    let targetPID: pid_t
    let windowNumber: Int
    let windowFrame: CGRect
    let modifierFlags: CGEventFlags

    func click(at windowLocalPoint: CGPoint, button: MouseButton = .left) throws {
        let screenPoint = screenPoint(from: windowLocalPoint)
        logFocusState("pid click start button=\(button.rawValue) point=\(formatPoint(windowLocalPoint))")
        postMouse(button.downEventType, at: screenPoint, button: button, clickState: 1, pressure: 1)
        usleep(30_000)
        postMouse(button.upEventType, at: screenPoint, button: button, clickState: 1, pressure: 0)
        logFocusState("pid click end")
    }

    func startDrag(at windowLocalPoint: CGPoint, button: MouseButton = .left) throws -> DragHandle {
        let screenPoint = screenPoint(from: windowLocalPoint)
        logFocusState("pid drag start button=\(button.rawValue) point=\(formatPoint(windowLocalPoint))")
        postMouse(.mouseMoved, at: screenPoint, button: button, clickState: 0, pressure: 0)
        usleep(15_000)
        postMouse(button.downEventType, at: screenPoint, button: button, clickState: 1, pressure: 1)
        return DragHandle(dispatcher: self, button: button)
    }

    fileprivate func postDragMove(
        handle: DragHandle,
        windowLocalPoint: CGPoint
    ) throws {
        let screenPoint = screenPoint(from: windowLocalPoint)
        postMouse(handle.button.draggedEventType, at: screenPoint, button: handle.button, clickState: 1, pressure: 1)
    }

    fileprivate func postDragUp(
        handle: DragHandle,
        windowLocalPoint: CGPoint
    ) throws {
        let screenPoint = screenPoint(from: windowLocalPoint)
        postMouse(handle.button.upEventType, at: screenPoint, button: handle.button, clickState: 1, pressure: 0)
        logFocusState("pid drag end")
    }

    func scroll(at windowLocalPoint: CGPoint, direction: String, pages: Double) throws {
        let screenPoint = screenPoint(from: windowLocalPoint)
        let pageAmount = max(0.05, pages)
        let ticks = max(1, Int((pageAmount * 8).rounded(.up)))
        let lineDelta: Int32 = 12
        let canonical = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let delta: (x: Int32, y: Int32) = switch canonical {
        case "up": (0, lineDelta)
        case "down": (0, -lineDelta)
        case "left": (lineDelta, 0)
        case "right": (-lineDelta, 0)
        default:
            throw ComputerUseError.invalidArgument("unsupported scroll direction \(direction)")
        }

        logFocusState("pid scroll start direction=\(canonical) point=\(formatPoint(windowLocalPoint))")

        for _ in 0 ..< ticks {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 2,
                wheel1: delta.y,
                wheel2: delta.x,
                wheel3: 0
            ) else {
                throw UIElementError.synthesizedEventCreationFailed(type: "scroll")
            }
            event.location = screenPoint
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID))
            event.setWindowAddressingFields(windowNumber: windowNumber)
            event.postToPid(targetPID)
            usleep(8_000)
        }
        logFocusState("pid scroll end")
    }

    private func postMouse(
        _ type: CGEventType,
        at screenPoint: CGPoint,
        button: MouseButton,
        clickState: Int64,
        pressure: Double
    ) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: screenPoint,
            mouseButton: button.cgMouseButton
        ) else {
            return
        }
        event.flags = modifierFlags
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber))
        event.setWindowAddressingFields(windowNumber: windowNumber)
        event.postToPid(targetPID)
    }

    private func screenPoint(from windowLocalPoint: CGPoint) -> CGPoint {
        axScreenPoint(
            fromWindowLocal: Point<WindowLocalSpace>(windowLocalPoint),
            windowFrame: windowFrame
        ).cgPoint
    }

    private func logFocusState(_ label: String) {
        guard FocusDebug.isEnabled else { return }
        let targetDescription: String
        if let app = NSRunningApplication(processIdentifier: targetPID) {
            let name = app.localizedName ?? app.bundleIdentifier ?? "unknown"
            targetDescription = "\(name) pid=\(app.processIdentifier) bundle=\(app.bundleIdentifier ?? "-") active=\(app.isActive) hidden=\(app.isHidden)"
        } else {
            targetDescription = "pid=\(targetPID) unavailable"
        }
        FocusDebug.log(
            "\(label): frontmost=\(FocusDebug.frontmostDescription()) target=\(targetDescription) window=\(windowNumber) \(FocusDebug.windowStackDescription(windowNumber: windowNumber, targetPID: targetPID))"
        )
    }

    private func formatPoint(_ point: CGPoint) -> String {
        "(\(Int(point.x.rounded())),\(Int(point.y.rounded())))"
    }
}

enum FocusDebug {
    static var isEnabled: Bool {
        ComputerUseDebug.focusEnabled
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("[cu-focus] \(message)\n".utf8))
    }

    static func frontmostDescription() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "nil"
        }
        let name = app.localizedName ?? app.bundleIdentifier ?? "unknown"
        return "\(name) pid=\(app.processIdentifier) bundle=\(app.bundleIdentifier ?? "-") active=\(app.isActive) hidden=\(app.isHidden)"
    }

    static func windowStackDescription(windowNumber: Int, targetPID: pid_t) -> String {
        guard windowNumber != 0,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]]
        else {
            return "z=unavailable"
        }

        var normalLayerIndex = 0
        var targetIndex: Int?
        var frontLayer0: String?

        for entry in list {
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let windowID = entry[kCGWindowNumber as String] as? Int ?? 0
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "unknown"

            if frontLayer0 == nil {
                frontLayer0 = "\(owner) pid=\(ownerPID) window=\(windowID)"
            }
            if windowID == windowNumber {
                targetIndex = normalLayerIndex
            }
            normalLayerIndex += 1
        }

        let targetText = targetIndex.map(String.init) ?? "missing"
        let frontText = frontLayer0 ?? "none"
        return "z_index=\(targetText) front_layer0=\(frontText) target_pid=\(targetPID)"
    }
}

struct DragHandle {
    fileprivate let dispatcher: BackgroundMouseDispatcher
    fileprivate let button: MouseButton

    mutating func move(to windowLocalPoint: CGPoint) throws {
        try dispatcher.postDragMove(handle: self, windowLocalPoint: windowLocalPoint)
    }

    mutating func release(at windowLocalPoint: CGPoint) throws {
        try dispatcher.postDragUp(handle: self, windowLocalPoint: windowLocalPoint)
    }
}

struct BackgroundKeyboardDispatcher {
    let targetPID: pid_t
    let windowNumber: Int

    private let source = CGEventSource(stateID: .hidSystemState)

    func typeText(_ text: String) throws {
        guard text.isEmpty == false else { return }

        for cluster in text {
            let units: [UniChar] = Array(String(cluster).utf16)
            try units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress, buffer.count > 0 else { return }
                guard
                    let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                    let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                else {
                    throw ComputerUseError.invalidArgument("keyboard event creation failed")
                }

                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                postKeyEvent(down)

                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                postKeyEvent(up)
            }

            usleep(1_000)
        }
    }

    func press(keyCombination: String) throws {
        let combo = try KeyCombination.parse(keyCombination)

        for modifier in combo.modifiers {
            let event = try buildKeyEvent(
                keyCode: modifier.virtualKey,
                flags: modifier.flags,
                isDown: true
            )
            postKeyEvent(event)
        }

        let combinedFlags = combo.modifiers.reduce(into: CGEventFlags()) { partial, modifier in
            partial.formUnion(modifier.flags)
        }

        let down = try buildKeyEvent(keyCode: combo.keyCode, flags: combinedFlags, isDown: true)
        postKeyEvent(down)

        let up = try buildKeyEvent(keyCode: combo.keyCode, flags: combinedFlags, isDown: false)
        postKeyEvent(up)

        var remainingFlags = combinedFlags
        for modifier in combo.modifiers.reversed() {
            remainingFlags.subtract(modifier.flags)
            let event = try buildKeyEvent(
                keyCode: modifier.virtualKey,
                flags: remainingFlags,
                isDown: false
            )
            postKeyEvent(event)
        }
    }

    private func postKeyEvent(_ event: CGEvent) {
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID))
        event.setWindowAddressingFields(windowNumber: windowNumber)
        event.postToPid(targetPID)
    }

    private func buildKeyEvent(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isDown: Bool
    ) throws -> CGEvent {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: isDown
        ) else {
            throw ComputerUseError.invalidArgument("keyboard event creation failed")
        }

        event.flags = flags
        return event
    }
}

private struct KeyCombination {
    let modifiers: [KeyModifier]
    let keyCode: CGKeyCode

    static func parse(_ raw: String) throws -> KeyCombination {
        let segments = raw
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        guard let final = segments.last, final.isEmpty == false else {
            throw ComputerUseError.unsupportedKey(raw)
        }

        let modifiers = try segments.dropLast().map(KeyModifier.init(token:))
        let keyCode = try keyCode(for: final)
        return KeyCombination(modifiers: modifiers, keyCode: keyCode)
    }

    private static func keyCode(for token: String) throws -> CGKeyCode {
        if token.count == 1, let scalar = token.unicodeScalars.first {
            switch scalar {
            case "a" ... "z":
                return alphaKeyCodes[String(scalar)]!
            case "0" ... "9":
                return digitKeyCodes[String(scalar)]!
            default:
                break
            }
        }

        guard let keyCode = namedKeyCodes[token] else {
            throw ComputerUseError.unsupportedKey(token)
        }
        return keyCode
    }
}

private struct KeyModifier {
    let flags: CGEventFlags
    let virtualKey: CGKeyCode

    init(token: String) throws {
        switch token {
        case "shift":
            flags = .maskShift
            virtualKey = CGKeyCode(kVK_Shift)
        case "control", "ctrl":
            flags = .maskControl
            virtualKey = CGKeyCode(kVK_Control)
        case "option", "alt":
            flags = .maskAlternate
            virtualKey = CGKeyCode(kVK_Option)
        case "command", "cmd", "super", "meta":
            flags = .maskCommand
            virtualKey = CGKeyCode(kVK_Command)
        default:
            throw ComputerUseError.unsupportedKey(token)
        }
    }
}

private let alphaKeyCodes: [String: CGKeyCode] = [
    "a": CGKeyCode(kVK_ANSI_A),
    "b": CGKeyCode(kVK_ANSI_B),
    "c": CGKeyCode(kVK_ANSI_C),
    "d": CGKeyCode(kVK_ANSI_D),
    "e": CGKeyCode(kVK_ANSI_E),
    "f": CGKeyCode(kVK_ANSI_F),
    "g": CGKeyCode(kVK_ANSI_G),
    "h": CGKeyCode(kVK_ANSI_H),
    "i": CGKeyCode(kVK_ANSI_I),
    "j": CGKeyCode(kVK_ANSI_J),
    "k": CGKeyCode(kVK_ANSI_K),
    "l": CGKeyCode(kVK_ANSI_L),
    "m": CGKeyCode(kVK_ANSI_M),
    "n": CGKeyCode(kVK_ANSI_N),
    "o": CGKeyCode(kVK_ANSI_O),
    "p": CGKeyCode(kVK_ANSI_P),
    "q": CGKeyCode(kVK_ANSI_Q),
    "r": CGKeyCode(kVK_ANSI_R),
    "s": CGKeyCode(kVK_ANSI_S),
    "t": CGKeyCode(kVK_ANSI_T),
    "u": CGKeyCode(kVK_ANSI_U),
    "v": CGKeyCode(kVK_ANSI_V),
    "w": CGKeyCode(kVK_ANSI_W),
    "x": CGKeyCode(kVK_ANSI_X),
    "y": CGKeyCode(kVK_ANSI_Y),
    "z": CGKeyCode(kVK_ANSI_Z),
]

private let digitKeyCodes: [String: CGKeyCode] = [
    "0": CGKeyCode(kVK_ANSI_0),
    "1": CGKeyCode(kVK_ANSI_1),
    "2": CGKeyCode(kVK_ANSI_2),
    "3": CGKeyCode(kVK_ANSI_3),
    "4": CGKeyCode(kVK_ANSI_4),
    "5": CGKeyCode(kVK_ANSI_5),
    "6": CGKeyCode(kVK_ANSI_6),
    "7": CGKeyCode(kVK_ANSI_7),
    "8": CGKeyCode(kVK_ANSI_8),
    "9": CGKeyCode(kVK_ANSI_9),
]

private let namedKeyCodes: [String: CGKeyCode] = [
    "space": CGKeyCode(kVK_Space),
    "tab": CGKeyCode(kVK_Tab),
    "return": CGKeyCode(kVK_Return),
    "enter": CGKeyCode(kVK_Return),
    "escape": CGKeyCode(kVK_Escape),
    "esc": CGKeyCode(kVK_Escape),
    "delete": CGKeyCode(kVK_Delete),
    "backspace": CGKeyCode(kVK_Delete),
    "forward-delete": CGKeyCode(kVK_ForwardDelete),
    "left": CGKeyCode(kVK_LeftArrow),
    "right": CGKeyCode(kVK_RightArrow),
    "up": CGKeyCode(kVK_UpArrow),
    "down": CGKeyCode(kVK_DownArrow),
    "home": CGKeyCode(kVK_Home),
    "end": CGKeyCode(kVK_End),
    "pageup": CGKeyCode(kVK_PageUp),
    "pagedown": CGKeyCode(kVK_PageDown),
]
