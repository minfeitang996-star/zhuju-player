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
        // 横竖屏旋转后容器 bounds 变了，渲染层输出表面也要按新可见尺寸重算，
        // 否则画面停在旧方向几何、填不满屏幕，要手动再转一下才铺满
        reportSizeToVideoOutput()
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

    /// 视图销毁前清掉 VLC 后插进来的渲染子视图 / 子层和最后一帧，避免退出后残影叠在上一层页面
    func teardown() {
        inner.subviews.forEach { $0.removeFromSuperview() }
        inner.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        inner.layer.contents = nil
        layer.sublayers?.forEach {
            if $0 !== inner.layer { $0.removeFromSuperlayer() }
        }
        layer.contents = nil
    }

    /// 容器 bounds 在首拍 / 旋转过渡期间可能是零或竖屏旧值，拿窗口、再拿屏幕尺寸兜底
    private func fallbackSize() -> CGSize {
        if let w = window, w.bounds.width > 1, w.bounds.height > 1 { return w.bounds.size }
        let sb = UIScreen.main.bounds
        if sb.width > 1, sb.height > 1 { return sb.size }
        return bounds.size
    }

    private func resolvedArea() -> CGRect {
        let base: CGRect
        if bounds.width > 1, bounds.height > 1 {
            base = bounds
        } else {
            base = CGRect(origin: .zero, size: fallbackSize())
        }
        let windowInsets = window?.safeAreaInsets ?? .zero
        let area = respectSafeArea ? base.inset(by: windowInsets) : base
        guard area.width > 1, area.height > 1 else { return base }
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

    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        var parent: VLCVideoView
        weak var view: VLCPlayerContainer?
        // 记住上次真正应用过的参数：SwiftUI 每次重建 body 都会调 updateUIView，
        // 没变就不重排，避免点个按钮画面跟着闪一下
        var lastMode: VideoMode?
        var lastSafeArea: Bool?
        var lastAspect: CGFloat?
        var lastTick: Int?

        init(parent: VLCVideoView) {
            self.parent = parent
        }

        func mediaPlayerStateChanged(_ aNotification: Notification!) {
            relay()
        }

        // 播放中 VLC 每秒回调多次时间变化；每次回调都强制重排渲染层会让画面一直抖 / 闪，
        // 这里不再跟着时间回调重排，尺寸变化由 layoutSubviews 和布局 tick 负责
        func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        }

        private func relay() {
            guard let view else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let view = self.view else { return }
                // 首帧 / 视频尺寸回传后，先把最新 videoSize、比例喂进容器，再强制重排，
                // 避免画面停在零尺寸或旧比例上变成居中窄条。
                self.parent.apply(to: view)
                self.parent.relayout(view)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> VLCPlayerContainer {
        let view = VLCPlayerContainer()
        player.drawable = view.drawableView
        context.coordinator.view = view
        context.coordinator.parent = self
        player.delegate = context.coordinator
        view.layoutIfNeeded()
        relayout(view)
        return view
    }

    func updateUIView(_ uiView: VLCPlayerContainer, context: Context) {
        context.coordinator.parent = self
        context.coordinator.view = uiView

        let c = context.coordinator
        let changed = c.lastMode != mode
            || c.lastSafeArea != safeArea
            || c.lastAspect != aspect
            || c.lastTick != tick
        c.lastMode = mode
        c.lastSafeArea = safeArea
        c.lastAspect = aspect
        c.lastTick = tick
        guard changed else { return }

        apply(to: uiView)
        relayout(uiView)
        // 首帧 / 渲染层可能晚于视图插入，延后几拍再强制重排，避免初次进播停在旧尺寸
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.apply(to: uiView); self.relayout(uiView) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.apply(to: uiView); self.relayout(uiView) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.apply(to: uiView); self.relayout(uiView) }
    }

    /// 把当前模式 / 安全区 / 最新视频尺寸 / 比例同步进容器，供状态回调与刷新时复用
    private func apply(to uiView: VLCPlayerContainer) {
        uiView.update(mode: mode, safeArea: safeArea, videoSize: player.videoSize, aspect: aspect)
    }

    static func dismantleUIView(_ uiView: VLCPlayerContainer, coordinator: Coordinator) {
        coordinator.view = nil
        uiView.teardown()
    }

    /// 拉伸模式：把引擎输出画面比例设成当前屏幕区域比例，让 VLC 直接把画面拉满 drawable，
    /// 不依赖视频尺寸回传；适合 / 填充模式复位为 nil，恢复源片比例。
    private func applyNativeAspect(_ player: VLCMediaPlayer, area: CGRect) {
        // 媒体还没挂上时不要动 videoAspectRatio，VLCKit 在没有媒体时改这个容易出问题
        guard player.media != nil else { return }
        if mode == .stretch, area.width > 1, area.height > 1 {
            var w = area.width
            var h = area.height
            // 横屏锁定下首拍区域可能还是竖屏旧比例，归一到宽≥高，避免把画面拉成竖比例
            let lockedLandscape = Prefs.orientation == "landscape"
            if lockedLandscape, w < h { swap(&w, &h) }
            let wi = max(1, Int(w.rounded()))
            let hi = max(1, Int(h.rounded()))
            "\(wi):\(hi)".withCString {
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
        // 回到「适配 drawable」的缩放基准，避免停在某次手动缩放留下的绝对倍率上
        player.scaleFactor = 0
        applyNativeAspect(player, area: uiView.currentArea)
    }
}
