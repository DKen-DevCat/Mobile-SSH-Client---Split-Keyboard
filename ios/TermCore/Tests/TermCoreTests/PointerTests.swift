import CoreGraphics
import XCTest
@testable import TermCore

final class PointerTests: XCTestCase {
    // MARK: 加速

    func testGainAtTheEnds() {
        XCTAssertEqual(PointerCurve.gain(speed: PointerCurve.slowSpeed), 0.9, accuracy: 1e-9)
        XCTAssertEqual(PointerCurve.gain(speed: PointerCurve.fastSpeed), 3.2, accuracy: 1e-9)
        XCTAssertEqual(PointerCurve.gain(speed: 10), 0.9, accuracy: 1e-9)
        XCTAssertEqual(PointerCurve.gain(speed: 5000), 3.2, accuracy: 1e-9)
        XCTAssertEqual(PointerCurve.gain(speed: .infinity), 3.2, accuracy: 1e-9)
    }

    /// 止まっている・負・数でない速さは最小の倍率（指を止めたらポインタも止まる、を壊さない）
    func testGainForZeroNegativeAndInvalidSpeed() {
        XCTAssertEqual(PointerCurve.gain(speed: 0), 0.9)
        XCTAssertEqual(PointerCurve.gain(speed: -300), 0.9)
        XCTAssertEqual(PointerCurve.gain(speed: .nan), 0.9)
    }

    func testGainGrowsWithSpeedAndStaysInRange() {
        let speeds = stride(from: 0.0, through: 1200, by: 10).map { CGFloat($0) }
        let gains = speeds.map { PointerCurve.gain(speed: $0) }
        XCTAssertEqual(gains, gains.sorted())
        XCTAssertTrue(gains.allSatisfy { $0 >= 0.9 && $0 <= 3.2 })
        // 遅い側と速い側のあいだは、本当に増える
        XCTAssertLessThan(PointerCurve.gain(speed: 100), PointerCurve.gain(speed: 300))
        XCTAssertLessThan(PointerCurve.gain(speed: 300), PointerCurve.gain(speed: 600))
        XCTAssertLessThan(PointerCurve.gain(speed: 600), PointerCurve.gain(speed: 880))
        // 真ん中の速さで、倍率の真ん中（smoothstep の 0.5）
        let mid = (PointerCurve.slowSpeed + PointerCurve.fastSpeed) / 2
        XCTAssertEqual(PointerCurve.gain(speed: mid), (0.9 + 3.2) / 2, accuracy: 1e-9)
    }

    // MARK: 動ける範囲

    let shell = CGRect(x: 234, y: 0, width: 344, height: 354)
    let rows = CGRect(x: 44, y: 0, width: 724, height: 52)

    func testPointInsideTheAreaStays() {
        for p in [CGPoint(x: 400, y: 200), CGPoint(x: 100, y: 30), CGPoint(x: 700, y: 10)] {
            XCTAssertEqual(PointerArea.clamp(p, toUnionOf: [shell, rows]), p)
        }
    }

    /// シェルの左（キーボードの上）へ出る動きは、上の 2 行の高さの中なら通り、その下ならシェルの左端に止まる
    func testPointerOutsideGoesToTheNearestPointOfTheUnion() {
        // キーボードの上で、上の 2 行の高さの中: 行の四角の中なのでそのまま
        XCTAssertEqual(PointerArea.clamp(CGPoint(x: 100, y: 40), toUnionOf: [shell, rows]), CGPoint(x: 100, y: 40))
        // 行より下（キーボードの上）で、シェルに近い: シェルの左端へ
        let nearShell = PointerArea.clamp(CGPoint(x: 220, y: 200), toUnionOf: [shell, rows])
        XCTAssertEqual(nearShell, CGPoint(x: 234, y: 200))
        // 行より下で、行の下端に近い（シェルより行の方が近い）: 行の下端へ
        let nearRows = PointerArea.clamp(CGPoint(x: 100, y: 70), toUnionOf: [shell, rows])
        XCTAssertEqual(nearRows, CGPoint(x: 100, y: 51))
        // 画面の外（上・右・下）
        XCTAssertEqual(PointerArea.clamp(CGPoint(x: 400, y: -30), toUnionOf: [shell, rows]), CGPoint(x: 400, y: 0))
        XCTAssertEqual(PointerArea.clamp(CGPoint(x: 900, y: 20), toUnionOf: [shell, rows]), CGPoint(x: 767, y: 20))
        XCTAssertEqual(PointerArea.clamp(CGPoint(x: 400, y: 900), toUnionOf: [shell, rows]), CGPoint(x: 400, y: 353))
    }

    /// 右端・下端は 1pt 内側に止める（その点の下のビューを hitTest で引けるように）
    func testClampKeepsTheLastPointInsideTheRect() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(PointerArea.clamp(CGPoint(x: 500, y: 500), to: r), CGPoint(x: 109, y: 69))
        XCTAssertEqual(PointerArea.clamp(CGPoint(x: -5, y: -5), to: r), CGPoint(x: 10, y: 20))
        XCTAssertTrue(r.contains(PointerArea.clamp(CGPoint(x: 500, y: 500), to: r)))
    }

    func testEmptyRectsAreIgnored() {
        let p = CGPoint(x: 5, y: 5)
        XCTAssertEqual(PointerArea.clamp(p, toUnionOf: []), p)
        XCTAssertEqual(PointerArea.clamp(p, toUnionOf: [.zero]), p)
        XCTAssertEqual(PointerArea.clamp(CGPoint(x: 0, y: 500), toUnionOf: [.zero, shell]), CGPoint(x: 234, y: 353))
    }
}
