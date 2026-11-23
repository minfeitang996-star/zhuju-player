import SwiftUI

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return short + "（\(build)）"
    }

    private struct Entry {
        let title: String
        let caption: String
        let icon: String
        let destination: any View
    }

    private var entries: [Entry] {
        [
            Entry(title: "播放设置", caption: "自动隐藏、屏幕方向、断点续播、后台播放", icon: "play.circle", destination: PlaybackSettingsView()),
            Entry(title: "视频设置", caption: "缩放模式、长宽比、解码方式、字幕大小", icon: "rectangle.on.rectangle", destination: VideoSettingsView()),
            Entry(title: "翻译设置", caption: "离线识别模型、翻译通道与接口", icon: "character.bubble", destination: TranslateSettingsView()),
            Entry(title: "主题外观", caption: "5 套配色，点一下立即生效", icon: "paintpalette", destination: ThemeSettingsView()),
            Entry(title: "手势与操作", caption: "亮度音量、双击暂停、长按快进、自动连播", icon: "hand.draw", destination: GestureSettingsView()),
            Entry(title: "隐私保护", caption: "文件夹面容加密", icon: "lock.shield", destination: PrivacySettingsView()),
        ]
    }

    var body: some View {
        NavigationView {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    entriesCard

                    summaryCard

                    aboutCard

                    notesSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [theme.background, theme.background.opacity(0.92)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(theme.accent)
    }

    private var entriesCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                NavigationLink {
                    AnyView(entry.destination)
                } label: {
                    rowLabel(entry)
                }
                .buttonStyle(RowPressStyle(accent: theme.accent))

                if index < entries.count - 1 {
                    Divider()
                        .background(Color.white.opacity(0.08))
                        .padding(.leading, 78)
                }
            }
        }
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 5)
    }

    private func rowLabel(_ entry: Entry) -> some View {
        HStack(spacing: 15) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.accent.opacity(0.16))
                .frame(width: 48, height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(theme.accent.opacity(0.28), lineWidth: 1)
                )
                .overlay(
                    Image(systemName: entry.icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(theme.accent)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text(entry.caption)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private var summaryCard: some View {
        Text("播放：自动隐藏菜单、时间显示、屏幕方向、快进快退秒数、断点续播、后台播放。视频：缩放模式、长宽比、解码方式、去隔行、字幕大小。翻译：离线识别模型、翻译通道、翻译接口。主题外观：5 套配色。手势与操作：亮度/音量手势、双击播放暂停、长按快进、自动播下一集、锁方向按钮。隐私：文件夹面容加密。")
            .font(.system(size: 12.5))
            .lineSpacing(6)
            .foregroundColor(.white.opacity(0.55))
            .padding(16)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关于")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .padding(.leading, 4)

            HStack(spacing: 15) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.accent.opacity(0.16))
                    .frame(width: 48, height: 48)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(theme.accent.opacity(0.28), lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "info.circle")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundColor(theme.accent)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("糖敏飞视频播放器")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Text("版本 \(appVersion)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("说明")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .padding(.leading, 4)

            VStack(spacing: 14) {
                noteRow("支持的容器：mp4 / mov / m4v / mkv / avi / flv / wmv / ts / webm / rmvb / mpg / vob 等，播放由 VLC 内核负责，系统解不了的格式也能放。")
                Divider().background(Color.white.opacity(0.08))
                noteRow("字幕生成：mp4/mov 可直接抽音轨，速度快；mkv/avi 需要先转码音轨，耗时约为视频时长，建议插电。")
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .lineSpacing(5)
            .foregroundColor(.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 入口点按：轻微缩放 + 高亮反馈，带过渡动画
private struct RowPressStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .background(configuration.isPressed ? accent.opacity(0.12) : Color.clear)
            .animation(.easeInOut(duration: 0.16), value: configuration.isPressed)
    }
}
