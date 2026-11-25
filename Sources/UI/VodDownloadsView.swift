import SwiftUI

/// 下载管理：查看进行中 / 已完成 / 失败的点播剧集，可播放、导出到「文件」或删除本地文件
struct VodDownloadsView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = VodDownloadManager.shared
    @ObservedObject private var library = MediaLibrary.shared
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @State private var shareFile: ShareFile?
    @State private var playing: MediaItem?
    @State private var deleteTarget: VodDownloadManager.DownloadRecord?

    private typealias Record = VodDownloadManager.DownloadRecord

    private var activeRecords: [Record] {
        manager.allRecords.filter { isActive($0.url) }
    }

    private var finishedRecords: [Record] {
        manager.allRecords.filter { manager.fileExists($0) && !isActive($0.url) }
    }

    private var staleRecords: [Record] {
        manager.allRecords.filter { !manager.fileExists($0) && !isActive($0.url) }
    }

    private func isActive(_ url: String) -> Bool {
        guard let task = manager.tasks[url], case .downloading = task.status else { return false }
        return true
    }

    private func statusText(_ record: Record) -> String {
        if let task = manager.tasks[record.url] {
            switch task.status {
            case .downloading:
                let pct = Int((task.progress * 100).rounded())
                return task.total > 0 ? "下载中 \(pct)%（\(task.done)/\(task.total)）" : "下载中…"
            case .failed(let message):
                return message
            case .done:
                return "已下载"
            case .idle:
                return "未开始"
            }
        }
        return manager.fileExists(record) ? "已下载" : "文件已不存在"
    }

    var body: some View {
        NavigationView {
            ZStack {
                theme.background.ignoresSafeArea()

                if manager.allRecords.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("下载管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $shareFile) { ShareSheet(url: $0.url) }
            .fullScreenCover(item: $playing) { item in
                PlayerScreen(item: item)
                    .environmentObject(library)
            }
            .alert("删除这条下载记录和本地文件？", isPresented: .constant(deleteTarget != nil)) {
                Button("取消", role: .cancel) { deleteTarget = nil }
                Button("删除", role: .destructive) {
                    if let target = deleteTarget { manager.removeRecord(target.url) }
                    deleteTarget = nil
                }
            } message: {
                Text("删除后本地视频文件会一起移除，不可恢复。")
            }
        }
        .navigationViewStyle(.stack)
        .tint(theme.accent)
    }

    private var list: some View {
        List {
            if !activeRecords.isEmpty {
                Section("进行中") {
                    ForEach(activeRecords) { record in
                        activeRow(record)
                    }
                }
            }

            if !finishedRecords.isEmpty {
                Section("已下载") {
                    ForEach(finishedRecords) { record in
                        finishedRow(record)
                    }
                }
            }

            if !staleRecords.isEmpty {
                Section("失败或残留") {
                    ForEach(staleRecords) { record in
                        staleRow(record)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { managerReload() }
    }

    // MARK: - 行

    private func activeRow(_ record: Record) -> some View {
        let task = manager.tasks[record.url]
        return VStack(alignment: .leading, spacing: 8) {
            rowHeader(record)

            ProgressView(value: task?.progress ?? 0)
                .tint(theme.accent)

            HStack {
                Text(statusText(record))
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Button(role: .destructive) {
                    manager.cancel(record.url)
                } label: {
                    Label("取消", systemImage: "xmark.circle")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    private func finishedRow(_ record: Record) -> some View {
        let item = MediaItem(url: manager.fileURL(for: record))
        return VStack(alignment: .leading, spacing: 6) {
            rowHeader(record)

            HStack(spacing: 14) {
                Button {
                    playing = item
                } label: {
                    Label("播放", systemImage: "play.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.plain)

                Button {
                    shareFile = ShareFile(url: item.url)
                } label: {
                    Label("导出到文件", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.plain)

                Spacer()

                Text(item.sizeText)
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.45))

                Button(role: .destructive) {
                    deleteTarget = record
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button {
                playing = item
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            Button {
                shareFile = ShareFile(url: item.url)
            } label: {
                Label("导出到文件", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                deleteTarget = record
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func staleRow(_ record: Record) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            rowHeader(record)

            HStack {
                Text(statusText(record))
                    .font(.system(size: 11.5))
                    .foregroundColor(.red.opacity(0.8))
                Spacer()
                Button {
                    manager.download(title: record.title, episodeName: record.episodeName, sourceURL: record.url)
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    deleteTarget = record
                } label: {
                    Label("移除记录", systemImage: "trash")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    private func rowHeader(_ record: Record) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.title.isEmpty ? record.fileName : record.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            if !record.episodeName.isEmpty {
                Text(record.episodeName)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.white.opacity(0.28))
            Text("还没有下载的剧集")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
            Text("在点播详情页或播放器里点下载图标，剧集就会保存到本地；下载完成后可以在这里播放、导出到「文件」或删除。")
                .font(.system(size: 13))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.45))
        }
        .padding(32)
    }

    private func managerReload() {
        library.reload()
    }
}
