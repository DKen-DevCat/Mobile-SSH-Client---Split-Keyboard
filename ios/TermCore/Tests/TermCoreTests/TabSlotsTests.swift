import XCTest
@testable import TermCore

final class TabSlotsTests: XCTestCase {
    func testFirstTabIsSlotOne() {
        XCTAssertEqual(TabSlots.next(used: []), 1)
    }

    func testTakesTheSmallestFreeNumber() {
        XCTAssertEqual(TabSlots.next(used: [1]), 2)
        XCTAssertEqual(TabSlots.next(used: [1, 2]), 3)
        // 閉じて空いた番号は、次に開くタブが使う（同じ tmux のセッションに戻る）
        XCTAssertEqual(TabSlots.next(used: [2]), 1)
        XCTAssertEqual(TabSlots.next(used: [1, 3]), 2)
        XCTAssertEqual(TabSlots.next(used: [1, 2, 4]), 3)
    }

    func testOrderAndDuplicatesDoNotMatter() {
        XCTAssertEqual(TabSlots.next(used: [3, 1, 2]), 4)
        XCTAssertEqual(TabSlots.next(used: [1, 1, 2, 2]), 3)
    }

    func testIgnoresNumbersBelowOne() {
        XCTAssertEqual(TabSlots.next(used: [0, -1]), 1)
        XCTAssertEqual(TabSlots.next(used: [0, 1]), 2)
    }

    func testOpenCloseSequenceReusesNumbers() {
        var open: [Int] = []
        for _ in 0..<3 { open.append(TabSlots.next(used: open)) }
        XCTAssertEqual(open, [1, 2, 3])
        open.removeAll { $0 == 2 }
        XCTAssertEqual(TabSlots.next(used: open), 2)
        open.append(2)
        XCTAssertEqual(TabSlots.next(used: open), 4)
    }
}
