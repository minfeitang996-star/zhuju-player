import SwiftUI

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        Label("播放设置", systemImage: "play.circle")
                    }
                    NavigationLink {
                        VideoSettingsView()
                    } label: {
                        Label("视频设置", systemImage: "rectangle.on.rectangle")
                    }
                    NavigationLink {
                        TranslateSettingsView()
                    } label: {
                        Label("翻译设置", systemImage: "character.bubble")
                    }
                    NavigationLink {
                        ThemeSettingsView()
                    } label: {
                        Label("主题外观", systemImage: "paintpalette")
                    }
                    NavigationLink {
                        GestureSettingsView()
                    } label: {
                        Label("手势与操作", systemImage: "hand.draw")
                    }
                    NavigationLink {
                        PrivacySettingsView()
                    } label: {
                        Label("隐私保护（文件夹加密）", systemImage: "lock.shield")
                    }
                } footer: {
                    Text("播放：自动隐藏菜单、时间显示、屏幕方向、快进快退秒数、断点续播、后台播放。视频：缩放模式、长宽比、解码方式、去隔行、字幕大小。翻译：离线识别模型、翻译通道、翻译接口。主题外观：5 套配色。手势与操作：亮度/音量手势、双击播放暂停、长按快进、自动播下一集、锁方向按钮。隐私：文件夹面容加密。")
                }

                Section {
                    Text("支持的容器：mp4 / mov / m4v / mkv / avi / flv / wmv / ts / webm / rmvb / mpg / vob 等，播放由 VLC 内核负责，系统解不了的格式也能放。")
                        .font(.system(size: 12))
                    Text("字幕生成：mp4/mov 可直接抽音轨，速度快；mkv/avi 需要先转码音轨，耗时约为视频时长，建议插电。")
                        .font(.system(size: 12))
                } header: {
                    Text("说明")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(theme.accent)
    }
}
