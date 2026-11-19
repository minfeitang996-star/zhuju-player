# 逐句 ZhuJu

iPhone 本地视频播放器 + 语音自动出中文字幕。iOS 17.0 / TrollStore（巨魔）可以直接装。

- 播放内核：VLCKit，mp4 / mov / mkv / avi / flv / wmv / ts / webm / rmvb / mpg / vob 等全支持
- 识别内核：whisper.cpp（编译进 App，完全离线，多语言自动检测）
- 翻译：OpenAI 兼容接口（DeepSeek / 月之暗面 / 通义 / OpenAI 都能填），也可关掉只出原文
- 字幕：生成同名 `.srt` 放在视频旁边，VLC 内核自动加载，字幕大小可调

## 怎么出 IPA（不需要 Mac）

编译交给 GitHub Actions 的 macOS 机器，你只负责推代码。

### 1. 建仓库

1. 打开 GitHub Desktop → `File` → `Add Local Repository…`
2. 选中这个 `ZhuJu` 文件夹
3. 如果提示不是仓库，点 `create a repository`，然后 `Publish repository`
4. **仓库必须设为 Public**（公开仓库的 Actions 分钟数不花钱；私有仓库 macOS 机器每月只有 200 分钟，不够跑）

### 2. 等云端编译

推上去后打开仓库的 `Actions` 页：

1. 找到 `Build TrollStore IPA` 工作流，等它跑完
2. 第一次会先编译 `whisper.xcframework`，整体约 20–35 分钟
3. 绿勾之后，点进这次运行，页面底部 `Artifacts` 里下载 **ZhuJu-ipa**
4. 解压得到 `ZhuJu.ipa`

跑红了的话，下载 `build-log` 这个 artifact，把里面的 `build.log` 发我，我按报错改。

### 3. 装到手机

1. 把 `ZhuJu.ipa` 传到 iPhone（微信/QQ 发给自己 → 在「文件」App 里存到「我的 iPhone」）
2. 在「文件」App 里点这个 ipa → 分享 → 选 **TrollStore**（巨魔）
3. 巨魔里点 `Install`，装完桌面出现「逐句」

> 需要 iOS ≤ 17.0（TrollStore 2 的上限）。17.0.1 以后没有 CoreTrust 漏洞，装不了。

### 4. 首次使用

1. 右上角齿轮 → 下载识别模型：先拿 **base（142 MB）**，觉得不够准再换 small
2. 同一个设置页填翻译接口：Base URL + 模型名 + API Key
3. 回列表点 `+` 导入视频，或者电脑上把视频丢进「文件 App → 我的 iPhone → 逐句 → Media」
4. 进播放页，右上角「生成字幕」→ 选模型和语言 → 开始

## 已知限制

- **MKV / AVI / RMVB 生成字幕要先转码音轨**：系统框架打不开这些容器，只能让 VLC 把音轨转成 m4a，速度是实时的，2 小时片子就要 2 小时。mp4 / mov / m4v 直接抽音轨，几十秒搞定。建议常用格式先转 mp4。
- 模型是逐窗（50 秒）识别的，跨窗口的上下文会断一下，长片偶有断句跳变。
- 首次启动没有图标（后面补）。

## 目录

```
project.yml             XcodeGen 工程描述（CI 里生成 .xcodeproj）
Podfile                 VLCKit
Sources/Core/           播放/识别/翻译/字幕核心逻辑
Sources/UI/             SwiftUI 界面
.github/workflows/      云端编译 IPA
tools/                  本地语法自检脚本（不影响构建）
```

## 本地改完想自检

```
python tools/swift_syntax_check.py Sources
```

只查语法树，不做类型检查；类型问题只能靠云端编译暴露。
