import SwiftUI

/// 内嵌音轨 / 字幕轨选择面板（从播放页顶栏列表键进入）
struct TrackSettingsView: View {

    @ObservedObject var controller: PlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                if controller.audioTracks.isEmpty {
                    Text("只有一条音轨，没有可切换的声道").foregroundColor(.secondary)
                } else {
                    ForEach(controller.audioTracks) { track in
                        row(name: track.name,
                            selected: controller.currentAudioIndex == track.index) {
                            controller.selectAudioTrack(track)
                        }
                    }
                }
            } header: {
                Text("音轨")
            } footer: {
                Text("多音轨影片在这里切换对白声道；单音轨影片不会列出其他选项。")
            }

            Section {
                row(name: "关闭字幕", selected: controller.currentSubtitleIndex < 0) {
                    controller.selectSubtitleTrack(nil)
                }
                if controller.subtitleTracks.isEmpty {
                    Text("没有内嵌字幕轨（外挂 srt 在播放页顶栏字幕键开关）").foregroundColor(.secondary)
                } else {
                    ForEach(controller.subtitleTracks) { track in
                        row(name: track.name,
                            selected: controller.currentSubtitleIndex == track.index) {
                            controller.selectSubtitleTrack(track)
                        }
                    }
                }
            } header: {
                Text("内嵌字幕")
            } footer: {
                Text("影片自带的字幕轨；选「关闭字幕」即可隐藏。")
            }
        }
        .onAppear { controller.refreshTracks() }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                controller.refreshTracks()
            }
        }
        .navigationTitle("音轨与字幕")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 16)
                    .foregroundColor(.accentColor)
                    .opacity(selected ? 1 : 0)
                Text(name)
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
