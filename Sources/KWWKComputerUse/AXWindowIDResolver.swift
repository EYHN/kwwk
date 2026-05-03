import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum AXWindowIDResolver {
    private typealias AXUIElementGetWindowFn = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private static let getWindowForAXElement: AXUIElementGetWindowFn? = {
        _ = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY
        )
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: AXUIElementGetWindowFn.self)
    }()

    static func cgWindowID(forAXWindow element: AXUIElement) -> CGWindowID? {
        guard let getWindowForAXElement else { return nil }
        var windowID: CGWindowID = 0
        guard getWindowForAXElement(element, &windowID) == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }
}
