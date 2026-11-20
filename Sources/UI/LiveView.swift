import SwiftUI

struct LiveView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var models = ModelManager.shared
    @StateObject private var live = LiveTranslator()

    @State private var modelID: String = UserDefaults.standard.string(forKey: "modelID") ?? "ggml-base.bin"
    @State private var language: String = "auto"

    private let languages: [(id: String, name: String)] = [
        ("auto", "自动检测"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"),
        ("zh", "中文"), ("ru", "俄语"), ("fr", "法语"), ("de", "德语"),
        ("es", "西语"), ("it", "意语"), ("pt", "葡语"), ("th", "泰语"), ("vi", "越南语")
    ]

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    transcript
                    controlBar
                }
            }
            .navigationTitle("麦克风同传")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        live.stop()
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onDisappear { live.stop() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if live.lines.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("怎么用")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.25))
                            Text("点下面的「开始收听」，把手机放在外放喇叭旁边（20~50 厘米最好），说什么就一段一段出中文。\n\n字幕只能显示在本 App 里——iOS 不允许别的 App 画面上浮字幕，这条绕不过去。")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                                .lineSpacing(4)
                        }
                        .padding(.top, 24)
                    }

                    ForEach(live.lines) { line in
                        VStack(alignment: .leading, spacing: 6) {
                            if let translated = line.translated, !translated.isEmpty {
                                Text(translated)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(line.original)
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            } else {
                                Text(line.original)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: live.lines.count) { _ in
                if let last = live.lines.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var controlBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Capsule()
                    .fill(Color(red: 1.0, green: 0.72, blue: 0.25))
                    .frame(width: max(4, 120 * live.level), height: 4)
                Text(live.status)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                Spacer()
            }

            HStack(spacing: 12) {
                Menu {
                    ForEach(ModelManager.catalog) { model in
                        Button {
                            modelID = model.id
                            UserDefaults.standard.set(model.id, forKey: "modelID")
                        } label: {
                            Text((modelID == model.id ? "✓ " : "") + "\(model.title) · \(model.sizeText)")
                        }
                    }
                } label: {
                    chip(models.isDownloaded(modelID) ? shortName : "未下载")
                }

                Menu {
                    ForEach(languages, id: \.id) { item in
                        Button {
                            language = item.id
                        } label: {
                            Text((language == item.id ? "✓ " : "") + item.name)
                        }
                    }
                } label: {
                    chip(languages.first(where: { $0.id == language })?.name ?? "自动")
                }

                Spacer()

                Button {
                    if live.running {
                        live.stop()
                    } else {
                        guard models.isDownloaded(modelID),
                              let url = ModelManager.shared.localURL(modelID) else {
                            return
                        }
                        live.start(modelPath: url.path,
                                   language: language == "auto" ? nil : language)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: live.running ? "stop.fill" : "mic.fill")
                        Text(live.running ? "停止" : "开始收听")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(live.running ? Color.red.opacity(0.85) : Color(red: 1.0, green: 0.72, blue: 0.25))
                    .foregroundColor(live.running ? .white : .black)
                    .clipShape(Capsule())
                }
            }

            if !models.isDownloaded(modelID) {
                Text("先在设置里下载识别模型（推荐 base）")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.9))
    }

    private var shortName: String {
        modelID.replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: ".bin", with: "")
    }

    private func chip(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.12))
        .foregroundColor(.white)
        .clipShape(Capsule())
    }
}
