import CoreText
import Metal
import TermCore
import UIKit

/// 文字を物理ピクセルの大きさで 1 度だけラスタライズしてためるテクスチャ（docs/design.md「文字の描画」）。
/// 倍率やフォントを変えたときだけ作り直す
final class GlyphAtlas {
    struct Key: Hashable {
        var text: String
        var bold: Bool
        var italic: Bool
        var wide: Bool
    }

    /// アトラスの中の位置（ピクセル）
    struct Entry {
        var x: Float, y: Float, w: Float, h: Float
    }

    struct FontSpec: Equatable {
        var family: String
        var cjkFamily: String
        /// 物理ピクセルでの文字の大きさ
        var pixelSize: CGFloat
        var scale: CGFloat
    }

    let device: MTLDevice
    let spec: FontSpec
    let metrics: CellMetrics
    /// セルの上端からベースラインまで（ピクセル）
    let baseline: CGFloat
    private(set) var texture: MTLTexture
    /// 作り直した回数。フレームの途中で作り直したら、そのフレームを組み直す
    private(set) var generation = 0

    private let size = 2048
    private var fonts: [Int: CTFont] = [:]
    private var cache: [Key: Entry] = [:]
    private var shelfX = 0, shelfY = 0, shelfHeight = 0

    init?(device: MTLDevice, spec: FontSpec) {
        self.device = device
        self.spec = spec
        let regular = Self.makeFont(spec, bold: false, italic: false)
        // セルの幅は「M」の送り幅、高さは行の高さを、どちらも物理ピクセルの整数に丸める
        var glyph = CGGlyph(0)
        var m: UniChar = 0x4D
        CTFontGetGlyphsForCharacters(regular, &m, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(regular), descent = CTFontGetDescent(regular), leading = CTFontGetLeading(regular)
        let natural = ascent + descent + leading
        let height = max((spec.pixelSize * 1.2).rounded(), natural.rounded(.up))
        metrics = CellMetrics(scale: spec.scale, widthPx: Int(advance.width.rounded()), heightPx: Int(height))
        baseline = ((height - (ascent + descent)) / 2 + ascent).rounded()
        guard let t = Self.makeTexture(device: device, size: size) else { return nil }
        texture = t
        fonts[0] = regular
    }

    static func makeTexture(device: MTLDevice, size: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    /// 設定の font-family。`system-mono` は iOS の等幅（SF Mono）
    static func makeFont(_ spec: FontSpec, bold: Bool, italic: Bool) -> CTFont {
        var base: CTFont
        if spec.family == "system-mono" {
            base = UIFont.monospacedSystemFont(ofSize: spec.pixelSize, weight: .regular) as CTFont
        } else {
            base = CTFontCreateWithName(spec.family as CFString, spec.pixelSize, nil)
            if (CTFontCopyFamilyName(base) as String) != spec.family {
                // 見つからない名前は等幅の既定に
                base = UIFont.monospacedSystemFont(ofSize: spec.pixelSize, weight: .regular) as CTFont
            }
        }
        // 日本語は font-family-cjk にフォールバックさせる
        let cjk = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: spec.cjkFamily] as CFDictionary)
        let desc = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), [kCTFontCascadeListAttribute: [cjk]] as CFDictionary)
        var font = CTFontCreateWithFontDescriptor(desc, spec.pixelSize, nil)
        var traits = CTFontSymbolicTraits()
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let t = CTFontCreateCopyWithSymbolicTraits(font, spec.pixelSize, nil, traits, traits) {
            font = t
        }
        return font
    }

    private func font(bold: Bool, italic: Bool) -> CTFont {
        let k = (bold ? 1 : 0) | (italic ? 2 : 0)
        if let f = fonts[k] { return f }
        let f = Self.makeFont(spec, bold: bold, italic: italic)
        fonts[k] = f
        return f
    }

    /// 文字の位置。無ければラスタライズして足す
    func entry(for key: Key) -> Entry? {
        if let e = cache[key] { return e }
        let w = metrics.widthPx * (key.wide ? 2 : 1)
        let h = metrics.heightPx
        if shelfX + w + 1 > size {
            shelfX = 0
            shelfY += shelfHeight + 1
            shelfHeight = 0
        }
        if shelfY + h + 1 > size {
            reset()
        }
        guard let pixels = rasterize(key, width: w, height: h) else { return nil }
        let region = MTLRegionMake2D(shelfX, shelfY, w, h)
        pixels.withUnsafeBytes { raw in
            texture.replace(region: region, mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: w)
        }
        let e = Entry(x: Float(shelfX), y: Float(shelfY), w: Float(w), h: Float(h))
        cache[key] = e
        shelfX += w + 1
        shelfHeight = max(shelfHeight, h)
        return e
    }

    /// いっぱいになったら全部捨てて作り直す（画面に出ている文字だけがまた入る）
    private func reset() {
        cache.removeAll(keepingCapacity: true)
        shelfX = 0
        shelfY = 0
        shelfHeight = 0
        if let t = Self.makeTexture(device: device, size: size) { texture = t }
        generation += 1
    }

    private func rasterize(_ key: Key, width w: Int, height h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: w * h)
        let ctFont = font(bold: key.bold, italic: key.italic)
        let attr = NSAttributedString(string: key.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldAntialias(true)
            ctx.setAllowsFontSubpixelPositioning(false)
            ctx.setGrayFillColor(1, alpha: 1)
            ctx.textMatrix = .identity
            // セルより狭い文字（全角のフォールバックなど）は中央に置く
            let x = advance < CGFloat(w) ? ((CGFloat(w) - advance) / 2).rounded(.down) : 0
            ctx.textPosition = CGPoint(x: x, y: CGFloat(h) - baseline)
            CTLineDraw(line, ctx)
            return true
        }
        return ok ? buf : nil
    }
}
