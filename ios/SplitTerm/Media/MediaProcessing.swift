import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import Speech
import TermCore
import UniformTypeIdentifiers

/// 送る前の加工（すべて端末の中。外のサービスに送らない）。docs/design.md「メディアを送る」「動画を画像にして送る」
enum MediaProcessing {
    enum Failure: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let s): return s
            }
        }
    }

    // MARK: 画像

    /// 位置情報だけを外した写し（再圧縮しない）。できない形式なら、そのままの写し
    static func stripImageLocation(_ src: URL, to dst: URL) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), let type = CGImageSourceGetType(source),
              let dest = CGImageDestinationCreateWithURL(dst as CFURL, type, CGImageSourceGetCount(source), nil) else {
            try FileManager.default.copyItem(at: src, to: dst)
            return
        }
        let options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        var error: Unmanaged<CFError>?
        if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) { return }
        // 画素はそのまま、メタデータだけ書き換えられない形式。位置情報を外した性質で書き直す（高い品質で）
        try? FileManager.default.removeItem(at: dst)
        try writeImage(source, to: dst, type: type, quality: 0.95, stripLocation: true)
    }

    /// エージェントが読めない画像（HEIC など）を JPEG に。大きさは変えない
    static func convertToJPEG(_ src: URL, to dst: URL, stripLocation: Bool) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else {
            throw Failure.unreadable("画像を読めません")
        }
        try writeImage(source, to: dst, type: UTType.jpeg.identifier as CFString, quality: 0.92, stripLocation: stripLocation)
    }

    private static func writeImage(_ source: CGImageSource, to dst: URL, type: CFString, quality: Double,
                                   stripLocation: Bool) throws {
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, type, 1, nil) else {
            throw Failure.unreadable("画像を書けません")
        }
        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        if stripLocation { props[kCGImagePropertyGPSDictionary] = kCFNull }
        CGImageDestinationAddImageFromSource(dest, source, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.unreadable("画像を書けません") }
    }

    // MARK: 動画

    /// 位置情報などの個人の情報を外した写し（再エンコードしない。AVMetadataItemFilter.forSharing）
    static func stripVideoLocation(_ src: URL, to dst: URL) async throws {
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            try FileManager.default.copyItem(at: src, to: dst)
            return
        }
        export.outputURL = dst
        export.outputFileType = dst.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        export.metadataItemFilter = .forSharing()
        export.shouldOptimizeForNetworkUse = false
        await export.export()
        if export.status != .completed {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
        }
    }

    struct Sheet {
        var jpeg: URL
        var layout: ContactSheetPlanner.Layout
        var times: [Double]
        var duration: Double
        var width: Int
        var height: Int
    }

    /// 動画のコンタクトシート。下見は 64px の縮図だけで、全解像度で読むのは選んだ枚数だけ
    static func contactSheet(_ video: URL, to dst: URL, frames: Int, longSide: Int) async throws -> Sheet {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.unreadable("動画に映像がありません")
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let shown = natural.applying(transform)
        let width = Int(abs(shown.width).rounded()), height = Int(abs(shown.height).rounded())

        // 1. 下見: 64px の縮図から 8×8 の明るさを取り、前との違いを点数にする
        let probe = AVAssetImageGenerator(asset: asset)
        probe.appliesPreferredTrackTransform = true
        probe.maximumSize = CGSize(width: 64, height: 64)
        probe.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        probe.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        let times = ContactSheetPlanner.probeTimes(duration: duration)
        var scores: [Double] = []
        var previous: [Double]?
        for t in times {
            let luma = lumaGrid(try await probe.image(at: CMTime(seconds: t, preferredTimescale: 600)).image)
            scores.append(previous.map { prev in zip(prev, luma).map { abs($0 - $1) }.reduce(0, +) / 64 } ?? 0)
            previous = luma
        }

        // 2. 選ぶ・3. 並べる
        let count = ContactSheetPlanner.frameCount(duration: duration, configured: frames, available: times.count)
        let picked = ContactSheetPlanner.select(times: times, scores: scores, count: count)
        let layout = ContactSheetPlanner.layout(count: picked.count, videoWidth: Double(width),
                                                videoHeight: Double(height), longSide: longSide)
        let tiles = AVAssetImageGenerator(asset: asset)
        tiles.appliesPreferredTrackTransform = true
        tiles.maximumSize = CGSize(width: layout.tileWidth, height: layout.tileHeight)
        tiles.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        tiles.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        guard let ctx = CGContext(data: nil, width: layout.width, height: layout.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure.unreadable("シートを作れません")
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        for (i, t) in picked.enumerated() {
            let col = i % layout.columns, row = i / layout.columns
            // CoreGraphics は左下が原点。上の行から並べる
            let cell = CGRect(x: col * layout.tileWidth, y: layout.height - (row + 1) * layout.tileHeight,
                              width: layout.tileWidth, height: layout.tileHeight)
            if let frame = try? await tiles.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                let image = frame.image
                ctx.draw(image, in: aspectFit(CGSize(width: image.width, height: image.height), in: cell))
            }
            drawLabel(ContactSheetPlanner.timestamp(t), in: cell, ctx: ctx)
        }
        guard let sheet = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.unreadable("シートを書けません")
        }
        CGImageDestinationAddImage(dest, sheet, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.unreadable("シートを書けません") }
        return Sheet(jpeg: dst, layout: layout, times: picked, duration: duration, width: width, height: height)
    }

    /// 8×8 の明るさ（0〜1）。64px の縮図をさらに縮めるだけなので軽い
    static func lumaGrid(_ image: CGImage) -> [Double] {
        var px = [UInt8](repeating: 0, count: 64)
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return px.map { Double($0) / 255 }
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// タイルの左下に時刻（黒地に白）
    static func drawLabel(_ text: String, in cell: CGRect, ctx: CGContext) {
        let size = max(11, cell.height * 0.11)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let pad = size * 0.3
        let box = CGRect(x: cell.minX + pad, y: cell.minY + pad, width: bounds.width + pad * 2, height: size + pad)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
        ctx.fill(box)
        ctx.textPosition = CGPoint(x: box.minX + pad, y: box.minY + pad * 0.8)
        CTLineDraw(line, ctx)
    }

    // MARK: 文字起こし（オンデバイスだけ）

    enum TranscriptOutcome {
        case segments([VideoNotes.Segment])
        /// 文字起こしをしなかった理由（添え書きに書く）
        case skipped(String)
    }

    /// 音声を、端末の中だけで日本語の文字にする。端末にモデルが無ければ、外へ送らずに飛ばす
    static func transcribe(_ media: URL) async -> TranscriptOutcome {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { return .skipped("（音声認識が許可されていないので、文字起こしを飛ばしました）") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), recognizer.isAvailable else {
            return .skipped("（日本語の音声認識が使えないので、文字起こしを飛ばしました）")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .skipped("（端末に日本語の音声認識のモデルが無いので、外へ送らずに飛ばしました）")
        }
        // 動画なら音声だけを取り出す（再エンコードは音声だけ。軽い）
        let audio: URL
        if case .audio = MediaSource(fileExtension: media.pathExtension) {
            audio = media
        } else {
            audio = media.deletingPathExtension().appendingPathExtension("audio.m4a")
            let asset = AVURLAsset(url: media)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                return .skipped("（音声を取り出せないので、文字起こしを飛ばしました）")
            }
            export.outputURL = audio
            export.outputFileType = .m4a
            await export.export()
            guard export.status == .completed else { return .skipped("（動画に音声が無いので、文字起こしを飛ばしました）") }
        }
        defer { if audio != media { try? FileManager.default.removeItem(at: audio) } }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return await withCheckedContinuation { (c: CheckedContinuation<TranscriptOutcome, Never>) in
            // 認識が終わるまで、認識器と作業を持っておく（終わったら離す）
            let holder = RecognitionHolder()
            holder.recognizer = recognizer
            holder.task = recognizer.recognitionTask(with: request) { result, error in
                guard !holder.finished else { return }
                if let result, result.isFinal {
                    holder.finish()
                    c.resume(returning: .segments(segments(result.bestTranscription)))
                } else if error != nil {
                    holder.finish()
                    c.resume(returning: .skipped("（文字起こしに失敗しました）"))
                }
            }
        }
    }

    private final class RecognitionHolder {
        var recognizer: SFSpeechRecognizer?
        var task: SFSpeechRecognitionTask?
        private(set) var finished = false
        func finish() {
            finished = true
            task = nil
            recognizer = nil
        }
    }

    /// 言葉の切れ目（0.8 秒以上の間）で区切り、区切りの最初の時刻を付ける
    static func segments(_ t: SFTranscription) -> [VideoNotes.Segment] {
        var out: [VideoNotes.Segment] = []
        var text = "", start = 0.0, lastEnd = -1.0
        for s in t.segments {
            if lastEnd >= 0 && s.timestamp - lastEnd > 0.8 && !text.isEmpty {
                out.append(.init(start: start, text: text))
                text = ""
            }
            if text.isEmpty { start = s.timestamp }
            text += s.substring
            lastEnd = s.timestamp + s.duration
        }
        if !text.isEmpty { out.append(.init(start: start, text: text)) }
        return out
    }
}
