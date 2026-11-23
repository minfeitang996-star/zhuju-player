import SwiftUI
import UIKit
import MobileVLCKit

/// 画面适配方式
enum VideoMode: String, CaseIterable, Identifiable {
    case fit
    case fill
    case stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "适合"
        case .fill: return "填充"
        case .stretch: return "拉伸"
        }
    }
}

/// drawable 容器：VLC 把渲染层作为子视图后插进来，插入即填满
private final class DrawableInnerView: UIView {
    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        subview.frame = bounds
        subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
}

/// VLC 渲染容器：内层是 VLC 的 drawable，按适配模式做缩放。
final class VLCPlayerContainer: UIView {

    private let inner = DrawableInnerView()
    private var mode: VideoMode = .fill
    private var respectSafeArea = false
    private var videoSize: CGSize = .zero
    private var aspect: CGFloat?

    var drawableView: UIView { inner }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        inner.backgroundColor = .black
        inner.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(inner)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        clipsToBounds = true
        inner.backgroundColor = .black
        inner.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(inner)
    }

    func update(mode: VideoMode, safeArea: Bool, videoSize: CGSize, aspect: CGFloat?) {
        let newSize = (videoSize.width > 0 && videoSize.height > 0) ? videoSize : self.videoSize
        self.mode = mode
        self.respectSafeArea = safeArea
        self.aspect = aspect
        self.videoSize = newSize
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutInner()
    }

    func fitDrawableSubviews() {
        for sub in inner.subviews {
            sub.frame = inner.bounds
            sub.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
    }

    private func layoutInner() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let windowInsets = window?.safeAreaInsets ?? .zero
        let area = respectSafeArea ? bounds.inset(by: windowInsets) : bounds
        guard area.width > 0, area.height > 0 else { return }

        var vs = (videoSize.width > 0 && videoSize.height > 0) ? videoSize : area.size
        if let aspect, aspect > 0 { vs = CGSize(width: aspect, height: 1) }

        inner.transform = .identity
        inner.frame = area
        // VLCKit 把渲染层作为子视图插进 drawable，插入时按当时尺寸定的帧；
        // 旋转 / 横竖屏切换后要跟着重新撑满，否则画面停在旧比例、填不满屏幕
        fitDrawableSubviews()

        guard mode != .fit else { return }

        let s0 = min(area.width / vs.width, area.height / vs.height)
        let fitW = max(1, vs.width * s0)
        let fitH = max(1, vs.height * s0)

        switch mode {
        case .fit:
            break
        case .fill:
            let factor = max(area.width / fitW, area.height / fitH)
            inner.transform = CGAffineTransform(scaleX: factor, y: factor)
        case .stretch:
            inner.transform = CGAffineTransform(scaleX: area.width / fitW,
                                                y: area.height / fitH)
        }
    }
}

struct VLCVideoView: UIViewRepresentable {

    let player: VLCMediaPlayer
    var mode: VideoMode
    var safeArea: Bool
    var aspect: CGFloat?
    var tick: Int = 0

    func makeUIView(context: Context) -> VLCPlayerContainer {
        let view = VLCPlayerContainer()
        player.drawable = view.drawableView
        return view
    }

    func updateUIView(_ uiView: VLCPlayerContainer, context: Context) {
        _ = tick
        uiView.update(mode: mode, safeArea: safeArea, videoSize: player.videoSize, aspect: aspect)
        // 每拍强制立刻重排：旋转 / 首帧尺寸回来后马上按当前容器铺满，
        // 不用手动切一次模式才触发
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
        uiView.fitDrawableSubviews()
    }
}
