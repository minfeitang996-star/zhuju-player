import SwiftUI

struct PlaybackSettingsView: View {

    @AppStorage("autoHideMenu") private var autoHideMenu: Bool = false
    @AppStorage("autoHideDelay") private var autoHideDelay: Double = 5
    @AppStorage("showElapsed") private var showElapsed: Bool = true
    @AppStorage("showClock") private var showClock: Bool = false
    @AppStorage("orientationPref") private var orientationPref: String = "landscape"
    @AppStorage("skipBack") private var skipBack: Double = 10
    @AppStorage("skipForward") private var skipForward: Double = 15
    @AppStorage("resumeEnabled") private var resumeEnabled: Bool = true
    @AppStorage("keepRate") private var keepRate: Bool = true
    @AppStorage("bgAudio") private var bgAudio: Bool = false

    @State private var cleared = false

    private let seconds: [Double] = [5, 10, 15, 20, 30, 60]

    var body: some View {
        Form {
            Section {
                Toggle("自动隐藏菜单", isOn: $autoHideMenu)
                if autoHideMenu {
                    Picker("隐藏延时", selection: $autoHideDelay) {
                        Text("3 秒").tag(3.0)
                        Text("5 秒").tag(5.0)
                        Text("10 秒").tag(10.0)
                    }
                }
                Toggle("显示已播放的时间", isOn: $showElapsed)
                Toggle("显示系统时间", isOn: $showClock)
            } header: {
                Text("界面")
            } footer: {
                Text("关掉「显示已播放的时间」就只显示总时长。")
            }

            Section {
                Picker("屏幕方向", selection: $orientationPref) {
                    Text("自动").tag("auto")
                    Text("竖屏").tag("portrait")
                    Text("横向全屏").tag("landscape")
                }
            } header: {
                Text("屏幕方向")
            } footer: {
                Text("选「横向全屏」后，一进播放页就自动横过来。")
            }

            Section {
                Picker("快退", selection: $skipBack) {
                    ForEach(seconds, id: \.self) { value in
                        Text("\(Int(value)) 秒").tag(value)
                    }
                }
                Picker("快进", selection: $skipForward) {
                    ForEach(seconds, id: \.self) { value in
                        Text("\(Int(value)) 秒").tag(value)
                    }
                }
            } header: {
                Text("快进快退")
            } footer: {
                Text("底部两个箭头按钮、以及画面上左右滑动，都按这里的秒数走。")
            }

            Section {
                Toggle("恢复播放（断点续播）", isOn: $resumeEnabled)
                Toggle("保持播放速率", isOn: $keepRate)
                Toggle("后台播放", isOn: $bgAudio)
            } header: {
                Text("视频播放")
            } footer: {
                Text("后台播放打开后，切到别的 App 声音继续。")
            }

            Section {
                Button(cleared ? "已清空" : "清空播放历史记录") {
                    Prefs.clearHistory()
                    cleared = true
                }
                .foregroundColor(.red)
            } footer: {
                Text("清空所有影片记住的播放位置。")
            }
        }
        .navigationTitle("播放")
        .navigationBarTitleDisplayMode(.inline)
    }
}
