import SwiftUI

struct JobView: View {

    let videoURL: URL

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var models = ModelManager.shared
    @StateObject private var job = SubtitleJob()

    @State private var selectedModel: String = UserDefaults.standard.string(forKey: "modelID") ?? "ggml-base.bin"
    @State private var language: String = "auto"
    @State private var translate: Bool = true
    @State private var running = false

    private let languages: [(String, String)] = [
        ("auto", "自动检测"),
        ("en", "英语"), ("ja", "日语"), ("ko", "韩语"), ("zh", "中文"),
        ("ru", "俄语"), ("fr", "法语"), ("de", "德语"), ("es", "西语"),
        ("it", "意语"), ("pt", "葡语"), ("th", "泰语"), ("vi", "越南语")
    ]

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach(ModelManager.catalog) { model in
                        modelRow(model)
                    }
                } header: {
                    Text("识别模型")
                } footer: {
                    Text("首次用要下载一次，之后完全离线识别。视频越长越推荐 small。")
                }

                Section("视频语言") {
                    Picker("语言", selection: $language) {
                        ForEach(languages, id: \.0) { pair in
                            Text(pair.1).tag(pair.0)
                        }
                    }
                }

                Section {
                    Toggle("翻译成简体中文", isOn: $translate)
                } footer: {
                    if TranslatorConfig.load().isUsable {
                        Text("翻译走你配置的接口，字幕会变成中文。")
                    } else {
                        Text("还没配置翻译接口：现在只会生成原文对照字幕，去设置里填完再回来。")
                    }
                }

                if running || job.finished || job.errorText != nil {
                    Section("进度") {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(value: job.progress)
                            Text(job.status)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            if let notice = job.notice {
                                Text(notice)
                                    .font(.system(size: 12))
                                    .foregroundColor(.orange)
                            }
                            if let error = job.errorText {
                                Text(error)
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                            }
                            if job.cueCount > 0 {
                                Text("已生成 \(job.cueCount) 条")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Button {
                        start()
                    } label: {
                        HStack {
                            Spacer()
                            Text(running ? "正在处理…" : (job.finished ? "再跑一遍" : "开始生成字幕"))
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                        }
                    }
                    .disabled(running || !models.isDownloaded(selectedModel) || models.activeDownload != nil)
                }
            }
            .navigationTitle("生成中文字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func modelRow(_ model: WhisperModelInfo) -> some View {
        HStack(spacing: 10) {
            Button {
                selectedModel = model.id
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectedModel == model.id ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(selectedModel == model.id ? .accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.title) · \(model.sizeText)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                        Text(model.note)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if models.isDownloaded(model.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if models.activeDownload == model.id {
                ProgressView(value: models.progress[model.id] ?? 0)
                    .frame(width: 46)
            } else {
                Button("下载") {
                    download(model.id)
                }
                .buttonStyle(.bordered)
                .disabled(models.activeDownload != nil)
            }
        }
    }

    private func download(_ id: String) {
        Task {
            _ = try? await ModelManager.shared.download(id)
        }
    }

    private func start() {
        guard !running else { return }
        running = true
        UserDefaults.standard.set(selectedModel, forKey: "modelID")

        Task {
            await job.run(videoURL: videoURL,
                          modelID: selectedModel,
                          language: language == "auto" ? nil : language,
                          translate: translate)
            running = false
        }
    }
}
