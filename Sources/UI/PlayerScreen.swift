import SwiftUI
import UIKit
import AVFoundation
import MediaPlayer
import MobileVLCKit

/// 用 MPVolumeView 的系统音量滑杆改「手机音量」，保证手势和侧边按键、音量 HUD 三者同步
final class SystemVolumeBridge {
    static let shared = SystemVolumeBridge()
    weak var volumeView: MPVolumeView?

    var slider: UISlider? {
        volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }

    var currentVolume: Float {
        let v = AVAudioSession.sharedInstance().outputVolume
        return v > 0 ? v : (slider?.value ?? 0)
    }

    func set(_ value: Float, allowRetry: Bool = true) {
        let target = min(1.0, max(0, value))
        guard let slider else {
            if allowRetry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.set(target, allowRetry: false)
                }
            }
            return
        }
        slider.value = target
        slider.sendActions(for: .touchUpInside)
    }
}

struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.showsRouteButton = false
        view.alpha = 0.01
        SystemVolumeBridge.shared.volumeView = view
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        SystemVolumeBridge.shared.volumeView = uiView
    }
}

final class PlayerController: ObservableObject {

    let player = VLCMediaPlayer()

    @Published var playing = false
    @Published var position: Float = 0
    @Published var timeText = "00:00"
    @Published var lengthText = "00:00"
    @Published var subtitlesEnabled = true
    @Published var rate: Float = 1.0

    private var timer: Timer?
    private var videoURL: URL?
    private var subtitleURL: URL?
    fileprivate var timerLogged = false
    private var endReported = false

    /// 播到结尾时回调一次（自动播下一集用）
    var onEnd: (() -> Void)?
    /// 当前音量 0...2（1 = 原始音量）
    private(set) var volume: Float = 1.0

    init() {
        rate = Float(UserDefaults.standard.object(forKey: "playerRate") as? Double ?? 1.0)
    }

    deinit {
        timer?.invalidate()
    }

    func open(video: URL, subtitle: URL?) {
        videoURL = video
        subtitleURL = subtitle
        subtitlesEnabled = subtitle != nil
        endReported = false
        UserDefaults.standard.set(video.lastPathComponent, forKey: "lastMedia")

        Boot.mark("D player.open \(video.lastPathComponent)")
        let media = makeMedia(url: video, subtitle: subtitle)
        Boot.mark("E media.made")
        player.media = media
        Boot.mark("F media.assigned")
        player.play()
        Boot.mark("G play.called")
        player.rate = Prefs.keepRate ? rate : 1.0
        if !Prefs.keepRate { rate = 1.0 }
        applyVolumeToPlayer()
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback,
                                    options: [.allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true)
        } catch {
            NSLog("ZhuJu audio.session failed \(error)")
        }
        if Prefs.backgroundAudio {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        restoreResume(after: 1.2)

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.timerLogged {
                self.timerLogged = true
                Boot.mark("H tick playing=\(self.player.isPlaying)")
            }
            self.playing = self.player.isPlaying
            self.position = self.player.position
            self.timeText = Self.format(self.player.time.intValue)
            self.lengthText = Self.format(self.player.media?.length.intValue ?? 0)

            let length = self.player.media?.length.intValue ?? 0
            if length > 0, self.player.position >= 0.995 {
                if let url = self.videoURL {
                    UserDefaults.standard.removeObject(forKey: "resume:\(url.lastPathComponent)")
                    UserDefaults.standard.set(true, forKey: "done:\(url.lastPathComponent)")
                    if UserDefaults.standard.string(forKey: "lastMedia") == url.lastPathComponent {
                        UserDefaults.standard.removeObject(forKey: "lastMedia")
                    }
                }
                UIApplication.shared.isIdleTimerDisabled = false
                if !self.endReported {
                    self.endReported = true
                    DispatchQueue.main.async { self.onEnd?() }
                }
            }
        }
    }

    /// 音量 0...2（1 = 原始音量），走 VLC 播放器内部音量，不影响系统音量
    func setVolume(_ value: Float) {
        volume = min(2.0, max(0, value))
        applyVolumeToPlayer()
    }

    private func applyVolumeToPlayer() {
        let target = Int32(volume * 100)
        let sel = NSSelectorFromString("audio")
        guard player.responds(to: sel),
              let audio = player.perform(sel)?.takeUnretainedValue() as? NSObject,
              audio.responds(to: NSSelectorFromString("setVolume:")) else { return }
        audio.setValue(NSNumber(value: target), forKey: "volume")
    }

    func close() {
        timer?.invalidate()
        timer = nil
        saveResume()
        UIApplication.shared.isIdleTimerDisabled = false
        player.stop()
    }

    func togglePlay() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func seek(to value: Float) {
        player.position = value
    }

    /// 按秒快进/快退（负数=后退）
    func skip(_ seconds: Double) {
        let length = Double(player.media?.length.intValue ?? 0) / 1000.0
        guard length > 1 else { return }
        let current = Double(player.position) * length
        var target = current + seconds
        target = min(max(0.2, target), length - 0.4)
        player.position = Float(target / length)
        Boot.mark("K skip \(Int(seconds))s -> \(Int(target))s")
    }

    func toggleSubtitles() {
        guard let videoURL, subtitleURL != nil else { return }
        subtitlesEnabled.toggle()

        let saved = player.position
        player.stop()
        player.media = makeMedia(url: videoURL, subtitle: subtitleURL)
        player.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.player.position = saved
        }
    }

    private func makeMedia(url: URL, subtitle: URL?) -> VLCMedia {
        let media = VLCMedia(url: url)

        // 1.6.3 起字幕默认缩小到 85%，不再糊住画面
        let rawScale = UserDefaults.standard.object(forKey: "subScale") as? Double ?? 85
        let scale = Int(rawScale)
        media.addOption(":sub-text-scale=\(scale)")

        switch Prefs.hwDecode {
        case "hw":
            media.addOption(":avcodec-hw=any")
        case "sw":
            media.addOption(":avcodec-hw=none")
        default:
            break
        }
        if Prefs.deinterlace {
            media.addOption(":deinterlace=1")
        }

        if subtitlesEnabled, let subtitle {
            media.addOption(":sub-file=\(subtitle.path)")
        } else {
            media.addOption(":no-sub-autodetect-file")
        }
        return media
    }

    func setRate(_ value: Float) {
        rate = value
        player.rate = value
        UserDefaults.standard.set(Double(value), forKey: "playerRate")
        Boot.mark("M rate \(value)")
    }

    func saveResume() {
        guard Prefs.resumeEnabled else { return }
        guard let videoURL else { return }
        let pos = Double(player.position)
        UserDefaults.standard.set(pos, forKey: "resume:\(videoURL.lastPathComponent)")
        if pos < 0.95 {
            UserDefaults.standard.removeObject(forKey: "done:\(videoURL.lastPathComponent)")
        }
    }

    private func restoreResume(after delay: Double) {
        guard Prefs.resumeEnabled else { return }
        guard let videoURL else { return }
        let saved = UserDefaults.standard.double(forKey: "resume:\(videoURL.lastPathComponent)")
        guard saved > 0.01, saved < 0.99 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.player.position = Float(saved)
            Boot.mark("L resume \(Int(saved * 100))%")
        }
    }

    static func format(_ milliseconds: Int32) -> String {
        let total = Int(max(0, milliseconds)) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct PlayerScreen: View {

    @State private var current: MediaItem

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MediaLibrary
    @AppStorage("themeID") private var themeID: String = "gold"
    @AppStorage("liveStatusVisible") private var liveStatusVisible: Bool = true
    @AppStorage("liveTextVisible") private var liveTextVisible: Bool = true
    private var theme: AppTheme { AppTheme.current(themeID) }

    @StateObject private var controller = PlayerController()
    @State private var activeSheet: PlayerSheet?
    @State private var showControls = true
    @State private var isFullscreen = false
    @State private var hideTask: Task<Void, Never>?
    @State private var layoutTick = 0
    @StateObject private var liveSub = LiveSubtitleEngine()
    @State private var liveOn = false
    @State private var noModelAlert = false
    @State private var pendingTap: DispatchWorkItem?
    @State private var dragAxis: String?
    @State private var baseBrightness: CGFloat = 0
    @State private var baseVolume: Float = 1
    @State private var orientationLocked = false
    @State private var hudText: String?

    private enum PlayerSheet: String, Identifiable {
        case job
        case liveSettings
        var id: String { rawValue }
    }
    @State private var videoMode: VideoMode = VideoMode(rawValue: UserDefaults.standard.string(forKey: "videoMode") ?? "fill") ?? .fill
    @State private var videoSafeArea: Bool = UserDefaults.standard.object(forKey: "videoSafeArea") as? Bool ?? false

    init(item: MediaItem) {
        _current = State(initialValue: item)
        Boot.mark("D0 player.screen.init")
    }

    // MARK: - 手势

    private func toggleControlsNow() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func handleSingleTap() {
        pendingTap?.cancel()
        let work = DispatchWorkItem { [self] in self.toggleControlsNow() }
        pendingTap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func handleDoubleTap() {
        pendingTap?.cancel()
        guard Prefs.gestureEnabled, Prefs.gestureDoubleTap else {
            toggleControlsNow()
            return
        }
        controller.togglePlay()
        showHUD(controller.playing ? "播放" : "暂停")
        scheduleHide()
    }

    /// 长按画面：快进固定秒数（默认 10 秒，可在「手势与操作」里改 10/20/30）
    private func handleLongPress() {
        guard Prefs.gestureEnabled, Prefs.longPressSkip else { return }
        pendingTap?.cancel()
        let seconds = Prefs.longPressSeconds
        controller.skip(seconds)
        showHUD("长按快进 " + String(Int(seconds)) + " 秒")
        scheduleHide()
    }

    private func handleDragChanged(_ value: DragGesture.Value, in size: CGSize) {
        guard Prefs.gestureEnabled else { return }
        if dragAxis == nil {
            let dx = abs(value.translation.width)
            let dy = abs(value.translation.height)
            guard max(dx, dy) > 14 else { return }
            dragAxis = dx > dy ? "h" : "v"
            if dragAxis == "v" {
                baseBrightness = UIScreen.main.brightness
                baseVolume = SystemVolumeBridge.shared.currentVolume
            } else {
                return
            }
        }
        guard dragAxis == "v" else { return }
        let delta = -value.translation.height / max(1, size.height)
        if value.startLocation.x < size.width * 0.35 {
            let target = min(1.0, max(0.02, baseBrightness + delta * 1.4))
            UIScreen.main.brightness = target
            showHUD("亮度 \(Int(target * 100))%")
        } else {
            let target = min(1.0, max(0, baseVolume + Float(delta * 1.4)))
            SystemVolumeBridge.shared.set(target)
            showHUD("音量 \(Int(target * 100))%")
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, in size: CGSize) {
        let axis = dragAxis
        dragAxis = nil
        guard axis == "h" else { return }
        let dx = value.translation.width
        guard abs(dx) > 45 else { return }
        let seconds = min(120.0, max(10.0, Double(abs(dx)) / 6.0))
        controller.skip(dx > 0 ? seconds : -seconds)
        showHUD(dx > 0 ? "快进 \(Int(seconds)) 秒" : "快退 \(Int(seconds)) 秒")
    }

    private func showHUD(_ text: String) {
        hudText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            if self.hudText == text {
                withAnimation(.easeOut(duration: 0.2)) { self.hudText = nil }
            }
        }
    }

    private func toggleOrientationLock() {
        orientationLocked.toggle()
        if orientationLocked {
            OrientationHelper.apply(isFullscreen ? .landscapeRight : .portrait)
            showHUD(isFullscreen ? "已锁定横屏" : "已锁定竖屏")
        } else {
            OrientationHelper.apply(isFullscreen ? .landscapeRight : .all)
            showHUD("已解锁，可自动旋转")
        }
        scheduleHide()
    }

    private func playNextIfEnabled(_ lib: MediaLibrary) {
        guard Prefs.autoNext else { return }
        guard let next = lib.nextVideo(after: current) else {
            showHUD("已是最后一个视频")
            return
        }
        controller.close()
        current = next
        controller.onEnd = { [self] in self.playNextIfEnabled(lib) }
        UserDefaults.standard.removeObject(forKey: "resume:\(next.url.lastPathComponent)")
        controller.open(video: next.url, subtitle: next.subtitleURL)
        if liveOn { restartLive() }
        showHUD("自动播下一集：\(next.title)")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SystemVolumeView()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VLCVideoView(player: controller.player, mode: videoMode, safeArea: videoSafeArea, aspect: Prefs.aspectRatio, tick: layoutTick)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleSingleTap()
                    }
                    .highPriorityGesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { _ in
                                handleDoubleTap()
                            }
                    )
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.45, maximumDistance: 14)
                            .onEnded { _ in handleLongPress() }
                    )
                    .gesture(
                        DragGesture(minimumDistance: 24)
                            .onChanged { value in
                                handleDragChanged(value, in: geo.size)
                            }
                            .onEnded { value in
                                handleDragEnded(value, in: geo.size)
                            }
                    )
            }

            if let hudText {
                Text(hudText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if liveOn, liveTextVisible, let liveCue = activeLiveCue {
                VStack {
                    Spacer()
                    VStack(spacing: 3) {
                        if let translated = liveCue.translated, !translated.isEmpty {
                            layeredText(translated, size: Prefs.liveSubSize, weight: .bold, color: .white)
                        }
                        layeredText(liveCue.original, size: Prefs.liveSubSize * 0.62, weight: .semibold,
                                    color: Color(red: 1.0, green: 0.82, blue: 0.42))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.38))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 22)
                    // 贴到播放/暂停那一排的上面，靠画面最底部
                    .padding(.bottom, liveBottomPadding)
                }
                .allowsHitTesting(false)
            }

            if liveOn, liveStatusVisible {
                VStack {
                    Text("\(livePairText) · \(liveSub.status) · 已识别 \(liveSub.cues.count) 段")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(.top, 56)
                .allowsHitTesting(false)
            }

            if showControls {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                )
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .alert("还没下载识别模型", isPresented: $noModelAlert) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("去设置里下载一个识别模型（推荐 base），回来再点这个按钮就能边看边译。")
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            layoutTick += 1
        }
        .onAppear {
            let lib = library
            controller.onEnd = { [self] in self.playNextIfEnabled(lib) }
            controller.open(video: current.url, subtitle: current.subtitleURL)
            switch Prefs.orientation {
            case "landscape":
                isFullscreen = true
                OrientationHelper.apply(.landscapeRight)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    OrientationHelper.apply(.landscapeRight)
                }
            case "portrait":
                isFullscreen = false
                OrientationHelper.apply(.portrait)
            default:
                OrientationHelper.apply(.all)
            }
            scheduleHide()
        }
        .onDisappear {
            liveSub.stop()
            controller.onEnd = nil
            controller.close()
            isFullscreen = false
            OrientationHelper.apply(.portrait)
        }
        .sheet(item: $activeSheet, onDismiss: {
            library.reload()
            restartLive()
        }) { sheet in
            switch sheet {
            case .job:
                JobView(videoURL: current.url)
            case .liveSettings:
                LiveSettingsView()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                controller.close()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }

            Text(current.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            if Prefs.showClock {
                Text(Date(), style: .time)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
            }

            Spacer()

            Button {
                activeSheet = .job
            } label: {
                Label("生成字幕", systemImage: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.accent.opacity(0.9))
                    .foregroundColor(.black)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if Prefs.showElapsed {
                    Text(controller.timeText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }

                Slider(
                    value: Binding(
                        get: { Double(controller.position) },
                        set: { controller.seek(to: Float($0)) }
                    ),
                    in: 0...1
                )
                .tint(theme.accent)

                Text(controller.lengthText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
            }

            HStack(spacing: 20) {
                Button {
                    controller.skip(-Prefs.skipBack)
                } label: {
                    Image(systemName: "gobackward")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.9))
                }

                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: controller.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                }

                Button {
                    controller.skip(Prefs.skipForward)
                } label: {
                    Image(systemName: "goforward")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.9))
                }

                Button {
                    toggleFullscreen()
                } label: {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.9))
                }

                if Prefs.showOrientationLock {
                    Button {
                        toggleOrientationLock()
                    } label: {
                        Image(systemName: orientationLocked ? "lock.rotation" : "lock.rotation.open")
                            .font(.system(size: 20))
                            .foregroundColor(orientationLocked ? theme.accent : .white.opacity(0.9))
                    }
                }

                aspectMenu

                speedMenu

                Button {
                    controller.toggleSubtitles()
                } label: {
                    Image(systemName: controller.subtitlesEnabled ? "captions.bubble.fill" : "captions.bubble")
                        .font(.system(size: 20))
                        .foregroundColor(controller.subtitlesEnabled ? theme.accent : .white.opacity(0.55))
                }
                .disabled(current.subtitleURL == nil)

                Button {
                    toggleLive()
                } label: {
                    Image(systemName: liveOn ? "text.bubble.fill" : "text.bubble")
                        .font(.system(size: 19))
                        .foregroundColor(liveOn ? theme.accent : .white.opacity(0.9))
                }

                Button {
                    activeSheet = .liveSettings
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 19))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 16)
    }

    private var aspectMenu: some View {
        Menu {
            ForEach(VideoMode.allCases) { mode in
                Section(mode.title) {
                    Button {
                        select(mode: mode, safeArea: false)
                    } label: {
                        Text((videoMode == mode && !videoSafeArea ? "✓ " : "") + mode.title)
                    }
                    Button {
                        select(mode: mode, safeArea: true)
                    } label: {
                        Text((videoMode == mode && videoSafeArea ? "✓ " : "") + mode.title + "（Safe Area）")
                    }
                }
            }
        } label: {
            Image(systemName: "aspectratio")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.9))
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                Button {
                    controller.setRate(Float(value))
                } label: {
                    Text((abs(controller.rate - Float(value)) < 0.01 ? "✓ " : "") + String(format: "%g×", value))
                }
            }
        } label: {
            Image(systemName: "speedometer")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.9))
        }
    }

    private var currentSeconds: Double {
        let ms = controller.player.time.intValue
        if ms > 0 { return Double(ms) / 1000.0 }
        let length = Double(controller.player.media?.length.intValue ?? 0) / 1000
        if length > 0 { return Double(controller.player.position) * length }
        return 0
    }

    private var activeLiveCue: LiveCue? {
        guard !liveSub.cues.isEmpty else { return nil }
        let position = currentSeconds
        // 拿不到进度时也不藏字，直接显示最新识别结果
        if position <= 0 { return liveSub.cues.last }
        let candidates = liveSub.cues.filter { $0.start <= position + 4.0 }
        guard let last = candidates.last else { return nil }
        if position > last.end + 12 { return nil }
        return last
    }

    private func toggleLive() {
        if liveOn {
            liveSub.stop()
            liveOn = false
            return
        }
        let modelID = UserDefaults.standard.string(forKey: "modelID") ?? "ggml-base.bin"
        guard let modelURL = ModelManager.shared.localURL(modelID) else {
            noModelAlert = true
            return
        }
        liveOn = true
        liveSub.start(videoURL: current.url,
                      modelPath: modelURL.path,
                      from: currentSeconds,
                      language: Prefs.liveSource == "auto" ? nil : Prefs.liveSource) { [controller] in
            let ms = controller.player.time.intValue
            if ms > 0 { return Double(ms) / 1000.0 }
            let length = Double(controller.player.media?.length.intValue ?? 0) / 1000
            guard length > 0 else { return 0 }
            return Double(controller.player.position) * length
        }
    }

    /// 字幕贴底距离：控制栏出现时落在播放/暂停那一排上方，收起时贴画面底部
    private var liveBottomPadding: CGFloat {
        let base: CGFloat = showControls ? 64 : 20
        return Prefs.liveSubPosition == "mid" ? base + 46 : base
    }

    /// 立体字幕：黑色描边 + 下移投影 + 顶部微高光，三层叠出厚度感
    private func layeredText(_ text: String, size: CGFloat, weight: Font.Weight, color: Color) -> some View {
        ZStack {
            Text(text)
                .font(.system(size: size, weight: weight))
                .foregroundColor(.black.opacity(0.95))
                .blur(radius: 0.6)
                .offset(x: 0, y: 2.4)
            Text(text)
                .font(.system(size: size, weight: weight))
                .foregroundColor(.black.opacity(0.85))
                .offset(x: 0, y: 1.2)
            Text(text)
                .font(.system(size: size, weight: weight))
                .foregroundColor(color)
                .shadow(color: .white.opacity(0.22), radius: 0.8, x: 0, y: -1)
        }
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var livePairText: String {
        let source: String
        switch Prefs.liveSource {
        case "ja": source = "日语"
        case "en": source = "英语"
        case "zh": source = "中文"
        case "ko": source = "韩语"
        case "ru": source = "俄语"
        case "fr": source = "法语"
        case "de": source = "德语"
        case "es": source = "西语"
        default: source = "自动检测"
        }
        return "\(source) → \(Prefs.translateTarget)"
    }

    private func restartLive() {
        guard liveOn else { return }
        liveSub.stop()
        liveOn = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            toggleLive()
        }
    }

    private func select(mode: VideoMode, safeArea: Bool) {
        videoMode = mode
        videoSafeArea = safeArea
        UserDefaults.standard.set(mode.rawValue, forKey: "videoMode")
        UserDefaults.standard.set(safeArea, forKey: "videoSafeArea")
        Boot.mark("J aspect \(mode.rawValue) safeArea=\(safeArea)")
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard Prefs.autoHideMenu else { return }
        let delay = Prefs.autoHideDelay
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
        }
    }

    private func toggleFullscreen() {
        isFullscreen.toggle()
        Boot.mark("I fullscreen=\(isFullscreen)")
        OrientationHelper.apply(isFullscreen ? .landscapeRight : .portrait)
        withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
    }
}
