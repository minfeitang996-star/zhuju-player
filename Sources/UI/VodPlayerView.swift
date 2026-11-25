import SwiftUI
import Combine
import UIKit
import MobileVLCKit

/// 点播播放目标：详情选集后传入
struct VodPlayTarget: Identifiable {
    let id = UUID()
    let title: String
    let episodeName: String
    let url: String
    let siteName: String
    let pic: String?
}

/// 点播全屏播放器：复用直播的 VLC 控制器与渲染容器
struct VodPlayerView: View {

    let target: VodPlayTarget

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = VodStore.shared
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @StateObject private var controller = LivePlayerController()
    @State private var showControls = true
    @State private var layoutTick = 0

    /// 画面适配（适合 / 填充 / 拉伸），记住上次选择
    @State private var aspectMode: VideoMode =
        VideoMode(rawValue: UserDefaults.standard.string(forKey: "vodVideoMode") ?? "fill") ?? .fill
    /// 当前是否横屏；可手动切成竖屏
    @State private var landscape = true

    // 进度
    @State private var currentSeconds: Double = 0
    @State private var lengthSeconds: Double = 0
    @State private var dragging = false
    @State private var dragSeconds: Double = 0
    /// 待恢复的上次播放位置（0...1）
    @State private var pendingResume: Double?
    @State private var saveTicks = 0
    @State private var lastSavedSeconds: Double = -1

    // 画面横滑快进（与本地播放器同一套手感）
    @State private var dragAxis: String?
    @State private var scrubStart: Double = 0
    @State private var scrubTarget: Double = 0
    @State private var scrubWasPlaying = false
    @State private var isScrubbing = false
    @State private var lastScrubSeekAt: Double = 0
    @State private var lastScrubSeekTarget: Double = 0
    @State private var hudText: String?

    // 用 @State 持有，避免每次 body 重建都新起一个定时器
    @State private var ticker = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VLCVideoView(player: controller.player, mode: aspectMode, safeArea: false, aspect: nil, tick: layoutTick)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                handleDragChanged(value, in: geo.size)
                            }
                            .onEnded { value in
                                handleDragEnded(value, in: geo.size)
                            }
                    )

                if let hudText {
                    VStack {
                        Text(hudText)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .transition(.opacity)
                        Spacer()
                    }
                    .padding(.top, 18 + geo.safeAreaInsets.top)
                    .allowsHitTesting(false)
                }

                if controller.loading {
                    loadingOverlay
                }
                // 已经拿到时长说明片子能播，别因为拖动时暂停被 10 秒判失败误伤
                if controller.failed, lengthSeconds <= 1 {
                    failedOverlay
                }
                if showControls {
                    controlsOverlay(insets: geo.safeAreaInsets)
                }
            }
            .onChange(of: geo.size) { _ in
                layoutTick += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { layoutTick += 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { layoutTick += 1 }
            }
            .onReceive(ticker) { _ in tickUpdate() }
        }
        .onAppear {
            landscape = true
            OrientationHelper.apply(.landscapeRight)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { OrientationHelper.apply(.landscapeRight) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { OrientationHelper.apply(.landscapeRight) }
            // 先写历史（会沿用已存的进度），再记下要续播到的位置
            store.recordHistory(name: target.title, pic: target.pic, url: target.url,
                                episodeName: target.episodeName, siteName: target.siteName)
            pendingResume = store.resumeProgress(for: target.url)?.progress
            controller.open(target.url)
        }
        .onDisappear {
            saveProgressNow()
            controller.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            OrientationHelper.apply(.portrait)
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
    }

    // MARK: - 每 0.3 秒刷新进度

    private func tickUpdate() {
        let length = Double(controller.player.media?.length.intValue ?? 0) / 1000.0
        let validLength = length > 1 ? length : lengthSeconds

        // 时长拿到之后才做续播跳转，否则不知道往哪儿跳
        if let resume = pendingResume, validLength > 1 {
            pendingResume = nil
            let seconds = resume * validLength
            controller.player.position = Float(resume)
            currentSeconds = seconds
            lengthSeconds = validLength
        }

        if validLength > 1 { lengthSeconds = validLength }

        if !dragging, !isScrubbing {
            currentSeconds = Double(controller.player.position) * validLength
        }

        // 每约 1.8 秒回写一次进度，切后台 / 退出时也不丢
        guard !dragging, !isScrubbing, lengthSeconds > 1, controller.player.isPlaying else { return }
        saveTicks += 1
        if saveTicks % 6 == 0, abs(currentSeconds - lastSavedSeconds) > 1 {
            lastSavedSeconds = currentSeconds
            store.updateProgress(url: target.url,
                                 progress: currentSeconds / lengthSeconds,
                                 duration: lengthSeconds)
        }
    }

    private func saveProgressNow() {
        guard lengthSeconds > 1 else { return }
        store.updateProgress(url: target.url,
                             progress: currentSeconds / lengthSeconds,
                             duration: lengthSeconds)
    }

    /// 跳到指定秒数
    private func seek(to seconds: Double) {
        guard lengthSeconds > 1 else { return }
        let clamped = min(max(0.2, seconds), lengthSeconds - 0.4)
        controller.player.position = Float(clamped / lengthSeconds)
        currentSeconds = clamped
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - 画面横滑快进（与本地播放器同一套手感）

    private func handleDragChanged(_ value: DragGesture.Value, in size: CGSize) {
        guard Prefs.gestureEnabled, lengthSeconds > 1 else { return }
        if dragAxis == nil {
            let dx = abs(value.translation.width)
            let dy = abs(value.translation.height)
            guard max(dx, dy) > 10 else { return }
            dragAxis = dx > dy ? "h" : "v"
            if dragAxis == "h" { beginScrub() }
        }
        guard dragAxis == "h", isScrubbing else { return }
        updateScrub(value.translation.width, width: max(1, size.width))
    }

    private func handleDragEnded(_ value: DragGesture.Value, in size: CGSize) {
        let axis = dragAxis
        dragAxis = nil
        guard axis == "h", isScrubbing else { return }
        updateScrub(value.translation.width, width: max(1, size.width))
        finishScrub()
    }

    private func beginScrub() {
        scrubStart = currentSeconds
        scrubTarget = currentSeconds
        scrubWasPlaying = controller.player.isPlaying
        lastScrubSeekAt = 0
        lastScrubSeekTarget = currentSeconds
        isScrubbing = true
        // 拖动期间先暂停，省得边解码边跳帧
        controller.player.pause()
        hudText = scrubHUD()
    }

    private func updateScrub(_ dx: CGFloat, width: CGFloat) {
        guard isScrubbing, lengthSeconds > 1 else { return }
        // 横滑满一屏对应「设置 → 手势与操作 → 横滑一屏进度」
        let seconds = Double(dx / width) * Prefs.scrubSeconds
        let target = min(max(0.2, scrubStart + seconds), lengthSeconds - 0.4)
        scrubTarget = target

        let now = Date().timeIntervalSince1970
        if now - lastScrubSeekAt >= 0.22, abs(target - lastScrubSeekTarget) >= 3.0 {
            lastScrubSeekAt = now
            lastScrubSeekTarget = target
            controller.player.position = Float(target / lengthSeconds)
            currentSeconds = target
        }
        hudText = scrubHUD()
    }

    private func scrubHUD() -> String {
        let delta = scrubTarget - scrubStart
        let sign = delta >= 0 ? "快进" : "快退"
        let secs = Int(abs(delta).rounded())
        return "\(sign) \(secs) 秒 · \(format(scrubTarget)) / \(format(lengthSeconds))"
    }

    private func finishScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        let delta = scrubTarget - scrubStart
        if abs(scrubTarget - lastScrubSeekTarget) >= 0.5 {
            controller.player.position = Float(scrubTarget / lengthSeconds)
            lastScrubSeekTarget = scrubTarget
            currentSeconds = scrubTarget
        }
        if scrubWasPlaying {
            // 定位落地后再恢复播放，避免互相抢解码
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [controller] in
                controller.player.play()
            }
        }
        if abs(delta) < 1 {
            hudText = nil
        } else {
            let text = (delta > 0 ? "快进 " : "快退 ")
                + "\(Int(abs(delta).rounded())) 秒 · "
                + format(scrubTarget)
            showHUD(text)
        }
    }

    private func showHUD(_ text: String) {
        hudText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            if self.hudText == text {
                withAnimation(.easeOut(duration: 0.2)) { self.hudText = nil }
            }
        }
    }

    // MARK: - 覆盖层

    private var loadingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView().tint(theme.accent)
            Text("正在加载影片…")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private var failedOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.white.opacity(0.4))
            Text("连不上这个播放地址")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            Text("可能是线路失效或地址需要解析，换一集 / 换一条线路再试。")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
            Button {
                controller.failed = false
                controller.loading = true
                controller.open(target.url)
            } label: {
                Text("重试")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(theme.accent)
                    .foregroundColor(.black)
                    .clipShape(Capsule())
            }
        }
        .padding(24)
    }

    private func controlsOverlay(insets: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            topBar(insets: insets)

            Spacer()

            bottomBar(insets: insets)
        }
    }

    private func topBar(insets: EdgeInsets) -> some View {
        HStack(spacing: 12) {
            Button {
                saveProgressNow()
                controller.stop()
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
                Text(target.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(target.episodeName)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            Button {
                store.toggleFavorite(VodHistoryItem(
                    id: UUID(), name: target.title, pic: target.pic,
                    url: target.url, episodeName: target.episodeName,
                    siteName: target.siteName, playedAt: Date()))
            } label: {
                Image(systemName: store.isFavorited(target.url) ? "heart.fill" : "heart")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(store.isFavorited(target.url) ? theme.accent : .white)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            // 画面适配：适合 / 填充 / 拉伸
            Menu {
                ForEach(VideoMode.allCases) { mode in
                    Button {
                        aspectMode = mode
                        UserDefaults.standard.set(mode.rawValue, forKey: "vodVideoMode")
                        layoutTick += 1
                    } label: {
                        if mode == aspectMode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "aspectratio")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }

            // 横屏 / 竖屏切换
            Button {
                landscape.toggle()
                OrientationHelper.apply(landscape ? .landscapeRight : .portrait)
                layoutTick += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { layoutTick += 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { layoutTick += 1 }
            } label: {
                Image(systemName: landscape ? "rectangle.portrait.and.arrow.right" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12 + insets.top)
        .padding(.leading, 16 + insets.leading)
        .padding(.trailing, 16 + insets.trailing)
    }

    private func bottomBar(insets: EdgeInsets) -> some View {
        VStack(spacing: 12) {
            if lengthSeconds > 1 {
                HStack(spacing: 10) {
                    Text(format(dragging ? dragSeconds : currentSeconds))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 56, alignment: .leading)

                    Slider(value: Binding(
                        get: { dragging ? dragSeconds : min(currentSeconds, lengthSeconds) },
                        set: { newValue in
                            dragging = true
                            dragSeconds = newValue
                        }
                    ), in: 0...max(1, lengthSeconds), onEditingChanged: { editing in
                        if editing {
                            dragSeconds = currentSeconds
                        } else {
                            dragging = false
                            seek(to: dragSeconds)
                        }
                    })
                    .tint(theme.accent)

                    Text(format(lengthSeconds))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 56, alignment: .trailing)
                }
            }

            HStack(spacing: 26) {
                // 快退 10 秒
                Button {
                    seek(to: currentSeconds - 10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)

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

                // 快进 10 秒
                Button {
                    seek(to: currentSeconds + 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24 + insets.leading)
        .padding(.bottom, 18 + insets.bottom)
    }
}
