import SwiftUI

/// 播放页里的同传设置：原片语言 + 翻译成 + 模型，改完回到播放页自动生效。
struct LiveSettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var models = ModelManager.shared

    @AppStorage("sourceLangPref") private var source: String = "auto"
    @AppStorage("translateTarget") private var target: String = "简体中文"
    @AppStorage("modelID") private var modelID: String = "ggml-base.bin"
    @AppStorage("translateEngine") private var engine: String = "auto"
    @AppStorage("liveSubSize") private var subSize: String = "small"
    @AppStorage("liveSubPos") private var subPos: String = "low"
    @State private var testing = false
    @State private var testResult = ""

    private let sources: [(id: String, name: String)] = [
        ("auto", "自动检测"), ("ja", "日语"), ("en", "英语"), ("zh", "中文"),
        ("ko", "韩语"), ("ru", "俄语"), ("fr", "法语"), ("de", "德语"),
        ("es", "西语"), ("it", "意语"), ("pt", "葡语"), ("th", "泰语"), ("vi", "越南语")
    ]

    private let targets: [String] = [
        "简体中文", "繁体中文", "英语", "日语", "韩语", "俄语",
        "法语", "德语", "西班牙语", "阿拉伯语", "泰语", "越南语"
    ]

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("原片语言", selection: $source) {
                        ForEach(sources, id: \.id) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    Picker("翻译成", selection: $target) {
                        ForEach(targets, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                } header: {
                    Text("语言")
                } footer: {
                    Text("看日本片翻中文：原片语言选「日语」，翻译成选「简体中文」。不知道是什么语言就都放「自动检测」。")
                }

                Section {
                    Picker("字幕大小", selection: $subSize) {
                        Text("小（默认）").tag("small")
                        Text("中").tag("medium")
                        Text("大").tag("large")
                    }
                    Picker("字幕位置", selection: $subPos) {
                        Text("贴底（控制栏上方）").tag("low")
                        Text("再高一点").tag("mid")
                    }
                } header: {
                    Text("字幕外观")
                } footer: {
                    Text("字幕落在这条播放/暂停键那一排的上面，带立体描边，不挡画面中间。")
                }

                Section {
                    Picker("翻译通道", selection: $engine) {
                        Text("自动（免费优先）").tag("auto")
                        Text("内置免费通道").tag("free")
                        Text("自配接口（DeepSeek）").tag("api")
                    }
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
                            .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.25))
                    }
                } header: {
                    Text("翻译")
                } footer: {
                    Text("内置免费通道不用填 API Key，装上就能用（有道 + MyMemory 双通道）。填了自配接口才走自配。")
                }

                Section {
                    Picker("识别模型", selection: $modelID) {
                        ForEach(ModelManager.catalog) { model in
                            Text("\(model.title) · \(model.sizeText)").tag(model.id)
                        }
                    }
                } header: {
                    Text("识别模型")
                } footer: {
                    Text("base 够用；small 更准但慢一半。")
                }

                Section {
                    Text("当前：\(sourceName) → \(target)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.25))
                }
            }
            .navigationTitle("同传设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var sourceName: String {
        sources.first(where: { $0.id == source })?.name ?? "自动检测"
    }

    private func runTest() {
        testing = true
        testResult = "正在请求翻译通道…"
        let sample = "おはようございます、今日はいい天気ですね。"
        Task {
            do {
                let translated = try await TranslationHub.shared.translate(
                    sample,
                    source: source == "auto" ? "ja" : source,
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
