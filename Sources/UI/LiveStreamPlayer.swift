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

/// 网络直播播放页：VLC 内核直接拉流
struct LiveStreamPlayer: View {

    let channel: LiveChannel

    @Environment(\.dismiss) private var dismiss
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @StateObject private var controller = LivePlayerController()
    @State private var showControls = true
    @State private var retryToken = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoView(player: controller.player, mode: .fill, safeArea: false, aspect: nil)

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
        .onAppear { controller.open(channel.url) }
        .onDisappear {
            controller.stop()
            UIApplication.shared.isIdleTimerDisabled = false
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
            Text("检查地址是否有效，或换个网络再试。")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
            Button {
                controller.failed = false
                controller.loading = true
                retryToken += 1
                controller.open(channel.url)
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
                    if let group = channel.group {
                        Text(group)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                Spacer()
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
}
