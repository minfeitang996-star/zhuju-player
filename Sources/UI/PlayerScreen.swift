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

/// 一条可选的内嵌音轨 / 字幕轨
struct TrackInfo: Identifiable, Equatable {
    let id: Int
    let index: Int32
    let name: String
}

final class PlayerController: ObservableObject {

    let player = VLCMediaPlayer()

    @Published var playing = false
    @Published var position: Float = 0
    @Published var timeText = "00:00"
    @Published var lengthText = "00:00"
    @Published var subtitlesEnabled = false
    @Published var rate: Float = 1.0

    /// 内嵌音轨 / 字幕轨列表（播放起来后才会填出来）
    @Published var audioTracks: [TrackInfo] = []
    @Published var subtitleTracks: [TrackInfo] = []
    @Published var currentAudioIndex: Int32 = -1
    @Published var currentSubtitleIndex: Int32 = -1

    private var timer: Timer?
    private var videoURL: URL?
    private var subtitleURL: URL?
    fileprivate var timerLogged = false
    private var endReported = false

    /// 播到结尾时回调一次（自动播下一集用）
    var onEnd: (() -> Void)?
    /// 当前音量 0...2（1 = 原始音量）
    private(set) var volume: Float = 1.0

    /// 按住临时倍速：按住期间记住原倍速，松开恢复
    private var boosting = false
    private var baseRate: Float = 1.0

    init() {
        rate = Float(UserDefaults.standard.object(forKey: "playerRate") as? Double ?? 1.0)
    }

    deinit {
        timer?.invalidate()
    }

    func open(video: URL, subtitle: URL?) {
        videoURL = video
        subtitleURL = subtitle
        // 1.7.11 字幕默认关闭：有 srt 也不自动挂，必须手动点顶栏字幕键
        subtitlesEnabled = false
        endReported = false
        audioTracks = []
        subtitleTracks = []
        currentAudioIndex = -1
        currentSubtitleIndex = -1
        boosting = false
        UserDefaults.standard.set(video.lastPathComponent, forKey: "lastMedia")

        // 1.7.22：每部片单独记忆倍速 / 音量，没存过再回落到全局默认
        let name = video.lastPathComponent
        if let savedRate = UserDefaults.standard.object(forKey: "rate:\(name)") as? Double {
            rate = Float(savedRate)
        } else {
            rate = Float(UserDefaults.standard.object(forKey: "playerRate") as? Double ?? 1.0)
        }
        if let savedVol = UserDefaults.standard.object(forKey: "vol:\(name)") as? Double {
            volume = Float(savedVol)
        }
        NowPlayingBridge.shared.setTitle(video.deletingPathExtension().lastPathComponent)

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

        // 轨道列表要等媒体解析完才填得出来，延后两轮再读
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshTracks() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.refreshTracks() }

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
            NowPlayingBridge.shared.tick(playing: self.player.isPlaying,
                                        current: Double(self.player.time.intValue) / 1000.0,
                                        duration: self.lengthSeconds,
                                        rate: self.rate)

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
        if let name = videoURL?.lastPathComponent {
            UserDefaults.standard.set(Double(volume), forKey: "vol:\(name)")
        }
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

    // MARK: - 内嵌音轨 / 字幕轨

    /// 从 VLC 并行的索引 / 名称数组里组装轨道列表（-1 的禁用伪条目过滤掉）
    private static func makeTracks(indexes: [Any]?, names: [Any]?) -> [TrackInfo] {
        let idx = indexes as? [NSNumber] ?? []
        let nms = names as? [String] ?? []
        return zip(idx, nms).compactMap { number, name in
            let trackIndex = number.int32Value
            guard trackIndex >= 0 else { return nil }
            return TrackInfo(id: Int(trackIndex), index: trackIndex, name: name)
        }
    }

    func refreshTracks() {
        audioTracks = Self.makeTracks(indexes: player.audioTrackIndexes, names: player.audioTrackNames)
        subtitleTracks = Self.makeTracks(indexes: player.videoSubTitlesIndexes, names: player.videoSubTitlesNames)
        currentAudioIndex = player.currentAudioTrackIndex
        currentSubtitleIndex = player.currentVideoSubTitleIndex
    }

    func selectAudioTrack(_ track: TrackInfo) {
        player.currentAudioTrackIndex = track.index
        currentAudioIndex = track.index
    }

    /// 传 nil = 关闭内嵌字幕
    func selectSubtitleTrack(_ track: TrackInfo?) {
        player.currentVideoSubTitleIndex = track?.index ?? -1
        currentSubtitleIndex = track?.index ?? -1
    }

    // MARK: - 按住临时倍速

    func beginBoost() {
        guard Prefs.holdBoostEnabled, !boosting else { return }
        baseRate = rate
        boosting = true
        player.rate = Float(Prefs.holdBoostRate)
    }

    func endBoost() {
        guard boosting else { return }
        boosting = false
        player.rate = baseRate
    }

    func close() {
        timer?.invalidate()
        timer = nil
        endBoost()
        saveResume()
        UIApplication.shared.isIdleTimerDisabled = false
        player.stop()
        NowPlayingBridge.shared.clearInfo()
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

    /// 当前媒体总时长（秒），拿不到返回 0
    var lengthSeconds: Double {
        Double(player.media?.length.intValue ?? 0) / 1000.0
    }

    /// 绝对秒定位（1.7.20 横滑快进专用），返回实际落到的秒数
    @discardableResult
    func seekSeconds(_ seconds: Double) -> Double {
        let length = lengthSeconds
        guard length > 1 else { return 0 }
        let clamped = min(max(0.2, seconds), length - 0.4)
        player.position = Float(clamped / length)
        return clamped
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
        // 1.7.21：快进跳转走快速定位，不等关键帧精确定位，松手后不明显卡一下
        media.addOption(":input-fast-seek")

        // 1.6.3 起字幕默认缩小到 85%，不再糊住画面
        let rawScale = UserDefaults.standard.object(forKey: "subScale") as? Double ?? 85
        let scale = Int(rawScale)
        media.addOption(":sub-text-scale=\(scale)")
        if Prefs.subDelay != 0 {
            media.addOption(":sub-delay=\(Int(Prefs.subDelay * 1000))")
        }

        switch Prefs.hwDecode {
        case "sw":
            media.addOption(":avcodec-hw=none")
        default:
            // 自动 / 只走硬件：优先 VideoToolbox 硬解，硬解不可用时自动回落软解
            media.addOption(":avcodec-hw=any")
        }
        if Prefs.deinterlace {
            media.addOption(":deinterlace=1")
        }

        if subtitlesEnabled, let subtitle {
            media.addOption(":sub-file=\(subtitle.path)")
        } else {
            media.addOption(":no-sub-autodetect-file")
            media.addOption(":sub-track=-1")
        }
        return media
    }

    func setRate(_ value: Float) {
        rate = value
        player.rate = value
        UserDefaults.standard.set(Double(value), forKey: "playerRate")
        if let name = videoURL?.lastPathComponent {
            UserDefaults.standard.set(Double(value), forKey: "rate:\(name)")
        }
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
    @State private var hudText: String?
    @State private var orientationLocked = false
    @State private var dragStartPad: CGFloat?
    @State private var openPanel: PlayPanel?
    @State private var holdingBoost = false

    // 1.7.20 横滑快进：拖动期间实时跟手预览 + 节流定位，松手只做一次最终定位
    @State private var isScrubbing = false
    @State private var scrubStart: Double = 0
    @State private var scrubTarget: Double = 0
    @State private var scrubWasPlaying = false
    @State private var lastScrubSeekAt: Double = 0
    @State private var lastScrubSeekTarget: Double = 0
    // 1.7.21：快进/快退后按新位置重启识别，避免字幕长时间不出现
    @State private var liveRestartToken: Int = 0

    private enum PlayerSheet: String, Identifiable {
        case job
        case liveSettings
        case tracks
        var id: String { rawValue }
    }

    /// 顶栏下拉面板：画质 / 倍速（自绘，避免系统 Menu 反复重建导致闪动、点不中）
    private enum PlayPanel: String, Identifiable {
        case aspect
        case speed
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
        guard openPanel == nil else { return }
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

    /// 切到同一个文件夹里的上一个 / 下一个视频
    private func switchTo(_ next: MediaItem) {
        let lib = library
        controller.close()
        current = next
        controller.onEnd = { [self] in self.playNextIfEnabled(lib) }
        UserDefaults.standard.removeObject(forKey: "resume:\(next.url.lastPathComponent)")
        liveSub.stop()
        liveOn = false
        controller.open(video: next.url, subtitle: next.subtitleURL)
        scheduleHide()
    }

    private func playNeighbor(forward: Bool) {
        let target = forward ? library.nextVideo(after: current) : library.previousVideo(before: current)
        guard let target else {
            showHUD(forward ? "已经是最后一个视频" : "已经是第一个视频")
            return
        }
        switchTo(target)
        showHUD((forward ? "下一集：" : "上一集：") + target.title)
    }

    /// 长按画面：快进固定秒数（默认 10 秒，可在「手势与操作」里改 10/20/30）
    private func handleLongPress() {
        guard openPanel == nil else { return }
        guard Prefs.gestureEnabled, Prefs.longPressSkip else { return }
        pendingTap?.cancel()
        let seconds = Prefs.longPressSeconds
        controller.skip(seconds)
        scheduleLiveRestart()
        showHUD("长按快进 " + String(Int(seconds)) + " 秒")
        scheduleHide()
    }

    private func handleDragChanged(_ value: DragGesture.Value, in size: CGSize) {
        guard openPanel == nil else { return }
        guard Prefs.gestureEnabled else { return }
        if dragAxis == nil {
            let dx = abs(value.translation.width)
            let dy = abs(value.translation.height)
            guard max(dx, dy) > 10 else { return }
            dragAxis = dx > dy ? "h" : "v"
            if dragAxis == "v" {
                baseBrightness = UIScreen.main.brightness
                baseVolume = SystemVolumeBridge.shared.currentVolume
            } else {
                beginScrub()
            }
        }
        if dragAxis == "h" {
            updateScrub(value.translation.width, width: max(1, size.width))
            return
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

    // MARK: - 横滑快进（跟手）

    private func beginScrub() {
        scrubStart = currentSeconds
        scrubTarget = scrubStart
        scrubWasPlaying = controller.player.isPlaying
        lastScrubSeekAt = 0
        lastScrubSeekTarget = scrubStart
        isScrubbing = true
        // 拖动期间先暂停，避免 VLC 边解码边跳帧，定位更顺、不卡音
        controller.player.pause()
        hudText = scrubHUD()
    }

    private func updateScrub(_ dx: CGFloat, width: CGFloat) {
        guard isScrubbing else { return }
        let length = controller.lengthSeconds
        guard length > 1 else { hudText = scrubHUD(); return }
        // 横滑满一屏约 240 秒；轻滑更细腻，不会一滑就飞出去
        let seconds = Double(dx / width) * Prefs.scrubSeconds
        let target = min(max(0.2, scrubStart + seconds), length - 0.4)
        scrubTarget = target

        let now = Date().timeIntervalSince1970
        let first = lastScrubSeekAt == 0
        let interval: Double = first ? 0 : 0.15
        if now - lastScrubSeekAt >= interval, abs(target - lastScrubSeekTarget) >= 1.5 {
            lastScrubSeekAt = now
            lastScrubSeekTarget = target
            controller.seekSeconds(target)
        }
        hudText = scrubHUD()
    }

    private func scrubHUD() -> String {
        let delta = scrubTarget - scrubStart
        let sign = delta >= 0 ? "快进" : "快退"
        let secs = Int(abs(delta).rounded())
        let cur = PlayerController.format(Int32(scrubTarget * 1000))
        return "\(sign) \(secs) 秒 · \(cur) / \(controller.lengthText)"
    }

    private func finishScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        let delta = scrubTarget - scrubStart
        // 拖动中已经定位到附近就不再重复 seek，省掉松手时那一下重复解码的顿感
        if abs(scrubTarget - lastScrubSeekTarget) >= 0.5 {
            controller.seekSeconds(scrubTarget)
            lastScrubSeekTarget = scrubTarget
        }
        if scrubWasPlaying {
            // 等定位落地再恢复播放，避免边 seek 边起播互相抢解码
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [controller] in
                controller.player.play()
            }
        }
        if abs(delta) < 1 {
            hudText = nil
        } else {
            showHUD((delta > 0 ? "快进 " : "快退 ")
                    + "\(Int(abs(delta).rounded())) 秒 · "
                    + PlayerController.format(Int32(scrubTarget * 1000)))
        }
        if abs(delta) > 3 { scheduleLiveRestart() }
        scheduleHide()
    }

    private func handleDragEnded(_ value: DragGesture.Value, in size: CGSize) {
        let axis = dragAxis
        dragAxis = nil
        if axis == "h" {
            updateScrub(value.translation.width, width: max(1, size.width))
            finishScrub()
            return
        }
        guard axis == "v" else { return }
    }

    private func showHUD(_ text: String) {
        hudText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            if self.hudText == text {
                withAnimation(.easeOut(duration: 0.2)) { self.hudText = nil }
            }
        }
    }

    private func wireNowPlaying() {
        let np = NowPlayingBridge.shared
        np.onTogglePlayPause = { [weak controller] in controller?.togglePlay() }
        np.onNext = { [self] in playNeighbor(forward: true) }
        np.onPrevious = { [self] in playNeighbor(forward: false) }
        np.onSkipForward = { [self] in
            controller.skip(Prefs.skipForward)
            scheduleLiveRestart()
        }
        np.onSkipBackward = { [self] in
            controller.skip(-Prefs.skipBack)
            scheduleLiveRestart()
        }
        np.onSeekTo = { [self] seconds in
            controller.seekSeconds(seconds)
            scheduleLiveRestart()
        }
    }

    private func playNextIfEnabled(_ lib: MediaLibrary) {
        // 单集循环：播到结尾回到开头重播
        if Prefs.repeatOne {
            controller.seekSeconds(0)
            controller.player.play()
            scheduleLiveRestart()
            showHUD("循环重播")
            return
        }
        guard Prefs.autoNext else { return }
        guard let next = lib.nextVideo(after: current) else {
            showHUD("已是最后一个视频")
            return
        }
        controller.close()
        current = next
        controller.onEnd = { [self] in self.playNextIfEnabled(lib) }
        UserDefaults.standard.removeObject(forKey: "resume:\(next.url.lastPathComponent)")
        liveSub.stop()
        liveOn = false
        controller.open(video: next.url, subtitle: next.subtitleURL)
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
                        DragGesture(minimumDistance: 12)
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
                    .padding(.bottom, liveBottomPadding)
                    .contentShape(Rectangle())
                    .gesture(subtitleDrag, including: Prefs.liveSubPosition == "drag" ? .all : .none)
                }
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(Prefs.liveSubPosition == "drag")
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
            if openPanel != nil {
                panelOverlay
                    .transition(.opacity)
                    .zIndex(10)
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
            // 关掉翻译后引擎必须停，防止任何路径把它又带起来
            if !liveOn, liveSub.running {
                liveSub.stop()
            }
            if !liveOn, !liveSub.cues.isEmpty {
                liveSub.cues.removeAll()
            }
        }
        .onAppear {
            // 边看边译默认关闭，必须手动点气泡开启
            liveSub.stop()
            liveOn = false
            let lib = library
            controller.onEnd = { [self] in self.playNextIfEnabled(lib) }
            wireNowPlaying()
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
            case .tracks:
                TrackSettingsView(controller: controller)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                openPanel = nil
                activeSheet = nil
                controller.close()
                dismiss()
                // 兜底：万一第一层弹层没拆干净，延迟再退一次，避免卡在播放器里出不去
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .padding(13)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }

            Spacer()

            HStack(spacing: 16) {
                aspectButton

                speedButton

                Button {
                    controller.refreshTracks()
                    activeSheet = .tracks
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.85))
                }

                Button {
                    controller.toggleSubtitles()
                    if controller.subtitlesEnabled {
                        showHUD("字幕：已开启")
                    } else {
                        showHUD("字幕：已关闭")
                    }
                } label: {
                    Image(systemName: controller.subtitlesEnabled ? "captions.bubble.fill" : "captions.bubble")
                        .font(.system(size: 19))
                        .foregroundColor(controller.subtitlesEnabled ? theme.accent : .white.opacity(0.5))
                }
                .disabled(current.subtitleURL == nil)

                Button {
                    toggleLive()
                } label: {
                    Image(systemName: liveOn ? "text.bubble.fill" : "text.bubble")
                        .font(.system(size: 19))
                        .foregroundColor(liveOn ? theme.accent : .white.opacity(0.5))
                }

                Button {
                    activeSheet = .liveSettings
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 19))
                        .foregroundColor(.white.opacity(0.85))
                }
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
                        set: {
                            controller.seek(to: Float($0))
                            scheduleLiveRestart()
                        }
                    ),
                    in: 0...1
                )
                .tint(theme.accent)

                Text(controller.lengthText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
            }

            HStack(spacing: 22) {
                Button {
                    toggleOrientationLock()
                } label: {
                    Image(systemName: orientationLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }

                Button {
                    playNeighbor(forward: false)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }

                Button {
                    controller.skip(-Prefs.skipBack)
                    scheduleLiveRestart()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                }

                Button {
                    controller.togglePlay()
                } label: {
                    PlayPauseGlyph(playing: controller.playing)
                        .frame(width: 30, height: 26)
                }

                Button {
                    controller.skip(Prefs.skipForward)
                    scheduleLiveRestart()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                }

                // 按住临时加速：按下提倍速，松开恢复原倍速
                Image(systemName: "hare")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(holdingBoost ? theme.accent : .white.opacity(Prefs.holdBoostEnabled ? 0.9 : 0.35))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !holdingBoost {
                                    holdingBoost = true
                                    controller.beginBoost()
                                    showHUD("按住加速 " + String(format: "%g×", Prefs.holdBoostRate))
                                }
                            }
                            .onEnded { _ in
                                holdingBoost = false
                                controller.endBoost()
                            }
                    )

                Button {
                    playNeighbor(forward: true)
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }

                Button {
                    toggleFullscreen()
                } label: {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white)
                }
            }
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 16)
    }

    private var aspectButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                openPanel = (openPanel == .aspect) ? nil : .aspect
            }
            showControls = true
            hideTask?.cancel()
        } label: {
            Image(systemName: "aspectratio")
                .font(.system(size: 20))
                .foregroundColor(openPanel == .aspect ? theme.accent : .white.opacity(0.9))
        }
    }

    private var speedButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                openPanel = (openPanel == .speed) ? nil : .speed
            }
            showControls = true
            hideTask?.cancel()
        } label: {
            Image(systemName: "speedometer")
                .font(.system(size: 18))
                .foregroundColor(openPanel == .speed ? theme.accent : .white.opacity(0.9))
        }
    }

    /// 自绘下拉卡片：点哪行都直接响应，不会闪
    private var panelOverlay: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { closePanel() }

            VStack(alignment: .leading, spacing: 0) {
                if openPanel == .aspect {
                    panelRow("适合", active: videoMode == .fit && !videoSafeArea) {
                        select(mode: .fit, safeArea: false)
                    }
                    panelRow("填充", active: videoMode == .fill && !videoSafeArea) {
                        select(mode: .fill, safeArea: false)
                    }
                    panelRow("拉伸", active: videoMode == .stretch && !videoSafeArea) {
                        select(mode: .stretch, safeArea: false)
                    }
                    panelDivider
                    panelRow("适合 · 避开安全区", active: videoMode == .fit && videoSafeArea) {
                        select(mode: .fit, safeArea: true)
                    }
                    panelRow("填充 · 避开安全区", active: videoMode == .fill && videoSafeArea) {
                        select(mode: .fill, safeArea: true)
                    }
                    panelRow("拉伸 · 避开安全区", active: videoMode == .stretch && videoSafeArea) {
                        select(mode: .stretch, safeArea: true)
                    }
                } else {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                        panelRow(String(format: "%g×", value),
                                 active: abs(controller.rate - Float(value)) < 0.01) {
                            controller.setRate(Float(value))
                            closePanel()
                            showHUD("倍速 " + String(format: "%g×", value))
                        }
                    }
                }
            }
            .frame(width: 248)
            .background(Color(white: 0.13).opacity(0.97))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            .padding(.top, 60)
            .padding(.trailing, 16)
        }
    }

    private func panelRow(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 16)
                    .opacity(active ? 1 : 0)
                Text(title)
                    .font(.system(size: 15))
                Spacer(minLength: 0)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    /// 手动拖拉字幕：在画面上直接上下拖，实时写回位置
    private var subtitleDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if dragStartPad == nil { dragStartPad = Prefs.liveSubManualPad }
                Prefs.setLiveSubManualPad((dragStartPad ?? 60) - value.translation.height)
            }
            .onEnded { _ in dragStartPad = nil }
    }

    private func closePanel() {
        withAnimation(.easeOut(duration: 0.15)) { openPanel = nil }
        scheduleHide()
    }

    private var currentSeconds: Double {
        let ms = controller.player.time.intValue
        if ms > 0 { return Double(ms) / 1000.0 }
        let length = Double(controller.player.media?.length.intValue ?? 0) / 1000
        if length > 0 { return Double(controller.player.position) * length }
        return 0
    }

    /// 当前该显示哪一段：优先「最新且有译文」；
    /// 新一段译文还没回来时保持上一条中文（1.7.20 修复译文一闪就没）
    private var activeLiveCue: LiveCue? {
        let list = liveSub.cues
        guard !list.isEmpty else { return nil }
        let position = currentSeconds
        // 拿不到进度时也不藏字，直接显示最新识别结果
        if position <= 0 { return list.last }

        let candidates = list.filter { $0.start <= position + 4.0 }
        guard let latest = candidates.last ?? list.first else { return nil }

        func fresh(_ cue: LiveCue) -> Bool { position <= cue.end + 18 }

        // 最新一段已经有译文，直接用
        if latest.translated?.isEmpty == false, fresh(latest) { return latest }
        // 否则退到最近一条有译文的，别让中文忽然消失
        if let translatedCue = candidates.last(where: { $0.translated?.isEmpty == false }),
           fresh(translatedCue) {
            return translatedCue
        }
        // 连译文都没有（还在翻或翻译失败），至少把原文留住
        if fresh(latest) { return latest }
        // 快进后新一段还没出来时，宁可保留上一句也不要整条消失（最多 90 秒）
        if let lastCue = list.last, position <= lastCue.end + 90 {
            return lastCue
        }
        return nil
    }

    private func toggleLive() {
        if liveOn {
            liveSub.stop()
            liveSub.cues.removeAll()
            liveOn = false
            showHUD("边看边译：已关闭")
            return
        }
        let modelID = UserDefaults.standard.string(forKey: "modelID") ?? "ggml-base.bin"
        guard let modelURL = ModelManager.shared.localURL(modelID) else {
            noModelAlert = true
            return
        }
        liveOn = true
        showHUD("边看边译：已开启")
        startLiveEngine(from: currentSeconds, modelPath: modelURL.path)
    }

    private func startLiveEngine(from seconds: Double, modelPath: String) {
        liveSub.start(videoURL: current.url,
                      modelPath: modelPath,
                      from: seconds,
                      language: Prefs.liveSource == "auto" ? nil : Prefs.liveSource) { [controller] in
            let ms = controller.player.time.intValue
            if ms > 0 { return Double(ms) / 1000.0 }
            let length = Double(controller.player.media?.length.intValue ?? 0) / 1000
            guard length > 0 else { return 0 }
            return Double(controller.player.position) * length
        }
    }

    /// 快进/快退后：识别流水线还停在旧位置，直接按新位置重开一路，
    /// 否则新段要等几十秒才会出来，字幕看着就像「消失了」
    private func scheduleLiveRestart() {
        guard liveOn else { return }
        liveRestartToken += 1
        let token = liveRestartToken
        let modelID = UserDefaults.standard.string(forKey: "modelID") ?? "ggml-base.bin"
        guard let modelURL = ModelManager.shared.localURL(modelID) else { return }
        liveSub.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            guard liveOn, token == liveRestartToken else { return }
            startLiveEngine(from: currentSeconds, modelPath: modelURL.path)
        }
    }

    /// 字幕贴底距离：控制栏出现时落在播放/暂停那一排上方，收起时贴画面底部
    /// 字幕贴底距离：控制栏上方 / 控制栏下方（贴画面最底边）/ 再高一点
    private var liveBottomPadding: CGFloat {
        switch Prefs.liveSubPosition {
        case "drag":
            return Prefs.liveSubManualPad
        case "below":
            // 控制栏那一排的下方，直接贴画面最底边
            return showControls ? 8 : 5
        case "mid":
            return (showControls ? 64 : 20) + 60
        default:
            // 贴底（控制栏上方）；控制栏收起时同样贴到最底边
            return showControls ? 64 : 8
        }
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
        closePanel()
        showHUD(mode.title + (safeArea ? " · 避开安全区" : ""))
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard openPanel == nil else { return }
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

/// 纯三角形播放键（播放中切换成两条竖杠的暂停）
struct PlayPauseGlyph: View {
    let playing: Bool

    var body: some View {
        ZStack {
            if playing {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .frame(width: 4, height: 20)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .frame(width: 4, height: 20)
                }
            } else {
                PlayTriangle()
                    .fill(Color.white)
                    .frame(width: 16, height: 19)
            }
        }
        .foregroundColor(.white)
    }
}

struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
