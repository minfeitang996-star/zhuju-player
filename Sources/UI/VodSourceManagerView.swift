import SwiftUI
import UniformTypeIdentifiers

/// 点播源管理中心：导入（单接口 / 配置链接 / 本地 JSON·TXT 文件）、导出备份、多选删除、重命名
struct VodSourceManagerView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = VodStore.shared
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @State private var multiSelect = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showForm = false
    @State private var showFileImporter = false
    @State private var showBulkDelete = false
    @State private var renameTarget: VodSite?
    @State private var renameText = ""
    @State private var shareFile: ShareFile?
    @State private var importMessage: String?

    private var selectableSites: [VodSite] { store.sites }

    var body: some View {
        NavigationView {
            ZStack {
                theme.background.ignoresSafeArea()

                if store.sites.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("点播源管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        if !store.sites.isEmpty {
                            Button {
                                withAnimation {
                                    multiSelect.toggle()
                                    selectedIDs.removeAll()
                                }
                            } label: {
                                Image(systemName: multiSelect ? "checkmark.circle.fill" : "checkmark.circle")
                            }
                        }
                        Button {
                            exportSites()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        Button {
                            showForm = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showForm) { VodSiteForm() }
            .sheet(item: $shareFile) { ShareSheet(url: $0.url) }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.json, .plainText, .data],
                          allowsMultipleSelection: false) { result in
                handleImportFile(result)
            }
            .alert("删除选中的 \(selectedIDs.count) 个源？", isPresented: $showBulkDelete) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) {
                    store.deleteSites(selectedIDs)
                    selectedIDs.removeAll()
                    multiSelect = false
                }
            } message: {
                Text("删除后不可恢复；观看记录和收藏会保留。")
            }
            .alert("重命名源", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("源名称", text: $renameText)
                Button("取消") { renameTarget = nil }
                Button("保存") {
                    if let target = renameTarget {
                        store.renameSite(target.id, name: renameText)
                    }
                    renameTarget = nil
                }
            }
            .alert("导入结果", isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )) {
                Button("知道了") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        }
        .navigationViewStyle(.stack)
        .tint(theme.accent)
    }

    // MARK: - 列表

    private var list: some View {
        List {
            Section {
                ForEach(selectableSites) { site in
                    siteRow(site)
                }
            } footer: {
                Text("共 \(store.sites.count) 个源；导出的 JSON 可备份到「文件」或发给其他设备导入。")
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            if multiSelect {
                bottomBar
            }
        }
    }

    private func siteRow(_ site: VodSite) -> some View {
        let isSelected = selectedIDs.contains(site.id)
        return Button {
            toggle(site)
        } label: {
            HStack(spacing: 12) {
                if multiSelect {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? theme.accent : .white.opacity(0.3))
                } else if store.activeSiteID == site.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(site.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(site.api)
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if site.searchable {
                            Text("可搜索")
                                .font(.system(size: 10))
                                .foregroundColor(theme.accent.opacity(0.8))
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameTarget = site
                renameText = site.name
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                store.deleteSite(site.id)
            } label: {
                Label("删除这个源", systemImage: "trash")
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                showFileImporter = true
            } label: {
                Label("从文件导入", systemImage: "folder.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            Button(role: .destructive) {
                guard !selectedIDs.isEmpty else { return }
                showBulkDelete = true
            } label: {
                Label("删除选中(\(selectedIDs.count))", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
            }
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.background.opacity(0.95))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.white.opacity(0.28))
            Text("还没有点播源")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
            Button {
                showForm = true
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

    // MARK: - 动作

    private func toggle(_ site: VodSite) {
        if multiSelect {
            if selectedIDs.contains(site.id) {
                selectedIDs.remove(site.id)
            } else {
                selectedIDs.insert(site.id)
            }
        } else {
            store.selectSite(site.id)
        }
    }

    private func exportSites() {
        guard let data = store.exportSitesData() else { return }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("点播源配置.json")
        do {
            try data.write(to: temp, options: .atomic)
            shareFile = ShareFile(url: temp)
        } catch {
            importMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func handleImportFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            importMessage = "读取本地文件失败"
            return
        }

        Task {
            var parsed = VodStore.parseConfig(data: data, baseURL: nil)

            // 本地文件只是订阅指针（里面存着一个远程配置链接）时，拉一次远程配置再解析
            if parsed.added.isEmpty,
               let link = parsed.remoteSubscription ?? VodStore.subscriptionURL(in: data),
               let linkURL = URL(string: link),
               let (remoteData, response) = try? await URLSession.shared.data(from: linkURL),
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                let remote = VodStore.parseConfig(data: remoteData, baseURL: linkURL)
                parsed = ConfigImportResult(
                    added: parsed.added + remote.added,
                    crawlerSkipped: parsed.crawlerSkipped + remote.crawlerSkipped,
                    invalidSkipped: parsed.invalidSkipped + remote.invalidSkipped,
                    remoteSubscription: remote.remoteSubscription ?? parsed.remoteSubscription
                )
            }

            let added = store.importSites(parsed)
            var message = "已导入 \(added) 个站点"
            if parsed.crawlerSkipped > 0 { message += "；爬虫源跳过 \(parsed.crawlerSkipped) 个" }
            if parsed.invalidSkipped > 0 { message += "；无效地址跳过 \(parsed.invalidSkipped) 个" }
            if added == 0 && parsed.invalidSkipped == 0 && parsed.crawlerSkipped == 0 {
                message = "文件里没有识别到可用的接口地址；若这是加密或专用客户端备份，请把文件内容发我核对格式"
            }
            importMessage = message
        }
    }
}
