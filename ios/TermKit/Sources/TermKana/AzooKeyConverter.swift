import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import TermCore

/// AzooKey のかな漢字変換（docs/design.md「かなフリック」）。
/// - 学習しない（打った語をディスクに残さない。docs/design.md「セキュリティ要件」）
/// - 絵文字と特殊な候補（日時・計算など）は出さない
/// - 変換器は Sendable でないので、このクラスを 1 本のキューの上だけで使う（`KanaConversionQueue`）
public final class AzooKeyConverter: KanaConverter {
    private let converter: KanaKanjiConverter
    private let options: ConvertRequestOptions

    /// 辞書を開く。重いので、メインスレッドの外で作る
    public init() {
        converter = KanaKanjiConverter.withDefaultDictionary()
        // 学習しないので書き込まれないが、変換器が場所を求めるので、消えてよい一時フォルダを渡す
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("azookey", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        options = ConvertRequestOptions(
            N_best: 10,
            requireJapanesePrediction: false,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            learningType: .nothing,
            memoryDirectoryURL: scratch,
            sharedContainerURL: scratch,
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: .init(versionString: "SplitTerm"))
    }

    public func candidates(for reading: String) -> [KanaCandidate] {
        guard !reading.isEmpty else { return [] }
        var composing = ComposingText()
        composing.insertAtCursorPosition(reading, inputStyle: .direct)
        let result = converter.requestCandidates(composing, options: options)
        let n = reading.count
        var seen = Set<String>()
        var out: [KanaCandidate] = []
        for c in result.mainResults where !c.text.isEmpty && seen.insert(c.text).inserted {
            out.append(KanaCandidate(text: c.text, consumed: min(max(c.rubyCount, 1), n)))
        }
        // 辞書に無い語でも打てるよう、読みそのままとカタカナを最後に足す
        for k in PassthroughConverter.kanaCandidates(for: reading) where seen.insert(k.text).inserted {
            out.append(k)
        }
        return out
    }

    public func reset() {
        converter.stopComposition()
    }
}

/// 変換を 1 本のキューで行い、結果をメインスレッドへ返す。打つたびに頼むので、古い頼みの結果は捨てる
public final class KanaConversionQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "splitterm.kana", qos: .userInitiated)
    private var converter: KanaConverter = PassthroughConverter()
    private var latest = 0
    private let lock = NSLock()

    public init() {
        // 辞書を開くのは裏で。開くまでは、ひらがな・カタカナだけを出す
        queue.async { [self] in converter = AzooKeyConverter() }
    }

    /// 読みの候補を頼む。`completion` はメインスレッドで、最新の頼みの結果だけを受け取る
    public func request(_ reading: String, completion: @escaping ([KanaCandidate]) -> Void) {
        let id: Int = lock.withLock {
            latest += 1
            return latest
        }
        // 変換器が答えるまでの間も、読みそのものはすぐに出す
        completion(PassthroughConverter.kanaCandidates(for: reading))
        guard !reading.isEmpty else { return }
        queue.async { [self] in
            guard lock.withLock({ latest == id }) else { return }
            let result = converter.candidates(for: reading)
            DispatchQueue.main.async { [self] in
                if lock.withLock({ latest == id }) { completion(result) }
            }
        }
    }

    public func reset() {
        lock.withLock { latest += 1 }
        queue.async { [self] in converter.reset() }
    }
}
