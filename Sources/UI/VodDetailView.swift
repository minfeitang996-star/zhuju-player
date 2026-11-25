import SwiftUI

/// 影片详情：简介 + 线路 + 剧集网格，选集进播放
struct VodDetailView: View {

    let item: VodItem

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = VodStore.shared
    @ObservedObject private var downloads = VodDownloadManager.shared
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @State private var detail: VodDetail?
    @State private var loading = true
    @State private var errorText: String?
    @State private var lineIndex = 0
    @State private var playTarget: VodPlayTarget?

    private var siteName: String { store.activeSite?.name ?? "点播" }
    private var currentLine: VodLine? {
        guard let detail, detail.lines.indices.contains(lineIndex) else { return nil }
        return detail.lines[lineIndex]
    }

    /// 详情返回后以它为准：列表接口可能不带封面，详情里通常有
    private var shownItem: VodItem {
        guard let detail else { return item }
        var merged = item
        let source = detail.item
        if merged.pic?.isEmpty ?? true { merged.pic = source.pic }
        if merged.remarks?.isEmpty ?? true { merged.remarks = source.remarks }
        if merged.year?.isEmpty ?? true { merged.year = source.year }
        if merged.area?.isEmpty ?? true { merged.area = source.area }
        if merged.typeName?.isEmpty ?? true { merged.typeName = source.typeName }
        if source.name.count > merged.name.count { merged.name = source.name }
        return merged
    }

    var body: some View {
        NavigationView {
            ZStack {
                theme.background.ignoresSafeArea()

                if loading {
                    ProgressView().tint(theme.accent)
                } else if let errorText {
                    errorView(errorText)
                } else if let detail {
                    content(detail)
                } else {
                    Text("没有拿到详情")
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("返回") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        toggleFavorite()
                    } label: {
                        Image(systemName: isFav ? "heart.fill" : "heart")
                            .foregroundColor(isFav ? theme.accent : .white)
                    }
                }
            }
            .fullScreenCover(item: $playTarget) { target in
                VodPlayerView(target: target)
            }
            .onAppear { Task { await loadDetail() } }
        }
        .navigationViewStyle(.stack)
        .tint(theme.accent)
    }

    // MARK: - 内容

    private func content(_ detail: VodDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(detail)

                if let content = detail.content, !content.isEmpty {
                    infoBlock(title: "简介", text: content)
                }
                if let actor = detail.actor, !actor.isEmpty {
                    infoBlock(title: "主演", text: actor)
                }
                if let director = detail.director, !director.isEmpty {
                    infoBlock(title: "导演", text: director)
                }

                if !detail.lines.isEmpty {
                    lineSelector(detail)
                    episodeGrid
                } else {
                    Text("这个影片没有可用播放线路")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.45))
                        .padding(.vertical, 16)
                }
            }
            .padding(16)
        }
    }

    private func header(_ detail: VodDetail) -> some View {
        HStack(spacing: 16) {
            VodCover(pic: shownItem.pic, width: 110, height: 150)

            VStack(alignment: .leading, spacing: 8) {
                Text(shownItem.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(3)

                HStack(spacing: 8) {
                    if let year = shownItem.year, !year.isEmpty {
                        Text(year).font(.system(size: 12))
                    }
                    if let area = shownItem.area, !area.isEmpty {
                        Text(area).font(.system(size: 12))
                    }
                    if let remarks = shownItem.remarks, !remarks.isEmpty {
                        Text(remarks).font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.accent)
                    }
                }
                .foregroundColor(.white.opacity(0.55))

                if let typeName = shownItem.typeName, !typeName.isEmpty {
                    Text(typeName).font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func infoBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.accent)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(5)
                .foregroundColor(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lineSelector(_ detail: VodDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("线路")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(detail.lines.indices, id: \.self) { index in
                        Button {
                            lineIndex = index
                        } label: {
                            Text(detail.lines[index].name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(lineIndex == index ? .white : .white.opacity(0.55))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(lineIndex == index ? theme.accent.opacity(0.22) : Color.white.opacity(0.06)))
                                .overlay(Capsule().stroke(lineIndex == index ? theme.accent.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var episodeGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选集")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                if let line = currentLine {
                    ForEach(line.episodes) { episode in
                        VStack(spacing: 5) {
                            Button {
                                playTarget = VodPlayTarget(
                                    title: shownItem.name,
                                    episodeName: episode.name,
                                    url: episode.url,
                                    siteName: siteName,
                                    pic: shownItem.pic
                                )
                            } label: {
                                Text(episode.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            downloadIndicator(for: episode)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func downloadIndicator(for episode: VodEpisode) -> some View {
        let state = downloads.state(for: episode.url)
        switch state.status {
        case .idle:
            Button {
                downloads.download(title: shownItem.name, episodeName: episode.name, sourceURL: episode.url)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
            }
            .buttonStyle(.plain)

        case .downloading:
            Button {
                downloads.cancel(episode.url)
            } label: {
                HStack(spacing: 4) {
                    ProgressView()
                        .tint(theme.accent)
                        .scaleEffect(0.7)
                    if state.total > 0 {
                        Text("\(state.done)/\(state.total)")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .buttonStyle(.plain)

        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(theme.accent)

        case .failed(let message):
            Button {
                downloads.download(title: shownItem.name, episodeName: episode.name, sourceURL: episode.url)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                    Text(message)
                        .font(.system(size: 9))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(.white.opacity(0.35))
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Button("重试") { Task { await loadDetail() } }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(theme.accent)
                .foregroundColor(.black)
                .clipShape(Capsule())
        }
        .padding(32)
    }

    // MARK: - 数据

    @MainActor
    private func loadDetail() async {
        guard let site = store.activeSite else {
            errorText = "先选择一个影视接口"
            loading = false
            return
        }
        loading = true
        errorText = nil
        do {
            let result = try await VodClient.shared.detail(site: site, vodID: item.id)
            detail = result
            lineIndex = 0
            loading = false
        } catch {
            errorText = error.localizedDescription
            loading = false
        }
    }

    private var favoriteURL: String? {
        currentLine?.episodes.first?.url ?? item.id
    }

    private var isFav: Bool {
        guard let url = favoriteURL else { return false }
        return store.isFavorited(url)
    }

    private func toggleFavorite() {
        guard let episode = currentLine?.episodes.first else { return }
        let snapshot = VodHistoryItem(
            id: UUID(),
            name: shownItem.name,
            pic: shownItem.pic,
            url: episode.url,
            episodeName: episode.name,
            siteName: siteName,
            playedAt: Date()
        )
        store.toggleFavorite(snapshot)
    }
}
