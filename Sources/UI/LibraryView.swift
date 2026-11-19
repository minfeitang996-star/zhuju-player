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
            .navigationTitle("逐句")
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
            .fullScreenCover(item: $selected) { item in
                PlayerScreen(item: item)
                    .environmentObject(library)
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { Boot.mark("C library.view") }
    }

    private var list: some View {
        List {
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
                    library.delete(library.items[index])
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { library.reload() }
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
            Text("从「文件」里导入，或者用电脑把视频放进\n「文件 App → 我的 iPhone → 逐句 → Media」")
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
