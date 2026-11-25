import SwiftUI

/// 影视点播主页：选源 → 分类 / 搜索 → 影片网格 → 进详情
struct VodView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = VodStore.shared
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @State private var categories: [VodCategory] = []
    @State private var items: [VodItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var errorText: String?
    @State private var keyword = ""
    @State private var selectedCategoryID: String?
    @State private var showSiteForm = false
    @State private var showSourceManager = false
    @State private var showDownloads = false
    @State private var route: VodRoute?
    @State private var requestTick = 0
    @FocusState private var searchFocused: Bool

    /// 影视页的两种去向：进详情 / 从观看记录直接续播
    private enum VodRoute: Identifiable {
        case detail(VodItem)
        case play(VodPlayTarget)

        var id: String {
            switch self {
            case .detail(let item): return "detail-" + item.id
            case .play(let target): return "play-" + target.url
            }
        }
    }

    private var activeSite: VodSite? { store.activeSite }
    private var hasMore: Bool { page < pageCount }

    var body: some View {
        NavigationView {
            ZStack {
                theme.background.ignoresSafeArea()

                if store.sites.isEmpty {
                    emptySites
                } else {
                    content
                }
            }
            .navigationTitle("影视")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            showDownloads = true
                        } label: {
                            Image(systemName: "arrow.down.circle")
                        }
                        Button {
                            showSourceManager = true
                        } label: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        if !store.sites.isEmpty {
                            siteMenu
                        }
                        Button {
                            showSiteForm = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showSiteForm) {
                VodSiteForm()
            }
            .sheet(isPresented: $showSourceManager) {
                VodSourceManagerView()
            }
            .sheet(isPresented: $showDownloads) {
                VodDownloadsView()
            }
            .fullScreenCover(item: $route) { route in
                switch route {
                case .detail(let item):
                    VodDetailView(item: item)
                case .play(let target):
                    VodPlayerView(target: target)
                }
            }
            .onAppear {
                OrientationHelper.apply(.portrait)
                guard activeSite != nil else { return }
                Task { await reload() }
            }
            .onChange(of: store.activeSiteID) { _ in
                Task { await reload() }
            }
        }
        .navigationViewStyle(.stack)
        .tint(theme.accent)
    }

    // MARK: - 内容

    private var content: some View {
        VStack(spacing: 0) {
            searchBar

            if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !store.searchHistory.isEmpty {
                searchHistoryRow
            }

            if !categories.isEmpty {
                categoryChips
            }

            list
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.white.opacity(0.4))
            TextField("搜影片名称", text: $keyword)
                .focused($searchFocused)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .onSubmit { submitSearch(keyword) }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    Task { await reload() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// 搜索历史：搜过的词都留着，点一下直接重新搜，不用每次重打
    private var searchHistoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("最近")
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.trailing, 2)

                ForEach(store.searchHistory, id: \.self) { text in
                    Button {
                        submitSearch(text)
                    } label: {
                        Text(text)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    store.clearSearchHistory()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    private func submitSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keyword = trimmed
        searchFocused = false
        store.addSearchKeyword(trimmed)
        Task { await reload() }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                chip(title: "全部", id: nil)
                ForEach(categories) { cat in
                    chip(title: cat.name, id: cat.typeID)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    private func chip(title: String, id: String?) -> some View {
        let active = selectedCategoryID == id
        return Button {
            selectedCategoryID = id
            Task { await reload() }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(active ? .white : .white.opacity(0.55))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(Capsule().fill(active ? theme.accent.opacity(0.22) : Color.white.opacity(0.06)))
                .overlay(Capsule().stroke(active ? theme.accent.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollView {
            if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !store.history.isEmpty {
                watchHistorySection
            }

            LazyVGrid(columns: gridColumns, spacing: 14) {
                ForEach(items) { item in
                    Button {
                        route = .detail(item)
                    } label: {
                        VodCard(item: item, theme: theme)
                    }
                    .buttonStyle(HomePressStyle(accent: theme.accent))
                    .onAppear {
                        if item.id == items.last?.id, hasMore, !loading {
                            Task { await loadNext() }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 24)

            if loading {
                ProgressView().tint(theme.accent).padding(.vertical, 16)
            }
            if let errorText, items.isEmpty {
                errorView(errorText)
            } else if items.isEmpty, !loading {
                Text("这个分类下暂时没有影片")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.vertical, 32)
            }
        }
        .refreshable { await reload() }
    }

    /// 观看记录：最近看过的片，显示看到第几集与百分比，点一下直接续播
    private var watchHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("观看记录")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Button("清空") { store.clearHistory() }
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(store.history.prefix(12))) { item in
                        watchHistoryCard(item)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func watchHistoryCard(_ item: VodHistoryItem) -> some View {
        Button {
            route = .play(VodPlayTarget(title: item.name,
                                        episodeName: item.episodeName,
                                        url: item.url,
                                        siteName: item.siteName,
                                        pic: item.pic))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    VodCover(pic: item.pic, width: 148, height: 84)
                    if let progress = item.progress, progress > 0.02 {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.2))
                            GeometryReader { proxy in
                                Capsule().fill(theme.accent)
                                    .frame(width: max(3, proxy.size.width * progress))
                            }
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 7)
                        .padding(.bottom, 7)
                    }
                }

                Text(item.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(item.episodeName).lineLimit(1)
                    if let progress = item.progress, progress > 0.02 {
                        Text("· 看到 \(Int(progress * 100))%")
                            .foregroundColor(theme.accent)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundColor(.white.opacity(0.45))
            }
            .frame(width: 148)
        }
        .buttonStyle(HomePressStyle(accent: theme.accent))
        .contextMenu {
            Button(role: .destructive) {
                store.deleteHistory(item.id)
            } label: {
                Label("删除这条记录", systemImage: "trash")
            }
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 14),
         GridItem(.flexible(), spacing: 14),
         GridItem(.flexible(), spacing: 14)]
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
            Button("重试") { Task { await reload() } }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(theme.accent)
                .foregroundColor(.black)
                .clipShape(Capsule())
        }
        .padding(.vertical, 32)
    }

    private var emptySites: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 104, height: 104)
                Image(systemName: "film.stack")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.white.opacity(0.28))
            }
            Text("还没有影视接口")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
            Text("点右上角 + 粘贴你找到的采集站地址，或 TVBox / 影视仓配置链接，即可浏览点播影片。")
                .font(.system(size: 13))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.45))
            Button {
                showSiteForm = true
            } label: {
                Text("添加影视接口")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(theme.accent)
                    .foregroundColor(.black)
                    .clipShape(Capsule())
            }
        }
        .padding(32)
    }

    // MARK: - 源菜单

    private var siteMenu: some View {
        Menu {
            ForEach(store.sites) { site in
                Button {
                    store.selectSite(site.id)
                } label: {
                    Label(site.name, systemImage: store.activeSiteID == site.id ? "checkmark.circle.fill" : "circle")
                }
            }
            Divider()
            if let active = activeSite {
                Button(role: .destructive) {
                    store.deleteSite(active.id)
                } label: {
                    Label("删除当前源", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
        }
    }

    // MARK: - 数据加载

    @MainActor
    private func reload() async {
        guard let site = activeSite else { return }
        requestTick += 1
        let tick = requestTick
        page = 1
        pageCount = 1
        items = []
        loading = true
        errorText = nil

        // 分类先拉一次，失败不阻塞列表
        do {
            let cats = try await VodClient.shared.categories(site: site)
            guard tick == requestTick else { return }
            categories = cats
        } catch {
            // 分类拿不到就只用列表
        }

        do {
            let result = try await VodClient.shared.list(site: site,
                                                          typeID: selectedCategoryID,
                                                          page: 1,
                                                          keyword: keyword)
            guard tick == requestTick else { return }
            items = result.items
            pageCount = result.pageCount
            loading = false
        } catch {
            guard tick == requestTick else { return }
            errorText = error.localizedDescription
            loading = false
        }
    }

    @MainActor
    private func loadNext() async {
        guard let site = activeSite, hasMore, !loading else { return }
        requestTick += 1
        let tick = requestTick
        loading = true
        do {
            let next = page + 1
            let result = try await VodClient.shared.list(site: site,
                                                          typeID: selectedCategoryID,
                                                          page: next,
                                                          keyword: keyword)
            guard tick == requestTick else { return }
            page = next
            pageCount = result.pageCount
            items.append(contentsOf: result.items)
            loading = false
        } catch {
            loading = false
        }
    }
}

// MARK: - 影片卡片

private struct VodCard: View {
    let item: VodItem
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                VodCover(pic: item.pic, width: nil, height: 168)
                if let remarks = item.remarks, !remarks.isEmpty {
                    Text(remarks)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(7)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let year = item.year, !year.isEmpty {
                        Text(year).font(.system(size: 11))
                    }
                    if let area = item.area, !area.isEmpty {
                        Text(area).font(.system(size: 11))
                    }
                }
                .foregroundColor(.white.opacity(0.45))
            }
        }
    }
}

/// 封面图：异步加载，失败回退占位图标
struct VodCover: View {
    let pic: String?
    let width: CGFloat?
    let height: CGFloat

    var body: some View {
        Group {
            if let pic, let url = URL(string: pic) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure, .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(
                colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: "film")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(.white.opacity(0.25)))
    }
}

// MARK: - 添加影视接口

struct VodSiteForm: View {

    enum Mode: Int {
        case site
        case config
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = VodStore.shared
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @State private var mode: Mode = .site
    @State private var name = ""
    @State private var api = ""
    @State private var configURL = ""
    @State private var importing = false
    @State private var errorText: String?
    @State private var resultText: String?

    var body: some View {
        NavigationView {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        Picker("方式", selection: $mode) {
                            Text("单个接口").tag(Mode.site)
                            Text("配置链接").tag(Mode.config)
                        }
                        .pickerStyle(.segmented)

                        if mode == .site {
                            Text("接口名称（可选）")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))
                            TextField("例如：量子资源", text: $name)
                                .padding(14)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            Text("采集站接口地址")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))
                            TextField("https://域名/api.php/provide/vod/（填域名也会自动补全）", text: $api)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(14)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            Button {
                                addSingle()
                            } label: {
                                Text("添加这个源")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(theme.accent)
                                    .foregroundColor(.black)
                                    .clipShape(Capsule())
                            }
                            .disabled(importing || !VodStore.isValidURL(api))
                        } else {
                            Text("TVBox / 影视仓配置链接")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))
                            TextField("粘贴配置 JSON 的网址", text: $configURL)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(14)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            Button {
                                Task { await importConfig() }
                            } label: {
                                HStack(spacing: 8) {
                                    if importing { ProgressView().tint(.black) }
                                    Text(importing ? "正在拉取…" : "解析并导入站点")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(theme.accent)
                                .foregroundColor(.black)
                                .clipShape(Capsule())
                            }
                            .disabled(importing || !VodStore.isValidURL(configURL))
                        }

                        if let errorText {
                            Text(errorText).font(.system(size: 12)).foregroundColor(.red)
                        }
                        if let resultText {
                            Text(resultText).font(.system(size: 12)).foregroundColor(theme.accent)
                        }

                        Text("只支持返回 JSON 的苹果 CMS 直采源（type 1）；JS 爬虫源（csp_/drpy/.js，type 3）原生端无法运行会跳过；网盘聚合、Emby、YouTube 等需专用客户端的源也不支持。")
                            .font(.system(size: 11.5))
                            .lineSpacing(4)
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(16)
                }
            }
            .navigationTitle("添加影视接口")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(theme.accent)
    }

    private func addSingle() {
        guard let site = store.addSite(name: name, api: api, searchable: true) else {
            errorText = "接口地址无效"
            return
        }
        _ = site
        dismiss()
    }

    private func importConfig() async {
        importing = true
        errorText = nil
        resultText = nil
        do {
            guard let url = URL(string: configURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw NSError(domain: "vod", code: -1, userInfo: [NSLocalizedDescriptionKey: "地址格式不对"])
            }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "vod", code: -2, userInfo: [NSLocalizedDescriptionKey: "配置返回异常"])
            }
            let parsed = VodStore.parseConfig(data: data, baseURL: url)
            guard !parsed.added.isEmpty else {
                let reason = "配置里没有可用的直采站点（JS 爬虫源 \(parsed.crawlerSkipped) 个不支持，无效地址 \(parsed.invalidSkipped) 个）"
                throw NSError(domain: "vod", code: -3, userInfo: [NSLocalizedDescriptionKey: reason])
            }
            var added = 0
            for site in parsed.added {
                if store.addSite(name: site.name, api: site.api, searchable: site.searchable) != nil {
                    added += 1
                }
            }
            await MainActor.run {
                var summary = "已导入 \(added) 个站点"
                if parsed.crawlerSkipped > 0 { summary += "；爬虫源跳过 \(parsed.crawlerSkipped) 个" }
                if parsed.invalidSkipped > 0 { summary += "；无效地址跳过 \(parsed.invalidSkipped) 个" }
                resultText = summary
                importing = false
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run { dismiss() }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
                importing = false
            }
        }
    }
}
