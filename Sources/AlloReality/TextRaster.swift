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
///
/// Deliberately not on the main actor: layout and drawing are CPU work over value types, and the
/// string comes from a peer — a big render must not stall the frame. The caller snapshots the
/// (main-actor) `Text` into an `Input` and runs `render` detached.
enum TextRaster
{
    /// The pieces of a `Text` the rasterizer needs, in `Sendable` form.
    struct Input: Sendable
    {
        let string: String
        let heightMetres: Float
        let widthMetres: Float
        let wrap: Bool
        let alignment: CTTextAlignment
        /// sRGB, each already finite and in 0...1.
        let rgba: SIMD4<Float>
    }

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

    static func render(_ text: Input) -> Raster?
    {
        guard !text.string.isEmpty, text.heightMetres > 0 else { return nil }

        // Same scale rule as the mesh path: the font's own line height equals `Text.height`, here
        // in pixels instead of metres. `.box` generates at the box's nominal height too, and
        // `placement` scales the finished block.
        let pixelsPerMetre = pixelsPerLine / CGFloat(text.heightMetres)
        let unit = CTFontCreateUIFontForLanguage(.system, 1, nil)!
        let lineHeightPerPoint = CTFontGetAscent(unit) + CTFontGetDescent(unit) + CTFontGetLeading(unit)
        let font = CTFontCreateUIFontForLanguage(.system, pixelsPerLine / lineHeightPerPoint, nil)!

        let color = CGColor(srgbRed: CGFloat(text.rgba.x), green: CGFloat(text.rgba.y),
                            blue: CGFloat(text.rgba.z), alpha: CGFloat(text.rgba.w))
        let attributed = NSAttributedString(string: text.string, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
            kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraphStyle(text.alignment),
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // A zero frame means "one line, no wrapping" on the mesh path; here that is an unbounded
        // width. Wrapping uses `width`, like the mesh path's container frame. Layout is NOT
        // clamped to the texture cap — that would change where lines break or drop content.
        let wrapWidth = text.wrap ? CGFloat(text.widthMetres) * pixelsPerMetre : .greatestFiniteMagnitude
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: wrapWidth, height: .greatestFiniteMagnitude), nil)
        let layout = CGSize(width: fitted.width.rounded(.up), height: fitted.height.rounded(.up))
        guard layout.width > 0, layout.height > 0 else { return nil }

        // The cap costs density, never content: an oversized block renders blurrier, laid out
        // and sized exactly as it would have been.
        let scale = min(1, maxPixels / layout.width, maxPixels / layout.height)
        let width = Int((layout.width * scale).rounded(.up)), height = Int((layout.height * scale).rounded(.up))

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else
        {
            // Distinguishable from "nothing to draw": this is the renderer failing, likely memory
            // pressure, and silence would read as an empty string.
            print("TextRaster: couldn't allocate a \(width)x\(height) bitmap for \"\(text.string.prefix(40))\"")
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        // CoreText draws into a bottom-left-origin context, which is what a bitmap context is; the
        // frame's path is the whole canvas, so the block lands where the framesetter measured it.
        let path = CGPath(rect: CGRect(origin: .zero, size: layout), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        guard let image = context.makeImage() else { return nil }

        return Raster(image: image, width: Float(layout.width / pixelsPerMetre), height: Float(layout.height / pixelsPerMetre))
    }

    private static func paragraphStyle(_ alignment: CTTextAlignment) -> CTParagraphStyle
    {
        var alignment = alignment
        let setting = withUnsafePointer(to: &alignment) { pointer in
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
        }
        return CTParagraphStyleCreate([setting], 1)
    }
}

@MainActor
extension TextRaster.Input
{
    /// Snapshot on the main actor, bounded like the mesh path — the string is a peer's word.
    /// Everything after is actor-free.
    init(of text: allonet2.Text)
    {
        self.init(string: String(text.string.prefix(allonet2.Text.maxRenderedCharacters)),
                  heightMetres: text.height, widthMetres: text.width,
                  wrap: text.wrap, alignment: text.halign.realityAlignment, rgba: text.color.srgba)
    }
}

@MainActor
extension allonet2.Color
{
    /// sRGB components, each forced finite and into 0...1: this value comes off the wire, and a
    /// NaN reaching the sector arithmetic below (or CoreGraphics) is a peer crashing the client.
    var srgba: SIMD4<Float>
    {
        func unit(_ x: Float) -> Float { x.isFinite ? min(max(x, 0), 1) : 0 }
        switch self
        {
        case .rgb(let red, let green, let blue, let alpha):
            return [unit(red), unit(green), unit(blue), unit(alpha)]
        case .hsv(let hue, let saturation, let value, let alpha):
            // HSV to RGB; the sector arithmetic, nothing platform-specific.
            let (h, sat, v) = (unit(hue), unit(saturation), unit(value))
            let c = v * sat, hp = h * 6, x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
            let (r, g, b): (Float, Float, Float) = switch Int(hp) % 6
            {
            case 0: (c, x, 0)
            case 1: (x, c, 0)
            case 2: (0, c, x)
            case 3: (0, x, c)
            case 4: (x, 0, c)
            default: (c, 0, x)
            }
            return [unit(r + m), unit(g + m), unit(b + m), alpha == 1 ? 1 : unit(alpha)]
        }
    }
}
