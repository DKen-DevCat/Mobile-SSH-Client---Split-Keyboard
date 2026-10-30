import XCTest
@testable import TermCore

final class MediaPlanTests: XCTestCase {
    func steps(_ ext: String, _ lines: String = "") -> [MediaStep] {
        MediaPlan.steps(for: MediaSource(fileExtension: ext), config: ConfigParser.parse(lines).config)
    }

    func testImagesAreSentAsIsWhenTheAgentCanReadThem() {
        XCTAssertEqual(steps("JPG"), [.original])
        XCTAssertEqual(steps("webp"), [.original])
        XCTAssertEqual(steps("heic"), [.convertToJPEG])
        XCTAssertEqual(steps("webp", "agent = generic"), [.convertToJPEG])
    }

    func testVideoBecomesASheetForImageOnlyAgents() {
        XCTAssertEqual(steps("mov"), [.contactSheet, .transcript])
        XCTAssertEqual(steps("mov", "video-transcribe = false"), [.contactSheet])
        XCTAssertEqual(steps("mov", "agent-media = image,video"), [.original])
        XCTAssertEqual(steps("mov", "video-mode = both"), [.original, .contactSheet, .transcript])
        XCTAssertEqual(steps("mp4", "video-mode = file"), [.original])
    }

    func testAudio() {
        XCTAssertEqual(steps("m4a"), [.transcript])
        XCTAssertEqual(steps("m4a", "agent-media = image,audio"), [.original])
        XCTAssertEqual(steps("wav", "audio-mode = both"), [.original, .transcript])
        XCTAssertEqual(steps("pdf"), [.original])
    }
}

final class InboxAndCommandTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func testInboxNames() {
        let n = InboxName(date: Date(timeIntervalSince1970: 1_793_340_000), random: 0xab12, timeZone: utc)
        XCTAssertEqual(n.base, "20261030-060000-ab12")
        XCTAssertEqual(n.file(ext: "HEIC"), "20261030-060000-ab12.heic")
        XCTAssertEqual(n.file(ext: "../x"), "20261030-060000-ab12.x")
        XCTAssertEqual(n.file(ext: ""), "20261030-060000-ab12.bin")
        XCTAssertEqual(n.sheet, "20261030-060000-ab12.sheet.jpg")
        XCTAssertTrue(InboxName.isSafe(n.videoNotes))
        for bad in ["", ".hidden", "a b", "a/b", "a;b", "$(x)", "a'b"] { XCTAssertFalse(InboxName.isSafe(bad), bad) }
    }

    func testPrepareCommand() throws {
        let c = try RemoteCommands.prepare(mediaDir: "~/.splitterm/inbox", name: "20261030-064000-ab12.jpg", retentionDays: 7)
        // ログインシェルが何であっても /bin/sh で動かす
        XCTAssertTrue(c.hasPrefix("exec /bin/sh -c '"))
        XCTAssertFalse(c.contains("\n"))
        // 消すのはアプリの名前のものだけ。自分の持ち物でない受け取り箱では何もしない
        XCTAssertTrue(c.contains("-name '\\''\(InboxName.glob)'\\'' -mtime +7"))
        XCTAssertTrue(c.contains("[ -O . ] || exit \(RemoteCommands.Exit.notOwner)"))
        // 0 バイトでも送れるよう .part を先に作る
        XCTAssertTrue(c.contains(": >> '\\''20261030-064000-ab12.jpg.part'\\''"))
        let keep = try RemoteCommands.prepare(mediaDir: "/srv/in", name: "a.jpg", retentionDays: 0)
        XCTAssertFalse(keep.contains("find"))
        XCTAssertTrue(keep.contains("mkdir -p '\\''/srv/in'\\''"))
    }

    func testCommandsRefuseUnsafeInput() {
        XCTAssertThrowsError(try RemoteCommands.prepare(mediaDir: "~/$(id)", name: "a.jpg", retentionDays: 7))
        XCTAssertThrowsError(try RemoteCommands.prepare(mediaDir: "~/in", name: "a';rm -rf ~;'", retentionDays: 7))
        XCTAssertThrowsError(try RemoteCommands.append(mediaDir: "~/in", name: "../a"))
        XCTAssertThrowsError(try RemoteCommands.finish(mediaDir: "~/in", name: "a.jpg", sha256: "x"))
        XCTAssertThrowsError(try RemoteCommands.finish(mediaDir: "~/in", name: "a.jpg", sha256: String(repeating: "A", count: 64)))
        // ホームや / そのものは受け取り箱にしない（古いものを消すので）
        for bad in ["~/", "/", "~", "~/.", "/./", "//"] {
            XCTAssertThrowsError(try RemoteCommands.prepare(mediaDir: bad, name: "a.jpg", retentionDays: 7), bad)
        }
    }

    func testAppendAndFinish() throws {
        XCTAssertEqual(try RemoteCommands.append(mediaDir: "~/in", name: "a.jpg"),
                       "exec /bin/sh -c 'umask 077; cd \"$HOME\"/'\\''in'\\'' || exit 3; [ -O . ] || exit 4; cat >> '\\''a.jpg.part'\\'''")
        let sum = String(repeating: "0f", count: 32)
        let f = try RemoteCommands.finish(mediaDir: "~/in", name: "a.jpg", sha256: sum)
        XCTAssertTrue(f.contains("if [ \"$s\" != '\\''\(sum)'\\'' ]"))
        XCTAssertTrue(f.hasSuffix("echo \(RemoteCommands.doneMarker)'"))
        for tool in ["shasum -a 256", "sha256sum", "sha256 -q", "openssl dgst -sha256"] { XCTAssertTrue(f.contains(tool), tool) }
    }

    func testFinishedNeedsStatusAndMarker() {
        XCTAssertTrue(RemoteCommands.finished(status: 0, stdout: "Looking up…\nsplitterm-done\n"))
        XCTAssertFalse(RemoteCommands.finished(status: 0, stdout: "token ok\n"))
        XCTAssertFalse(RemoteCommands.finished(status: RemoteCommands.Exit.mismatch, stdout: "splitterm-done\n"))
        XCTAssertFalse(RemoteCommands.finished(status: nil, stdout: "splitterm-done"))
    }

    func testDiscard() throws {
        XCTAssertEqual(try RemoteCommands.discard(mediaDir: "~/in", name: "a.jpg"),
                       "exec /bin/sh -c 'cd \"$HOME\"/'\\''in'\\'' || exit 3; [ -O . ] || exit 4; rm -f '\\''a.jpg.part'\\'''")
        XCTAssertThrowsError(try RemoteCommands.discard(mediaDir: "~/in", name: "*"))
    }

    func testParsePrepare() {
        XCTAssertEqual(RemoteCommands.parsePrepare("0\n/Users/me/.splitterm/inbox\n")?.offset, 0)
        XCTAssertEqual(RemoteCommands.parsePrepare("motd line\n1234\n/Users/me/in")?.offset, 1234)
        XCTAssertEqual(RemoteCommands.parsePrepare("1234\n/Users/me/in")?.directory, "/Users/me/in")
        XCTAssertNil(RemoteCommands.parsePrepare("oops"))
        XCTAssertNil(RemoteCommands.parsePrepare("-1\n/x"))
        // 入力行に入れるので、制御文字の入ったパスは読まない
        XCTAssertNil(RemoteCommands.parsePrepare("0\n/Users/me/\u{1b}[2Jin"))
    }

    func testAppNamesForCleaning() {
        XCTAssertTrue(InboxName.isAppName("20261030-060000-ab12.jpg"))
        XCTAssertTrue(InboxName.isAppName("20261030-060000-ab12.sheet.jpg"))
        XCTAssertTrue(InboxName.isAppName("20261030-060000-ab12.mov.part"))
        for other in ["notes.txt", "authorized_keys", "20261030-060000-ab12", "20261030-060000-AB12.jpg", "2026103-060000-ab12.jpg"] {
            XCTAssertFalse(InboxName.isAppName(other), other)
        }
    }

    func testInsertText() {
        XCTAssertEqual(MediaInsert.text(template: "{paths} ", paths: ["/Users/me/in/a.jpg", "/Users/me/in/a.video.md"]),
                       "/Users/me/in/a.jpg /Users/me/in/a.video.md ")
        XCTAssertEqual(MediaInsert.text(template: "見て: {paths}", paths: ["/Users/John Doe/in/a.jpg"]),
                       "見て: '/Users/John Doe/in/a.jpg'")
    }
}

final class ContactSheetTests: XCTestCase {
    func testProbeTimes() {
        XCTAssertEqual(ContactSheetPlanner.probeTimes(duration: 2), [0, 0.5, 1, 1.5])
        XCTAssertEqual(ContactSheetPlanner.probeTimes(duration: 600).count, 240)
        XCTAssertEqual(ContactSheetPlanner.probeTimes(duration: 0), [0])
    }

    func testFrameCount() {
        XCTAssertEqual(ContactSheetPlanner.frameCount(duration: 60, configured: 12, available: 120), 12)
        XCTAssertEqual(ContactSheetPlanner.frameCount(duration: 8, configured: 12, available: 16), 6)
        XCTAssertEqual(ContactSheetPlanner.frameCount(duration: 1, configured: 12, available: 2), 2)
    }

    func testSelectionPrefersSceneChangesAndCoversTime() {
        // 60 秒、0.5 秒ごと。20 秒と 41 秒で場面が変わる
        let times = ContactSheetPlanner.probeTimes(duration: 60)
        let scores = times.map { t -> Double in t == 20 ? 50 : t == 41 ? 40 : 1 }
        let picked = ContactSheetPlanner.select(times: times, scores: scores, count: 12)
        XCTAssertEqual(picked.count, 12)
        XCTAssertEqual(picked.first, 0)
        XCTAssertTrue(picked.contains(20))
        XCTAssertTrue(picked.contains(41))
        XCTAssertEqual(picked, picked.sorted())
        // 各区間（約 5 秒）から 1 枚ずつ
        for k in 0..<12 {
            let lo = 59.5 * Double(k) / 12, hi = 59.5 * Double(k + 1) / 12
            XCTAssertEqual(picked.filter { $0 >= lo && $0 < hi + 0.001 }.count >= 1, true, "区間 \(k)")
        }
        XCTAssertEqual(ContactSheetPlanner.select(times: [0, 1], scores: [0, 9], count: 12), [0, 1])
    }

    func testLayoutForLandscapeAndPortrait() {
        let land = ContactSheetPlanner.layout(count: 12, videoWidth: 1920, videoHeight: 1080, longSide: 1568)
        XCTAssertEqual(land.columns, 4)
        XCTAssertEqual(land.rows, 3)
        XCTAssertEqual(land.tileWidth, 392)
        XCTAssertEqual(land.tileHeight, 220)
        XCTAssertLessThanOrEqual(max(land.width, land.height), 1568)
        let tall = ContactSheetPlanner.layout(count: 12, videoWidth: 1080, videoHeight: 1920, longSide: 1568)
        XCTAssertEqual(tall.columns * tall.rows >= 12, true)
        XCTAssertGreaterThan(tall.columns, tall.rows)
        XCTAssertLessThanOrEqual(max(tall.width, tall.height), 1568)
        let one = ContactSheetPlanner.layout(count: 1, videoWidth: 1920, videoHeight: 1080, longSide: 1568)
        XCTAssertEqual(one.columns, 1)
        XCTAssertEqual(one.width, 1568)
    }

    func testTokenEstimateMatchesTheDesign() {
        // 設計書の表: 4×3 のシート 1 枚（1,568×660）約 1,400、12 枚を 1,568×882 で別々に 約 22,100
        let land = ContactSheetPlanner.layout(count: 12, videoWidth: 1920, videoHeight: 1080, longSide: 1568)
        XCTAssertEqual(land.height, 660)
        XCTAssertEqual(ContactSheetPlanner.estimatedTokens(width: land.width, height: land.height), 1380)
        XCTAssertEqual(ContactSheetPlanner.estimatedTokens(width: 1568, height: 882) * 12, 22_128)
    }

    func testTimestamp() {
        XCTAssertEqual(ContactSheetPlanner.timestamp(0), "0:00")
        XCTAssertEqual(ContactSheetPlanner.timestamp(75.9), "1:15")
        XCTAssertEqual(ContactSheetPlanner.timestamp(3723), "1:02:03")
    }

    func testNotes() {
        let layout = ContactSheetPlanner.Layout(columns: 2, rows: 1, tileWidth: 784, tileHeight: 441)
        let md = VideoNotes.render(originalName: "IMG_0001.MOV", duration: 12.3, width: 1920, height: 1080,
                                   sheetName: "x.sheet.jpg", layout: layout, times: [0, 6],
                                   transcript: [.init(start: 1, text: "こんにちは\n世界")])
        XCTAssertTrue(md.contains("- 長さ: 0:12（12.3 秒）"))
        XCTAssertTrue(md.contains("| 2（1 行 2 列） | 0:06 |"))
        XCTAssertTrue(md.contains("- [0:01] こんにちは 世界"))
        let none = VideoNotes.render(originalName: nil, duration: 5, width: 1, height: 1, sheetName: "s", layout: layout,
                                     times: [0], transcript: nil, transcriptNote: "（端末に日本語の音声認識が無いので飛ばしました）")
        XCTAssertTrue(none.contains("飛ばしました"))
    }
}
