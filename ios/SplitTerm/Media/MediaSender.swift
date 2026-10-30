import Foundation
import TermCore
import TermSession
import UIKit

/// 選んだメディアを加工して受け取り箱へ送り、パスを入力行に入れる（docs/design.md「メディアを送る」）。
/// 加工は裏のタスク（メインスレッドを空ける）。送るのは同じ SSH の接続。切れたら繋ぎ直しを待って続きから
@MainActor
final class MediaSender {
    /// 環境バーに出す進み具合（nil で消す）
    var onStatus: ((String?) -> Void)?
    var onError: ((String) -> Void)?
    /// 入力行へ入れる（Enter は押さない）
    var onInsert: ((String) -> Void)?
    private(set) var busy = false

    /// 1 回の送信。加工してできたファイルと、接続先での名前
    struct Outgoing {
        var local: URL
        var remoteName: String
    }

    func send(_ items: [PickedMedia], config: TermConfig, session: TerminalSession) {
        guard !busy else {
            onError?("前のメディアを送っている途中です")
            return
        }
        busy = true
        var background = UIBackgroundTaskIdentifier.invalid
        // 裏に回っても、区切りまでは送る（iOS が許す間だけ。切れたら次に開いたとき続きから）
        background = UIApplication.shared.beginBackgroundTask(withName: "send-media") {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        Task { @MainActor [self] in
            defer {
                busy = false
                onStatus?(nil)
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
                for item in items { try? FileManager.default.removeItem(at: item.url) }
            }
            var paths: [String] = []
            for (i, item) in items.enumerated() {
                let prefix = items.count > 1 ? "\(i + 1)/\(items.count) " : ""
                onStatus?("\(prefix)準備中")
                let outgoing: [Outgoing]
                do {
                    outgoing = try await Self.prepare(item, config: config)
                } catch {
                    onError?("送る準備ができませんでした: \(error.localizedDescription)")
                    continue
                }
                defer { for o in outgoing where o.local != item.url { try? FileManager.default.removeItem(at: o.local) } }
                for o in outgoing {
                    do {
                        let path = try await upload(o, config: config, session: session) { [weak self] p in
                            self?.onStatus?("\(prefix)送信中 \(Int(p * 100))%")
                        }
                        paths.append(path)
                    } catch {
                        onError?("送れませんでした: \(error.localizedDescription)")
                    }
                }
            }
            if !paths.isEmpty { onInsert?(MediaInsert.text(template: config.mediaInsert, paths: paths)) }
        }
    }

    /// 送る。切れていたら繋ぎ直しを 30 秒まで待ち、同じ名前で続きから（3 回まで）
    private func upload(_ o: Outgoing, config: TermConfig, session: TerminalSession,
                        progress: @escaping @MainActor (Double) -> Void) async throws -> String {
        let target = MediaUploader.Target(mediaDir: config.mediaDir, retentionDays: config.mediaRetentionDays)
        var lastError: Error = ExecError.notConnected
        for _ in 0..<3 {
            guard let conn = await waitForConnection(session) else { throw lastError }
            do {
                return try await MediaUploader.upload(o.local, as: o.remoteName, to: target, over: conn) { p in
                    Task { @MainActor in progress(p) }
                }
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw lastError
    }

    private func waitForConnection(_ session: TerminalSession) async -> SSHConnection? {
        for _ in 0..<60 {
            if let c = session.uploadConnection { return c }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    // MARK: 加工（裏で）

    /// 何をどの名前で送るか。エージェントが読める形式・config の送り方から（MediaPlan）
    nonisolated static func prepare(_ item: PickedMedia, config: TermConfig) async throws -> [Outgoing] {
        let ext = item.url.pathExtension
        let source = MediaSource(fileExtension: ext)
        let steps = MediaPlan.steps(for: source, config: config)
        let name = InboxName(date: Date(), random: UInt16.random(in: 0...UInt16.max))
        var out: [Outgoing] = []
        var sheet: MediaProcessing.Sheet?
        var transcript: MediaProcessing.TranscriptOutcome?
        for step in steps {
            switch step {
            case .original:
                let dst = MediaPicker.newURL(ext: ext)
                switch source {
                case .image where config.mediaStripLocation:
                    try MediaProcessing.stripImageLocation(item.url, to: dst)
                case .video where config.mediaStripLocation:
                    try await MediaProcessing.stripVideoLocation(item.url, to: dst)
                default:
                    try FileManager.default.copyItem(at: item.url, to: dst)
                }
                out.append(Outgoing(local: dst, remoteName: name.file(ext: ext)))
            case .convertToJPEG:
                let dst = MediaPicker.newURL(ext: "jpg")
                try MediaProcessing.convertToJPEG(item.url, to: dst, stripLocation: config.mediaStripLocation)
                out.append(Outgoing(local: dst, remoteName: name.file(ext: "jpg")))
            case .contactSheet:
                let dst = MediaPicker.newURL(ext: "jpg")
                let s = try await MediaProcessing.contactSheet(item.url, to: dst, frames: config.videoFrames,
                                                               longSide: config.videoSheetSize)
                sheet = s
                out.append(Outgoing(local: dst, remoteName: name.sheet))
            case .transcript:
                transcript = await MediaProcessing.transcribe(item.url)
            }
        }
        let segments: [VideoNotes.Segment]? = { if case .segments(let s) = transcript { return s } else { return nil } }()
        let skipped: String? = { if case .skipped(let r) = transcript { return r } else { return nil } }()
        if let sheet {
            // 動画: シートの読み方・各タイルの時刻・文字起こしを 1 枚に
            let md = VideoNotes.render(originalName: item.originalName, duration: sheet.duration, width: sheet.width,
                                       height: sheet.height, sheetName: name.sheet, layout: sheet.layout,
                                       times: sheet.times, transcript: segments,
                                       transcriptNote: config.videoTranscribe ? skipped : "（文字起こしはしない設定です）")
            out.append(try write(md, name: name.videoNotes))
        } else if transcript != nil {
            // 音声: 文字起こしだけを 1 枚に
            var lines = ["# 文字起こし（Mobile-SSH-Client---Split-Keyboard）", ""]
            if let n = item.originalName { lines += ["- 元の音声: \(n)", ""] }
            if let segments, !segments.isEmpty {
                lines += segments.map { "- [\(ContactSheetPlanner.timestamp($0.start))] \($0.text)" }
            } else {
                lines.append(skipped ?? "（なし）")
            }
            out.append(try write(lines.joined(separator: "\n") + "\n", name: name.transcript))
        }
        return out
    }

    nonisolated private static func write(_ text: String, name: String) throws -> Outgoing {
        let dst = MediaPicker.newURL(ext: "md")
        try text.write(to: dst, atomically: true, encoding: .utf8)
        return Outgoing(local: dst, remoteName: name)
    }
}
