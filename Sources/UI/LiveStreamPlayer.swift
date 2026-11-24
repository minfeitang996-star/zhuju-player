import SwiftUI
import UIKit
import AVFoundation
import MobileVLCKit

/// 网络直播播放控制器：比本地播放器轻量，不记断点、不切下一集
final class LivePlayerController: ObservableObject {

    let player = VLCMediaPlayer()

    @Published var playing = false
    @Published var loading = true
    @Published var failed = false

    private var timer: Timer?
    private var failedWork: DispatchWorkItem?

    func open(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            failed = true
            loading = false
            return
        }
        activateAudio()

        let media = VLCMedia(url: url)
        media.addOption(":input-fast-seek")
        player.media = media
        player.play()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.playing = self.player.isPlaying
            if self.player.isPlaying {
                self.loading = false
                self.failed = false
            }
        }

        failedWork?.cancel()
        failedWork = DispatchWorkItem { [weak self] in
            guard let self, !self.player.isPlaying else { return }
            self.loading = false
            self.failed = true
        }
        if let failedWork {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: failedWork)
        }
    }

    func toggle() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        failedWork?.cancel()
        player.stop()
    }

    private func activateAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback,
                                    options: [.allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true)
        } catch {
            NSLog("Live audio session failed \(error)")
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }
}

/// 网络直播播放页：进页自动横屏全屏，支持同一频道多条线路切换与画面适配
struct LiveStreamPlayer: View {

    let channel: LiveChannel

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LiveSourceStore.shared
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @StateObject private var controller = LivePlayerController()
    @State private var showControls = true
    @State private var sourceIndex = 0
    @State private var liveMode: VideoMode = VideoMode(rawValue: UserDefaults.standard.string(forKey: "liveVideoMode") ?? "fill") ?? .fill
    @State private var liveSafeArea: Bool = UserDefaults.standard.object(forKey: "liveVideoSafeArea") as? Bool ?? false

    /// 顶栏下拉面板改成自绘：系统 Menu 在横屏全屏里弹出 / 收起会带一次整体重排，画面跟着闪
    private enum LivePanel {
        case aspect
        case source
    }
    @State private var openPanel: LivePanel?
    @State private var layoutTick = 0

    private var currentSource: LiveSource? {
        guard channel.sources.indices.contains(sourceIndex) else { return nil }
        return channel.sources[sourceIndex]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VLCVideoView(player: controller.player, mode: liveMode, safeArea: liveSafeArea, aspect: nil, tick: layoutTick)
                    .ignoresSafeArea()

                // 透明手势层：点画面切换控制条，点面板外关闭面板
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if openPanel != nil {
                            openPanel = nil
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                        }
                    }

                if controller.loading {
                    loadingOverlay
                }

                if controller.failed {
                    failedOverlay
                }

                if showControls {
                    controlsOverlay(insets: geo.safeAreaInsets)
                }

                if let panel = openPanel {
                    panelOverlay(panel, insets: geo.safeAreaInsets)
                }
            }
            .onChange(of: geo.size) { _ in
                // 转屏后容器尺寸变了，逼 VLC 渲染层按新尺寸重新铺满
                layoutTick += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { layoutTick += 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { layoutTick += 1 }
            }
        }
        .onAppear {
            OrientationHelper.apply(.landscapeRight)
            // requestGeometryUpdate 在 fullScreenCover 刚出现时经常被系统忽略，隔两拍再要两次
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { OrientationHelper.apply(.landscapeRight) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { OrientationHelper.apply(.landscapeRight) }
            if let source = currentSource {
                store.recordHistory(name: channel.name, url: source.url, label: source.label)
                controller.open(source.url)
            } else {
                controller.failed = true
                controller.loading = false
            }
        }
        .onDisappear {
            openPanel = nil
            controller.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            OrientationHelper.apply(.portrait)
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(theme.accent)
            Text("正在连接直播源…")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private var failedOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.white.opacity(0.4))
            Text("连不上这个直播源")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            Text("检查地址是否有效，或换个线路 / 网络再试。")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
            HStack(spacing: 12) {
                Button {
                    retryCurrent()
                } label: {
                    Text("重试")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(theme.accent)
                        .foregroundColor(.black)
                        .clipShape(Capsule())
                }
                if channel.sources.count > 1 {
                    Button {
                        switchToNextSource()
                    } label: {
                        Text("切换下一源")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.14))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(24)
    }

    private func controlsOverlay(insets: EdgeInsets) -> some View {
        VStack {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let category = currentSourceLabel {
                        Text(category)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }

                Spacer()

                Button {
                    openPanel = (openPanel == .source) ? nil : .source
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 14, weight: .semibold))
                        Text(currentSource?.label ?? "线路")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Color.black.opacity(0.45))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    openPanel = (openPanel == .aspect) ? nil : .aspect
                } label: {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(openPanel == .aspect ? theme.accent : .white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12 + insets.top)
            .padding(.leading, 16 + insets.leading)
            .padding(.trailing, 16 + insets.trailing)

            Spacer()

            HStack(spacing: 20) {
                Button {
                    controller.toggle()
                } label: {
                    Image(systemName: controller.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                // 系统偶尔会拒绝自动转屏（尤其开着竖屏方向锁时），给一个手动强制横屏的入口
                Button {
                    OrientationHelper.apply(.landscapeRight)
                    layoutTick += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { layoutTick += 1 }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 18 + insets.bottom)
        }
    }

    private func panelOverlay(_ panel: LivePanel, insets: EdgeInsets) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { openPanel = nil }

            VStack(alignment: .leading, spacing: 0) {
                if panel == .aspect {
                    panelRow("适合", active: liveMode == .fit && !liveSafeArea) {
                        selectAspect(.fit, false)
                    }
                    panelRow("填充", active: liveMode == .fill && !liveSafeArea) {
                        selectAspect(.fill, false)
                    }
                    panelRow("拉伸", active: liveMode == .stretch && !liveSafeArea) {
                        selectAspect(.stretch, false)
                    }
                    panelDivider
                    panelRow("适合 · 避开安全区", active: liveMode == .fit && liveSafeArea) {
                        selectAspect(.fit, true)
                    }
                    panelRow("填充 · 避开安全区", active: liveMode == .fill && liveSafeArea) {
                        selectAspect(.fill, true)
                    }
                    panelRow("拉伸 · 避开安全区", active: liveMode == .stretch && liveSafeArea) {
                        selectAspect(.stretch, true)
                    }
                } else {
                    if channel.sources.isEmpty {
                        Text("没有可用线路")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.55))
                            .padding(16)
                    } else {
                        ForEach(channel.sources.indices, id: \.self) { index in
                            panelRow(channel.sources[index].label, active: index == sourceIndex) {
                                selectSource(index)
                            }
                        }
                    }
                }
            }
            .frame(width: 250)
            .background(Color(white: 0.13).opacity(0.97))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.top, 58 + insets.top)
            .padding(.trailing, 16 + insets.trailing)
        }
    }

    private func panelRow(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    private var currentSourceLabel: String? {
        guard !channel.sources.isEmpty else { return nil }
        return "线路 \(sourceIndex + 1)/\(channel.sources.count)"
    }

    private func selectAspect(_ mode: VideoMode, _ safe: Bool) {
        liveMode = mode
        liveSafeArea = safe
        UserDefaults.standard.set(mode.rawValue, forKey: "liveVideoMode")
        UserDefaults.standard.set(safe, forKey: "liveVideoSafeArea")
        openPanel = nil
        layoutTick += 1
    }

    private func selectSource(_ index: Int) {
        guard channel.sources.indices.contains(index) else { return }
        openPanel = nil
        // 点当前正在播的这条不重启媒体，否则画面会黑一下
        if index == sourceIndex && (controller.playing || controller.loading) { return }
        sourceIndex = index
        let picked = channel.sources[index]
        store.recordHistory(name: channel.name, url: picked.url, label: picked.label)
        controller.failed = false
        controller.loading = true
        controller.open(picked.url)
        layoutTick += 1
    }

    private func retryCurrent() {
        guard let source = currentSource else { return }
        controller.failed = false
        controller.loading = true
        controller.open(source.url)
    }

    private func switchToNextSource() {
        let next = (sourceIndex + 1) % channel.sources.count
        selectSource(next)
    }
}
