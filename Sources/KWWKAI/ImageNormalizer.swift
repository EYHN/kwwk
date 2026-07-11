import Foundation
import WebP
import libwebp
import stb_image
import stb_image_resize
import stb_image_write

public enum ImageNormalizationError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedFormat
    case sourceTooLarge(byteCount: Int, maximumBytes: Int)
    case dimensionsTooLarge(width: Int, height: Int, maximumPixels: Int)
    case decodeFailed
    case resizeFailed
    case encodeFailed(format: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "unsupported image format"
        case .sourceTooLarge(let byteCount, let maximumBytes):
            return "image file is too large (\(byteCount) bytes; limit \(maximumBytes))"
        case .dimensionsTooLarge(let width, let height, let maximumPixels):
            return "image dimensions are too large (\(width)x\(height); limit \(maximumPixels) pixels)"
        case .decodeFailed:
            return "failed to decode image"
        case .resizeFailed:
            return "failed to resize image"
        case .encodeFailed(let format):
            return "failed to encode image as \(format)"
        }
    }
}

public struct NormalizedImage: Sendable, Hashable {
    public let content: ImageContent
    public let byteCount: Int
    public let originalWidth: Int
    public let originalHeight: Int
    public let width: Int
    public let height: Int
    public let wasReencoded: Bool

    public var coordinateMappingNote: String? {
        guard width != originalWidth || height != originalHeight else { return nil }

        let xScale = Double(originalWidth) / Double(width)
        let yScale = Double(originalHeight) / Double(height)
        let mapping: String
        if abs(xScale - yScale) < 0.005 {
            mapping = "Multiply coordinates by \(Self.formatScale(xScale))"
        } else {
            mapping = "Multiply x coordinates by \(Self.formatScale(xScale)) and y coordinates by \(Self.formatScale(yScale))"
        }
        return "[Image: original \(originalWidth)x\(originalHeight), displayed at \(width)x\(height). \(mapping) to map to the original image.]"
    }

    private static func formatScale(_ scale: Double) -> String {
        String(format: "%.2f", scale)
    }
}

public enum ImageNormalizer {
    public static func normalize(
        _ data: Data,
        excludingWebP: Bool? = nil
    ) throws -> NormalizedImage {
        try normalize(
            data,
            options: .default(
                excludingWebP: excludingWebP
                    ?? excludesWebP(in: ProcessInfo.processInfo.environment)
            )
        )
    }

    static func excludesWebP(in environment: [String: String]) -> Bool {
        guard let raw = environment["KWWK_NO_WEBP"] else { return false }
        return raw == "1" || raw.lowercased() == "true"
    }

    static func normalize(
        _ data: Data,
        options: ImageNormalizationOptions
    ) throws -> NormalizedImage {
        guard let sourceFormat = ImageFileFormat(data: data) else {
            throw ImageNormalizationError.unsupportedFormat
        }
        guard data.count <= options.maximumSourceBytes else {
            throw ImageNormalizationError.sourceTooLarge(
                byteCount: data.count,
                maximumBytes: options.maximumSourceBytes
            )
        }
        // Reject decompression bombs before decoding: the decoder expands the
        // source into width * height * 4 bytes of RGBA regardless of file size.
        let probed = try probeDimensions(data, format: sourceFormat)
        guard probed.width * probed.height <= options.maximumSourcePixels else {
            throw ImageNormalizationError.dimensionsTooLarge(
                width: probed.width,
                height: probed.height,
                maximumPixels: options.maximumSourcePixels
            )
        }

        let orientation = sourceFormat == .jpeg
            ? EXIFOrientation(jpegData: data) ?? .identity
            : .identity
        let source = try decode(data, format: sourceFormat).applying(orientation)
        let minimumDimension = min(options.minimumDimension, options.maximumWidth, options.maximumHeight)
        let isComfortablyWithinLimits = source.width >= minimumDimension
            && source.height >= minimumDimension
            && source.width <= options.maximumWidth
            && source.height <= options.maximumHeight
            && data.count <= options.maximumBytes / 4
            && orientation == .identity
            && !(options.excludeWebP && sourceFormat == .webp)

        if isComfortablyWithinLimits {
            return NormalizedImage(
                content: ImageContent(
                    data: data.base64EncodedString(),
                    mimeType: sourceFormat.mimeType
                ),
                byteCount: data.count,
                originalWidth: source.width,
                originalHeight: source.height,
                width: source.width,
                height: source.height,
                wasReencoded: false
            )
        }

        let targetSize = targetSize(
            width: source.width,
            height: source.height,
            minimumDimension: minimumDimension,
            maximumWidth: options.maximumWidth,
            maximumHeight: options.maximumHeight
        )
        let target = try resize(source, width: targetSize.width, height: targetSize.height)

        var best = try encodeSmallest(
            target,
            quality: options.initialQuality,
            excludingWebP: options.excludeWebP
        )
        if best.data.count <= options.maximumBytes {
            return normalizedImage(best, source: source)
        }

        for quality in options.qualitySteps {
            let candidate = try encodeSmallestLossy(
                target,
                quality: quality,
                excludingWebP: options.excludeWebP
            )
            if candidate.data.count < best.data.count {
                best = candidate
            }
            if candidate.data.count <= options.maximumBytes {
                return normalizedImage(candidate, source: source)
            }
        }

        for scale in options.scaleSteps {
            let width = Int((Double(target.width) * scale).rounded())
            let height = Int((Double(target.height) * scale).rounded())
            if width < options.minimumFallbackDimension || height < options.minimumFallbackDimension {
                break
            }

            let scaled = try resize(source, width: width, height: height)
            for quality in options.qualitySteps {
                let candidate = try encodeSmallestLossy(
                    scaled,
                    quality: quality,
                    excludingWebP: options.excludeWebP
                )
                if candidate.data.count < best.data.count {
                    best = candidate
                }
                if candidate.data.count <= options.maximumBytes {
                    return normalizedImage(candidate, source: source)
                }
            }
        }

        return normalizedImage(best, source: source)
    }

    private static func normalizedImage(
        _ encoded: EncodedImage,
        source: RasterImage
    ) -> NormalizedImage {
        NormalizedImage(
            content: ImageContent(
                data: encoded.data.base64EncodedString(),
                mimeType: encoded.format.mimeType
            ),
            byteCount: encoded.data.count,
            originalWidth: source.width,
            originalHeight: source.height,
            width: encoded.width,
            height: encoded.height,
            wasReencoded: true
        )
    }

    private static func targetSize(
        width originalWidth: Int,
        height originalHeight: Int,
        minimumDimension: Int,
        maximumWidth: Int,
        maximumHeight: Int
    ) -> (width: Int, height: Int) {
        var width = originalWidth
        var height = originalHeight

        if width > maximumWidth {
            height = Int((Double(height) * Double(maximumWidth) / Double(width)).rounded())
            width = maximumWidth
        }
        if height > maximumHeight {
            width = Int((Double(width) * Double(maximumHeight) / Double(height)).rounded())
            height = maximumHeight
        }

        if width < minimumDimension || height < minimumDimension {
            let shortEdge = min(width, height)
            let upscale = min(
                Double(minimumDimension) / Double(shortEdge),
                Double(maximumWidth) / Double(width),
                Double(maximumHeight) / Double(height)
            )
            if upscale > 1 {
                width = Int((Double(width) * upscale).rounded())
                height = Int((Double(height) * upscale).rounded())
            }
            width = min(maximumWidth, max(minimumDimension, width))
            height = min(maximumHeight, max(minimumDimension, height))
        }

        return (width, height)
    }

    private static func probeDimensions(
        _ data: Data,
        format: ImageFileFormat
    ) throws -> (width: Int, height: Int) {
        var width: Int32 = 0
        var height: Int32 = 0
        let didProbe = data.withUnsafeBytes { bytes -> Bool in
            let base = bytes.bindMemory(to: UInt8.self).baseAddress
            if format == .webp {
                return WebPGetInfo(base, bytes.count, &width, &height) != 0
            }
            var channels: Int32 = 0
            return stbi_info_from_memory(
                base,
                Int32(bytes.count),
                &width,
                &height,
                &channels
            ) != 0
        }
        guard didProbe, width > 0, height > 0 else {
            throw ImageNormalizationError.decodeFailed
        }
        return (Int(width), Int(height))
    }

    private static func decode(_ data: Data, format: ImageFileFormat) throws -> RasterImage {
        if format == .webp {
            do {
                let image = try WebP.decode(Array(data))
                return RasterImage(width: image.width, height: image.height, rgba: image.rgba)
            } catch {
                throw ImageNormalizationError.decodeFailed
            }
        }

        var width: Int32 = 0
        var height: Int32 = 0
        var sourceChannels: Int32 = 0
        let decoded = data.withUnsafeBytes { bytes in
            stbi_load_from_memory(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                Int32(bytes.count),
                &width,
                &height,
                &sourceChannels,
                4
            )
        }
        guard let decoded else {
            throw ImageNormalizationError.decodeFailed
        }
        defer { stbi_image_free(decoded) }

        let pixelCount = Int(width) * Int(height) * 4
        return RasterImage(
            width: Int(width),
            height: Int(height),
            rgba: Array(UnsafeBufferPointer(start: decoded, count: pixelCount))
        )
    }

    private static func resize(
        _ image: RasterImage,
        width: Int,
        height: Int
    ) throws -> RasterImage {
        guard image.width != width || image.height != height else { return image }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let didResize = image.rgba.withUnsafeBufferPointer { source in
            rgba.withUnsafeMutableBufferPointer { destination in
                stbir_resize_uint8_srgb(
                    source.baseAddress,
                    Int32(image.width),
                    Int32(image.height),
                    0,
                    destination.baseAddress,
                    Int32(width),
                    Int32(height),
                    0,
                    4,
                    3,
                    0
                )
            }
        }
        guard didResize != 0 else {
            throw ImageNormalizationError.resizeFailed
        }
        return RasterImage(width: width, height: height, rgba: rgba)
    }

    private static func encodeSmallest(
        _ image: RasterImage,
        quality: Int,
        excludingWebP: Bool
    ) throws -> EncodedImage {
        var candidates = try [
            encodePNG(image),
            encodeJPEG(image, quality: quality),
        ]
        if !excludingWebP {
            candidates.append(try encodeWebP(image, quality: quality))
        }
        return candidates.min(by: { $0.data.count < $1.data.count })!
    }

    private static func encodeSmallestLossy(
        _ image: RasterImage,
        quality: Int,
        excludingWebP: Bool
    ) throws -> EncodedImage {
        let jpeg = try encodeJPEG(image, quality: quality)
        guard !excludingWebP else { return jpeg }
        let webP = try encodeWebP(image, quality: quality)
        return jpeg.data.count < webP.data.count ? jpeg : webP
    }

    private static func encodePNG(_ image: RasterImage) throws -> EncodedImage {
        let sink = ImageDataSink()
        let context = Unmanaged.passUnretained(sink).toOpaque()
        let didEncode = image.rgba.withUnsafeBytes { pixels in
            stbi_write_png_to_func(
                appendImageData,
                context,
                Int32(image.width),
                Int32(image.height),
                4,
                pixels.baseAddress!,
                Int32(image.width * 4)
            )
        }
        guard didEncode != 0 else {
            throw ImageNormalizationError.encodeFailed(format: ImageFileFormat.png.mimeType)
        }
        return EncodedImage(data: sink.data, format: .png, width: image.width, height: image.height)
    }

    private static func encodeJPEG(
        _ image: RasterImage,
        quality: Int
    ) throws -> EncodedImage {
        let sink = ImageDataSink()
        let context = Unmanaged.passUnretained(sink).toOpaque()
        let didEncode = image.rgba.withUnsafeBytes { pixels in
            stbi_write_jpg_to_func(
                appendImageData,
                context,
                Int32(image.width),
                Int32(image.height),
                4,
                pixels.baseAddress!,
                Int32(quality)
            )
        }
        guard didEncode != 0 else {
            throw ImageNormalizationError.encodeFailed(format: ImageFileFormat.jpeg.mimeType)
        }
        return EncodedImage(data: sink.data, format: .jpeg, width: image.width, height: image.height)
    }

    private static func encodeWebP(
        _ image: RasterImage,
        quality: Int
    ) throws -> EncodedImage {
        do {
            let encoded = try WebP(
                width: image.width,
                height: image.height,
                rgba: image.rgba
            ).encode(quality: Float(quality))
            return EncodedImage(
                data: Data(encoded),
                format: .webp,
                width: image.width,
                height: image.height
            )
        } catch {
            throw ImageNormalizationError.encodeFailed(format: ImageFileFormat.webp.mimeType)
        }
    }
}

struct ImageNormalizationOptions: Sendable {
    let maximumWidth: Int
    let maximumHeight: Int
    let minimumDimension: Int
    let maximumBytes: Int
    /// Hard cap on the encoded source size, checked before any decoding.
    var maximumSourceBytes: Int = 100 * 1024 * 1024
    /// Hard cap on decoded pixel count, checked against header dimensions
    /// before decoding. 64 megapixels decodes into 256 MB of RGBA.
    var maximumSourcePixels: Int = 64 * 1024 * 1024
    let initialQuality: Int
    let qualitySteps: [Int]
    let scaleSteps: [Double]
    let minimumFallbackDimension: Int
    let excludeWebP: Bool

    static func `default`(excludingWebP: Bool = false) -> ImageNormalizationOptions {
        ImageNormalizationOptions(
            maximumWidth: 1568,
            maximumHeight: 1568,
            minimumDimension: 200,
            maximumBytes: 500 * 1024,
            initialQuality: 80,
            qualitySteps: [70, 60, 50, 40],
            scaleSteps: [1.0, 0.75, 0.5, 0.35, 0.25],
            minimumFallbackDimension: 100,
            excludeWebP: excludingWebP
        )
    }
}

private enum ImageFileFormat: Sendable {
    case png
    case jpeg
    case gif
    case webp

    init?(data: Data) {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            self = .png
        } else if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) {
            self = .gif
        } else if data.count >= 12
            && data.starts(with: Array("RIFF".utf8))
            && data[8..<12].elementsEqual("WEBP".utf8) {
            self = .webp
        } else {
            return nil
        }
    }

    var mimeType: String {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        case .gif: return "image/gif"
        case .webp: return "image/webp"
        }
    }
}

struct RasterImage {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    func applying(_ orientation: EXIFOrientation) -> RasterImage {
        guard orientation != .identity else { return self }

        let outputWidth = orientation.swapsAxes ? height : width
        let outputHeight = orientation.swapsAxes ? width : height
        var output = [UInt8](repeating: 0, count: rgba.count)

        rgba.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                for sourceY in 0..<height {
                    for sourceX in 0..<width {
                        let destinationPoint = orientation.destination(
                            sourceX: sourceX,
                            sourceY: sourceY,
                            sourceWidth: width,
                            sourceHeight: height
                        )
                        let sourceOffset = (sourceY * width + sourceX) * 4
                        let destinationOffset = (
                            destinationPoint.y * outputWidth + destinationPoint.x
                        ) * 4
                        destination[destinationOffset] = source[sourceOffset]
                        destination[destinationOffset + 1] = source[sourceOffset + 1]
                        destination[destinationOffset + 2] = source[sourceOffset + 2]
                        destination[destinationOffset + 3] = source[sourceOffset + 3]
                    }
                }
            }
        }

        return RasterImage(width: outputWidth, height: outputHeight, rgba: output)
    }
}

enum EXIFOrientation: UInt16, Sendable, CaseIterable {
    case identity = 1
    case mirroredHorizontally = 2
    case rotated180 = 3
    case mirroredVertically = 4
    case transposed = 5
    case rotated90Clockwise = 6
    case mirroredAcrossAntiDiagonal = 7
    case rotated90Counterclockwise = 8

    init?(jpegData: Data) {
        guard let orientation = jpegData.withUnsafeBytes(Self.readJPEGOrientation) else {
            return nil
        }
        self = orientation
    }

    var swapsAxes: Bool {
        switch self {
        case .transposed,
             .rotated90Clockwise,
             .mirroredAcrossAntiDiagonal,
             .rotated90Counterclockwise:
            return true
        case .identity,
             .mirroredHorizontally,
             .rotated180,
             .mirroredVertically:
            return false
        }
    }

    func destination(
        sourceX: Int,
        sourceY: Int,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> (x: Int, y: Int) {
        switch self {
        case .identity:
            return (sourceX, sourceY)
        case .mirroredHorizontally:
            return (sourceWidth - 1 - sourceX, sourceY)
        case .rotated180:
            return (sourceWidth - 1 - sourceX, sourceHeight - 1 - sourceY)
        case .mirroredVertically:
            return (sourceX, sourceHeight - 1 - sourceY)
        case .transposed:
            return (sourceY, sourceX)
        case .rotated90Clockwise:
            return (sourceHeight - 1 - sourceY, sourceX)
        case .mirroredAcrossAntiDiagonal:
            return (sourceHeight - 1 - sourceY, sourceWidth - 1 - sourceX)
        case .rotated90Counterclockwise:
            return (sourceY, sourceWidth - 1 - sourceX)
        }
    }

    private enum TIFFByteOrder {
        case littleEndian
        case bigEndian
    }

    private static let exifSignature: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]

    private static func readJPEGOrientation(
        _ bytes: UnsafeRawBufferPointer
    ) -> EXIFOrientation? {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            return nil
        }

        var offset = 2
        while offset < bytes.count {
            while offset < bytes.count, bytes[offset] != 0xFF {
                offset += 1
            }
            while offset < bytes.count, bytes[offset] == 0xFF {
                offset += 1
            }
            guard offset < bytes.count else { return nil }

            let marker = bytes[offset]
            offset += 1
            if marker == 0xD9 || marker == 0xDA {
                return nil
            }
            if marker == 0x01 || marker == 0xD8 || (0xD0...0xD7).contains(marker) {
                continue
            }

            guard let segmentLength = readUInt16BigEndian(bytes, at: offset),
                  segmentLength >= 2
            else {
                return nil
            }
            let payloadStart = offset + 2
            let payloadEnd = payloadStart + Int(segmentLength) - 2
            guard payloadEnd <= bytes.count else { return nil }

            if marker == 0xE1,
               let orientation = readEXIFOrientation(
                   bytes,
                   payloadStart: payloadStart,
                   payloadEnd: payloadEnd
               ) {
                return orientation
            }
            offset = payloadEnd
        }
        return nil
    }

    private static func readEXIFOrientation(
        _ bytes: UnsafeRawBufferPointer,
        payloadStart: Int,
        payloadEnd: Int
    ) -> EXIFOrientation? {
        guard payloadEnd - payloadStart >= exifSignature.count + 8 else { return nil }
        for (index, byte) in exifSignature.enumerated() {
            guard bytes[payloadStart + index] == byte else { return nil }
        }

        let tiffStart = payloadStart + exifSignature.count
        let byteOrder: TIFFByteOrder
        switch (bytes[tiffStart], bytes[tiffStart + 1]) {
        case (0x49, 0x49):
            byteOrder = .littleEndian
        case (0x4D, 0x4D):
            byteOrder = .bigEndian
        default:
            return nil
        }
        guard readUInt16(bytes, at: tiffStart + 2, byteOrder: byteOrder) == 42,
              let firstIFDOffset = readUInt32(
                  bytes,
                  at: tiffStart + 4,
                  byteOrder: byteOrder
              )
        else {
            return nil
        }

        let firstIFD = tiffStart + Int(firstIFDOffset)
        guard firstIFD + 2 <= payloadEnd,
              let entryCount = readUInt16(bytes, at: firstIFD, byteOrder: byteOrder)
        else {
            return nil
        }

        for entryIndex in 0..<Int(entryCount) {
            let entry = firstIFD + 2 + entryIndex * 12
            guard entry + 12 <= payloadEnd else { return nil }
            guard readUInt16(bytes, at: entry, byteOrder: byteOrder) == 0x0112 else {
                continue
            }
            guard readUInt16(bytes, at: entry + 2, byteOrder: byteOrder) == 3,
                  readUInt32(bytes, at: entry + 4, byteOrder: byteOrder) == 1,
                  let rawOrientation = readUInt16(
                      bytes,
                      at: entry + 8,
                      byteOrder: byteOrder
                  )
            else {
                return nil
            }
            return EXIFOrientation(rawValue: rawOrientation)
        }
        return nil
    }

    private static func readUInt16BigEndian(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readUInt16(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int,
        byteOrder: TIFFByteOrder
    ) -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        switch byteOrder {
        case .littleEndian:
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        case .bigEndian:
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
    }

    private static func readUInt32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int,
        byteOrder: TIFFByteOrder
    ) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        switch byteOrder {
        case .littleEndian:
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        case .bigEndian:
            return UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }
    }
}

private struct EncodedImage {
    let data: Data
    let format: ImageFileFormat
    let width: Int
    let height: Int
}

private final class ImageDataSink: @unchecked Sendable {
    var data = Data()
}

private func appendImageData(
    context: UnsafeMutableRawPointer?,
    data: UnsafeMutableRawPointer?,
    size: Int32
) {
    let sink = Unmanaged<ImageDataSink>.fromOpaque(context!).takeUnretainedValue()
    sink.data.append(data!.assumingMemoryBound(to: UInt8.self), count: Int(size))
}
