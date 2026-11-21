import SwiftUI

/// 设置 →「手势与操作」：手势开关、双击动作、自动播下一集、锁方向按钮
struct GestureSettingsView: View {

    @AppStorage("gestureEnabled") private var gestureEnabled: Bool = true
    @AppStorage("gestureDoubleTap") private var gestureDoubleTap: Bool = true
    @AppStorage("gestureDoubleTapPlay") private var gestureDoubleTapPlay: Bool = true
    @AppStorage("gestureDoubleTapSeek") private var gestureDoubleTapSeek: Bool = true
    @AppStorage("doubleTapSeconds") private var doubleTapSeconds: Double = 10
    @AppStorage("autoNext") private var autoNext: Bool = true
    @AppStorage("showOrientationLock") private var showOrientationLock: Bool = true

    private let tapSeconds: [Double] = [5, 10, 15, 20, 30]

    var body: some View {
        Form {
            Section {
                Toggle("启用手势控制", isOn: $gestureEnabled)
                Toggle("双击画面播放 / 暂停", isOn: $gestureDoubleTapPlay)
                    .disabled(!gestureEnabled)
                Toggle("双击左右两侧快退 / 快进", isOn: $gestureDoubleTapSeek)
                    .disabled(!gestureEnabled)
                if gestureDoubleTapSeek {
                    Picker("双击跳转秒数", selection: $doubleTapSeconds) {
                        ForEach(tapSeconds, id: \.self) { value in
                            Text("\(Int(value)) 秒").tag(value)
                        }
                    }
                    .disabled(!gestureEnabled)
                }
            } header: {
                Text("手势")
            } footer: {
                Text("左侧上下滑调亮度，右侧上下滑调音量，左右横滑快进快退，双击画面中间播放/暂停，双击左侧快退、右侧快进。")
            }

            Section {
                Toggle("自动播下一集", isOn: $autoNext)
            } header: {
                Text("连播")
            } footer: {
                Text("一个视频播完后，自动播同文件夹里按名称排在下一位的那个视频。最后一个播完就停住，不会跳别的文件夹。")
            }

            Section {
                Toggle("显示锁方向按钮", isOn: $showOrientationLock)
            } header: {
                Text("屏幕方向")
            } footer: {
                Text("打开后播放页控制栏会多一个锁形按钮，点一下锁定当前方向，再点一下恢复自动旋转（跟随「播放设置」里的屏幕方向）。")
            }
        }
        .navigationTitle("手势与操作")
        .navigationBarTitleDisplayMode(.inline)
    }
}
