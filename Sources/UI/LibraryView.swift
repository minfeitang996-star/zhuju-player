import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {

    @EnvironmentObject private var library: MediaLibrary
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("themeID") private var themeID: String = "gold"

    @State private var showImporter = false
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
                theme.background.ignoresSafeArea()

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
        .onAppear { Boot.mark("C library.view") }
    }

    private var entries: [LibraryEntry] {
        library.entries(in: currentFolder)
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

    private var list: some View {
        List {
            if path.isEmpty, let resume = resumeItem {
                Button {
                    openVideo(resume)
                } label: {
                    resumeRow(resume)
                }
                .buttonStyle(.plain)
                .listRowBackground(theme.accent.opacity(0.16))
            }

            ForEach(entries) { entry in
                switch entry {
                case .folder(let url, let count):
                    Button {
                        openFolder(url)
                    } label: {
                        folderRow(url, count: count)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.white.opacity(0.06))
                    .contextMenu {
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

                case .video(let item):
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
                            row(item)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selectedIDs.contains(item.id)
                                       ? theme.accent.opacity(0.14)
                                       : Color.white.opacity(0.06))
                    .contextMenu {
                        if !selecting {
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
            .onDelete { indexSet in
                for index in indexSet {
                    guard index < entries.count else { continue }
                    switch entries[index] {
                    case .video(let item):
                        removeResume(for: item)
                        library.delete(item)
                    case .folder(let url, _):
                        library.deleteFolder(url)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { library.reload() }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar }
        }
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

    private func folderRow(_ url: URL, count: Int) -> some View {
        let locked = FolderLock.isLocked(url)
        return HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 26))
                .foregroundColor(theme.accent)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.accent)
                    }
                }
                Text(locked ? "已加密 · \(BiometricAuth.biometryName)解锁" : "\(count) 个项目")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.gray.opacity(0.6))
        }
        .padding(.vertical, 6)
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

    private func resumeRow(_ item: MediaItem) -> some View {
        let saved = UserDefaults.standard.double(forKey: "resume:\(item.url.lastPathComponent)")
        return HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 34))
                .foregroundColor(theme.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text("继续播放 · \(Int(saved * 100))%")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.accent)
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.gray.opacity(0.6))
        }
        .padding(.vertical, 8)
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

    private func row(_ item: MediaItem) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 46, height: 46)
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(theme.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(item.fileExtension.uppercased())
                    Text(item.sizeText)
                    if item.hasSubtitle {
                        Label("字幕", systemImage: "captions.bubble")
                            .foregroundColor(Color(red: 0.45, green: 0.85, blue: 0.55))
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.gray)

                if let progressValue = progress(for: item) {
                    if progressValue >= 1.0 {
                        Label("已看完", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(red: 0.45, green: 0.85, blue: 0.55))
                    } else {
                        HStack(spacing: 6) {
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.15))
                                    .frame(width: 90, height: 4)
                                Capsule()
                                    .fill(theme.accent)
                                    .frame(width: max(2, 90 * CGFloat(progressValue)), height: 4)
                            }
                            Text("看到 \(Int(progressValue * 100))%")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accent)
                        }
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.gray.opacity(0.6))
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundColor(.white.opacity(0.25))
            Text(path.isEmpty ? "还没有视频" : "这个文件夹是空的")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
            Text("点右上角「+」导入视频或新建文件夹。\n也可以在「文件 App → 我的 iPhone → 糖敏飞视频播放器 → Media」里放文件夹。")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
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
