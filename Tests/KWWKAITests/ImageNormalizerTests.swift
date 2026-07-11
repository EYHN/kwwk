import Foundation
import Testing
@testable import KWWKAI

@Suite("Image normalization")
struct ImageNormalizerTests {
    @Test("upscales undersized images to the 200px floor")
    func minimumDimension() throws {
        let result = try ImageNormalizer.normalize(redPixelPNG, excludingWebP: false)

        #expect(result.originalWidth == 1)
        #expect(result.originalHeight == 1)
        #expect(result.width == 200)
        #expect(result.height == 200)
        #expect(result.wasReencoded)
        #expect(result.byteCount <= 500 * 1024)
        #expect(result.coordinateMappingNote?.contains("original 1x1, displayed at 200x200") == true)
    }

    @Test("caps the long edge and records coordinate mapping")
    func maximumDimension() throws {
        let options = ImageNormalizationOptions(
            maximumWidth: 8,
            maximumHeight: 8,
            minimumDimension: 1,
            maximumBytes: 500 * 1024,
            initialQuality: 80,
            qualitySteps: [70, 60, 50, 40],
            scaleSteps: [1.0, 0.75, 0.5, 0.35, 0.25],
            minimumFallbackDimension: 1,
            excludeWebP: false
        )
        let result = try ImageNormalizer.normalize(sixteenByOnePNG, options: options)

        #expect(ImageNormalizationOptions.default().maximumWidth == 1568)
        #expect(ImageNormalizationOptions.default().maximumHeight == 1568)
        #expect(result.originalWidth == 16)
        #expect(result.originalHeight == 1)
        #expect(result.width == 8)
        #expect(result.height == 1)
        #expect(result.byteCount <= 500 * 1024)
        #expect(result.coordinateMappingNote?.contains("Multiply x coordinates") == true)
        #expect(result.coordinateMappingNote?.contains("y coordinates") == true)
    }

    @Test("keeps normalized images unchanged on the comfortable-size fast path")
    func fastPath() throws {
        let first = try ImageNormalizer.normalize(redPixelPNG, excludingWebP: false)
        let firstBytes = try #require(Data(base64Encoded: first.content.data))
        let second = try ImageNormalizer.normalize(firstBytes, excludingWebP: false)

        #expect(!second.wasReencoded)
        #expect(second.content == first.content)
        #expect(second.byteCount == first.byteCount)
        #expect(second.width == 200)
        #expect(second.height == 200)
    }

    @Test("chooses the smallest of PNG, JPEG, and WebP")
    func choosesSmallestFormat() throws {
        let result = try ImageNormalizer.normalize(redPixelPNG, excludingWebP: false)

        #expect(result.content.mimeType == "image/webp")
        #expect(Data(base64Encoded: result.content.data)?.starts(with: Array("RIFF".utf8)) == true)
    }

    @Test("can exclude WebP and re-encodes WebP sources on the fast path")
    func excludesWebP() throws {
        let webP = try ImageNormalizer.normalize(redPixelPNG, excludingWebP: false)
        let webPBytes = try #require(Data(base64Encoded: webP.content.data))

        let result = try ImageNormalizer.normalize(webPBytes, excludingWebP: true)

        #expect(webP.content.mimeType == "image/webp")
        #expect(result.content.mimeType != "image/webp")
        #expect(result.wasReencoded)
        #expect(result.width == 200)
        #expect(result.height == 200)
    }

    @Test("KWWK_NO_WEBP accepts only 1 or true")
    func webPEnvironmentFlag() {
        #expect(ImageNormalizer.excludesWebP(in: ["KWWK_NO_WEBP": "1"]))
        #expect(ImageNormalizer.excludesWebP(in: ["KWWK_NO_WEBP": "TRUE"]))
        #expect(!ImageNormalizer.excludesWebP(in: ["KWWK_NO_WEBP": "0"]))
        #expect(!ImageNormalizer.excludesWebP(in: ["KWWK_NO_WEBP": ""]))
        #expect(!ImageNormalizer.excludesWebP(in: [:]))
    }

    @Test("walks the quality and scale ladders when the target cannot be met")
    func qualityAndScaleLadders() throws {
        let options = ImageNormalizationOptions(
            maximumWidth: 1568,
            maximumHeight: 1568,
            minimumDimension: 200,
            maximumBytes: 1,
            initialQuality: 80,
            qualitySteps: [70, 60, 50, 40],
            scaleSteps: [1.0, 0.75, 0.5, 0.35, 0.25],
            minimumFallbackDimension: 100,
            excludeWebP: false
        )

        let result = try ImageNormalizer.normalize(redPixelPNG, options: options)

        #expect(result.width == 100)
        #expect(result.height == 100)
        #expect(result.byteCount > options.maximumBytes)
    }

    @Test("applies every EXIF orientation to RGBA pixels")
    func exifPixelOrientations() {
        let source = RasterImage(
            width: 2,
            height: 3,
            rgba: [
                rgba(1), rgba(2),
                rgba(3), rgba(4),
                rgba(5), rgba(6),
            ].flatMap { $0 }
        )
        let expectations: [(EXIFOrientation, Int, Int, [UInt8])] = [
            (.identity, 2, 3, [1, 2, 3, 4, 5, 6]),
            (.mirroredHorizontally, 2, 3, [2, 1, 4, 3, 6, 5]),
            (.rotated180, 2, 3, [6, 5, 4, 3, 2, 1]),
            (.mirroredVertically, 2, 3, [5, 6, 3, 4, 1, 2]),
            (.transposed, 3, 2, [1, 3, 5, 2, 4, 6]),
            (.rotated90Clockwise, 3, 2, [5, 3, 1, 6, 4, 2]),
            (.mirroredAcrossAntiDiagonal, 3, 2, [6, 4, 2, 5, 3, 1]),
            (.rotated90Counterclockwise, 3, 2, [2, 4, 6, 1, 3, 5]),
        ]

        for (orientation, width, height, expectedPixels) in expectations {
            let result = source.applying(orientation)
            let pixels = stride(from: 0, to: result.rgba.count, by: 4).map {
                result.rgba[$0]
            }

            #expect(result.width == width)
            #expect(result.height == height)
            #expect(pixels == expectedPixels)
        }
    }

    @Test("reads every EXIF orientation value from JPEG metadata")
    func parsesEXIFOrientations() {
        for orientation in EXIFOrientation.allCases {
            #expect(
                EXIFOrientation(jpegData: jpegWithEXIFOrientation(orientation)) == orientation
            )
        }
        #expect(
            EXIFOrientation(
                jpegData: jpegWithBigEndianEXIFOrientation(.rotated90Counterclockwise)
            ) == .rotated90Counterclockwise
        )
    }

    @Test("matches OMP orientation-6 landscape dimensions and bakes the transform")
    func orientationSixLandscapeSemantics() throws {
        let orientedJPEG = jpegWithEXIFOrientation(.rotated90Clockwise)

        let result = try ImageNormalizer.normalize(orientedJPEG, excludingWebP: false)

        #expect(result.originalWidth == 3)
        #expect(result.originalHeight == 2)
        #expect(result.width == 300)
        #expect(result.height == 200)
        #expect(result.wasReencoded)

        let output = try #require(Data(base64Encoded: result.content.data))
        let secondPass = try ImageNormalizer.normalize(output, excludingWebP: false)
        #expect(secondPass.originalWidth == 300)
        #expect(secondPass.originalHeight == 200)
        #expect(!secondPass.wasReencoded)
    }

    @Test("rejects oversized source files before decoding")
    func rejectsOversizedSourceBytes() {
        var options = ImageNormalizationOptions.default()
        options.maximumSourceBytes = redPixelPNG.count - 1

        #expect(throws: ImageNormalizationError.sourceTooLarge(
            byteCount: redPixelPNG.count,
            maximumBytes: options.maximumSourceBytes
        )) {
            try ImageNormalizer.normalize(redPixelPNG, options: options)
        }
    }

    @Test("rejects decompression bombs by header dimensions before decoding")
    func rejectsOversizedDimensions() {
        var options = ImageNormalizationOptions.default()
        options.maximumSourcePixels = 8

        #expect(throws: ImageNormalizationError.dimensionsTooLarge(
            width: 16,
            height: 1,
            maximumPixels: 8
        )) {
            try ImageNormalizer.normalize(sixteenByOnePNG, options: options)
        }
    }

    @Test("throws instead of retaining undecodable source bytes")
    func invalidImageThrows() {
        #expect(throws: ImageNormalizationError.unsupportedFormat) {
            try ImageNormalizer.normalize(Data("not an image".utf8), excludingWebP: false)
        }
        #expect(throws: ImageNormalizationError.decodeFailed) {
            try ImageNormalizer.normalize(
                Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
                excludingWebP: false
            )
        }
    }
}

private let redPixelPNG = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
)!

private let sixteenByOnePNG = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAABAAAAABBAMAAAAlVzNsAAAAAXNSR0IDN8dNUwAAADBQTFRF////v7//gID/QED//7+/v5+/gIC/QGC//4CAv4CAgICAQICA/0BAv2BAgIBAQJ9AHjSTbgAAACx0RVh0Q29weXJpZ2h0AKkgMjAxMywyMDE1IEpvaG4gQ3VubmluZ2hhbSBCb3dsZXJ9dHP+AAAAdGlUWHRMaWNlbnNpbmcAAQBlbgAACNctjE0OgyAQha/y4gEcu22XeBGEl0oiDIGxC0+vCV1/PytjCt4YYQrbiXpuRwqImn0qqGxwjd7Sj3Cas5aOh7N0YnJuwWtepg92s9rfIuHvhqHO2r4yjmMoF5vK08gNMzIqgtiYrSYAAAAMSURBVAjXY2RUggAAA9IA8clsiM8AAAAASUVORK5CYII="
)!

private let twoByThreeJPEG = Data(base64Encoded:
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAADAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD8X6KKK/ynP+/g/9k="
)!

private func rgba(_ value: UInt8) -> [UInt8] {
    [value, 0, 0, 255]
}

private func jpegWithEXIFOrientation(_ orientation: EXIFOrientation) -> Data {
    let applicationSegment: [UInt8] = [
        0xFF, 0xE1, 0x00, 0x22,
        0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
        0x49, 0x49, 0x2A, 0x00,
        0x08, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x12, 0x01, 0x03, 0x00,
        0x01, 0x00, 0x00, 0x00,
        UInt8(orientation.rawValue), 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]
    var bytes = Array(twoByThreeJPEG)
    bytes.insert(contentsOf: applicationSegment, at: 2)
    return Data(bytes)
}

private func jpegWithBigEndianEXIFOrientation(_ orientation: EXIFOrientation) -> Data {
    let applicationSegment: [UInt8] = [
        0xFF, 0xE1, 0x00, 0x22,
        0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
        0x4D, 0x4D, 0x00, 0x2A,
        0x00, 0x00, 0x00, 0x08,
        0x00, 0x01,
        0x01, 0x12, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x01,
        0x00, UInt8(orientation.rawValue), 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]
    var bytes = Array(twoByThreeJPEG)
    bytes.insert(contentsOf: applicationSegment, at: 2)
    return Data(bytes)
}
