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

    /// 位置情報を外せなかった（送らずに止める。原本をそのまま送ることはしない）
    static let locationNotRemoved = Failure.unreadable(
        "位置情報を外せなかったので送りませんでした。そのまま送るなら config で media-strip-location = false（端末での確認が要ります）")

    // MARK: 位置情報を外す

    /// 位置情報を外した写しを作り、その場所を返す。外せたことを読み直して確かめる。外せなければ投げる（送らない）。
    /// - 画像: メタデータだけ書き換える（再圧縮しない）。書き戻せない形式（RAW・WebP など）は JPEG にして外す
    /// - 動画・m4a: 書き出し直す（再エンコードしない）。時系列の位置のトラックが残るものは送らない
    /// - そのほか（PDF・テキスト・mp3・wav など、位置を持たない形式）: そのままの写し
    static func withoutLocation(_ src: URL) async throws -> URL {
        let ext = src.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true && type?.conforms(to: .svg) != true {
            return try stripImageLocation(src)
        }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true || ext == "m4a" {
            return try await stripAVLocation(src)
        }
        let dst = MediaPicker.newURL(ext: ext)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    private static func stripImageLocation(_ src: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), let type = CGImageSourceGetType(source) else {
            throw Failure.unreadable("画像を読めません")
        }
        let dst = MediaPicker.newURL(ext: src.pathExtension)
        if copyWithoutGPS(source, type: type, to: dst) { return dst }
        // 書き戻せない形式。JPEG にして外す
        let jpg = MediaPicker.newURL(ext: "jpg")
        try convertToJPEG(src, to: jpg, stripLocation: true)
        return jpg
    }

    /// メタデータから GPS（EXIF と XMP）だけを外して写す。外せたことまで確かめられたら true
    private static func copyWithoutGPS(_ source: CGImageSource, type: CFString, to dst: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, type, CGImageSourceGetCount(source), nil) else {
            return false
        }
        let options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        var error: Unmanaged<CFError>?
        if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error), hasNoLocation(image: dst) {
            return true
        }
        try? FileManager.default.removeItem(at: dst)
        return false
    }

    /// 画像に位置情報が残っていないか（EXIF の GPS と、XMP の GPS のタグ）
    static func hasNoLocation(image url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        for i in 0..<CGImageSourceGetCount(source) {
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
               props[kCGImagePropertyGPSDictionary] != nil {
                return false
            }
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, i, nil) {
                var found = false
                let options = [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
                CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, options) { _, tag in
                    if let name = CGImageMetadataTagCopyName(tag) as String?, name.hasPrefix("GPS") {
                        found = true
                        return false
                    }
                    return true
                }
                if found { return false }
            }
        }
        return true
    }

    // MARK: 画像

    /// エージェントが読めない画像（HEIC など）を JPEG に。大きさは変えない。位置情報を外すなら、外れたことまで確かめる
    static func convertToJPEG(_ src: URL, to dst: URL, stripLocation: Bool) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else {
            throw Failure.unreadable("画像を読めません")
        }
        let jpeg = UTType.jpeg.identifier as CFString
        guard stripLocation else {
            try writeImage(source, to: dst, type: jpeg, quality: 0.92)
            return
        }
        // 一度 JPEG にしてから、メタデータの GPS（EXIF と XMP）を外して写す
        let tmp = MediaPicker.newURL(ext: "jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeImage(source, to: tmp, type: jpeg, quality: 0.92)
        guard let encoded = CGImageSourceCreateWithURL(tmp as CFURL, nil), copyWithoutGPS(encoded, type: jpeg, to: dst) else {
            throw locationNotRemoved
        }
    }

    private static func writeImage(_ source: CGImageSource, to dst: URL, type: CFString, quality: Double) throws {
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, type, 1, nil) else {
            throw Failure.unreadable("画像を書けません")
        }
        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImageFromSource(dest, source, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.unreadable("画像を書けません") }
    }

    // MARK: 動画・音声

    /// 位置情報などの個人の情報を外した写し（再エンコードしない。AVMetadataItemFilter.forSharing）
    private static func stripAVLocation(_ src: URL) async throws -> URL {
        let ext = src.pathExtension.lowercased()
        let (fileType, outExt): (AVFileType, String) =
            ext == "mp4" ? (.mp4, "mp4") : ext == "m4v" ? (.m4v, "m4v") : ext == "m4a" ? (.m4a, "m4a") : (.mov, "mov")
        let dst = MediaPicker.newURL(ext: outExt)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: src), presetName: AVAssetExportPresetPassthrough) else {
            throw locationNotRemoved
        }
        export.outputURL = dst
        export.outputFileType = fileType
        export.metadataItemFilter = .forSharing()
        export.shouldOptimizeForNetworkUse = false
        await export.export()
        guard export.status == .completed, (try? await hasNoLocation(av: dst)) == true else {
            try? FileManager.default.removeItem(at: dst)
            throw locationNotRemoved
        }
        return dst
    }

    /// 動画・音声に位置情報が残っていないか（位置のメタデータと、時系列のメタデータのトラック）
    static func hasNoLocation(av url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        for item in try await asset.load(.metadata) {
            if item.commonKey == .commonKeyLocation { return false }
            if let id = item.identifier?.rawValue.lowercased(), id.contains("location") || id.contains("gps") { return false }
        }
        return try await asset.loadTracks(withMediaType: .metadata).isEmpty
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
        var times: [Double] = []
        var scores: [Double] = []
        var previous: [Double]?
        for t in ContactSheetPlanner.probeTimes(duration: duration) {
            // 読めない 1 枚は飛ばす（壊れた区間があっても、シートは作る）
            guard let frame = try? await probe.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { continue }
            let luma = lumaGrid(frame.image)
            times.append(t)
            scores.append(previous.map { prev in zip(prev, luma).map { abs($0 - $1) }.reduce(0, +) / 64 } ?? 0)
            previous = luma
        }
        guard !times.isEmpty else { throw Failure.unreadable("動画の絵を読めません") }

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
            audio = MediaPicker.newURL(ext: "m4a")
            let asset = AVURLAsset(url: media)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                return .skipped("（音声を取り出せないので、文字起こしを飛ばしました）")
            }
            export.outputURL = audio
            export.outputFileType = .m4a
            await export.export()
            guard export.status == .completed else {
                try? FileManager.default.removeItem(at: audio)
                return .skipped("（動画に音声が無いので、文字起こしを飛ばしました）")
            }
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
