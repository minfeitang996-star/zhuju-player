import SwiftUI

/// 网络直播源管理：手动添加单条流地址，或粘贴 m3u / m3u8 列表一次性导入
struct LiveSourceView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LiveSourceStore.shared
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @State private var showAdd = false
    @State private var editing: LiveChannel?
    @State private var active: LiveChannel?

    var body: some View {
        NavigationView {
            ZStack {
                theme.background.ignoresSafeArea()

                if store.channels.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.channels) { channel in
                            HStack(spacing: 8) {
                                channelRow(channel)

                                Menu {
                                    Button {
                                        editing = channel
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        store.delete(channel.id)
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
                            .onTapGesture { active = channel }
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
                                    store.delete(channel.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.delete(channel.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("网络直播")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(theme.accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                LiveSourceForm(mode: .single, existing: nil)
            }
            .sheet(item: $editing) { channel in
                LiveSourceForm(mode: .edit, existing: channel)
            }
            .fullScreenCover(item: $active) { channel in
                LiveStreamPlayer(channel: channel)
            }
        }
        .navigationViewStyle(.stack)
        .tint(theme.accent)
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
                Text(channel.group ?? channel.url)
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 104, height: 104)
                Image(systemName: "tv")
                    .font(.system(size: 42, weight: .light))
                    .foregroundColor(.white.opacity(0.28))
            }
            Text("还没有直播源")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
            Text("添加一条直播地址，或导入 m3u / m3u8 频道列表，VLC 内核直接拉流播放。")
                .font(.system(size: 13))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.45))
            Button {
                showAdd = true
            } label: {
                Text("添加直播源")
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
}

/// 添加 / 编辑直播源表单
private struct LiveSourceForm: View {

    enum FormMode {
        case single
        case m3u
        case edit
    }

    let mode: FormMode
    let existing: LiveChannel?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LiveSourceStore.shared
    @AppStorage("themeID") private var themeID: String = "gold"
    private var theme: AppTheme { AppTheme.current(themeID) }

    @State private var name = ""
    @State private var url = ""
    @State private var m3uURL = ""
    @State private var formMode: FormMode = .single
    @State private var importing = false
    @State private var resultText: String?
    @State private var errorText: String?

    private var isEdit: Bool { existing != nil }

    var body: some View {
        NavigationView {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        if !isEdit {
                            modePicker
                        }

                        if isEdit || formMode == .single {
                            singleSection
                        } else {
                            m3uSection
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(isEdit ? "编辑直播源" : "添加直播源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isEdit || formMode == .single {
                        Button("保存") { saveSingle() }
                            .disabled(!LiveSourceStore.isValidURL(url))
                    }
                }
            }
            .onAppear {
                formMode = mode
                if let existing {
                    name = existing.name
                    url = existing.url
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(theme.accent)
    }

    private var modePicker: some View {
        Picker("方式", selection: Binding(
            get: { formMode == .m3u ? 1 : 0 },
            set: { formMode = $0 == 1 ? .m3u : .single }
        )) {
            Text("单条链接").tag(0)
            Text("m3u 列表").tag(1)
        }
        .pickerStyle(.segmented)
    }

    private var singleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("频道名称")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            TextField("例如：央视新闻", text: $name)
                .padding(14)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("直播地址")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            TextField("http / https / rtsp / rtmp / udp / m3u8", text: $url)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(14)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let errorText {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
        }
    }

    private var m3uSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("m3u / m3u8 地址")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            TextField("粘贴播放列表链接", text: $m3uURL)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(14)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                Task { await importM3U() }
            } label: {
                HStack(spacing: 8) {
                    if importing {
                        ProgressView().tint(.black)
                    }
                    Text(importing ? "正在拉取…" : "拉取并导入")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(theme.accent)
                .foregroundColor(.black)
                .clipShape(Capsule())
            }
            .disabled(importing || !LiveSourceStore.isValidURL(m3uURL))

            if let resultText {
                Text(resultText)
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.45, green: 0.85, blue: 0.55))
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }

            Text("支持标准 #EXTINF 格式，分组标题会一并保留；导入后可在列表里逐条删除或编辑。")
                .font(.system(size: 11.5))
                .lineSpacing(4)
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func saveSingle() {
        if let existing {
            store.update(existing.id, name: name, url: url)
        } else {
            store.add(name: name, url: url)
        }
        dismiss()
    }

    private func importM3U() async {
        importing = true
        errorText = nil
        resultText = nil
        do {
            guard let url = URL(string: m3uURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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
                LiveChannel(id: UUID(), name: $0.name, url: $0.url, group: $0.group)
            }
            await MainActor.run {
                store.add(channels)
                resultText = "已导入 \(channels.count) 个频道"
                importing = false
            }
        } catch {
            await MainActor.run {
                errorText = error.localizedDescription
                importing = false
            }
        }
    }
}
