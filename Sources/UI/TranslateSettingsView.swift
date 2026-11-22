import SwiftUI

/// 设置 → 翻译设置：离线识别模型 + 翻译通道 + 翻译接口，全都收在这一页
struct TranslateSettingsView: View {

    @ObservedObject private var models = ModelManager.shared

    @AppStorage("apiBase") private var apiBase: String = ""
    @AppStorage("apiKey") private var apiKey: String = ""
    @AppStorage("azureKey") private var azureKey: String = ""
    @AppStorage("azureRegion") private var azureRegion: String = "eastasia"
    @AppStorage("apiModel") private var apiModel: String = "deepseek-chat"
    @AppStorage("translateEnabled") private var translateEnabled: Bool = true
    @AppStorage("liveStatusVisible") private var liveStatusVisible: Bool = true
    @AppStorage("liveTextVisible") private var liveTextVisible: Bool = true
    @AppStorage("translateEngine") private var engine: String = "auto"
    @AppStorage("translateTarget") private var target: String = "简体中文"
    @AppStorage("modelID") private var modelID: String = "ggml-base.bin"

    @State private var testing = false
    @State private var testResult = ""

    private let targets: [String] = [
        "简体中文", "繁体中文", "英语", "日语", "韩语", "俄语",
        "法语", "德语", "西班牙语", "阿拉伯语", "泰语", "越南语"
    ]

    var body: some View {
        Form {
            Section {
                Toggle("启用翻译", isOn: $translateEnabled)
                Toggle("显示同传状态条", isOn: $liveStatusVisible)
                Toggle("显示翻译字幕", isOn: $liveTextVisible)
                Picker("翻译成", selection: $target) {
                    ForEach(targets, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Picker("翻译通道", selection: $engine) {
                    Text("自动（有 Key 优先）").tag("auto")
                    Text("Azure 翻译（免费额度）").tag("azure")
                    Text("自配接口（OpenAI 兼容）").tag("api")
                    Text("内置免密钥（多数已失效）").tag("free")
                }
                .pickerStyle(.navigationLink)
                Button {
                    runTest()
                } label: {
                    HStack {
                        Text(testing ? "正在测试…" : "测试翻译")
                        Spacer()
                        Image(systemName: "bolt.horizontal.circle")
                    }
                }
                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.system(size: 12))
                        .foregroundColor(testResult.hasPrefix("成功")
                                         ? Color(red: 0.45, green: 0.85, blue: 0.55) : .red)
                }
            } header: {
                Text("翻译")
            } footer: {
                Text("两个开关各自独立：关「显示同传状态条」只隐藏「日语 → 简体中文 · 边看边译中 · 已识别 9 段」那一行；关「显示翻译字幕」只隐藏画面底部滚动的原文/译文。关掉只是不显示，识别和翻译仍在后台跑，再打开就恢复。免密钥通道这两年被陆续封停（MyMemory 每天额度很小、Google 需要代理），所以想长期稳定翻译，最好填 Azure（免费 200 万字符/月）或自配接口的 Key。译文都会存本地缓存，重复台词不再联网。")
            }

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
                            if modelID == model.id {
                                Text("使用中")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.25))
                            } else {
                                Button("设为默认") { modelID = model.id }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        } else if models.activeDownload == model.id {
                            ProgressView(value: models.progress[model.id] ?? 0)
                                .frame(width: 50)
                        } else {
                            Button("下载") { download(model.id) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(models.activeDownload != nil)
                        }
                    }
                }
            } header: {
                Text("离线识别模型")
            } footer: {
                Text("模型完全在本机跑，不上传任何音频。当前默认：\(modelID.replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: ""))。base 够用；small 更准但慢一半。")
            }

            Section {
                SecureField("Azure 订阅密钥（Ocp-Apim-Subscription-Key）", text: $azureKey)
                TextField("Azure 区域，例如 eastasia（留空用全球端点）", text: $azureRegion)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Azure 翻译（推荐，长期可用）")
            } footer: {
                Text("portal.azure.com 免费注册「翻译」资源（F0 层每月 200 万字符），把密钥和区域填这里，通道选「Azure 翻译」或「自动」即可。国内可直连，不需要代理。")
            }

            Section {
                TextField("Base URL，例如 https://api.deepseek.com/v1", text: $apiBase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("模型名，例如 deepseek-chat", text: $apiModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key（可留空）", text: $apiKey)
            } header: {
                Text("翻译接口（OpenAI 兼容）")
            } footer: {
                Text("DeepSeek、月之暗面、通义、硅基流动、OpenAI 这类 /chat/completions 接口都能填，填完把通道选「自配接口」。")
            }

            Section {
                Text("识别跑的是 whisper.cpp，模型放在「文件 App → 我的 iPhone → 糖敏飞视频播放器 → Models」。")
                    .font(.system(size: 12))
                Text("字幕生成：mp4/mov 抽音轨快；mkv/avi 要先转码音轨，耗时约等于片长，建议插电、开后台。")
                    .font(.system(size: 12))
            } header: {
                Text("说明")
            }
        }
        .navigationTitle("翻译设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func download(_ id: String) {
        Task {
            _ = try? await ModelManager.shared.download(id)
        }
    }

    private func runTest() {
        testing = true
        testResult = "正在请求翻译通道…"
        let sample = "おはようございます、今日はいい天気ですね。"
        Task {
            do {
                let translated = try await TranslationHub.shared.translate(
                    sample,
                    source: "ja",
                    target: LangCode.code(for: target)
                )
                let channel = await TranslationHub.shared.currentEngine()
                await MainActor.run {
                    testResult = "成功（\(channel)）：\(translated)"
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = "失败：\(error.localizedDescription)"
                    testing = false
                }
            }
        }
    }
}
