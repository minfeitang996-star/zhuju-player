import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {

    @EnvironmentObject private var library: MediaLibrary
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("themeID") private var themeID: String = "gold"

    @State private var showImporter = false
    @State private var jobTarget: JobTarget?

    private struct JobTarget: Identifiable {
        let id = UUID()
        let url: URL
    }
    @State private var showSettings = false
    @State private var showLive = false
    @State private var selected: MediaItem?
    @State private var importErrors: String?
    @State private var showErrors = false

    @State private var path: [URL] = []
    @State private var unlocked: Set<String> = []
    @State private var lockFailed = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var moveTarget: MediaItem?
    @State private var moveOptions: [URL] = []
    @State private var searchText = ""
    @AppStorage("librarySort") private var librarySort: String = "name"

    // 收藏 / 重命名 / 分享
    @State private var favoriteIDs: Set<String> = Prefs.favorites
    @State private var renameVideoItem: MediaItem?
    @State private var renameFolderURL: URL?
    @State private var renameText = ""
    @State private var shareItem: MediaItem?

    // 多选
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBatchDelete = false
    @State private var batchMoveItems: [MediaItem] = []
    @State private var showBatchMove = false

    private var currentFolder: URL { path.last ?? library.root }
    private var theme: AppTheme { AppTheme.current(themeID) }

    var body: some View {
        NavigationView {
            ZStack {
                backgroundLayer

                if entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle(path.isEmpty ? "本地" : currentFolder.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if path.isEmpty {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                    } else {
                        Button {
                            let popped = path.removeLast()
                            unlocked.remove(FolderLock.relativePath(popped))
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        if selecting {
                            Button("完成") {
                                selecting = false
                                selectedIDs.removeAll()
                            }
                            .font(.system(size: 15, weight: .semibold))
                        } else {
                            if !path.isEmpty {
                                Button {
                                    toggleLockForCurrentFolder()
                                } label: {
                                    Image(systemName: FolderLock.isLocked(currentFolder) ? "lock.fill" : "lock.open")
                                        .foregroundColor(FolderLock.isLocked(currentFolder)
                                                         ? theme.accent
                                                         : .primary)
                                }
                            }
                            Button { showLive = true } label: {
                                Image(systemName: "waveform")
                            }
                            Button("选择") {
                                selecting = true
                            }
                            .font(.system(size: 15))
                            .disabled(videosInCurrentFolder.isEmpty)
                            Menu {
                                Button("按名称") { librarySort = "name" }
                                Button("按大小") { librarySort = "size" }
                                Button("按日期") { librarySort = "date" }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                            }
                            Menu {
                                Button {
                                    showImporter = true
                                } label: {
                                    Label("导入视频", systemImage: "square.and.arrow.down")
                                }
                                Button {
                                    newFolderName = ""
                                    showNewFolder = true
                                } label: {
                                    Label("新建文件夹", systemImage: "folder.badge.plus")
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showLive) {
                LiveView()
            }
            .sheet(item: $jobTarget, onDismiss: { library.reload() }) { target in
                JobView(videoURL: target.url)
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.movie, .video, .audiovisualContent, .data],
                          allowsMultipleSelection: true) { result in
                handleImport(result)
            }
            .alert("导入失败", isPresented: $showErrors) {
                Button("好", role: .cancel) { }
            } message: {
                Text(importErrors ?? "")
            }
            .alert("面容或密码验证未通过", isPresented: $lockFailed) {
                Button("好", role: .cancel) { }
            } message: {
                Text("这个文件夹已加密，验证通过才能进去。")
            }
            .alert("新建文件夹", isPresented: $showNewFolder) {
                TextField("文件夹名称", text: $newFolderName)
                Button("取消", role: .cancel) { }
                Button("创建") {
                    if library.createFolder(named: newFolderName, in: currentFolder) != nil {
                        library.reload()
                    }
                }
            }
            .alert("重命名视频", isPresented: Binding(
                get: { renameVideoItem != nil },
                set: { if !$0 { renameVideoItem = nil } }
            )) {
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) { renameVideoItem = nil }
                Button("保存") {
                    if let item = renameVideoItem {
                        removeResume(for: item)
                        _ = library.renameVideo(item, to: renameText)
                    }
                    renameVideoItem = nil
                }
            } message: {
                Text("保留原扩展名，配对字幕会一起改名。")
            }
            .alert("重命名文件夹", isPresented: Binding(
                get: { renameFolderURL != nil },
                set: { if !$0 { renameFolderURL = nil } }
            )) {
                TextField("文件夹名称", text: $renameText)
                Button("取消", role: .cancel) { renameFolderURL = nil }
                Button("保存") {
                    if let url = renameFolderURL {
                        _ = library.renameFolder(url, to: renameText)
                    }
                    renameFolderURL = nil
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(url: item.url)
            }
            .confirmationDialog("移到哪个文件夹", isPresented: Binding(
                get: { moveTarget != nil },
                set: { if !$0 { moveTarget = nil } }
            ), titleVisibility: .visible) {
                ForEach(moveOptions, id: \.path) { folder in
                    Button(folderName(folder)) {
                        if let item = moveTarget {
                            _ = library.move(item, to: folder)
                            library.reload()
                        }
                        moveTarget = nil
                    }
                }
                Button("取消", role: .cancel) { moveTarget = nil }
            }
            .alert("删除选中的 \(selectedIDs.count) 个视频？", isPresented: $showBatchDelete) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) { deleteSelected() }
            } message: {
                Text("删掉的文件不進「最近删除」，删了就没了。")
            }
            .confirmationDialog("批量移到哪个文件夹", isPresented: $showBatchMove, titleVisibility: .visible) {
                ForEach(moveOptions, id: \.path) { folder in
                    Button(folderName(folder)) {
                        moveSelected(to: folder)
                        batchMoveItems = []
                    }
                }
                Button("取消", role: .cancel) { batchMoveItems = [] }
            }
            .fullScreenCover(item: $selected, onDismiss: { library.reload() }) { item in
                PlayerScreen(item: item)
                    .environmentObject(library)
            }
            .onChange(of: scenePhase) { phase in
                // 退到后台自动重新上锁
                if phase == .background { unlocked.removeAll() }
            }
            .onChange(of: path) { _ in
                // 换文件夹时退出多选，避免选中的是上一个文件夹里的东西
                selecting = false
                selectedIDs.removeAll()
            }
        }
        .navigationViewStyle(.stack)
        .tint(theme.accent)
        .onAppear { Boot.mark("C library.view") }
    }

    private var entries: [LibraryEntry] {
        library.entries(in: currentFolder)
    }

    /// 文件夹（始终排在前面，不参与搜索过滤）
    private var folderEntries: [LibraryEntry] {
        entries.compactMap { entry -> URL? in
            if case .folder(let url, _) = entry { return url }
            return nil
        }.map { LibraryEntry.folder($0, library.videoCount(in: $0)) }
    }

    /// 搜索过滤 + 排序后的视频
    private var videoEntries: [MediaItem] {
        var videos = entries.compactMap { entry -> MediaItem? in
            if case .video(let item) = entry { return item }
            return nil
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            videos = videos.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        switch librarySort {
        case "size": videos.sort { $0.fileSize > $1.fileSize }
        case "date": videos.sort { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
        default: videos.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return videos
    }

    /// 搜索过滤 + 排序后的展示列表（文件夹始终在前）
    private var filteredEntries: [LibraryEntry] {
        folderEntries + videoEntries.map { LibraryEntry.video($0) }
    }

    private var videosInCurrentFolder: [MediaItem] {
        entries.compactMap {
            if case .video(let item) = $0 { return item }
            return nil
        }
    }

    private var allSelected: Bool {
        !videosInCurrentFolder.isEmpty && selectedIDs.count == videosInCurrentFolder.count
    }

    private func toggleSelection(_ item: MediaItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    private func isFav(_ item: MediaItem) -> Bool {
        favoriteIDs.contains(item.url.path)
    }

    private func toggleFavorite(_ item: MediaItem) {
        if isFav(item) {
            favoriteIDs.remove(item.url.path)
        } else {
            favoriteIDs.insert(item.url.path)
        }
        Prefs.favorites = favoriteIDs
    }

    private var videoTotalSizeText: String {
        let total = videoEntries.reduce(Int64(0)) { $0 + $1.fileSize }
        let gb = Double(total) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(total) / 1_048_576)
    }

    private func selectedVideos() -> [MediaItem] {
        videosInCurrentFolder.filter { selectedIDs.contains($0.id) }
    }

    private func deleteSelected() {
        let targets = selectedVideos()
        for item in targets {
            removeResume(for: item)
            library.delete(item)
        }
        selectedIDs.removeAll()
        selecting = false
        library.reload()
    }

    private func moveSelected(to folder: URL) {
        let targets = selectedVideos()
        for item in targets {
            _ = library.move(item, to: folder)
        }
        selectedIDs.removeAll()
        selecting = false
        library.reload()
    }

    // MARK: - 背景

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [theme.background.opacity(0.96), theme.background],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // 顶部一团柔和的主题色光晕，避免背景一块死色
            Circle()
                .fill(theme.accent.opacity(0.10))
                .frame(width: 340, height: 340)
                .blur(radius: 90)
                .offset(x: 100, y: -170)
                .ignoresSafeArea()
        }
    }

    // MARK: - 列表

    private var list: some View {
        List {
            if path.isEmpty, let resume = resumeItem {
                Button {
                    openVideo(resume)
                } label: {
                    resumeHero(resume)
                }
                .buttonStyle(HomePressStyle(accent: theme.accent))
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if !folderEntries.isEmpty {
                sectionHeader("文件夹", count: folderEntries.count)

                ForEach(folderEntries) { entry in
                    if case .folder(let url, let count) = entry {
                        Button {
                            openFolder(url)
                        } label: {
                            folderCard(url, count: count)
                        }
                        .buttonStyle(HomePressStyle(accent: theme.accent))
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button {
                                renameFolderURL = url
                                renameText = url.lastPathComponent
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            if FolderLock.isLocked(url) {
                                Button {
                                    unlockAndThen(url) { FolderLock.setLocked(url, false) }
                                } label: {
                                    Label("解除加密", systemImage: "lock.open")
                                }
                            } else {
                                Button {
                                    FolderLock.setLocked(url, true)
                                    // 加锁后这个会话里也立刻上锁，必须验证才能进去
                                    unlocked.remove(FolderLock.relativePath(url))
                                } label: {
                                    Label("加密这个文件夹", systemImage: "lock.fill")
                                }
                            }
                        }
                    }
                }
            }

            if !videoEntries.isEmpty {
                sectionHeader("视频", count: videoEntries.count, trailing: videoTotalSizeText)

                ForEach(videoEntries) { item in
                    Button {
                        if selecting {
                            toggleSelection(item)
                        } else {
                            openVideo(item)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if selecting {
                                Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 21))
                                    .foregroundColor(selectedIDs.contains(item.id)
                                                     ? theme.accent
                                                     : .white.opacity(0.35))
                            }
                            videoCard(item)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HomePressStyle(accent: theme.accent))
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        if !selecting {
                            Button {
                                toggleFavorite(item)
                            } label: {
                                Label(isFav(item) ? "取消收藏" : "收藏",
                                      systemImage: isFav(item) ? "star.fill" : "star")
                            }
                            Button {
                                renameVideoItem = item
                                renameText = item.title
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button {
                                shareItem = item
                            } label: {
                                Label("分享视频", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                jobTarget = JobTarget(url: item.url)
                            } label: {
                                Label(item.subtitleURL == nil ? "生成字幕" : "重新生成字幕", systemImage: "wand.and.stars")
                            }
                            Button {
                                moveOptions = allFolders()
                                moveTarget = item
                            } label: {
                                Label("移到文件夹…", systemImage: "folder")
                            }
                            Button(role: .destructive) {
                                removeResume(for: item)
                                library.delete(item)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "搜视频")
        .scrollContentBackground(.hidden)
        .refreshable { library.reload() }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar }
        }
    }

    private func sectionHeader(_ title: String, count: Int, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            Text("\(count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.35))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(.leading, 4)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.clear)
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button(allSelected ? "取消全选" : "全选") {
                if allSelected {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = Set(videosInCurrentFolder.map { $0.id })
                }
            }
            .font(.system(size: 14, weight: .medium))

            Spacer()

            Text("已选 \(selectedIDs.count) 个")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Spacer()

            Button {
                batchMoveItems = selectedVideos()
                moveOptions = allFolders()
                showBatchMove = true
            } label: {
                Label("移动", systemImage: "folder")
            }
            .font(.system(size: 14, weight: .medium))
            .disabled(selectedIDs.isEmpty)

            Button(role: .destructive) {
                showBatchDelete = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.red)
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - 卡片外观

    private func cardBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(Color.white.opacity(0.07))
            .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 3)
    }

    private func folderCard(_ url: URL, count: Int) -> some View {
        let locked = FolderLock.isLocked(url)
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [theme.accent.opacity(0.24), theme.accent.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                Image(systemName: "folder.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(theme.accent)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.accent)
                    }
                }
                Text(locked ? "已加密 · \(BiometricAuth.biometryName)解锁" : "\(count) 个项目")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.22))
        }
        .padding(14)
        .background(cardBackground(cornerRadius: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 上次没看完的那一部（跨启动记忆播放）
    private var resumeItem: MediaItem? {
        guard Prefs.resumeEnabled else { return nil }
        guard let name = UserDefaults.standard.string(forKey: "lastMedia") else { return nil }
        guard let item = library.allVideos().first(where: { $0.url.lastPathComponent == name }) else { return nil }
        let saved = UserDefaults.standard.double(forKey: "resume:\(name)")
        guard saved > 0.02, saved < 0.98 else { return nil }
        return item
    }

    private func resumeHero(_ item: MediaItem) -> some View {
        let saved = UserDefaults.standard.double(forKey: "resume:\(item.url.lastPathComponent)")
        return HStack(spacing: 14) {
            VideoThumbnail(url: item.url, width: 72, height: 56)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("继续播放")
                    Text("· \(Int(saved * 100))%")
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(theme.accent)

                Text(item.title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .padding(.bottom, 20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [theme.accent.opacity(0.22), theme.accent.opacity(0.07)],
                    startPoint: .leading, endPoint: .trailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.accent.opacity(0.25), lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 3)
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: max(4, proxy.size.width * saved), height: 3)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(height: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 单个视频看过的进度：0.02~0.98 是有进度，1.0 是已看完
    private func progress(for item: MediaItem) -> Double? {
        let name = item.url.lastPathComponent
        if UserDefaults.standard.bool(forKey: "done:\(name)") { return 1.0 }
        let saved = UserDefaults.standard.double(forKey: "resume:\(name)")
        return (saved > 0.02 && saved < 0.98) ? saved : nil
    }

    private func videoCard(_ item: MediaItem) -> some View {
        HStack(spacing: 13) {
            VideoThumbnail(url: item.url, width: 62, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    if isFav(item) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.accent)
                    }
                }

                VideoMetaLabel(item: item)

                if let progressValue = progress(for: item) {
                    if progressValue >= 1.0 {
                        Label("已看完", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(red: 0.45, green: 0.85, blue: 0.55))
                    } else {
                        HStack(spacing: 6) {
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 84, height: 4)
                                Capsule()
                                    .fill(theme.accent)
                                    .frame(width: max(2, 84 * CGFloat(progressValue)), height: 4)
                            }
                            Text("看到 \(Int(progressValue * 100))%")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accent)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(cardBackground(cornerRadius: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 104, height: 104)
                Image(systemName: "film.stack")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.white.opacity(0.28))
            }
            Text(path.isEmpty ? "还没有视频" : "这个文件夹是空的")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
            Text("点右上角「+」导入视频或新建文件夹。\n也可以在「文件 App → 我的 iPhone → 糖敏飞视频播放器 → Media」里放文件夹。")
                .font(.system(size: 13))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.45))
            Button {
                showImporter = true
            } label: {
                Text("导入视频")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(theme.accent)
                    .foregroundColor(.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(HomePressStyle(accent: theme.accent))
        }
        .padding(32)
    }

    // MARK: - 加密与导航

    private func openFolder(_ url: URL) {
        let rel = FolderLock.relativePath(url)
        guard FolderLock.isLocked(url), !unlocked.contains(rel) else {
            path.append(url)
            return
        }
        Task {
            let passed = await BiometricAuth.authenticate(reason: "解锁「\(url.lastPathComponent)」")
            await MainActor.run {
                if passed {
                    unlocked.insert(rel)
                    path.append(url)
                } else {
                    lockFailed = true
                }
            }
        }
    }

    /// 点视频也要过锁：防止从「继续播放」卡片直接跳进加密文件夹里的片
    private func openVideo(_ item: MediaItem) {
        if let locked = FolderLock.firstLockedAncestor(of: item.url, excluding: unlocked) {
            Task {
                let passed = await BiometricAuth.authenticate(reason: "解锁「\(locked.lastPathComponent)」")
                await MainActor.run {
                    if passed {
                        unlocked.insert(FolderLock.relativePath(locked))
                        selected = item
                    } else {
                        lockFailed = true
                    }
                }
            }
            return
        }
        selected = item
    }

    private func toggleLockForCurrentFolder() {
        let folder = currentFolder
        let rel = FolderLock.relativePath(folder)
        if FolderLock.isLocked(folder) {
            unlockAndThen(folder) {
                FolderLock.setLocked(folder, false)
                unlocked.remove(rel)
            }
        } else {
            FolderLock.setLocked(folder, true)
            unlocked.remove(rel)
            if !path.isEmpty { path.removeLast() }
        }
    }

    private func unlockAndThen(_ url: URL, action: @escaping () -> Void) {
        Task {
            let passed = await BiometricAuth.authenticate(reason: "验证后解除加密")
            await MainActor.run {
                if passed { action() } else { lockFailed = true }
            }
        }
    }

    private func allFolders() -> [URL] {
        var result: [URL] = [library.root]
        func walk(_ folder: URL, depth: Int) {
            guard depth < 6 else { return }
            for sub in library.folders(in: folder) {
                result.append(sub)
                walk(sub, depth: depth + 1)
            }
        }
        walk(library.root, depth: 0)
        return result
    }

    private func folderName(_ url: URL) -> String {
        url.standardizedFileURL.path == library.root.standardizedFileURL.path
            ? "本地（根目录）"
            : FolderLock.relativePath(url)
    }

    private func removeResume(for item: MediaItem) {
        let name = item.url.lastPathComponent
        if UserDefaults.standard.string(forKey: "lastMedia") == name {
            UserDefaults.standard.removeObject(forKey: "lastMedia")
        }
        UserDefaults.standard.removeObject(forKey: "resume:\(name)")
        UserDefaults.standard.removeObject(forKey: "done:\(name)")
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrors = error.localizedDescription
            showErrors = true
        case .success(let urls):
            let failures = library.importFiles(urls, into: currentFolder)
            if !failures.isEmpty {
                importErrors = failures.joined(separator: "\n")
                showErrors = true
            }
        }
    }
}

/// 主页入口点按：轻微缩放 + 透明度，带柔和回弹
private struct HomePressStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 视频元信息行：格式、大小、时长、分辨率、字幕标记
private struct VideoMetaLabel: View {
    let item: MediaItem
    @ObservedObject private var store = VideoMetaStore.shared

    private var meta: VideoMeta? { store.cache[item.url.path] }

    var body: some View {
        HStack(spacing: 8) {
            Text(item.fileExtension.uppercased())
            Text(item.sizeText)
            if let duration = meta?.duration {
                Text(VideoMetaStore.durationText(duration))
            }
            if let w = meta?.width, let h = meta?.height,
               let resolution = VideoMetaStore.resolutionText(w: w, h: h) {
                Text(resolution)
            }
            if item.hasSubtitle {
                Label("字幕", systemImage: "captions.bubble")
                    .foregroundColor(Color(red: 0.45, green: 0.85, blue: 0.55))
            }
        }
        .font(.system(size: 11.5))
        .foregroundColor(.white.opacity(0.45))
        .onAppear { store.load(item.url) }
    }
}
