import AppKit
import Foundation

protocol CoordinateSpace {}

enum AXScreenSpace: CoordinateSpace {}
enum AppKitScreenSpace: CoordinateSpace {}
enum WindowLocalSpace: CoordinateSpace {}
enum QuartzWindowSpace: CoordinateSpace {}
enum ScreenshotPixelSpace: CoordinateSpace {}

struct Point<Space: CoordinateSpace>: Equatable {
    var x: CGFloat
    var y: CGFloat

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

func appKitScreenPoint(from point: Point<AXScreenSpace>) -> Point<AppKitScreenSpace> {
    let spaces = DisplayCoordinateSpaceRegistry.current()
    let space = spaces.first(where: { $0.axFrame.contains(point.cgPoint) })
        ?? spaces.min(by: {
            DisplayCoordinateSpaceRegistry.distanceSquared(from: point.cgPoint, to: $0.axFrame) <
                DisplayCoordinateSpaceRegistry.distanceSquared(from: point.cgPoint, to: $1.axFrame)
        })
    guard let space else { return Point(point.cgPoint) }

    let localX = point.x - space.axFrame.minX
    let localY = point.y - space.axFrame.minY
    return Point(
        x: space.appKitFrame.minX + localX,
        y: space.appKitFrame.maxY - localY
    )
}

func axScreenPoint(from point: Point<AppKitScreenSpace>) -> Point<AXScreenSpace> {
    let spaces = DisplayCoordinateSpaceRegistry.current()
    let space = spaces.first(where: { $0.appKitFrame.contains(point.cgPoint) })
        ?? spaces.min(by: {
            DisplayCoordinateSpaceRegistry.distanceSquared(from: point.cgPoint, to: $0.appKitFrame) <
                DisplayCoordinateSpaceRegistry.distanceSquared(from: point.cgPoint, to: $1.appKitFrame)
        })
    guard let space else { return Point(point.cgPoint) }

    let localX = point.x - space.appKitFrame.minX
    let localY = space.appKitFrame.maxY - point.y
    return Point(
        x: space.axFrame.minX + localX,
        y: space.axFrame.minY + localY
    )
}

func axScreenPoint(
    fromWindowLocal point: Point<WindowLocalSpace>,
    windowFrame: CGRect
) -> Point<AXScreenSpace> {
    Point(
        x: point.x + windowFrame.minX,
        y: windowFrame.minY + (windowFrame.height - point.y)
    )
}

func windowLocalPoint(
    fromAXScreen point: Point<AXScreenSpace>,
    windowFrame: CGRect
) -> Point<WindowLocalSpace> {
    Point(
        x: point.x - windowFrame.minX,
        y: windowFrame.height - (point.y - windowFrame.minY)
    )
}

func appKitScreenPoint(
    fromWindowLocal point: Point<WindowLocalSpace>,
    windowFrame: CGRect
) -> Point<AppKitScreenSpace> {
    appKitScreenPoint(
        from: axScreenPoint(fromWindowLocal: point, windowFrame: windowFrame)
    )
}

func windowLocalPoint(
    fromAppKitScreen point: Point<AppKitScreenSpace>,
    windowFrame: CGRect
) -> Point<WindowLocalSpace> {
    windowLocalPoint(
        fromAXScreen: axScreenPoint(from: point),
        windowFrame: windowFrame
    )
}

func quartzWindowPoint(
    fromWindowLocal point: Point<WindowLocalSpace>,
    windowHeight: CGFloat
) -> Point<QuartzWindowSpace> {
    Point(x: point.x, y: windowHeight - point.y)
}

func windowLocalPoint(
    fromScreenshotPixel pixel: Point<ScreenshotPixelSpace>,
    screenshotSize: CGSize,
    windowFrame: CGRect
) -> Point<WindowLocalSpace> {
    let clampedX = min(max(0, pixel.x), screenshotSize.width)
    let clampedY = min(max(0, pixel.y), screenshotSize.height)
    let normalizedX = screenshotSize.width == 0 ? 0 : clampedX / screenshotSize.width
    let normalizedY = screenshotSize.height == 0 ? 0 : clampedY / screenshotSize.height
    return Point(
        x: normalizedX * windowFrame.width,
        y: windowFrame.height - (normalizedY * windowFrame.height)
    )
}

private enum DisplayCoordinateSpaceRegistry {
    struct DisplaySpace {
        let appKitFrame: CGRect
        let axFrame: CGRect
    }

    static func current() -> [DisplaySpace] {
        NSScreen.screens.compactMap { screen in
            guard
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            return DisplaySpace(
                appKitFrame: screen.frame,
                axFrame: CGDisplayBounds(displayID)
            )
        }
    }

    static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx: CGFloat = if point.x < rect.minX {
            rect.minX - point.x
        } else if point.x > rect.maxX {
            point.x - rect.maxX
        } else {
            0
        }

        let dy: CGFloat = if point.y < rect.minY {
            rect.minY - point.y
        } else if point.y > rect.maxY {
            point.y - rect.maxY
        } else {
            0
        }

        return (dx * dx) + (dy * dy)
    }
}
