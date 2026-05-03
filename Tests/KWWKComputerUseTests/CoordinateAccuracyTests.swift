import CoreGraphics
import Testing
@testable import KWWKComputerUse

@Suite("Computer use coordinate accuracy")
struct CoordinateAccuracyTests {
    @Test("screenshot pixels map exactly into window-local coordinates")
    func screenshotPixelsMapIntoWindowLocalCoordinates() {
        let windowFrame = CGRect(x: 100, y: 220, width: 800, height: 600)
        let screenshotSize = CGSize(width: 1600, height: 1200)

        expectPoint(
            windowLocalPoint(
                fromScreenshotPixel: CGPoint(x: 0, y: 0),
                screenshotSize: screenshotSize,
                windowFrame: windowFrame
            ),
            equals: CGPoint(x: 0, y: 600)
        )
        expectPoint(
            windowLocalPoint(
                fromScreenshotPixel: CGPoint(x: 800, y: 600),
                screenshotSize: screenshotSize,
                windowFrame: windowFrame
            ),
            equals: CGPoint(x: 400, y: 300)
        )
        expectPoint(
            windowLocalPoint(
                fromScreenshotPixel: CGPoint(x: 1600, y: 1200),
                screenshotSize: screenshotSize,
                windowFrame: windowFrame
            ),
            equals: CGPoint(x: 800, y: 0)
        )
        expectPoint(
            windowLocalPoint(
                fromScreenshotPixel: CGPoint(x: 400, y: 300),
                screenshotSize: screenshotSize,
                windowFrame: windowFrame
            ),
            equals: CGPoint(x: 200, y: 450)
        )
    }

    @Test("screenshot coordinates are clamped before mapping")
    func screenshotCoordinatesAreClampedBeforeMapping() {
        let windowFrame = CGRect(x: 100, y: 220, width: 800, height: 600)
        let screenshotSize = CGSize(width: 1600, height: 1200)

        expectPoint(
            windowLocalPoint(
                fromScreenshotPixel: CGPoint(x: -100, y: -40),
                screenshotSize: screenshotSize,
                windowFrame: windowFrame
            ),
            equals: CGPoint(x: 0, y: 600)
        )
        expectPoint(
            windowLocalPoint(
                fromScreenshotPixel: CGPoint(x: 1900, y: 1400),
                screenshotSize: screenshotSize,
                windowFrame: windowFrame
            ),
            equals: CGPoint(x: 800, y: 0)
        )
    }

    @Test("window-local and AX screen coordinates round-trip")
    func windowLocalAndAXScreenCoordinatesRoundTrip() {
        let windowFrame = CGRect(x: 560, y: 420, width: 380, height: 240)
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 108, y: 53),
            CGPoint(x: 355, y: 200),
            CGPoint(x: 380, y: 240),
        ]

        for point in points {
            let axPoint = axScreenPoint(
                fromWindowLocal: Point<WindowLocalSpace>(point),
                windowFrame: windowFrame
            )
            let roundTrip = windowLocalPoint(
                fromAXScreen: axPoint,
                windowFrame: windowFrame
            )
            expectPoint(roundTrip.cgPoint, equals: point)
        }
    }

    @Test("screenshot coordinate calculation round-trips to AX screen points")
    func screenshotCoordinateCalculationRoundTripsToAXScreenPoints() {
        let windowFrame = CGRect(x: 560, y: 420, width: 380, height: 240)
        let screenshotSize = CGSize(width: 1140, height: 720)
        let screenPoints = [
            CGPoint(x: 560, y: 420),
            CGPoint(x: 668, y: 607),
            CGPoint(x: 915, y: 460),
            CGPoint(x: 940, y: 660),
        ]

        for screenPoint in screenPoints {
            let screenshotPoint = CGPoint(
                x: ((screenPoint.x - windowFrame.minX) / windowFrame.width) * screenshotSize.width,
                y: ((screenPoint.y - windowFrame.minY) / windowFrame.height) * screenshotSize.height
            )
            let windowLocal = windowLocalPoint(
                fromScreenshotPixel: screenshotPoint,
                screenshotSize: screenshotSize,
                windowFrame: windowFrame
            )
            let roundTrip = axScreenPoint(
                fromWindowLocal: Point<WindowLocalSpace>(windowLocal),
                windowFrame: windowFrame
            )
            expectPoint(roundTrip.cgPoint, equals: screenPoint)
        }
    }
}

private func expectPoint(
    _ actual: CGPoint,
    equals expected: CGPoint,
    tolerance: CGFloat = 0.0001
) {
    #expect(abs(actual.x - expected.x) <= tolerance)
    #expect(abs(actual.y - expected.y) <= tolerance)
}
