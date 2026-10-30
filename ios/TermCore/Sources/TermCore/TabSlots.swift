import Foundation

/// タブの番号（slot）。同じ接続先で開いているタブが使っていない、1 から数えて最小の番号を選ぶ。
/// 番号は tmux のセッション名になる（1 番は `main`、2 番からは `main-2`…。`HostEntry.tmuxSessionName(slot:)`）。
/// タブを閉じても tmux は残すので、次に開いたタブが同じ番号なら、そのセッションに戻る
/// （docs/design.md「接続の安定性」）
public enum TabSlots {
    /// `used` は、同じ接続先で今開いているタブの番号（順序・重なりは問わない）
    public static func next(used: [Int]) -> Int {
        let taken = Set(used)
        var n = 1
        while taken.contains(n) { n += 1 }
        return n
    }
}
