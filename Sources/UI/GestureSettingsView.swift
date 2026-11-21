import SwiftUI

/// 设置 →「手势与操作」：手势开关、双击播放/暂停、长按快进、自动播下一集、锁方向按钮
struct GestureSettingsView: View {

    @AppStorage("gestureEnabled") private var gestureEnabled: Bool = true
    @AppStorage("gestureDoubleTap") private var gestureDoubleTap: Bool = true
    @AppStorage("gestureDoubleTapPlay") private var gestureDoubleTapPlay: Bool = true
    @AppStorage("longPressSkip") private var longPressSkip: Bool = true
    @AppStorage("longPressSeconds") private var longPressSeconds: Double = 10
    @AppStorage("autoNext") private var autoNext: Bool = true
    @AppStorage("showOrientationLock") private var showOrientationLock: Bool = true

    private let pressSeconds: [Double] = [10, 20, 30]

    var body: some View {
        Form {
            Section {
                Toggle("启用手势控制", isOn: $gestureEnabled)
                Toggle("双击画面播放 / 暂停", isOn: $gestureDoubleTapPlay)
                    .disabled(!gestureEnabled)
                Toggle("长按画面快进", isOn: $longPressSkip)
                    .disabled(!gestureEnabled)
                if longPressSkip {
                    Picker("长按快进秒数", selection: $longPressSeconds) {
                        ForEach(pressSeconds, id: \.self) { value in
                            Text("\(Int(value)) 秒").tag(value)
                        }
                    }
                    .disabled(!gestureEnabled)
                }
            } header: {
                Text("手势")
            } footer: {
                Text("左侧上下滑调亮度，右侧上下滑调音量（手机系统音量，跟侧边按键同步），左右横滑快进快退，双击画面播放/暂停，长按画面快进固定秒数。")
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
