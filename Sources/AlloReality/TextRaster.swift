//
//  TextRaster.swift
//  AlloReality
//

import CoreGraphics
import CoreText
import Foundation
import allonet2

/// Text drawn to a bitmap, for strings a glyph-outline mesh can't show: emoji exist only as
/// colour bitmaps, so `MeshResource.generateText` returns an empty mesh for them (measured, see
/// docs/realitykit-rendering.md). The image goes on a flat plane the size the text would have
/// had, which keeps `Text.height` and the placement math meaning the same thing either way.
@MainActor
enum TextRaster
{
    struct Raster
    {
        let image: CGImage
        /// The plane's size, in metres; the pixels cover exactly this.
        let width: Float
        let height: Float
    }

    /// Pixels per line height: sharp up close, and a sign's worth of text stays far under the
    /// texture cap.
    static let pixelsPerLine: CGFloat = 256
    static let maxPixels: CGFloat = 4096

    static func render(_ text: allonet2.Text) -> Raster?
    {
        guard !text.string.isEmpty, text.height > 0 else { return nil }

        // Same scale rule as the mesh path: the font's own line height equals `Text.height`, here
        // in pixels instead of metres. `.box` generates at the box's nominal height too, and
        // `placement` scales the finished block.
        let pixelsPerMetre = pixelsPerLine / CGFloat(text.height)
        let unit = CTFontCreateUIFontForLanguage(.system, 1, nil)!
        let lineHeightPerPoint = CTFontGetAscent(unit) + CTFontGetDescent(unit) + CTFontGetLeading(unit)
        let font = CTFontCreateUIFontForLanguage(.system, pixelsPerLine / lineHeightPerPoint, nil)!

        let paragraph = text.halign.paragraphStyle
        let attributed = NSAttributedString(string: text.string, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: text.color.cgColor,
            kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // A zero frame means "one line, no wrapping" on the mesh path; here that is an unbounded
        // width. Wrapping uses `width`, like the mesh path's container frame.
        let wrapWidth = text.wrap ? min(CGFloat(text.width) * pixelsPerMetre, maxPixels) : maxPixels
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: wrapWidth, height: maxPixels), nil)
        let width = Int(min(fitted.width.rounded(.up), maxPixels)), height = Int(min(fitted.height.rounded(.up), maxPixels))
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CoreText draws into a bottom-left-origin context, which is what a bitmap context is; the
        // frame's path is the whole canvas, so the block lands where the framesetter measured it.
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        guard let image = context.makeImage() else { return nil }

        return Raster(image: image, width: Float(CGFloat(width) / pixelsPerMetre), height: Float(CGFloat(height) / pixelsPerMetre))
    }
}

@MainActor
extension allonet2.Text.HorizontalAlignment
{
    var paragraphStyle: CTParagraphStyle
    {
        var alignment: CTTextAlignment = switch self
        {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        let setting = withUnsafePointer(to: &alignment) { pointer in
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
        }
        return CTParagraphStyleCreate([setting], 1)
    }
}

@MainActor
extension allonet2.Color
{
    var cgColor: CGColor
    {
        switch self
        {
        case .rgb(let red, let green, let blue, let alpha):
            return CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
        case .hsv(let hue, let saturation, let value, let alpha):
            // HSV to RGB; the sector arithmetic, nothing platform-specific.
            let c = value * saturation, hp = hue * 6, x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = value - c
            let (r, g, b): (Float, Float, Float) = switch Int(hp) % 6
            {
            case 0: (c, x, 0)
            case 1: (x, c, 0)
            case 2: (0, c, x)
            case 3: (0, x, c)
            case 4: (x, 0, c)
            default: (c, 0, x)
            }
            return CGColor(srgbRed: CGFloat(r + m), green: CGFloat(g + m), blue: CGFloat(b + m), alpha: CGFloat(alpha))
        }
    }
}
