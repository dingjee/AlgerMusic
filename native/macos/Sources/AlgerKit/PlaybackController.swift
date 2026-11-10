import Foundation
import AVFoundation

/// 队列中的一项（本地文件或网络曲目）。
public struct PlaybackItem: Identifiable, Equatable {
    /// 来源。
    public enum Origin: Equatable {
        /// 本地文件（绝对路径）。
        case local(path: String)
        /// 网络曲目（网易云 ID）。
        case remote(neteaseId: Int64)
    }

    /// 队列内稳定标识。
    public var id: String {
        switch origin {
        case .local(let path): return "path:\(path)"
        case .remote(let neteaseId): return "netease:\(neteaseId)"
        }
    }

    /// 每次入队的独立身份，撤回添加时不误删同曲目的旧队列项。
    public let queueEntryId = UUID()
    public var title: String
    public var artist: String
    public var album: String
    public var durationMs: Int64
    public var origin: Origin
    /// 网络曲目的完整数据（解析播放地址 / 编辑远程歌单时用）。
    public var remoteSong: RemoteSong?

    public init(
        title: String,
        artist: String,
        album: String = "",
        durationMs: Int64 = 0,
        origin: Origin,
        remoteSong: RemoteSong? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.origin = origin
        self.remoteSong = remoteSong
    }

    /// 本地文件条目。
    public static func local(_ track: TrackRecord) -> PlaybackItem {
        PlaybackItem(
            title: track.title.isEmpty ? URL(fileURLWithPath: track.path).lastPathComponent : track.title,
            artist: track.artist,
            album: track.album,
            durationMs: Int64(track.durationMs),
            origin: .local(path: track.path),
            remoteSong: nil
        )
    }

    /// 网络条目。
    public static func remote(_ song: RemoteSong) -> PlaybackItem {
        PlaybackItem(
            title: song.name,
            artist: song.artistText,
            album: song.album.name,
            durationMs: song.durationMs,
            origin: .remote(neteaseId: song.id),
            remoteSong: song
        )
    }

    /// 是否是网络曲目。
    public var isRemote: Bool {
        if case .remote = origin { return true }
        return false
    }
}

/// 解析出来的播放来源。
public struct PlaybackSource: Equatable {
    /// 实际播放的地址。
    public var url: URL
    /// 是否命中本地文件。
    public var isLocal: Bool
    /// 提示（例如「官方链接不可用，已回退第三方音源」）。
    public var note: String?

    public init(url: URL, isLocal: Bool, note: String? = nil) {
        self.url = url
        self.isLocal = isLocal
        self.note = note
    }
}

/// 播放地址解析器（**本地优先**：有本地文件就播本地，没有才走网络）。
public protocol PlaybackResolving: AnyObject {
    func resolve(_ item: PlaybackItem) async throws -> PlaybackSource
}

/// 播放控制器（AVFoundation）。
///
/// 约定：
/// - **本地优先**：网络曲目先查本地索引，命中本地文件就直接播本地；
/// - 暂停 / 续播 / 跳过 / seek 全部走同一个 `AVPlayer`；
/// - 播放地址解析失败 **明确报错**，不静默跳过；
/// - 「完整在线播放」只在自然播完时回调一次（跳过 / 拖到结尾不计数）。
@MainActor
public final class PlayerController: ObservableObject {

    // MARK: - 对外状态

    /// 播放队列。
    @Published public private(set) var queue: [PlaybackItem] = []
    /// 当前曲目下标（nil = 没有当前曲目）。
    @Published public private(set) var currentIndex: Int?
    /// 当前曲目。
    @Published public private(set) var current: PlaybackItem?
    /// 是否正在播放。
    @Published public private(set) var isPlaying = false
    /// 当前播放位置（秒）。
    @Published public private(set) var currentTime: Double = 0
    /// 总时长（秒；未知为 0）。
    @Published public private(set) var duration: Double = 0
    /// 是否正在解析播放地址。
    @Published public private(set) var isResolving = false
    /// 当前播放来源说明（本地 / 网络 + 音源）。
    @Published public private(set) var sourceDescription: String = ""
    /// 播放顺序模式（顺序 / 随机）。
    ///
    /// 随机模式下 `queue` 的 **显示顺序不变**，只是播放顺序被打乱
    /// （队列界面仍然按加入顺序显示，随机只影响「下一首是谁」）。
    @Published public private(set) var playbackOrder: PlaybackOrder = .ordered
    /// 明确的错误信息（解析失败 / 播放失败）。
    @Published public var errorMessage: String?
    /// 自然播完（**实际播的是网络流**的网络曲目）时回调，供播放计数使用。
    ///
    /// 本地文件播放、网络曲目本地优先命中本地文件的播放都 **不回调**。
    public var onCompletedRemotePlay: ((PlaybackItem) -> Void)?
    /// 队列耗尽回调（**队列末尾且没有下一首**时触发一次）。
    ///
    /// - 普通顺序 / 随机播放：**不消费**这个回调（行为完全不变）；
    /// - 私人 FM：**消费**它（取下一批并自动接播）。
    public var onQueueExhausted: (() -> Void)?
    /// 队列耗尽时 **由外部接管续播**（私人 FM：取下一批并接播）。
    ///
    /// - true：`next()` 走到队列末尾时 **先报耗尽**，
    ///   **不**重开一轮普通随机播放（FM 的下一批由外部接上）；
    /// - false（默认）：普通行为（随机模式重开一轮）。
    public var continuesOnExhaustion: Bool = false
    /// 用户主动暂停回调（**「暂停」按钮 / `pause()`**）。
    ///
    /// 私人 FM 用它保护用户的暂停：**取批途中用户按了暂停，就不自动接播**。
    public var onUserPause: (() -> Void)?

    // MARK: - 内部

    private let player = AVPlayer()
    private let resolver: PlaybackResolving
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    /// 当前播放项的状态观察（加载失败要报错，不能假装还在播放）。
    private var itemStatusObservation: NSKeyValueObservation?
    /// 当前这一项是否已经计过完整播放（一次播放最多计一次）。
    private var countedCurrentItem = false
    /// 本次播放 **不再计数**（用户拖过进度 / 停止 / 换了曲目）。
    private var suppressCompletionCount = false
    /// 当前加载的地址（用于判断是否需要重建播放项）。
    private var loadedURL: URL?
    /// 当前这一项是不是 **本地文件** 命中（网络曲目也可能本地优先命中本地文件）。
    private var loadedIsLocal = false
    /// 解析代次：**快速切歌** 时旧解析结果不得覆盖新曲目。
    private var resolutionGeneration = 0
    /// 随机播放序列（`queue` 下标的排列）。
    private var shuffleOrder: [Int] = []
    /// 当前曲目在 `shuffleOrder` 里的位置（nil = 不在随机序列中）。
    private var shuffleCursor: Int?
    /// 本轮已经播过的曲目（队列下标）。
    ///
    /// **一轮 = 队列里的每一首各播一次**：随机模式下 `next` 只挑 **没播过** 的，
    /// 因此从哪一首开始都能把整张歌单走完，然后才停。
    private var shuffleVisited: Set<Int> = []
    /// 随机序列的随机源种子（**每次启动随机**，测试可注入固定值）。
    private var shuffleSeed: UInt64 = UInt64.random(in: 0..<UInt64.max)

    /// 当前 **实际播放** 的本地文件路径（nil = 当前不是本地文件）。
    ///
    /// 网络曲目 **本地优先** 命中时也会返回本地路径 ——
    /// 删除本地文件前必须用它判断「正在播的是不是这个文件」。
    public var currentLocalPath: String? {
        guard loadedIsLocal, let loadedURL else { return nil }
        return loadedURL.isFileURL ? loadedURL.path : nil
    }

    /// 当前实际播放的地址（诊断用）。
    public var currentLoadedURL: URL? { loadedURL }

    /// 如果 **正在播放的本地文件** 就是这个路径 → 停止播放。
    ///
    /// - Returns: 是否因此停止了播放。
    @discardableResult
    public func stopIfPlayingLocalFile(path: String) -> Bool {
        guard let current = currentLocalPath else { return false }
        guard current == path else { return false }
        stopPlayback()
        return true
    }

    /// 当前 `AVPlayerItem`（测试用：触发「播放到结尾」通知）。
    var currentPlayerItem: AVPlayerItem? { player.currentItem }

    public init(resolver: PlaybackResolving) {
        self.resolver = resolver
        installObservers()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        itemStatusObservation?.invalidate()
    }

    // MARK: - 队列

    /// 替换队列并从指定位置开始播放。
    public func replaceQueue(_ items: [PlaybackItem], startAt index: Int = 0) async {
        queue = items
        guard !items.isEmpty else {
            currentIndex = nil
            current = nil
            resetShuffleRound()
            stopPlayback()
            return
        }
        // 随机模式下先重建整轮的排列，再从 **选中的那一首** 开始：
        // 选中曲目在排列里的位置决定这一轮从哪里开始，但 **整轮仍覆盖全部曲目**
        // （`next` 会绕回排列前面继续找没播过的）。
        currentIndex = nil
        rebuildShuffleRound()
        await play(at: min(max(0, index), items.count - 1))
    }

    /// 追加到队列末尾。
    public func enqueue(_ items: [PlaybackItem]) {
        guard !items.isEmpty else { return }
        queue.append(contentsOf: items)
        // 追加不会改变已有下标 → 已播过的记录继续有效，只重建排列。
        rebuildShuffleRound(keepingVisited: true)
    }

    /// 清空队列（同时停止播放）。
    public func clearQueue() {
        queue = []
        currentIndex = nil
        current = nil
        resetShuffleRound()
        stopPlayback()
    }

    /// 从队列移除某一项。
    ///
    /// 移除 **正在播放** 的项 → 停止播放并清空当前项；
    /// 移除当前项 **之前** 的项 → 当前下标跟着前移。
    public func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
        if let currentIndex {
            if index == currentIndex {
                self.currentIndex = nil
                current = nil
                resetShuffleRound()
                stopPlayback()
            } else if index < currentIndex {
                self.currentIndex = currentIndex - 1
            }
        }
        // 移除会让下标整体前移 → 已播过的记录不再可靠，重新开一轮。
        rebuildShuffleRound()
    }

    @discardableResult
    public func removeQueueEntry(id: UUID) -> Bool {
        guard let index = queue.firstIndex(where: { $0.queueEntryId == id }) else { return false }
        removeFromQueue(at: index)
        return true
    }

    /// 播放队列中的某一项。
    public func play(at index: Int) async {
        guard queue.indices.contains(index) else { return }
        // 换曲：作废上一次还没回来的解析结果。
        resolutionGeneration += 1
        currentIndex = index
        current = queue[index]
        countedCurrentItem = false
        suppressCompletionCount = false
        // 随机模式下记录「当前这一首在随机序列里的位置」并标记为已播。
        syncShuffleCursor(with: index)
        if playbackOrder == .shuffle { shuffleVisited.insert(index) }
        // **立刻停掉旧声音**：解析新地址期间旧音频继续播会让
        // 「听到的」与「界面显示的」不一致（旧声 / 新 UI 不一致）。
        detachCurrentItem()
        await startCurrentItem()
    }

    /// 脱离当前播放项（**停止发声**，不保留旧播放状态）。
    private func detachCurrentItem() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        loadedURL = nil
        loadedIsLocal = false
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    /// 播放指定曲目（不在队列里时先入队）。
    public func play(_ item: PlaybackItem) async {
        if let index = queue.firstIndex(where: { $0.id == item.id }) {
            await play(at: index)
            return
        }
        queue.append(item)
        rebuildShuffleRound(keepingVisited: true)
        await play(at: queue.count - 1)
    }

    // MARK: - 传输控制

    /// 暂停 / 继续。
    public func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
            onUserPause?()
        } else {
            guard current != nil else { return }
            player.play()
            isPlaying = true
        }
    }

    /// 暂停。
    public func pause() {
        player.pause()
        isPlaying = false
        onUserPause?()
    }

    /// 继续。
    public func resume() {
        guard current != nil else { return }
        player.play()
        isPlaying = true
    }

    /// 下一首（队列末尾 → 停止）。
    ///
    /// - 顺序模式：下一项；
    /// - 随机模式：随机序列里 **下一首没播过** 的（**一轮里每首各播一次**；
    ///   本轮播完后再按「下一首」会 **重新开一轮**）；
    /// - 队列末尾：**停止并通知队列耗尽**（私人 FM 用它取下一批；
    ///   普通播放不消费这个回调，行为不变）。
    public func next() {
        guard let index = currentIndex else {
            stopPlayback()
            return
        }
        // **外部接管续播时（私人 FM）先识别耗尽**：
        // 队列末尾先通知外部取下一批，**不重开普通随机轮**。
        if continuesOnExhaustion,
           nextIndex(after: index, restartRoundWhenFinished: false) == nil {
            stopPlayback()
            onQueueExhausted?()
            return
        }
        guard let following = nextIndex(after: index, restartRoundWhenFinished: true) else {
            stopPlayback()
            onQueueExhausted?()
            return
        }
        Task { await play(at: following) }
    }

    /// 上一首（队列开头 → 回到第一首）。
    ///
    /// - 顺序模式：上一项；已经是第一首 → 回到第一首；
    /// - 随机模式：随机序列里的上一项；已经是第一项 → 回到最后一项。
    public func previous() {
        guard let index = currentIndex else {
            guard !queue.isEmpty else { return }
            Task { await play(at: 0) }
            return
        }
        guard let preceding = previousIndex(before: index) else {
            stopPlayback()
            return
        }
        Task { await play(at: preceding) }
    }

    /// 切换播放顺序（顺序 ↔ 随机）。
    ///
    /// - Parameter randomSeed: 随机序列的种子（测试可注入固定值；`nil` = 沿用当前种子推进）。
    public func setPlaybackOrder(_ order: PlaybackOrder, randomSeed: UInt64? = nil) {
        if let randomSeed { shuffleSeed = randomSeed }
        playbackOrder = order
        rebuildShuffleRound()
    }

    // MARK: - 随机序列

    /// 重建随机序列（`queue` 下标的一个排列）。
    ///
    /// - Parameter keepingVisited: 保留「本轮已播过」的记录
    ///   （只有 **追加** 队列时安全：追加不会改变已有下标）。
    private func rebuildShuffleRound(keepingVisited: Bool = false) {
        guard !queue.isEmpty else {
            resetShuffleRound()
            return
        }
        var indices = Array(queue.indices)
        if playbackOrder == .shuffle {
            shuffleSeed &+= 0x9E37_79B9_7F4A_7C15
            var generator = SplitMix64(seed: shuffleSeed)
            // Fisher–Yates：打乱后每一项都只出现一次。
            if indices.count > 1 {
                for position in stride(from: indices.count - 1, to: 0, by: -1) {
                    let swap = Int(generator.next() % UInt64(position + 1))
                    indices.swapAt(position, swap)
                }
            }
        }
        shuffleOrder = indices
        if !keepingVisited { shuffleVisited = [] }
        syncShuffleCursor(with: currentIndex)
    }

    /// 清空随机状态（队列空了 / 换队列）。
    private func resetShuffleRound() {
        shuffleOrder = []
        shuffleCursor = nil
        shuffleVisited = []
    }

    /// 让随机游标跟上当前曲目（当前曲目不在随机序列里 → 游标清空）。
    private func syncShuffleCursor(with index: Int?) {
        guard let index, let position = shuffleOrder.firstIndex(of: index) else {
            shuffleCursor = nil
            return
        }
        shuffleCursor = position
    }

    /// 下一首的队列下标（nil = 没有下一首了）。
    ///
    /// - Parameter restartRoundWhenFinished: 本轮已播完时是否 **重新开一轮**
    ///   （手动按「下一首」= true；自然播完 = false：播完就停）。
    private func nextIndex(after index: Int, restartRoundWhenFinished: Bool) -> Int? {
        switch playbackOrder {
        case .ordered:
            let following = index + 1
            return following < queue.count ? following : nil
        case .shuffle:
            guard !shuffleOrder.isEmpty else { return nil }
            let count = shuffleOrder.count
            if let cursor = shuffleCursor {
                // 从游标的下一个位置开始 **绕着找** 没播过的曲目。
                var offset = 1
                while offset <= count {
                    let candidate = shuffleOrder[(cursor + offset) % count]
                    if !shuffleVisited.contains(candidate) { return candidate }
                    offset += 1
                }
            } else if let first = shuffleOrder.first(where: { !shuffleVisited.contains($0) }) {
                return first
            }
            // 本轮已经全部播过。
            guard restartRoundWhenFinished else { return nil }
            rebuildShuffleRound()
            return shuffleOrder.first
        }
    }

    /// 上一首的队列下标（nil = 没有上一首了）。
    private func previousIndex(before index: Int) -> Int? {
        switch playbackOrder {
        case .ordered:
            guard index > 0 else { return queue.isEmpty ? nil : 0 }
            return index - 1
        case .shuffle:
            guard let cursor = shuffleCursor, !shuffleOrder.isEmpty else { return nil }
            if cursor > 0 { return shuffleOrder[cursor - 1] }
            // 随机序列的第一项 → 回到最后一项（循环）。
            return shuffleOrder.last
        }
    }

    /// 把队列里指向某个本地路径的条目改成新路径（**不打断当前播放**）。
    ///
    /// 用于「优质替换」：旧文件被换掉后，队列里还指向旧路径的条目
    /// 会指向一个不存在的文件（「上一首」「临时播放」就播不出来了）。
    ///
    /// - 当前正在播的条目：**保留正在播放的音频**，只更新 `origin`
    ///   （后续解析按新路径走）。
    public func updateLocalPath(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        for position in queue.indices {
            if case .local(let path) = queue[position].origin, path == oldPath {
                queue[position].origin = .local(path: newPath)
            }
        }
        if let playing = current, case .local(let path) = playing.origin, path == oldPath {
            var updated = playing
            updated.origin = .local(path: newPath)
            current = updated
        }
    }

    /// 跳转到指定位置（秒）。
    ///
    /// **任何一次 seek 都会取消本次播放的计数**：拖过进度就不算「完整听完」。
    public func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let target = min(max(0, seconds), duration)
        suppressCompletionCount = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
    }

    /// 停止播放（保留队列）。
    public func stopPlayback() {
        // 停止：作废在途解析 + 取消本次播放的计数。
        resolutionGeneration += 1
        suppressCompletionCount = true
        countedCurrentItem = true
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        loadedURL = nil
        loadedIsLocal = false
        isPlaying = false
        isResolving = false
        currentTime = 0
        duration = 0
        sourceDescription = ""
    }

    // MARK: - 内部

    private func startCurrentItem() async {
        guard let item = current else { return }
        // 代次：解析期间用户又切了曲 / 停了播放，旧结果必须丢弃。
        let generation = resolutionGeneration
        isResolving = true
        errorMessage = nil
        do {
            let source = try await resolver.resolve(item)
            guard generation == resolutionGeneration, current?.id == item.id else {
                // 已被更新的操作作废（不覆盖新曲目，也不报错）。
                return
            }
            guard let url = source.url as URL? else {
                throw PlaybackError.invalidSource("播放地址无效")
            }
            let asset = try await Self.makePlayableAsset(for: url)
            // 资产加载是异步的：这期间用户可能又切了曲 / 停了播放，
            // 旧资产必须丢弃（否则会覆盖新曲目）。
            guard generation == resolutionGeneration, current?.id == item.id else {
                return
            }
            isResolving = false
            let playerItem = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: playerItem)
            observeStatus(of: playerItem)
            loadedURL = url
            loadedIsLocal = source.isLocal
            sourceDescription = source.isLocal ? "本地文件" : (source.note ?? "网络")
            duration = item.durationMs > 0 ? Double(item.durationMs) / 1000 : 0
            currentTime = 0
            player.play()
            isPlaying = true
        } catch {
            guard generation == resolutionGeneration, current?.id == item.id else { return }
            isResolving = false
            isPlaying = false
            errorMessage = "无法播放「\(item.title)」：\(Self.describe(error))"
        }
    }

    // MARK: - 资产创建

    /// 创建用于播放的资产（**按来源区别对待时长精度**）。
    ///
    /// - **本地文件**：用默认选项。未压缩 PCM（WAV / AIFF）在
    ///   `AVURLAssetPreferPreciseDurationAndTimingKey: false`（快速时长）下
    ///   会直接 **不可播放**：`load(.duration)` 报
    ///   `AVFoundationErrorDomain -11800`（内含
    ///   `NSOSStatusErrorDomain -17770`，失败依赖是 `Duration`），
    ///   `load(.isPlayable)` 返回 `false` → 播放项直接失败、一点声音都没有。
    ///   本地读取成本很低，用默认（精确）时长即可。
    /// - **网络流**：用「快速时长」，否则精确时长可能要 **把整个文件下完**
    ///   才能算出来（真实网络播放会迟迟不出声）。
    static func makeAsset(for url: URL) -> AVURLAsset {
        if url.isFileURL {
            return AVURLAsset(url: url)
        }
        return AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
    }

    /// 创建 **保证可播放** 的资产。
    ///
    /// 网络流在「快速时长」下可能不可播放（未压缩 PCM 流就是这种情况），
    /// 这时退回默认选项重来一次：宁可慢一点，也不能完全播不了。
    static func makePlayableAsset(for url: URL) async throws -> AVURLAsset {
        let asset = makeAsset(for: url)
        guard !url.isFileURL else { return asset }
        // 加载失败（地址不通等）不在这里下结论：交给播放项自己报错。
        guard let playable = try? await asset.load(.isPlayable) else { return asset }
        guard !playable else { return asset }
        return AVURLAsset(url: url)
    }

    /// 观察当前播放项的状态。
    ///
    /// 资产加载失败时 `AVPlayerItem.status` 变成 `.failed`，但
    /// `AVPlayerItemFailedToPlayToEndTime` **不一定** 会发出来；
    /// 不观察状态的话，界面会一直假装「正在播放」。
    private func observeStatus(of item: AVPlayerItem) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleStatus(item)
            }
        }
    }

    private func handleStatus(_ item: AVPlayerItem) {
        // 只处理 **当前** 播放项：切歌后旧项的状态变化与当前曲目无关。
        guard item === player.currentItem else { return }
        guard item.status == .failed else { return }
        isPlaying = false
        errorMessage = "播放失败：\(item.error.map(Self.describe) ?? "未知原因")"
    }

    private func installObservers() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                self?.handleProgress(seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleEnd(notification)
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleFailure(notification)
            }
        }
    }

    private func handleProgress(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if let item = player.currentItem {
            let assetDuration = item.duration.seconds
            if assetDuration.isFinite, assetDuration > 0, duration <= 0 {
                duration = assetDuration
            }
        }
    }

    private func handleEnd(_ notification: Notification) {
        guard let item = current else { return }
        guard let finished = notification.object as? AVPlayerItem, finished === player.currentItem else { return }
        isPlaying = false
        // **只计完整在线播放**：
        // - 队列来源是网络曲目（`item.isRemote`）；
        // - **实际播放的来源是网络流**（`loadedIsLocal == false`）：
        //   网络曲目本地优先命中本地文件时播的是本地文件，不算在线播放。
        if item.isRemote, !loadedIsLocal, !countedCurrentItem, !suppressCompletionCount {
            countedCurrentItem = true
            onCompletedRemotePlay?(item)
        }
        // 队列还有下一项 → 自动接着播（顺序 / 随机都按当前模式走；
        // 随机模式本轮播完就 **停**，不自动开新一轮）。
        if let index = currentIndex, let following = nextIndex(after: index, restartRoundWhenFinished: false) {
            Task { @MainActor [weak self] in
                await self?.play(at: following)
            }
        } else {
            currentTime = duration
            // **队列耗尽**：私人 FM 用它取下一批并自动接播（普通播放不消费）。
            onQueueExhausted?()
        }
    }

    private func handleFailure(_ notification: Notification) {
        // 只处理 **当前** 播放项的失败通知：切歌后旧项的失败与当前曲目无关。
        guard let failed = notification.object as? AVPlayerItem, failed === player.currentItem else { return }
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        isPlaying = false
        errorMessage = "播放失败：\(error.map(Self.describe) ?? "未知原因")"
    }

    static func describe(_ error: Error) -> String {
        if let bridgeError = error as? BridgeClient.BridgeError {
            return bridgeError.description
        }
        if let clientError = error as? BridgeClient.ClientError {
            return clientError.description
        }
        return error.localizedDescription
    }
}

/// 播放器可以迁移 **内存里的播放引用**（文件被替换后队列要跟着走）。
extension PlayerController: PlaybackReferenceUpdating {}

/// 播放相关错误。
public enum PlaybackError: Error, CustomStringConvertible {
    case invalidSource(String)
    case localFileMissing(String)

    public var description: String {
        switch self {
        case .invalidSource(let message): return "播放地址无效：\(message)"
        case .localFileMissing(let path): return "本地文件不存在：\(path)"
        }
    }
}

/// 可复现的伪随机数发生器（SplitMix64）。
///
/// 随机播放序列必须 **可复现**：给定同一个种子，同一个队列得到同一个顺序
/// （测试可断言，用户也能得到稳定的「随机」体验）。
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    /// 下一个伪随机数。
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 基于本地资料库 + 桥接的播放地址解析器（**本地优先**）。
public final class LibraryPlaybackResolver: PlaybackResolving {
    private let library: LocalLibrary
    private let bridge: BridgeService

    public init(library: LocalLibrary, bridge: BridgeService) {
        self.library = library
        self.bridge = bridge
    }

    public func resolve(_ item: PlaybackItem) async throws -> PlaybackSource {
        switch item.origin {
        case .local(let path):
            guard FileManager.default.fileExists(atPath: path) else {
                throw PlaybackError.localFileMissing(path)
            }
            return PlaybackSource(url: URL(fileURLWithPath: path), isLocal: true, note: nil)
        case .remote(let neteaseId):
            // **只按明确来源 ID 关联**：标题 / 艺人相同不代表同一录音，
            // 模糊匹配会把用户放到错误的文件上。
            if let track = library.matchLocalTrack(neteaseId: neteaseId) {
                return PlaybackSource(url: URL(fileURLWithPath: track.path), isLocal: true, note: "本地文件")
            }
            guard let song = item.remoteSong else {
                throw PlaybackError.invalidSource("缺少网络曲目数据")
            }
            let audio = try await bridge.resolve(song: song)
            guard let url = URL(string: audio.url) else {
                throw PlaybackError.invalidSource("播放地址无法解析：\(audio.url)")
            }
            let label = audio.sourceLabel.isEmpty ? audio.source : audio.sourceLabel
            var note = audio.note
            if !label.isEmpty {
                note = note.map { "\($0)（\(label)）" } ?? label
            }
            return PlaybackSource(url: url, isLocal: false, note: note)
        }
    }
}
