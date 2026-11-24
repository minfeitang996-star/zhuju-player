import SwiftUI

/// 网络直播：频道（当前配置内按分类浏览）/ 收藏 / 配置（点哪套切哪套）
struct LiveSourceView: View {

    enum Tab: String, CaseIterable {
        case channels
        case favorites
        case playlists

        var title: String {
            switch self {
            case .channels: return "频道"
            case .favorites: return "收藏"
            case .playlists: return "配置"
            }
        }

        var icon: String {
            switch self {
            case .channels: return "tv.fill"
            case .favorites: return "heart.fill"
            case .playlists: return "folder.fill"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LiveSourceStore.shared
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @State private var tab: Tab = .channels
    @State private var currentFolder: String?
    @State private var showAddChannel = false
    @State private var showAddPlaylist = false
    @State private var editing: LiveChannel?
    @State private var active: LiveChannel?
    @State private var searchText = ""
    @State private var showClearHistory = false
    @State private var refreshError: String?
    @State private var renameTarget: LivePlaylist?
    @State private var renameText = ""

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 当前激活配置内的频道，按分类分组：央视、卫视排前面，其他地区按名称排，其他兜底放最后
    private var activeGrouped: [FolderGroup] {
        let dict = Dictionary(grouping: store.activeChannels) { $0.category }
        let preferred = ["央视", "卫视"]
        let keys = dict.keys.sorted { a, b in
            if a == b { return false }
            if preferred.contains(a) && !preferred.contains(b) { return true }
            if preferred.contains(b) && !preferred.contains(a) { return false }
            if a == "其他" { return false }
            if b == "其他" { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return keys.map { name in
            let items = (dict[name] ?? []).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return FolderGroup(name: name, items: items)
        }
    }

    private var currentItems: [LiveChannel] {
        guard let folder = currentFolder else { return [] }
        return activeGrouped.first(where: { $0.name == folder })?.items ?? []
    }

    private var filteredChannels: [LiveChannel] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.allChannels
            .filter { $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationView {
            ZStack {
                theme.background.ignoresSafeArea()

                Group {
                    switch tab {
                    case .channels: channelsBody
                    case .favorites: favoritesBody
                    case .playlists: playlistsBody
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索频道")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if tab == .channels && currentFolder != nil {
                        Button {
                            currentFolder = nil
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    } else {
                        Button("关闭") { dismiss() }
                            .foregroundColor(theme.accent)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    trailingButton
                }
            }
            .sheet(isPresented: $showAddChannel) {
                ChannelForm(mode: .single, targetPlaylistID: store.activePlaylist?.id)
            }
            .sheet(item: $editing) { channel in
                ChannelForm(mode: .edit, existing: channel)
            }
            .sheet(isPresented: $showAddPlaylist) {
                PlaylistForm()
            }
            .fullScreenCover(item: $active) { channel in
                LiveStreamPlayer(channel: channel)
            }
            .alert("清空最近看过的记录？", isPresented: $showClearHistory) {
                Button("取消", role: .cancel) { }
                Button("清空", role: .destructive) { store.clearHistory() }
            } message: {
                Text("只清除观看记录，不会删掉已添加的直播源。")
            }
            .alert("配置拉取出错", isPresented: .constant(refreshError != nil)) {
                Button("知道了") { refreshError = nil }
            } message: {
                Text(refreshError ?? "")
            }
            .alert("重命名配置", isPresented: .constant(renameTarget != nil)) {
                TextField("配置名称", text: $renameText)
                Button("取消") { renameTarget = nil }
                Button("保存") {
                    if let target = renameTarget {
                        store.renamePlaylist(target.id, title: renameText)
                    }
                    renameTarget = nil
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(theme.accent)
        .safeAreaInset(edge: .bottom) { bottomTabBar }
    }

    private var navigationTitle: String {
        switch tab {
        case .channels: return currentFolder ?? "频道"
        case .favorites: return "收藏"
        case .playlists: return "配置中心"
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch tab {
        case .channels:
            Button {
                showAddChannel = true
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .disabled(store.activePlaylist == nil)
        case .playlists:
            Button {
                showAddPlaylist = true
            } label: {
                Image(systemName: "plus.circle.fill")
            }
        case .favorites:
            EmptyView()
        }
    }

    // MARK: - 底部 Tab

    private var bottomTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    tab = item
                    currentFolder = nil
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 20, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(tab == item ? theme.accent : .white.opacity(0.45))
                }
                .buttonStyle(HomeFolderStyle(accent: theme.accent))
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }

    // MARK: - 频道 Tab

    @ViewBuilder
    private var channelsBody: some View {
        if isSearching {
            searchList
        } else if currentFolder == nil {
            channelHomeList
        } else {
            List {
                ForEach(currentItems) { channel in
                    channelRowView(channel)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var channelHomeList: some View {
        List {
            if !store.history.isEmpty {
                Section {
                    ForEach(store.history) { item in
                        historyRow(item)
                    }
                } header: {
                    sectionHeader("最近看过", trailing: "清空") {
                        showClearHistory = true
                    }
                }
            }

            if let active = store.activePlaylist {
                Section {
                    if activeGrouped.isEmpty {
                        Text("这套配置还没有频道，去配置页刷新或添加。")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.45))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(activeGrouped) { group in
                            Button {
                                currentFolder = group.name
                            } label: {
                                folderRow(name: group.name, count: group.items.count)
                            }
                            .buttonStyle(HomeFolderStyle(accent: theme.accent))
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    sectionHeader(active.title, trailing: nil)
                }
            } else {
                Section {
                    Text("还没有配置，点底部「配置」添加一套直播源。")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.45))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var searchList: some View {
        List {
            if filteredChannels.isEmpty {
                Text("没找到匹配「\(searchText)」的频道")
                    .foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(filteredChannels) { channel in
                    channelRowView(channel)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 收藏 Tab

    @ViewBuilder
    private var favoritesBody: some View {
        if store.favorites.isEmpty {
            emptyFavorites
        } else {
            List {
                ForEach(store.favorites) { item in
                    Button {
                        active = channel(from: item)
                    } label: {
                        historyRowContent(item, starred: true)
                    }
                    .buttonStyle(HomeFolderStyle(accent: theme.accent))
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.removeFavorite(item.id)
                        } label: {
                            Label("取消收藏", systemImage: "heart.slash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyFavorites: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 104, height: 104)
                Image(systemName: "heart")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.white.opacity(0.28))
            }
            Text("还没有收藏频道")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
            Text("在频道列表里点星标，常用频道会收进这里。")
                .font(.system(size: 13))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.45))
        }
        .padding(32)
    }

    // MARK: - 配置 Tab

    private var playlistsBody: some View {
        List {
            ForEach(store.playlists) { pl in
                playlistRow(pl)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func playlistRow(_ pl: LivePlaylist) -> some View {
        let isActive = store.activePlaylist?.id == pl.id
        return Button {
            store.selectPlaylist(pl.id)
            tab = .channels
            currentFolder = nil
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isActive ? "record.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isActive ? theme.accent : .white.opacity(0.25))

                VStack(alignment: .leading, spacing: 5) {
                    Text(pl.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("共 \(pl.channels.count) 个频道 · \(timeText(pl))")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                    if let feedURL = pl.feedURL, !feedURL.isEmpty {
                        Text(feedURL)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                    } else {
                        Text(pl.isBuiltin ? "内置示例" : "本地配置")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }

                Spacer(minLength: 0)

                Menu {
                    if pl.feedURL != nil {
                        Button {
                            Task { await refresh(pl) }
                        } label: {
                            Label("刷新源", systemImage: "arrow.clockwise")
                        }
                    }
                    Button {
                        renameTarget = pl
                        renameText = pl.title
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    .disabled(pl.isBuiltin)
                    Button(role: .destructive) {
                        store.deletePlaylist(pl.id)
                    } label: {
                        Label("删除配置", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 34, height: 34)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(isActive ? 0.12 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isActive ? theme.accent.opacity(0.5) : Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeFolderStyle(accent: theme.accent))
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 12))
        .listRowBackground(Color.clear)
    }

    private func refresh(_ pl: LivePlaylist) async {
        do {
            try await store.refreshPlaylist(pl.id)
        } catch {
            refreshError = error.localizedDescription
        }
    }

    private func timeText(_ pl: LivePlaylist) -> String {
        let reference = pl.feedURL != nil ? pl.updatedAt : pl.createdAt
        let day = Calendar.current.dateComponents([.day], from: reference, to: Date()).day ?? 0
        let hour = Calendar.current.dateComponents([.hour], from: reference, to: Date()).hour ?? 0
        if pl.feedURL != nil {
            if day > 0 { return "更新于 \(day) 天前" }
            if hour > 0 { return "更新于 \(hour) 小时前" }
            return "刚刚更新"
        } else {
            if day > 0 { return "添加于 \(day) 天前" }
            if hour > 0 { return "添加于 \(hour) 小时前" }
            return "刚刚添加"
        }
    }

    // MARK: - 行组件

    private func sectionHeader(_ title: String, trailing: String?, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Spacer(minLength: 0)
            if let trailing, let action {
                Button(trailing) { action() }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accent)
            }
        }
        .padding(.horizontal, 4)
        .textCase(nil)
    }

    private func channel(from item: LiveHistoryItem) -> LiveChannel {
        LiveChannel(
            id: UUID(),
            name: item.name,
            sources: [LiveSource(id: UUID(), label: item.label, url: item.url)],
            group: item.label,
            kind: "manual"
        )
    }

    private func historyRow(_ item: LiveHistoryItem) -> some View {
        Button {
            active = channel(from: item)
        } label: {
            historyRowContent(item, starred: false)
        }
        .buttonStyle(HomeFolderStyle(accent: theme.accent))
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.deleteHistory(item.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func historyRowContent(_ item: LiveHistoryItem, starred: Bool) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.accent.opacity(0.16))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: starred ? "heart.fill" : "clock.arrow.circlepath")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(theme.accent)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(item.url)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.25))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 4)
        .contentShape(Rectangle())
    }

    private func folderRow(name: String, count: Int) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.accent.opacity(0.16))
                .frame(width: 54, height: 54)
                .overlay(
                    Image(systemName: "folder.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(theme.accent)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("\(count) 个频道")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.22))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 4)
        .contentShape(Rectangle())
    }

    private func channelRowView(_ channel: LiveChannel) -> some View {
        let favorited = store.isFavorited(channel.primaryURL)
        return HStack(spacing: 8) {
            Button {
                active = channel
            } label: {
                channelRow(channel)
            }
            .buttonStyle(HomeFolderStyle(accent: theme.accent))
            .frame(maxWidth: .infinity)

            Button {
                store.toggleFavorite(name: channel.name, url: channel.primaryURL, label: channel.category)
            } label: {
                Image(systemName: favorited ? "heart.fill" : "heart")
                    .font(.system(size: 18))
                    .foregroundColor(favorited ? theme.accent : .white.opacity(0.35))
                    .frame(width: 34, height: 34)
            }

            Menu {
                Button {
                    editing = channel
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    store.deleteChannel(channel.id)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 34, height: 34)
            }
        }
        .contentShape(Rectangle())
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 12))
        .listRowBackground(Color.clear)
        .contextMenu {
            Button {
                editing = channel
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                store.deleteChannel(channel.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.deleteChannel(channel.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func channelRow(_ channel: LiveChannel) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.accent.opacity(0.16))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "tv.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(theme.accent)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(channel.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if channel.sourceCount > 1 {
                    Text("\(channel.sourceCount) 条线路")
                        .font(.system(size: 12))
                        .foregroundColor(theme.accent)
                } else {
                    Text(channel.primaryURL)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.25))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 4)
        .contentShape(Rectangle())
    }
}

/// 一个分类文件夹（央视 / 卫视 / 地区 / 其他）
private struct FolderGroup: Identifiable {
    let name: String
    let items: [LiveChannel]
    var id: String { name }
}

/// 文件夹入口点按反馈
private struct HomeFolderStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - 频道表单（加单条 / 编辑 / 追加线路）

private struct ChannelForm: View {

    enum FormMode {
        case single
        case edit
    }

    let mode: FormMode
    let targetPlaylistID: UUID?
    let existing: LiveChannel?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LiveSourceStore.shared
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @State private var name = ""
    @State private var url = ""
    @State private var extraURL = ""
    @State private var errorText: String?

    private var isEdit: Bool { existing != nil }

    private var liveChannel: LiveChannel? {
        guard let existing else { return nil }
        return store.allChannels.first(where: { $0.id == existing.id })
    }

    var body: some View {
        NavigationView {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("频道名称")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                        TextField("例如：央视新闻", text: $name)
                            .padding(14)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        Text("直播地址（一源）")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                        TextField("http / https / rtsp / rtmp / udp / m3u8", text: $url)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .padding(14)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        if isEdit, let channel = liveChannel, channel.sourceCount > 1 {
                            Text("已有线路")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))
                            ForEach(channel.sources) { source in
                                HStack(spacing: 8) {
                                    Text(source.label)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                        .frame(width: 40)
                                    Text(source.url)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.5))
                                        .lineLimit(1)
                                }
                                .padding(10)
                                .background(Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }

                        if isEdit {
                            Text("追加备用线路（可选）")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))
                            TextField("再贴一条同频道的备用地址", text: $extraURL)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(14)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Button {
                                addExtraSource()
                            } label: {
                                Text("添加为备用线路")
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.10))
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .disabled(!LiveSourceStore.isValidURL(extraURL))
                        }

                        if let errorText {
                            Text(errorText)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(isEdit ? "编辑直播源" : "添加频道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                        .disabled(!LiveSourceStore.isValidURL(url))
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    url = existing.primaryURL
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(theme.accent)
    }

    private func save() {
        if let existing {
            store.updateChannel(existing.id, name: name, url: url)
        } else if let targetPlaylistID {
            store.addChannel(to: targetPlaylistID, name: name, url: url)
        } else {
            errorText = "当前没有可添加的配置"
            return
        }
        dismiss()
    }

    private func addExtraSource() {
        guard let existing else { return }
        guard LiveSourceStore.isValidURL(extraURL) else { return }
        store.appendSource(to: existing.id, url: extraURL)
        extraURL = ""
    }
}

// MARK: - 配置表单（订阅源 / 新建本地配置）

private struct PlaylistForm: View {

    enum Mode: Int {
        case feed
        case local
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LiveSourceStore.shared
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @State private var mode: Mode = .feed
    @State private var title = ""
    @State private var feedURL = ""
    @State private var importing = false
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        Picker("方式", selection: $mode) {
                            Text("订阅源").tag(Mode.feed)
                            Text("本地配置").tag(Mode.local)
                        }
                        .pickerStyle(.segmented)

                        Text("配置名称")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                        TextField(mode == .feed ? "例如：央视 / 卫视聚合" : "例如：我的收藏台", text: $title)
                            .padding(14)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        if mode == .feed {
                            Text("m3u / m3u8 / txt 订阅地址")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))
                            TextField("粘贴播放列表链接", text: $feedURL)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(14)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            HStack(spacing: 10) {
                                ForEach(LiveSourceStore.presetFeeds.indices, id: \.self) { i in
                                    let feed = LiveSourceStore.presetFeeds[i]
                                    Button(feed.title) {
                                        feedURL = feed.url
                                        if title.isEmpty { title = feed.title }
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.10))
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                                }
                            }

                            Button {
                                Task { await importFeed() }
                            } label: {
                                HStack(spacing: 8) {
                                    if importing {
                                        ProgressView().tint(.black)
                                    }
                                    Text(importing ? "正在拉取…" : "拉取并建成配置")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(theme.accent)
                                .foregroundColor(.black)
                                .clipShape(Capsule())
                            }
                            .disabled(importing || !LiveSourceStore.isValidURL(feedURL))
                        } else {
                            Button {
                                createLocal()
                            } label: {
                                Text("创建空配置")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(theme.accent)
                                    .foregroundColor(.black)
                                    .clipShape(Capsule())
                            }
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if let errorText {
                            Text(errorText)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                        }

                        Text("订阅配置会把整套频道缓存到本地，之后在「配置」页点刷新即可重新拉取；本地配置用来手动整理自己的频道。")
                            .font(.system(size: 11.5))
                            .lineSpacing(4)
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(16)
                }
            }
            .navigationTitle("添加配置")
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

    private func createLocal() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addPlaylist(title: trimmed, feedURL: nil, channels: [], isBuiltin: false)
        dismiss()
    }

    private func importFeed() async {
        importing = true
        errorText = nil
        do {
            guard let url = URL(string: feedURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw NSError(domain: "live", code: -1, userInfo: [NSLocalizedDescriptionKey: "地址格式不对"])
            }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "live", code: -2, userInfo: [NSLocalizedDescriptionKey: "列表返回异常"])
            }
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            let entries = M3UParser.parse(text)
            guard !entries.isEmpty else {
                throw NSError(domain: "live", code: -3, userInfo: [NSLocalizedDescriptionKey: "没解析到可用频道"])
            }
            let channels = entries.map {
                LiveChannel(id: UUID(), name: $0.name,
                            sources: [LiveSource(id: UUID(), label: "一源", url: $0.url)],
                            group: $0.group, kind: "imported")
            }
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = trimmedTitle.isEmpty ? "订阅配置" : trimmedTitle
            await MainActor.run {
                store.addPlaylist(title: fallbackTitle, feedURL: feedURL, channels: channels, isBuiltin: false)
                importing = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
                importing = false
            }
        }
    }
}
