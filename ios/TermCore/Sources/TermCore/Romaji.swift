import Foundation

/// ローマ字をかなにする（docs/design.md「ローマ字入力」）。Mac の日本語入力と同じ規則:
/// - `nn`・`n'` で「ん」。n の後に子音（y と n 以外）が来ても「ん」
/// - 同じ子音を重ねると「っ」（kk → っk）
/// - `x`・`l` で小さい文字（xa → ぁ、xtu → っ）
/// - `,` `.` `-` `[` `]` `/` は「、」「。」「ー」「「」「」」「・」
public struct RomajiConverter: Sendable {
    /// まだかなにならない英字（画面に出す）
    public private(set) var pending = ""

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    /// 1 文字入れて、確定したかなを返す。ローマ字の英字か記号でなければ nil（呼ぶ側でそのまま扱う）
    public mutating func input(_ c: Character) -> String? {
        let lower = Character(c.lowercased())
        if let p = Self.punctuation[lower] {
            return flush() + p
        }
        guard lower.isASCII, lower.isLetter || lower == "'" else { return nil }
        pending.append(lower)
        var out = ""
        while !pending.isEmpty {
            if let kana = Self.table[pending] {
                out += kana
                pending = ""
                break
            }
            let chars = Array(pending)
            // 同じ子音を重ねたら「っ」（n は「ん」なので除く）
            if chars.count >= 2, chars[0] == chars[1], Self.consonants.contains(chars[0]), chars[0] != "n" {
                out += "っ"
                pending.removeFirst()
                continue
            }
            // n の後に、母音・y・n 以外が来たら「ん」
            if chars.count >= 2, chars[0] == "n", !"aiueoyn'".contains(chars[1]) {
                out += "ん"
                pending.removeFirst()
                continue
            }
            // 続きがありうるなら待つ
            if Self.prefixes.contains(pending) { break }
            // どの綴りにもならない。最初の 1 文字はそのまま出す
            out.append(pending.removeFirst())
        }
        return out
    }

    /// 1 文字消す（まだかなになっていない英字があれば）。消したら true
    public mutating func deleteBackward() -> Bool {
        guard !pending.isEmpty else { return false }
        pending.removeLast()
        return true
    }

    /// 残りを確定する（n だけなら「ん」、ほかの英字はそのまま）
    public mutating func flush() -> String {
        defer { pending = "" }
        if pending == "n" { return "ん" }
        return pending
    }

    static let consonants = Set("bcdfghjklmpqrstvwxyz")

    static let punctuation: [Character: String] = [
        ",": "、", ".": "。", "-": "ー", "[": "「", "]": "」", "/": "・", "~": "〜",
    ]

    /// ローマ字 → かな
    static let table: [String: String] = {
        var t: [String: String] = [
            "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
            "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
            "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
            "sa": "さ", "si": "し", "shi": "し", "su": "す", "se": "せ", "so": "そ",
            "za": "ざ", "zi": "じ", "ji": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
            "ta": "た", "ti": "ち", "chi": "ち", "tu": "つ", "tsu": "つ", "te": "て", "to": "と",
            "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
            "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
            "ha": "は", "hi": "ひ", "hu": "ふ", "fu": "ふ", "he": "へ", "ho": "ほ",
            "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
            "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
            "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
            "ya": "や", "yu": "ゆ", "yo": "よ", "ye": "いぇ",
            "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
            "wa": "わ", "wi": "うぃ", "we": "うぇ", "wo": "を",
            "nn": "ん", "n'": "ん", "xn": "ん",
            "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
            "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ", "fyu": "ふゅ",
            "sha": "しゃ", "shu": "しゅ", "she": "しぇ", "sho": "しょ",
            "cha": "ちゃ", "chu": "ちゅ", "che": "ちぇ", "cho": "ちょ",
            "ja": "じゃ", "ju": "じゅ", "je": "じぇ", "jo": "じょ",
            "tsa": "つぁ", "thi": "てぃ", "dhi": "でぃ", "twu": "とぅ", "dwu": "どぅ",
            "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ",
            "xya": "ゃ", "xyu": "ゅ", "xyo": "ょ", "xtu": "っ", "xtsu": "っ", "xwa": "ゎ",
            "xka": "ヵ", "xke": "ヶ",
        ]
        // ky・gy・… の拗音（きゃ きぃ きゅ きぇ きょ）
        let youon: [(String, String)] = [
            ("k", "き"), ("g", "ぎ"), ("s", "し"), ("z", "じ"), ("j", "じ"), ("t", "ち"), ("c", "ち"), ("d", "ぢ"),
            ("n", "に"), ("h", "ひ"), ("b", "び"), ("p", "ぴ"), ("m", "み"), ("r", "り"),
        ]
        let small = ["a": "ゃ", "i": "ぃ", "u": "ゅ", "e": "ぇ", "o": "ょ"]
        for (c, base) in youon {
            for (v, s) in small { t["\(c)y\(v)"] = base + s }
        }
        // l でも小さい文字（la・ltu など）
        for (k, v) in t where k.hasPrefix("x") && k != "xn" {
            t["l" + k.dropFirst()] = v
        }
        return t
    }()

    /// どれかの綴りの途中（続きを待つ）
    static let prefixes: Set<String> = {
        var p = Set<String>()
        for k in table.keys {
            for i in 1..<k.count { p.insert(String(k.prefix(i))) }
        }
        return p
    }()
}
