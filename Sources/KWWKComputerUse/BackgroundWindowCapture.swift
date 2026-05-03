import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ComputerUseScreenshotCompression: Codable, Equatable, Sendable {
    public static let foregroundDefault = ComputerUseScreenshotCompression()

    public var maxLongEdgePixels: Int
    public var maxPixelArea: Int
    public var jpegQuality: Double

    public init(
        maxLongEdgePixels: Int = 1568,
        maxPixelArea: Int = 629_145,
        jpegQuality: Double = 0.82
    ) {
        self.maxLongEdgePixels = maxLongEdgePixels
        self.maxPixelArea = maxPixelArea
        self.jpegQuality = jpegQuality
    }
}

enum BackgroundWindowCapture {
    static func captureWindowScreenshot(
        windowID: Int,
        compression: ComputerUseScreenshotCompression = .foregroundDefault
    ) -> (url: URL, size: CGSize)? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(windowID),
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            return nil
        }

        let scaled = scaleToLimits(image, compression: compression)
        return writeJPEG(scaled, prefix: "kwwk-cu-capture", quality: compression.jpegQuality).map {
            (url: $0, size: CGSize(width: scaled.width, height: scaled.height))
        }
    }

    private static func scaleToLimits(
        _ image: CGImage,
        compression: ComputerUseScreenshotCompression
    ) -> CGImage {
        let srcW = image.width
        let srcH = image.height
        let longEdge = max(srcW, srcH)
        let area = srcW * srcH

        let maxLongEdge = max(1, compression.maxLongEdgePixels)
        let maxPixelArea = max(1, compression.maxPixelArea)
        let longEdgeScale = CGFloat(maxLongEdge) / CGFloat(max(longEdge, 1))
        let areaScale = sqrt(CGFloat(maxPixelArea) / CGFloat(max(area, 1)))
        let scale = min(1.0, min(longEdgeScale, areaScale))
        guard scale < 1.0 else {
            return flattenedForJPEG(image) ?? image
        }

        let dstW = max(1, Int((CGFloat(srcW) * scale).rounded()))
        let dstH = max(1, Int((CGFloat(srcH) * scale).rounded()))
        return redraw(image, width: dstW, height: dstH) ?? flattenedForJPEG(image) ?? image
    }

    private static func redraw(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = makeOpaqueRGBContext(width: width, height: height) else {
            return nil
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func flattenedForJPEG(_ image: CGImage) -> CGImage? {
        redraw(image, width: image.width, height: image.height)
    }

    private static func makeOpaqueRGBContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        )
    }

    private static func writeJPEG(_ image: CGImage, prefix: String, quality: Double) -> URL? {
        do {
            try ComputerUseSnapshotStore.ensureRootDirectory()
            let url = ComputerUseSnapshotStore.rootURL.appendingPathComponent(
                "\(prefix)-\(UUID().uuidString.lowercased()).jpg"
            )
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            let clampedQuality = min(max(quality, 0.01), 1.0)
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: clampedQuality,
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                return nil
            }
            return url
        } catch {
            return nil
        }
    }
}
