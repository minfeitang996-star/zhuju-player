import SwiftUI

/// 设置 →「手势与操作」：手势开关、双击播放/暂停、长按快进、自动播下一集
struct GestureSettingsView: View {

    @AppStorage("gestureEnabled") private var gestureEnabled: Bool = true
    @AppStorage("gestureDoubleTap") private var gestureDoubleTap: Bool = true
    @AppStorage("gestureDoubleTapPlay") private var gestureDoubleTapPlay: Bool = true
    @AppStorage("longPressSkip") private var longPressSkip: Bool = true
    @AppStorage("longPressSeconds") private var longPressSeconds: Double = 10
    @AppStorage("autoNext") private var autoNext: Bool = true
    @AppStorage("scrubSeconds") private var scrubSeconds: Double = 240
    @AppStorage("holdBoostEnabled") private var holdBoostEnabled: Bool = true
    @AppStorage("holdBoostRate") private var holdBoostRate: Double = 2.0

    private let pressSeconds: [Double] = [10, 20, 30]
    private let boostRates: [Double] = [1.5, 2.0, 3.0]

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
                Text("左侧上下滑调亮度，右侧上下滑调音量（手机系统音量，跟侧边按键同步），左右横滑快进快退，双击画面播放/暂停，长按画面快进固定秒数。\n影视点播播放器同样支持左右横滑快进快退，横滑灵敏度用下面「横滑定位」里的档位一起调。")
            }

            Section {
                Toggle("按住临时加速", isOn: $holdBoostEnabled)
                if holdBoostEnabled {
                    Picker("加速倍率", selection: $holdBoostRate) {
                        ForEach(boostRates, id: \.self) { value in
                            Text(String(format: "%g×", value)).tag(value)
                        }
                    }
                }
            } header: {
                Text("按住倍速")
            } footer: {
                Text("播放控制栏的兔子键：按住临时提速，松开自动回到原来的倍速。")
            }

            Section {
                Picker("横滑一屏进度", selection: $scrubSeconds) {
                    Text("2 分钟").tag(120.0)
                    Text("4 分钟").tag(240.0)
                    Text("6 分钟").tag(360.0)
                    Text("10 分钟").tag(600.0)
                }
            } header: {
                Text("横滑定位")
            } footer: {
                Text("左右滑满整个屏幕对应的跳转秒数；片长很长就调大，短片调小更好拖。")
            }

            Section {
                Toggle("自动播下一集", isOn: $autoNext)
            } header: {
                Text("连播")
            } footer: {
                Text("一个视频播完后，自动播同文件夹里按名称排在下一位的那个视频。最后一个播完就停住，不会跳别的文件夹。")
            }

            Section {
                Text("屏幕方向在「播放设置 → 屏幕方向」里选：横屏 / 竖屏 / 自动。")
                    .font(.system(size: 12))
            } header: {
                Text("屏幕方向")
            }
        }
        .navigationTitle("手势与操作")
        .navigationBarTitleDisplayMode(.inline)
    }
}
