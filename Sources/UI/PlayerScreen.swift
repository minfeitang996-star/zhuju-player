import SwiftUI
import UIKit
import AVFoundation
import MobileVLCKit

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
            }
        }
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

        let rawScale = UserDefaults.standard.object(forKey: "subScale") as? Double ?? 110
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

    let item: MediaItem

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: MediaLibrary

    @StateObject private var controller = PlayerController()
    @State private var activeSheet: PlayerSheet?
    @State private var showControls = true
    @State private var isFullscreen = false
    @State private var hideTask: Task<Void, Never>?
    @State private var layoutTick = 0
    @StateObject private var liveSub = LiveSubtitleEngine()
    @State private var liveOn = false
    @State private var noModelAlert = false

    private enum PlayerSheet: String, Identifiable {
        case job
        case liveSettings
        var id: String { rawValue }
    }
    @State private var videoMode: VideoMode = VideoMode(rawValue: UserDefaults.standard.string(forKey: "videoMode") ?? "fill") ?? .fill
    @State private var videoSafeArea: Bool = UserDefaults.standard.object(forKey: "videoSafeArea") as? Bool ?? false

    init(item: MediaItem) {
        self.item = item
        Boot.mark("D0 player.screen.init")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoView(player: controller.player, mode: videoMode, safeArea: videoSafeArea, aspect: Prefs.aspectRatio, tick: layoutTick)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    if showControls { scheduleHide() }
                }
                .gesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            let dx = value.translation.width
                            guard abs(dx) > 45 else { return }
                            let seconds = min(120.0, max(10.0, Double(abs(dx)) / 6.0))
                            controller.skip(dx > 0 ? seconds : -seconds)
                        }
                )

            if liveOn, let liveCue = activeLiveCue {
                VStack {
                    Spacer()
                    VStack(spacing: 5) {
                        if let translated = liveCue.translated, !translated.isEmpty {
                            Text(translated)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                        }
                        Text(liveCue.original)
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.25))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.62))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.bottom, showControls ? 132 : 46)
                }
                .allowsHitTesting(false)
            }

            if liveOn {
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
            controller.open(video: item.url, subtitle: item.subtitleURL)
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
                JobView(videoURL: item.url)
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

            Text(item.title)
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
                    .background(Color(red: 1.0, green: 0.72, blue: 0.25).opacity(0.9))
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
                .tint(Color(red: 1.0, green: 0.72, blue: 0.25))

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

                aspectMenu

                speedMenu

                Button {
                    controller.toggleSubtitles()
                } label: {
                    Image(systemName: controller.subtitlesEnabled ? "captions.bubble.fill" : "captions.bubble")
                        .font(.system(size: 20))
                        .foregroundColor(controller.subtitlesEnabled ? Color(red: 1.0, green: 0.72, blue: 0.25) : .white.opacity(0.55))
                }
                .disabled(item.subtitleURL == nil)

                Button {
                    toggleLive()
                } label: {
                    Image(systemName: liveOn ? "text.bubble.fill" : "text.bubble")
                        .font(.system(size: 19))
                        .foregroundColor(liveOn ? Color(red: 1.0, green: 0.72, blue: 0.25) : .white.opacity(0.9))
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
        liveSub.start(videoURL: item.url,
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
