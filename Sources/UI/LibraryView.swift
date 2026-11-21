import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {

    @EnvironmentObject private var library: MediaLibrary
    @Environment(\.scenePhase) private var scenePhase

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

    private var currentFolder: URL { path.last ?? library.root }

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.07).ignoresSafeArea()

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
                            path.removeLast()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button { showLive = true } label: {
                            Image(systemName: "waveform")
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
            .fullScreenCover(item: $selected, onDismiss: { library.reload() }) { item in
                PlayerScreen(item: item)
                    .environmentObject(library)
            }
            .onChange(of: scenePhase) { phase in
                // 退到后台自动重新上锁
                if phase == .background { unlocked.removeAll() }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { Boot.mark("C library.view") }
    }

    private var entries: [LibraryEntry] {
        library.entries(in: currentFolder)
    }

    private var list: some View {
        List {
            if path.isEmpty, let resume = resumeItem {
                Button {
                    selected = resume
                } label: {
                    resumeRow(resume)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color(red: 1.0, green: 0.72, blue: 0.25).opacity(0.16))
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
                                unlocked.insert(FolderLock.relativePath(url))
                            } label: {
                                Label("加密这个文件夹", systemImage: "lock.fill")
                            }
                        }
                    }

                case .video(let item):
                    Button {
                        selected = item
                    } label: {
                        row(item)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.white.opacity(0.06))
                    .contextMenu {
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
    }

    private func folderRow(_ url: URL, count: Int) -> some View {
        let locked = FolderLock.isLocked(url)
        return HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 26))
                .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.25))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.25))
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
                .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.25))

            VStack(alignment: .leading, spacing: 4) {
                Text("继续播放 · \(Int(saved * 100))%")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.25))
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
                    .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.25))
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
                                    .fill(Color(red: 1.0, green: 0.72, blue: 0.25))
                                    .frame(width: max(2, 90 * CGFloat(progressValue)), height: 4)
                            }
                            Text("看到 \(Int(progressValue * 100))%")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.25))
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
                    .background(Color(red: 1.0, green: 0.72, blue: 0.25))
                    .foregroundColor(.black)
                    .clipShape(Capsule())
            }
        }
        .padding(32)
    }

    // MARK: - 加密与导航

    private func openFolder(_ url: URL) {
        let rel = FolderLock.relativePath(url)
        guard FolderLock.enabled, FolderLock.isLocked(url), !unlocked.contains(rel) else {
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
