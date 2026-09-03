import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import allonet2
@testable import AlloReality

/// Turning a peer's `InlineImage` bytes into something drawable. Only the byte count was checked
/// on the way in, so the picture they describe is still theirs to choose.
@MainActor
struct InlineImageTests
{
    /// A solid PNG of the given size: the smallest payload that can declare the most pixels.
    private func png(width: Int, height: Int) throws -> Data
    {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func aThumbnailSizedPngDecodes() throws
    {
        let image = try RealityViewMapper.decodePNG(try png(width: 64, height: 48))
        #expect(image.width == 64 && image.height == 48)
    }

    /// The component's 16 KiB cap bounds the bytes, not the picture: a solid PNG under it declares
    /// megabytes of texture. The header says so before anything allocates them.
    @Test func aPngDeclaringMoreThanAThumbnailIsRefused() throws
    {
        let bytes = try png(width: 768, height: 768)
        #expect(bytes.count <= InlineImage.maximumBytes,
                "\(bytes.count) bytes; the component cap would already have stopped this")
        #expect(throws: InlineImageRefusal.tooManyPixels(width: 768, height: 768))
        {
            try RealityViewMapper.decodePNG(bytes)
        }
    }

    @Test func bytesThatAreNotAnImageAreRefused() throws
    {
        let bytes = Data("not a png".utf8)
        #expect(throws: InlineImageRefusal.unreadable(bytes: bytes.count))
        {
            try RealityViewMapper.decodePNG(bytes)
        }
    }
}
