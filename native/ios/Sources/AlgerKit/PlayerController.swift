import AVFoundation
import Foundation

/// 播放控制器（AVPlayer）：队列 + 当前曲目 + 进度。
///
/// - **队列**：点一首歌 → 从它开始播；「下一首 / 上一首」在队列内移动；
/// - **本地文件**：下载完成后可直接播（file:// URL）；
/// - **后台播放**：iOS 侧配置 `AVAudioSession`（`.playback`），
///   App 退到后台仍继续播（Info.plist 需声明 `UIBackgroundModes: audio`）。
public final class PlayerController: ObservableObject {
    /// 当前播放曲目（远程或本地文件）。
    public struct NowPlaying: Equatable {
        public var title: String
        public var artist: String
        public var isLocal: Bool
        public var sourceLabel: String

        public static func == (lhs: NowPlaying, rhs: NowPlaying) -> Bool {
            lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.isLocal == rhs.isLocal
        }
    }

    /// 队列项（远程曲目或本地文件）。
    public enum QueueItem: Equatable {
        case remote(RemoteSong)
        case local(RemoteSong, url: URL)

        public var title: String {
            switch self {
            case .remote(let song): return song.name
            case .local(let song, _): return song.name
            }
        }

        public var artist: String {
            switch self {
            case .remote(let song): return song.artistText
            case .local(let song, _): return song.artistText
            }
        }
    }

    @Published public private(set) var queue: [QueueItem] = []
    @Published public private(set) var currentIndex: Int?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var nowPlaying: NowPlaying?
    @Published public private(set) var elapsed: Double = 0
    @Published public private(set) var duration: Double = 0

    private let player = AVPlayer()
    private var timeObserver: Any?
    /// 播放失败原因（如音源不可用）。
    @Published public private(set) var lastError: String?

    public init() {
        configureAudioSession()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.elapsed = time.seconds.isFinite ? time.seconds : 0
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            }
        }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
            self.playNext()
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 队列

    /// 从指定曲目开始播放（替换队列）。
    public func play(items: [QueueItem], startAt index: Int) {
        guard !items.isEmpty, items.indices.contains(index) else { return }
        queue = items
        currentIndex = index
        loadCurrent()
    }

    /// 播放单个远程曲目。
    public func play(song: RemoteSong) {
        play(items: [.remote(song)], startAt: 0)
    }

    /// 播放已下载的本地文件。
    public func playLocal(song: RemoteSong, url: URL) {
        play(items: [.local(song, url: url)], startAt: 0)
    }

    public func playNext() {
        guard let index = currentIndex else { return }
        if index + 1 < queue.count {
            currentIndex = index + 1
            loadCurrent()
        } else {
            stop()
        }
    }

    public func playPrevious() {
        guard let index = currentIndex, index > 0 else { return }
        currentIndex = index - 1
        loadCurrent()
    }

    public func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            guard player.currentItem != nil else { return }
            player.play()
            isPlaying = true
        }
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        nowPlaying = nil
        elapsed = 0
        duration = 0
        currentIndex = nil
    }

    // MARK: - 内部

    private func loadCurrent() {
        guard let index = currentIndex, queue.indices.contains(index) else { return }
        let item = queue[index]
        switch item {
        case .remote(let song):
            nowPlaying = NowPlaying(title: song.name, artist: song.artistText, isLocal: false, sourceLabel: "")
            // **远程地址解析是异步的**（桥接 src.resolve）：由上层解析后
            // 调用 `playResolved` 落地；这里只保留占位，避免误播。
            lastError = nil
        case .local(let song, let url):
            playResolved(url: url, song: song, sourceLabel: "本地文件")
        }
    }

    /// 播放已解析出的地址（远程 URL 或本地文件 URL）。
    public func playResolved(url: URL, song: RemoteSong, sourceLabel: String) {
        nowPlaying = NowPlaying(title: song.name, artist: song.artistText, isLocal: url.isFileURL, sourceLabel: sourceLabel)
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        lastError = nil
    }

    /// 播放失败提示（音源解析失败等）。
    public func reportError(_ message: String) {
        lastError = message
        isPlaying = false
    }

    // MARK: - 音频会话（iOS）

    private func configureAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // 音频会话失败不阻断界面：播放时仍会尝试。
        }
        #endif
    }
}
