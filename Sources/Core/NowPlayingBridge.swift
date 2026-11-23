import Foundation
import MediaPlayer

/// 锁屏 / 控制中心信息与远程命令桥接。
/// 信息（片名、时长、进度、倍速、播放状态）由播放器定时回写；
/// 命令（播放暂停、上下一集、快进快退、按位置跳转）由 PlayerScreen 接入对应回调。
final class NowPlayingBridge {

    static let shared = NowPlayingBridge()

    var onTogglePlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSkipForward: (() -> Void)?
    var onSkipBackward: (() -> Void)?
    var onSeekTo: ((TimeInterval) -> Void)?

    private var title: String = ""
    private var duration: TimeInterval = 0
    private var current: TimeInterval = 0
    private var rate: Float = 1.0
    private var playing: Bool = false

    private init() {
        configureCommands()
    }

    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.onTogglePlayPause?()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.onTogglePlayPause?()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onTogglePlayPause?()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNext?()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPrevious?()
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.onSkipForward?()
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.onSkipBackward?()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onSeekTo?(e.positionTime)
            return .success
        }
    }

    func setTitle(_ name: String) {
        title = name
        publish()
    }

    /// 播放器定时回写状态。
    func tick(playing: Bool, current: TimeInterval, duration: TimeInterval, rate: Float) {
        self.playing = playing
        self.current = current
        self.duration = duration
        self.rate = rate
        publish()
    }

    private func publish() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        if duration > 1 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = current
            info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? Double(rate) : 0
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 只清锁屏信息（切集 / 换片时用，回调保留，远程命令继续可用）
    func clearInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// 退出播放页：清空锁屏信息并摘掉回调。
    func clear() {
        clearInfo()
        onTogglePlayPause = nil
        onNext = nil
        onPrevious = nil
        onSkipForward = nil
        onSkipBackward = nil
        onSeekTo = nil
    }
}
