import SwiftUI

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var models = ModelManager.shared

    @AppStorage("apiBase") private var apiBase: String = ""
    @AppStorage("apiKey") private var apiKey: String = ""
    @AppStorage("apiModel") private var apiModel: String = "deepseek-chat"
    @AppStorage("translateEnabled") private var translateEnabled: Bool = true
    @AppStorage("subScale") private var subScale: Double = 110
    @AppStorage("modelID") private var modelID: String = "ggml-base.bin"

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach(ModelManager.catalog) { model in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(model.title) · \(model.sizeText)")
                                    .font(.system(size: 14, weight: .medium))
                                Text(model.note)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if models.isDownloaded(model.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            } else if models.activeDownload == model.id {
                                ProgressView(value: models.progress[model.id] ?? 0)
                                    .frame(width: 50)
                            } else {
                                Button("下载") { download(model.id) }
                                    .buttonStyle(.bordered)
                                    .disabled(models.activeDownload != nil)
                            }
                        }
                    }
                } header: {
                    Text("离线识别模型")
                } footer: {
                    Text("下载后完全离线跑，不上传任何音频。当前默认用 \(modelID.replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: ""))。")
                }

                Section {
                    TextField("Base URL，例如 https://api.deepseek.com/v1", text: $apiBase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("模型名，例如 deepseek-chat", text: $apiModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                } header: {
                    Text("翻译接口（OpenAI 兼容）")
                } footer: {
                    Text("DeepSeek、月之暗面、通义、OpenAI 之类的 /chat/completions 接口都能填。留空就只出原文字幕。")
                }

                Section {
                    Toggle("启用翻译", isOn: $translateEnabled)
                } footer: {
                    Text("关掉就只生成原语言字幕，速度快一倍。")
                }

                Section {
                    HStack {
                        Text("字幕大小")
                        Spacer()
                        Text("\(Int(subScale))%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $subScale, in: 70...200, step: 5)
                } header: {
                    Text("字幕")
                } footer: {
                    Text("下一次打开视频生效。")
                }

                Section {
                    Text("支持的容器：mp4 / mov / m4v / mkv / avi / flv / wmv / ts / webm / rmvb / mpg / vob 等，播放由 VLC 内核负责，系统解码不了的格式也能放。")
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
    }

    private func download(_ id: String) {
        Task {
            _ = try? await ModelManager.shared.download(id)
        }
    }
}
