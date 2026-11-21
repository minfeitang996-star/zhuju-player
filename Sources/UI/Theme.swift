import SwiftUI

/// App 主题：只换配色，不动功能
enum AppTheme: String, CaseIterable, Identifiable {
    case gold
    case ocean
    case forest
    case violet
    case rose

    var id: String { rawValue }

    var name: String {
        switch self {
        case .gold: return "暗夜金"
        case .ocean: return "深海蓝"
        case .forest: return "森野绿"
        case .violet: return "霓虹紫"
        case .rose: return "酒红"
        }
    }

    /// 强调色：播放按钮、进度条、已解锁标签、选中高亮
    var accent: Color {
        switch self {
        case .gold: return Color(red: 1.0, green: 0.72, blue: 0.25)
        case .ocean: return Color(red: 0.30, green: 0.74, blue: 1.0)
        case .forest: return Color(red: 0.36, green: 0.86, blue: 0.56)
        case .violet: return Color(red: 0.72, green: 0.56, blue: 1.0)
        case .rose: return Color(red: 1.0, green: 0.45, blue: 0.52)
        }
    }

    /// 列表页背景
    var background: Color {
        switch self {
        case .gold: return Color(red: 0.06, green: 0.06, blue: 0.07)
        case .ocean: return Color(red: 0.04, green: 0.08, blue: 0.13)
        case .forest: return Color(red: 0.04, green: 0.10, blue: 0.07)
        case .violet: return Color(red: 0.07, green: 0.05, blue: 0.12)
        case .rose: return Color(red: 0.10, green: 0.04, blue: 0.06)
        }
    }

    /// 行背景（强调色淡淡一层）
    var rowTint: Color { accent.opacity(0.16) }

    var summary: String {
        switch self {
        case .gold: return "经典暗夜金，原来的配色"
        case .ocean: return "蓝色强调，冷调深海背景"
        case .forest: return "绿色强调，低亮度护眼"
        case .violet: return "紫色强调，霓虹夜店感"
        case .rose: return "红色强调，偏暖的酒红背景"
        }
    }

    static func current(_ id: String) -> AppTheme {
        AppTheme(rawValue: id) ?? .gold
    }
}

struct ThemeSettingsView: View {
    @AppStorage("themeID") private var themeID: String = "gold"

    var body: some View {
        Form {
            Section {
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        themeID = theme.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(theme.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text(theme.summary)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if themeID == theme.rawValue {
                                Image(systemName: "checkmark")
                                    .foregroundColor(theme.accent)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("主题")
            } footer: {
                Text("点一下立即生效，不用重启。只换配色（播放按钮、进度条、列表背景），播放、字幕、翻译、加密、多选这些功能完全不变。")
            }

            Section {
                HStack(spacing: 10) {
                    Spacer()
                    ForEach(AppTheme.allCases) { theme in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.background)
                                .frame(width: 42, height: 30)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(theme.accent, lineWidth: themeID == theme.rawValue ? 2 : 1)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(theme.accent)
                                        .frame(width: 22, height: 3)
                                        .offset(y: 8)
                                )
                            Text(theme.name)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            } header: {
                Text("预览")
            }
        }
        .navigationTitle("主题外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}
