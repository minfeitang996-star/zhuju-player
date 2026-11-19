import SwiftUI

struct VideoSettingsView: View {

    @AppStorage("videoMode") private var videoMode: String = "fill"
    @AppStorage("videoSafeArea") private var videoSafeArea: Bool = false
    @AppStorage("aspectOverride") private var aspectOverride: String = "default"
    @AppStorage("hwDecode") private var hwDecode: String = "auto"
    @AppStorage("deinterlace") private var deinterlace: Bool = false
    @AppStorage("subScale") private var subScale: Double = 110

    var body: some View {
        Form {
            Section {
                Picker("缩放模式", selection: $videoMode) {
                    Text("适合").tag("fit")
                    Text("填充").tag("fill")
                    Text("拉伸").tag("stretch")
                }
                Toggle("避开刘海与底部横条（Safe Area）", isOn: $videoSafeArea)
            } header: {
                Text("画面缩放")
            } footer: {
                Text("「填充」会铺满屏幕并裁掉一点点边；「适合」保留完整画面但可能留黑边。")
            }

            Section {
                Picker("长宽比", selection: $aspectOverride) {
                    Text("默认（按片源）").tag("default")
                    Text("16:9").tag("16:9")
                    Text("4:3").tag("4:3")
                    Text("1:1").tag("1:1")
                    Text("21:9").tag("21:9")
                }
            } header: {
                Text("长宽比")
            } footer: {
                Text("片源比例不对（比如变形画面）时，强制成这里选的比例。")
            }

            Section {
                Picker("硬件解码", selection: $hwDecode) {
                    Text("自动").tag("auto")
                    Text("只走硬件").tag("hw")
                    Text("只走软件").tag("sw")
                }
                Toggle("去隔行", isOn: $deinterlace)
            } header: {
                Text("解码")
            } footer: {
                Text("硬解更省电；某些老片源花屏就切软件解。隔行扫描的旧片（DVD/电视录制）打开去隔行更干净。")
            }

            Section {
                HStack {
                    Text("字幕大小")
                    Spacer()
                    Text("\(Int(subScale))%").foregroundColor(.secondary)
                }
                Slider(value: $subScale, in: 70...200, step: 5)
            } header: {
                Text("字幕")
            } footer: {
                Text("下一次打开视频生效。")
            }
        }
        .navigationTitle("视频")
        .navigationBarTitleDisplayMode(.inline)
    }
}
