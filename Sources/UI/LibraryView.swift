import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {

    @EnvironmentObject private var library: MediaLibrary

    @State private var showImporter = false
    @State private var showSettings = false
    @State private var selected: MediaItem?
    @State private var importErrors: String?
    @State private var showErrors = false

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.07).ignoresSafeArea()

                if library.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("糖敏飞视频播放器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImporter = true } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
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
            .fullScreenCover(item: $selected, onDismiss: { library.reload() }) { item in
                PlayerScreen(item: item)
                    .environmentObject(library)
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { Boot.mark("C library.view") }
    }

    private var list: some View {
        List {
            if let resume = resumeItem {
                Button {
                    selected = resume
                } label: {
                    resumeRow(resume)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color(red: 1.0, green: 0.72, blue: 0.25).opacity(0.16))
            }

            ForEach(library.items) { item in
                Button {
                    selected = item
                } label: {
                    row(item)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.white.opacity(0.06))
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let item = library.items[index]
                    if UserDefaults.standard.string(forKey: "lastMedia") == item.url.lastPathComponent {
                        UserDefaults.standard.removeObject(forKey: "lastMedia")
                    }
                    UserDefaults.standard.removeObject(forKey: "resume:\(item.url.lastPathComponent)")
                    UserDefaults.standard.removeObject(forKey: "done:\(item.url.lastPathComponent)")
                    library.delete(item)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { library.reload() }
    }

    /// 单个视频看过的进度：0.02~0.98 是有进度，1.0 是已看完
    private func progress(for item: MediaItem) -> Double? {
        let name = item.url.lastPathComponent
        if UserDefaults.standard.bool(forKey: "done:\(name)") { return 1.0 }
        let saved = UserDefaults.standard.double(forKey: "resume:\(name)")
        return (saved > 0.02 && saved < 0.98) ? saved : nil
    }

    /// 上次没看完的那一部（跨启动记忆播放）
    private var resumeItem: MediaItem? {
        guard Prefs.resumeEnabled else { return nil }
        guard let name = UserDefaults.standard.string(forKey: "lastMedia") else { return nil }
        guard let item = library.items.first(where: { $0.url.lastPathComponent == name }) else { return nil }
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
            Text("还没有视频")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
            Text("从「文件」里导入，或者用电脑把视频放进\n「文件 App → 我的 iPhone → 糖敏飞视频播放器 → Media」")
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

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importErrors = error.localizedDescription
            showErrors = true
        case .success(let urls):
            let failures = library.importFiles(urls)
            if !failures.isEmpty {
                importErrors = failures.joined(separator: "\n")
                showErrors = true
            }
        }
    }
}
