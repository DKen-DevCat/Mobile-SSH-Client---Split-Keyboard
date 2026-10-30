import Metal
import QuartzCore
import simd
import TermCore
import TermSession
import UIKit

/// 選択の範囲（行はスクロールバックを含めた通し番号）
struct TextSelection: Equatable {
    var anchor: GridPoint
    var head: GridPoint

    var ordered: (start: GridPoint, end: GridPoint) {
        anchor <= head ? (anchor, head) : (head, anchor)
    }
}

struct GridPoint: Equatable, Comparable {
    var row: Int
    var col: Int
    static func < (a: GridPoint, b: GridPoint) -> Bool { (a.row, a.col) < (b.row, b.col) }
}

/// 画面全体を少ない描画命令にまとめて Metal で描く（docs/design.md「描画と解像度」）。
/// 1 回目: 塗りつぶし（背景・罫線・下線・選択・カーソル）、2 回目: 文字。どちらもインスタンス描画 1 回
final class MetalRenderer {
    struct RectInstance {
        var rect: SIMD4<Float>
        var color: SIMD4<Float>
    }

    struct GlyphInstance {
        var rect: SIMD4<Float>
        var uv: SIMD4<Float>
        var color: SIMD4<Float>
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let rectPipeline: MTLRenderPipelineState
    let glyphPipeline: MTLRenderPipelineState
    private(set) var atlas: GlyphAtlas?
    /// 描き終わるのを待つ数（3 枚まで先に組む）
    private let inflight = DispatchSemaphore(value: 3)
    private var rects: [RectInstance] = []
    private var glyphs: [GlyphInstance] = []

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        func pipeline(_ v: String, _ f: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let r = pipeline("rect_vertex", "rect_fragment"),
              let g = pipeline("glyph_vertex", "glyph_fragment") else { return nil }
        rectPipeline = r
        glyphPipeline = g
    }

    /// フォントと倍率。変わったときだけアトラスを作り直す
    @discardableResult
    func configure(_ spec: GlyphAtlas.FontSpec) -> CellMetrics? {
        if let a = atlas, a.spec == spec { return a.metrics }
        atlas = GlyphAtlas(device: device, spec: spec)
        return atlas?.metrics
    }

    static func color(_ c: RGB, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255, alpha)
    }

    /// 1 フレームを描く。描けなければ false（次のフレームでもう一度）
    @discardableResult
    func draw(_ frame: ScreenFrame, theme: Theme, selection: TextSelection?, cursorVisible: Bool,
              scrolledBack: Bool, layer: CAMetalLayer) -> Bool {
        guard let atlas else { return false }
        let generation = atlas.generation
        build(frame, theme: theme, selection: selection, cursorVisible: cursorVisible, scrolledBack: scrolledBack,
              atlas: atlas)
        if atlas.generation != generation {
            // 組んでいる途中でアトラスを作り直した。前に取った位置が古いので組み直す
            build(frame, theme: theme, selection: selection, cursorVisible: cursorVisible, scrolledBack: scrolledBack,
                  atlas: atlas)
        }

        inflight.wait()
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else {
            inflight.signal()
            return false
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = theme.background
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg.r) / 255, green: Double(bg.g) / 255, blue: Double(bg.b) / 255, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            inflight.signal()
            return false
        }
        var viewport = SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height))
        if !rects.isEmpty, let buf = makeBuffer(rects) {
            enc.setRenderPipelineState(rectPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: rects.count)
        }
        if !glyphs.isEmpty, let buf = makeBuffer(glyphs) {
            enc.setRenderPipelineState(glyphPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: glyphs.count)
        }
        enc.endEncoding()
        let sem = inflight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.present(drawable)
        cb.commit()
        return true
    }

    private func makeBuffer<T>(_ items: [T]) -> MTLBuffer? {
        items.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
    }

    private func build(_ frame: ScreenFrame, theme: Theme, selection: TextSelection?, cursorVisible: Bool,
                       scrolledBack: Bool, atlas: GlyphAtlas) {
        rects.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        let cw = Float(atlas.metrics.widthPx), ch = Float(atlas.metrics.heightPx)
        let defaultBG = theme.background
        let cols = frame.cols

        // 背景。同じ色が続くセルは 1 つの四角にまとめる。既定の背景は塗らない（クリアの色）
        for row in 0..<frame.rows {
            var runStart = 0
            var runColor = frame.cells[row * cols].bg
            for col in 1...cols {
                let c: RGB? = col < cols ? frame.cells[row * cols + col].bg : nil
                if c != runColor {
                    if runColor != defaultBG {
                        rects.append(RectInstance(
                            rect: SIMD4(Float(runStart) * cw, Float(row) * ch, Float(col - runStart) * cw, ch),
                            color: Self.color(runColor)))
                    }
                    if let c {
                        runStart = col
                        runColor = c
                    }
                }
            }
        }

        // 選択
        if let selection {
            let (s, e) = selection.ordered
            let lo = max(s.row, frame.topRow), hi = min(e.row, frame.topRow + frame.rows - 1)
            for row in stride(from: lo, through: hi, by: 1) {
                let y = row - frame.topRow
                let c0 = row == s.row ? s.col : 0
                let c1 = row == e.row ? e.col : cols - 1
                guard c1 >= c0 else { continue }
                rects.append(RectInstance(
                    rect: SIMD4(Float(c0) * cw, Float(y) * ch, Float(c1 - c0 + 1) * cw, ch),
                    color: Self.color(theme.selection)))
            }
        }

        // カーソル（ブロックは塗ってから、その上の文字を背景色で描く）
        var blockCursor: (col: Int, row: Int)? = nil
        if cursorVisible, let cur = frame.cursor {
            let x = Float(cur.col) * cw, y = Float(cur.row) * ch
            let wide = frame.cell(col: cur.col, row: cur.row).wide
            let w = cw * (wide ? 2 : 1)
            let thin = max(2, (ch / 12).rounded())
            switch cur.shape {
            case .block:
                rects.append(RectInstance(rect: SIMD4(x, y, w, ch), color: Self.color(theme.cursor)))
                blockCursor = (cur.col, cur.row)
            case .bar:
                rects.append(RectInstance(rect: SIMD4(x, y, thin, ch), color: Self.color(theme.cursor)))
            case .underline:
                rects.append(RectInstance(rect: SIMD4(x, y + ch - thin, w, thin), color: Self.color(theme.cursor)))
            }
        }

        // 文字・罫線・下線
        let line = max(1, (ch / 16).rounded())
        for row in 0..<frame.rows {
            for col in 0..<cols {
                let cell = frame.cells[row * cols + col]
                guard !cell.text.isEmpty else { continue }
                let x = Float(col) * cw, y = Float(row) * ch
                let isCursor = blockCursor.map { $0.col == col && $0.row == row } ?? false
                let fg = isCursor ? Self.color(theme.background) : Self.color(cell.fg)
                let span: Float = cell.wide ? 2 : 1
                if cell.flags.contains(.underline) {
                    rects.append(RectInstance(rect: SIMD4(x, y + ch - line * 2, cw * span, line), color: fg))
                }
                if cell.flags.contains(.strike) {
                    rects.append(RectInstance(rect: SIMD4(x, y + (ch / 2).rounded(), cw * span, line), color: fg))
                }
                if cell.text == " " { continue }
                if let shapes = BoxDrawing.shapes(
                    for: cell.text,
                    cell: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(cw * span), height: CGFloat(ch))) {
                    for s in shapes {
                        var c = fg
                        c.w *= s.alpha
                        rects.append(RectInstance(
                            rect: SIMD4(Float(s.rect.minX), Float(s.rect.minY), Float(s.rect.width), Float(s.rect.height)),
                            color: c))
                    }
                    continue
                }
                let key = GlyphAtlas.Key(text: cell.text, bold: cell.flags.contains(.bold),
                                         italic: cell.flags.contains(.italic), wide: cell.wide)
                guard let e = atlas.entry(for: key) else { continue }
                glyphs.append(GlyphInstance(rect: SIMD4(x, y, e.w, e.h), uv: SIMD4(e.x, e.y, e.w, e.h), color: fg))
            }
        }

        // スクロールバックを見ている間は、右端に細い印を出す
        if scrolledBack {
            let total = Float(frame.rows) * ch
            rects.append(RectInstance(rect: SIMD4(Float(cols) * cw - 3, 0, 3, total),
                                      color: Self.color(theme.cursor, alpha: 0.6)))
        }
    }
}
