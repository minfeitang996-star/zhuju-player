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

/// 网络直播播放页：进页自动横屏全屏，支持同一频道多条线路切换
struct LiveStreamPlayer: View {

    let channel: LiveChannel

    @Environment(\.dismiss) private var dismiss
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @StateObject private var controller = LivePlayerController()
    @State private var showControls = true
    @State private var sourceIndex = 0
    @State private var liveMode: VideoMode = VideoMode(rawValue: UserDefaults.standard.string(forKey: "liveVideoMode") ?? "fill") ?? .fill
    @State private var liveSafeArea: Bool = UserDefaults.standard.object(forKey: "liveVideoSafeArea") as? Bool ?? false

    private var currentSource: LiveSource? {
        guard channel.sources.indices.contains(sourceIndex) else { return nil }
        return channel.sources[sourceIndex]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoView(player: controller.player, mode: liveMode, safeArea: liveSafeArea, aspect: nil)

            if controller.loading {
                loadingOverlay
            }

            if controller.failed {
                failedOverlay
            }

            if showControls {
                controlsOverlay
            }
        }
        .onAppear {
            OrientationHelper.apply(.landscapeRight)
            if let source = currentSource {
                controller.open(source.url)
            } else {
                controller.failed = true
                controller.loading = false
            }
        }
        .onDisappear {
            controller.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            OrientationHelper.apply(.portrait)
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
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

    private var controlsOverlay: some View {
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

                Menu {
                    ForEach(channel.sources.indices, id: \.self) { index in
                        Button {
                            selectSource(index)
                        } label: {
                            Label(channel.sources[index].label,
                                  systemImage: index == sourceIndex ? "checkmark" : "dot")
                        }
                    }
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
                    .clipShape(Capsule())
                }

                Menu {
                    aspectButton(.fit, safeArea: false, title: "适合")
                    aspectButton(.fill, safeArea: false, title: "填充")
                    aspectButton(.stretch, safeArea: false, title: "拉伸")
                    Divider()
                    aspectButton(.fit, safeArea: true, title: "适合 · 避开安全区")
                    aspectButton(.fill, safeArea: true, title: "填充 · 避开安全区")
                    aspectButton(.stretch, safeArea: true, title: "拉伸 · 避开安全区")
                } label: {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            HStack(spacing: 22) {
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
            }
            .padding(.bottom, 28)
        }
    }

    private var currentSourceLabel: String? {
        guard !channel.sources.isEmpty else { return nil }
        return "线路 \(sourceIndex + 1)/\(channel.sources.count)"
    }

    private func aspectButton(_ mode: VideoMode, safeArea: Bool, title: String) -> some View {
        Button {
            selectAspect(mode, safeArea)
        } label: {
            Label(title, systemImage: liveMode == mode && liveSafeArea == safeArea ? "checkmark" : "dot")
        }
    }

    private func selectAspect(_ mode: VideoMode, _ safe: Bool) {
        liveMode = mode
        liveSafeArea = safe
        UserDefaults.standard.set(mode.rawValue, forKey: "liveVideoMode")
        UserDefaults.standard.set(safe, forKey: "liveVideoSafeArea")
    }

    private func selectSource(_ index: Int) {
        guard channel.sources.indices.contains(index) else { return }
        sourceIndex = index
        controller.failed = false
        controller.loading = true
        controller.open(channel.sources[index].url)
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
