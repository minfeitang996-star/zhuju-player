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
    @AppStorage("bgConvert") private var bgConvert: Bool = true
    @AppStorage("fastASR") private var fastASR: Bool = true

    private struct LangOption: Identifiable {
        let id: String
        let name: String
    }

    private let languages: [LangOption] = [
        LangOption(id: "auto", name: "自动检测"),
        LangOption(id: "en", name: "英语"),
        LangOption(id: "ja", name: "日语"),
        LangOption(id: "ko", name: "韩语"),
        LangOption(id: "zh", name: "中文"),
        LangOption(id: "ru", name: "俄语"),
        LangOption(id: "fr", name: "法语"),
        LangOption(id: "de", name: "德语"),
        LangOption(id: "es", name: "西语"),
        LangOption(id: "it", name: "意语"),
        LangOption(id: "pt", name: "葡语"),
        LangOption(id: "th", name: "泰语"),
        LangOption(id: "vi", name: "越南语")
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

                Section {
                    Picker("识别速度", selection: $fastASR) {
                        Text("极速").tag(true)
                        Text("标准").tag(false)
                    }
                } header: {
                    Text("速度")
                } footer: {
                    Text("极速比标准快 20~35%，模型也只加载一次；个别生僻词或口音重的地方识别不稳时切标准。无人声的片段会自动跳过，不占时间。")
                }

                Section("视频语言") {
                    Picker("语言", selection: $language) {
                        ForEach(languages) { option in
                            Text(option.name).tag(option.id)
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

                Section {
                    Toggle("后台转字幕（切走也继续跑）", isOn: $bgConvert)
                } footer: {
                    Text("开着就可以切到微信、浏览器，锁屏也行，识别会一直跑到完。转完回来看列表里那条视频，字幕已经挂上。")
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
                            if running && bgConvert {
                                Label("后台保活中：可以切到别的 App，也可以锁屏", systemImage: "waveform")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Color(red: 0.45, green: 0.85, blue: 0.55))
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
