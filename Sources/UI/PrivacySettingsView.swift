import SwiftUI

struct PrivacySettingsView: View {

    private struct LockedFolder: Identifiable {
        let id: String
        let url: URL
    }

    @AppStorage("privacyLockEnabled") private var enabled: Bool = true
    @State private var folders: [LockedFolder] = []
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                Toggle("启用文件夹加密", isOn: $enabled)
                HStack {
                    Text("解锁方式")
                    Spacer()
                    Text(BiometricAuth.biometryName)
                        .foregroundColor(.secondary)
                }
                if !BiometricAuth.canAuthenticate() {
                    Text("这台设备还没设置面容或密码，去「设置 → 面容 ID 与密码」里设一个。")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            } header: {
                Text("加密")
            } footer: {
                Text("进入加密文件夹时先验证：\(BiometricAuth.biometryName)优先，识别不出来会自动让你输入设备密码。App 退到后台再回来会重新上锁。")
            }

            Section {
                if folders.isEmpty {
                    Text("还没有加密的文件夹。回首页长按文件夹，选「加密这个文件夹」。")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(folders) { folder in
                        HStack(spacing: 10) {
                            Image(systemName: "lock.fill")
                                .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.25))
                            Text(folder.id)
                                .font(.system(size: 14))
                            Spacer()
                            Button("解除") {
                                unlock(folder.url)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("已加密的文件夹")
            } footer: {
                Text("解除加密需要先通过面容或设备密码验证。")
            }
        }
        .navigationTitle("隐私保护")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .alert("验证未通过", isPresented: $failed) {
            Button("好", role: .cancel) { }
        } message: {
            Text("没通过验证，文件夹保持加密状态。")
        }
    }

    private func reload() {
        folders = FolderLock.lockedFolders.map { LockedFolder(id: $0.name, url: $0.url) }
    }

    private func unlock(_ url: URL) {
        Task {
            let passed = await BiometricAuth.authenticate(reason: "解除「\(url.lastPathComponent)」加密")
            await MainActor.run {
                if passed {
                    FolderLock.setLocked(url, false)
                    reload()
                } else {
                    failed = true
                }
            }
        }
    }
}
