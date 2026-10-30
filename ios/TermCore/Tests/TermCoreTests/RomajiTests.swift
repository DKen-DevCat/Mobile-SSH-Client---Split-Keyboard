import XCTest
@testable import TermCore

final class RomajiTests: XCTestCase {
    /// 打った文字をすべて入れ、最後に残りを確定したかな
    func convert(_ s: String) -> String {
        var r = RomajiConverter()
        var out = ""
        for c in s {
            out += r.input(c) ?? String(c)
        }
        return out + r.flush()
    }

    func testBasics() {
        XCTAssertEqual(convert("aiueo"), "あいうえお")
        // nn はその場で「ん」になる（Mac・Windows の日本語入力と同じ）。こんにちは は n を 3 回
        XCTAssertEqual(convert("konnnichiha"), "こんにちは")
        XCTAssertEqual(convert("shinbun"), "しんぶん")
        XCTAssertEqual(convert("sinbun"), "しんぶん")
        XCTAssertEqual(convert("tsukue"), "つくえ")
        XCTAssertEqual(convert("fujisan"), "ふじさん")
    }

    func testSmallTsuAndN() {
        XCTAssertEqual(convert("kitte"), "きって")
        XCTAssertEqual(convert("macchi"), "まっち")
        XCTAssertEqual(convert("kannna"), "かんな")
        XCTAssertEqual(convert("kan'i"), "かんい")
        XCTAssertEqual(convert("hon"), "ほん")
        XCTAssertEqual(convert("nnn"), "んん")
    }

    func testYouonAndSmall() {
        XCTAssertEqual(convert("kyouto"), "きょうと")
        XCTAssertEqual(convert("ryokou"), "りょこう")
        XCTAssertEqual(convert("jidousha"), "じどうしゃ")
        XCTAssertEqual(convert("xa"), "ぁ")
        XCTAssertEqual(convert("ltu"), "っ")
        XCTAssertEqual(convert("fa"), "ふぁ")
        XCTAssertEqual(convert("thi"), "てぃ")
        XCTAssertEqual(convert("vu"), "ゔ")
    }

    func testPunctuation() {
        XCTAssertEqual(convert("ra-men."), "らーめん。")
        XCTAssertEqual(convert("[a],"), "「あ」、")
    }

    func testPendingAndDelete() {
        var r = RomajiConverter()
        XCTAssertEqual(r.input("k"), "")
        XCTAssertEqual(r.pending, "k")
        XCTAssertTrue(r.deleteBackward())
        XCTAssertTrue(r.isEmpty)
        XCTAssertFalse(r.deleteBackward())
        XCTAssertEqual(r.input("K"), "")
        XCTAssertEqual(r.input("A"), "か")
        // 英字と記号のほかは扱わない（数字など）
        XCTAssertNil(r.input("1"))
    }
}
