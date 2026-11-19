import SwiftUI
import UIKit
import MobileVLCKit

final class PlayerController: ObservableObject {

    let player = VLCMediaPlayer()

    @Published var playing = false
    @Published var position: Float = 0
    @Published var timeText = "00:00"
    @Published var lengthText = "00:00"
    @Published var subtitlesEnabled = true

    private var timer: Timer?
    private var videoURL: URL?
    private var subtitleURL: URL?
    fileprivate var timerLogged = false

    deinit {
        timer?.invalidate()
    }

    func open(video: URL, subtitle: URL?) {
        videoURL = video
        subtitleURL = subtitle
        subtitlesEnabled = subtitle != nil

        Boot.mark("D player.open \(video.lastPathComponent)")
        let media = makeMedia(url: video, subtitle: subtitle)
        Boot.mark("E media.made")
        player.media = media
        Boot.mark("F media.assigned")
        player.play()
        Boot.mark("G play.called")

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
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
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

        if subtitlesEnabled, let subtitle {
            media.addOption(":sub-file=\(subtitle.path)")
        } else {
            media.addOption(":no-sub-autodetect-file")
        }
        return media
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
    @State private var showJob = false
    @State private var showControls = true
    @State private var isFullscreen = false
    @State private var videoMode: VideoMode = VideoMode(rawValue: UserDefaults.standard.string(forKey: "videoMode") ?? "fit") ?? .fit
    @State private var videoSafeArea: Bool = UserDefaults.standard.object(forKey: "videoSafeArea") as? Bool ?? false

    init(item: MediaItem) {
        self.item = item
        Boot.mark("D0 player.screen.init")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoView(player: controller.player, mode: videoMode, safeArea: videoSafeArea)
                .ignoresSafeArea()

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
        .onTapGesture(count: 2) { toggleFullscreen() }
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }
        .onAppear {
            controller.open(video: item.url, subtitle: item.subtitleURL)
        }
        .onDisappear {
            controller.close()
            isFullscreen = false
            OrientationHelper.apply(.portrait)
        }
        .sheet(isPresented: $showJob, onDismiss: { library.reload() }) {
            JobView(videoURL: item.url)
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

            Spacer()

            Button {
                showJob = true
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
                Text(controller.timeText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))

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

            HStack(spacing: 26) {
                Button {
                    controller.seek(to: max(0, controller.position - 0.02))
                } label: {
                    Image(systemName: "gobackward.10")
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
                    controller.seek(to: min(1, controller.position + 0.02))
                } label: {
                    Image(systemName: "goforward.10")
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

                Button {
                    controller.toggleSubtitles()
                } label: {
                    Image(systemName: controller.subtitlesEnabled ? "captions.bubble.fill" : "captions.bubble")
                        .font(.system(size: 20))
                        .foregroundColor(controller.subtitlesEnabled ? Color(red: 1.0, green: 0.72, blue: 0.25) : .white.opacity(0.55))
                }
                .disabled(item.subtitleURL == nil)
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

    private func select(mode: VideoMode, safeArea: Bool) {
        videoMode = mode
        videoSafeArea = safeArea
        UserDefaults.standard.set(mode.rawValue, forKey: "videoMode")
        UserDefaults.standard.set(safeArea, forKey: "videoSafeArea")
        Boot.mark("J aspect \(mode.rawValue) safeArea=\(safeArea)")
    }

    private func toggleFullscreen() {
        isFullscreen.toggle()
        Boot.mark("I fullscreen=\(isFullscreen)")
        OrientationHelper.apply(isFullscreen ? .landscapeRight : .portrait)
    }
}
