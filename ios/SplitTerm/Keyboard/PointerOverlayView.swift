import UIKit

/// ポインタ（矢印）を描く、画面全体の透明な層（docs/design.md「ポインタ」）。タッチは受けない。
/// 位置は RootViewController の view の座標。動いたときだけ CALayer 1 枚を動かす（待機中は何も描かない）
final class PointerOverlayView: UIView {
    /// 矢印の大きさ（Mac の矢印の約 0.75 倍）
    static let scale: CGFloat = 0.75

    private let arrow = CAShapeLayer()
    /// ポインタの先の位置。まだ動かしていなければ nil（隠していても覚えている）
    private(set) var location: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        // Mac の矢印の形（先が原点）
        let k = Self.scale
        let path = UIBezierPath()
        path.move(to: .zero)
        for (x, y) in [(0.0, 17.0), (4.2, 13.2), (7.2, 19.8), (9.6, 18.8), (6.7, 12.3), (12.2, 12.3)] {
            path.addLine(to: CGPoint(x: CGFloat(x) * k, y: CGFloat(y) * k))
        }
        path.close()
        arrow.path = path.cgPath
        arrow.fillColor = UIColor.white.cgColor
        arrow.strokeColor = UIColor.black.cgColor
        arrow.lineWidth = 1
        arrow.lineJoin = .round
        arrow.isHidden = true
        layer.addSublayer(arrow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 矢印の先を p に置いて出す
    func show(at p: CGPoint) {
        location = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.position = p
        arrow.isHidden = false
        CATransaction.commit()
    }

    /// 隠して、覚えた位置も捨てる（向きを替えたとき。次に動かすとシェルの中央から）
    func forget() {
        location = nil
        hide()
    }

    /// 文字を打ったら隠す（Mac と同じ。位置は覚えておく）
    func hide() {
        guard !arrow.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrow.isHidden = true
        CATransaction.commit()
    }
}
