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

/// drawable 容器：VLC 把渲染对象作为子视图 / 子层后插进来，插入即填满
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

    /// 当前实际铺给画面的区域（含避开安全区的内缩），供外层取比例
    var currentArea: CGRect { resolvedArea() }

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

    /// 递归把 VLC 后插进来的渲染子视图 / 子层全部撑满当前区域
    func fitDrawableSubviews() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        func fitView(_ v: UIView) {
            v.frame = inner.bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.layer.contentsScale = scale
            for sub in v.subviews { fitView(sub) }
        }
        inner.subviews.forEach(fitView)
        inner.layer.sublayers?.forEach {
            $0.frame = inner.bounds
            $0.contentsScale = scale
        }
        // 个别版本把渲染层挂在容器层上而不是 inner 上，一并兜住
        layer.sublayers?.forEach {
            if $0 !== inner.layer {
                $0.frame = bounds
                $0.contentsScale = scale
            }
        }
    }

    /// 把可见尺寸重新报给 VLC 的 GL 渲染层。
    /// 只改渲染层 frame 不够：CAOpenGLLayer 只在自身 layoutSublayers 时按可见尺寸 × contentsScale
    /// 上报输出尺寸；首帧前那次布局会被丢弃，之后不会自动重报，画面就停在旧/零尺寸（半幅、两端黑边）。
    /// 这里逐层 setNeedsLayout + layoutIfNeeded，强制渲染层按当前可见尺寸重算输出表面。
    func reportSizeToVideoOutput() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        func walkLayer(_ layer: CALayer) {
            layer.contentsScale = scale
            layer.setNeedsLayout()
            layer.layoutIfNeeded()
            layer.sublayers?.forEach(walkLayer)
        }
        func walkView(_ v: UIView) {
            walkLayer(v.layer)
            v.subviews.forEach(walkView)
        }
        walkView(inner)
    }

    private func resolvedArea() -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let windowInsets = window?.safeAreaInsets ?? .zero
        let area = respectSafeArea ? bounds.inset(by: windowInsets) : bounds
        guard area.width > 0, area.height > 0 else { return bounds }
        return area
    }

    private func layoutInner() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let area = resolvedArea()

        var vs = (videoSize.width > 0 && videoSize.height > 0) ? videoSize : area.size
        if let aspect, aspect > 0 { vs = CGSize(width: aspect, height: 1) }

        inner.transform = .identity
        inner.frame = area
        // VLCKit 把渲染对象插到 drawable 里，插入时按当时尺寸定的帧；
        // 旋转 / 横竖屏切换 / 首帧回来后要跟着重新撑满，否则画面停在旧比例、填不满屏幕
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
            // 拉伸由引擎原生画面比例完成（见 applyNativeAspect），这里不再叠加视图变换，避免二次变形
            break
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
        relayout(uiView)
        // 首帧 / 渲染层可能晚于视图插入，延后几拍再强制重排，避免初次进播停在旧尺寸
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { relayout(uiView) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { relayout(uiView) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { relayout(uiView) }
    }

    /// 拉伸模式：把引擎输出画面比例设成当前屏幕区域比例，让 VLC 直接把画面拉满 drawable，
    /// 不依赖视频尺寸回传；适合 / 填充模式复位为 nil，恢复源片比例。
    private func applyNativeAspect(_ player: VLCMediaPlayer, area: CGRect) {
        if mode == .stretch, area.width > 1, area.height > 1 {
            let w = max(1, Int(area.width.rounded()))
            let h = max(1, Int(area.height.rounded()))
            "\(w):\(h)".withCString {
                player.videoAspectRatio = UnsafeMutablePointer(mutating: $0)
            }
        } else {
            player.videoAspectRatio = nil
        }
    }

    private func relayout(_ uiView: VLCPlayerContainer) {
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
        uiView.fitDrawableSubviews()
        uiView.reportSizeToVideoOutput()
        applyNativeAspect(player, area: uiView.currentArea)
    }
}
