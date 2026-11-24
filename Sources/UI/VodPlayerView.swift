import SwiftUI
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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VLCVideoView(player: controller.player, mode: .fill, safeArea: false, aspect: nil, tick: layoutTick)
                    .ignoresSafeArea()

                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
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
            }
            .onChange(of: geo.size) { _ in
                layoutTick += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { layoutTick += 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { layoutTick += 1 }
            }
        }
        .onAppear {
            OrientationHelper.apply(.landscapeRight)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { OrientationHelper.apply(.landscapeRight) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { OrientationHelper.apply(.landscapeRight) }
            store.recordHistory(name: target.title, pic: target.pic, url: target.url,
                                episodeName: target.episodeName, siteName: target.siteName)
            controller.open(target.url)
        }
        .onDisappear {
            controller.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            OrientationHelper.apply(.portrait)
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
    }

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
        VStack {
            HStack(spacing: 12) {
                Button {
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
            }
            .padding(.bottom, 18 + insets.bottom)
        }
    }
}
