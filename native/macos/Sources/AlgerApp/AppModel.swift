import AlgerKit
import Foundation
import Combine

/// 侧栏 / 内容区的导航目标。
enum NavigationTarget: Hashable, Identifiable {
    case home
    case localSongs
    case localAlbums
    case localArtists
    case localPlaylist(String)
    case remotePlaylist(Int64)
    /// 艺人详情（本地艺人名 + 可选的网络艺人 ID）。
    case artistDetail(name: String, remoteID: Int64?)
    /// 专辑详情（本地专辑键 + 可选的网络专辑 ID）。
    case albumDetail(name: String, artist: String, remoteID: Int64?)
    case downloads
    case queue
    case settings

    var id: String {
        switch self {
        case .home: return "home"
        case .localSongs: return "local-songs"
        case .localAlbums: return "local-albums"
        case .localArtists: return "local-artists"
        case .localPlaylist(let id): return "local-playlist-\(id)"
        case .remotePlaylist(let id): return "remote-playlist-\(id)"
        case .artistDetail(let name, let remoteID): return "artist-\(name)-\(remoteID ?? 0)"
        case .albumDetail(let name, let artist, let remoteID): return "album-\(artist)-\(name)-\(remoteID ?? 0)"
        case .downloads: return "downloads"
        case .queue: return "queue"
        case .settings: return "settings"
        }
    }
}

/// 一条搜索结果（本地文件或网络曲目）。
enum SearchResult: Identifiable, Equatable {
    case local(TrackRecord)
    case remote(RemoteSong)

    var id: String {
        switch self {
        case .local(let track): return "local:\(track.path)"
        case .remote(let song): return "remote:\(song.id)"
        }
    }

    var title: String {
        switch self {
        case .local(let track): return track.title.isEmpty ? track.path : track.title
        case .remote(let song): return song.name
        }
    }

    var subtitle: String {
        switch self {
        case .local(let track): return track.artist
        case .remote(let song): return song.artistText
        }
    }

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    /// 网络曲目（本地结果为 nil）。
    var song: RemoteSong? {
        if case .remote(let song) = self { return song }
        return nil
    }

    /// 本地曲目（网络结果为 nil）。
    var track: TrackRecord? {
        if case .local(let track) = self { return track }
        return nil
    }
}

/// 首页的一个分区。
struct HomeSection: Identifiable {
    enum Item: Identifiable {
        case remote(RemoteSong)
        case local(TrackRecord)

        var id: String {
            switch self {
            case .remote(let song): return "remote:\(song.id)"
            case .local(let track): return "local:\(track.path)"
            }
        }

        var title: String {
            switch self {
            case .remote(let song): return song.name
            case .local(let track): return track.title.isEmpty ? track.path : track.title
            }
        }

        var subtitle: String {
            switch self {
            case .remote(let song): return song.artistText
            case .local(let track): return track.artist
            }
        }
    }

    let id: String
    let title: String
    var items: [Item] = []
    /// 该分区的 **具体错误**（例如「网络请求失败：…」）。
    ///
    /// 取不到内容时必须显示真实原因，**不得**用空列表假装「暂时没有内容」。
    var error: String?
}

/// 添加目标（「更改添加目标」用）。
///
/// **只含本地目标**：网络歌单是 **只读** 的，不能作为添加目标。
enum AdditionTarget: Equatable, Identifiable {
    case localPlaylist(String)
    /// 当前临时临时播放。
    case queue
    /// 新建本地歌单。
    case newLocalPlaylist

    var id: String {
        switch self {
        case .localPlaylist(let id): return "local:\(id)"
        case .queue: return "queue"
        case .newLocalPlaylist: return "new"
        }
    }
}

/// 一次添加的回执（**只撤回本次新增**用）。
struct AdditionReceipt: Equatable {
    /// 添加到的目标。
    var target: AdditionTarget
    /// 本地歌单里 **本次真正新增** 的路径（按歌单 ID）。
    var localNewlyAdded: [String: [String]] = [:]
    var queueEntryId: UUID?
    /// 曲目标题（提示用）。
    var title: String = ""
    /// 网络曲目（换目标时重新加入用）。
    var song: RemoteSong?
    /// 本地曲目（换目标时重新加入用）。
    var track: TrackRecord?
}

/// 艺人详情数据（**本地上方、网络下方**）。
struct ArtistDetailData {
    var localTracks: [TrackRecord] = []
    var hotSongs: [RemoteSong] = []
    var albums: [RemoteAlbum] = []
    var error: String?
}

/// 专辑详情数据。
struct AlbumDetailData {
    var localTracks: [TrackRecord] = []
    var songs: [RemoteSong] = []
    var error: String?
}

/// 推荐雷达的状态（**每个分区独立**：歌单之间互不影响）。
///
/// 「加载失败独立于歌单曲目」：雷达出错 **不会** 影响歌单自身的曲目列表。
struct RadarState: Equatable {
    /// 已展示的推荐结果（**过滤后**的最终列表）。
    var items: [RemoteSong] = []
    /// 是否正在加载。
    var isLoading = false
    /// 具体错误（不吞原因；可重试）。
    var error: String?
    /// 空结果的原因（没有可用种子 / 上游没有相似歌曲）。
    var emptyReason: String?
    /// 部分种子失败时的提示（**有结果时**才可能非空）。
    var warning: String?
    /// 内容身份（歌单内容变了 → 旧结果不再算数）。
    var contentSignature: String = ""
}

/// 推荐雷达的请求（**只读**）。
///
/// 请求 **按歌单及内容身份管理**：同一个分区 + 同一份内容只请求一次；
/// 内容变了（歌单增删曲目）就重新请求。
struct RadarRequest {
    /// 分区身份（`explore` / `local:<歌单 ID>` / `remote:<歌单 ID>`）。
    var scope: String
    /// 内容身份（歌单内容摘要）。
    var contentSignature: String
    /// **来源歌单的真实标题**（雷达分区标题与队列标题都用它）。
    var title: String
    /// 种子曲目（已知的网易曲目 ID）。
    var seedSongIDs: [Int64]
    /// 需要解析来源 ID 的本地曲目（**小规模精确搜索**，不写库、不改标签）。
    var seedLocalTracks: [TrackRecord]
    /// 来源歌单的 **全部** 网易曲目 ID（**排除用**：推荐不得重复歌单里的歌）。
    var sourceSongIDs: Set<Int64>

    init(
        scope: String,
        contentSignature: String,
        title: String = "",
        seedSongIDs: [Int64] = [],
        seedLocalTracks: [TrackRecord] = [],
        sourceSongIDs: Set<Int64> = []
    ) {
        self.scope = scope
        self.contentSignature = contentSignature
        self.title = title
        self.seedSongIDs = seedSongIDs
        self.seedLocalTracks = seedLocalTracks
        self.sourceSongIDs = sourceSongIDs
    }
}

/// 应用根状态模型。
///
/// 职责：把桥接（网络 / 下载 / 扫描）、本地资料库与播放器串起来，
/// 并把 **明确错误** 交给界面显示（不静默失败、不造数据）。
@MainActor
final class AppModel: ObservableObject {

    // MARK: - 提示

    /// 顶部提示条。
    struct Banner: Identifiable, Equatable {
        enum Kind: Equatable {
            case info
            case warning
            case error
        }

        let id = UUID()
        var kind: Kind
        var text: String

        static func info(_ text: String) -> Banner { Banner(kind: .info, text: text) }
        static func warning(_ text: String) -> Banner { Banner(kind: .warning, text: text) }
        static func error(_ text: String) -> Banner { Banner(kind: .error, text: text) }
    }

    // MARK: - 依赖

    let environment: AlgerEnvironment
    let player: PlayerController
    private var cancellables = Set<AnyCancellable>()

    private var isRecoveringDownloads = false

    // MARK: - 导航 / 搜索

    @Published var selection: NavigationTarget? = .home
    @Published var searchText: String = "" {
        didSet {
            // 输入改变即使旧请求失效，覆盖 debounce 等待和清空关键词两条路径。
            searchGeneration += 1
            isLoadingMoreResults = false
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults = []
                remoteSearchTotal = 0
                remoteSearchLoaded = 0
                isSearching = false
            }
        }
    }
    @Published private(set) var searchResults: [SearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingMoreResults = false
    @Published private(set) var remoteSearchTotal: Int = 0
    /// 已经取回的网络结果数量（分页用）。
    private var remoteSearchLoaded = 0
    /// 搜索代次：**过期结果直接丢弃**（快速改关键词不会看到旧结果）。
    private var searchGeneration = 0
    private let searchPageSize = 50
    /// 搜索框聚焦请求（**⌘F** 用：换 token 就是「再聚焦一次」）。
    @Published private(set) var searchFocusToken = UUID()

    /// 侧栏分组的展开状态（**放在模型里**：播放来源时要自动展开对应分组）。
    @Published var localSectionExpanded = true
    @Published var remoteSectionExpanded = true

    // MARK: - 账号

    @Published private(set) var account: AccountInfo?
    @Published private(set) var isLoggedIn = false
    @Published private(set) var sessionIssue: String?
    /// 真实会话快照（音质 / 音源 / 下载目录都从这里回显）。
    @Published private(set) var sessionSnapshot: SessionSnapshot?

    // MARK: - 本地资料库

    @Published private(set) var localSongs: [TrackRecord] = []
    @Published private(set) var localAlbums: [LocalAlbum] = []
    @Published private(set) var localArtists: [LocalArtist] = []
    @Published private(set) var localPlaylists: [LocalPlaylist] = []
    /// 本地库读取问题（**具体到哪个歌单**，不整组吞掉）。
    @Published private(set) var libraryIssues: [String] = []

    // MARK: - 远程

    @Published private(set) var remotePlaylists: [RemotePlaylist] = []
    /// **临时展示** 的网络歌单（公开推荐歌单的预览行）。
    ///
    /// - **不写进收藏、不持久化**：只是当前浏览 / 播放时的一个稳定 ID 行；
    /// - 读详情与已有网络歌单 **走同一路**（`RemotePlaylistDetailView`）。
    @Published private(set) var transientRemotePlaylists: [RemotePlaylist] = []
    /// 探索页的 **公开推荐歌单**（**匿名可用**：不依赖登录）。
    @Published private(set) var recommendedPlaylists: [RemotePlaylist] = []
    @Published private(set) var isLoadingRecommendedPlaylists = false
    /// 公开推荐歌单的具体错误（**可重试**；不吞原因）。
    @Published private(set) var recommendedPlaylistsError: String?
    @Published private(set) var homeSections: [HomeSection] = []
    @Published private(set) var isLoadingHome = false
    /// 歌单电台选用哪张歌单（可自选）。
    @Published var radioPlaylistID: Int64?

    /// **已关注艺人**（真实读取关注列表，分页取全）。
    ///
    /// 「关注艺人的新歌」以这份列表为准：**空列表 ≠ 没有关注**
    /// （读失败时看 `followedArtistsError`）。
    @Published private(set) var followedArtists: [RemoteArtist] = []
    /// 关注艺人列表的读取问题（登录失败 / 网络失败 → 明确原因）。
    @Published private(set) var followedArtistsError: String?
    /// 是否正在读取关注艺人列表。
    @Published private(set) var isLoadingFollowedArtists = false
    /// 关注艺人刷新的 **代次令牌**：过期的响应 **不得回写**。
    ///
    /// 退出登录 / 重新登录都会让在途请求失效 → 旧账号的关注列表
    /// 不会在退出后又被写回来。
    private var followedArtistsGeneration = 0

    // MARK: - 下载

    @Published private(set) var downloadTasks: [DownloadTask] = []
    /// 本次进程 **触碰过** 的下载任务 ID（**会话范围**）。
    ///
    /// - 记账点只有两个：桥接的 `dl` 事件（`reserve` 落盘后必然发出）与
    ///   **成功重试**；失败的重试不记账 → 旧队列仍能被后续恢复。
    /// - 只按 ID 记账，**不按时间戳** 判断：桥接载入时会把上次遗留的
    ///   `running` 任务改成 `queued` 并刷新 `updatedAt`，用时间戳会把旧任务
    ///   当成本次会话（旧任务不再自动恢复，入口还会误报「正在下载」）。
    /// - 关窗口再打开仍是同一进程 → 记录保留；完全退出后重启 → 记录清空。
    @Published private(set) var sessionDownloadTaskIDs: Set<Int64> = []
    @Published private(set) var isScanning = false
    /// 待处理的入单操作（**持久可见**）。
    @Published private(set) var pendingIntakes: [DownloadIntake] = []
    /// 待重试的自动保存记录。
    @Published private(set) var autoSavePending: [AutoSaveRecord] = []

    // MARK: - 详情

    @Published private(set) var artistDetails: [String: ArtistDetailData] = [:]
    @Published private(set) var albumDetails: [String: AlbumDetailData] = [:]
    @Published private(set) var isLoadingArtistDetail = false
    @Published private(set) var isLoadingAlbumDetail = false

    // MARK: - 推荐雷达

    /// 推荐雷达状态（**按分区**：探索 / 每个歌单各一份）。
    @Published private(set) var radarStates: [String: RadarState] = [:]
    /// 各分区的请求代次：**过期响应不得回写**（快速切换歌单不会看到旧推荐）。
    private var radarGenerations: [String: Int] = [:]

    // MARK: - 提示条

    @Published var banner: Banner?

    /// 是否显示「更改添加目标」面板。
    /// 是否显示「更改添加目标」面板。
    @Published var showingAdditionTargetPicker = false
    /// 正在编辑元信息的本地曲目（E5）。
    @Published var metadataEditorTrack: TrackRecord?
    /// 上一次添加的回执（「更改…」时只撤回本次新增）。
    @Published private(set) var lastAddition: AdditionReceipt?

    // MARK: - 播放

    /// 当前播放上下文（正在播放的曲目来自哪个来源）。
    @Published private(set) var playbackContext: PlaybackContext = .none

    // MARK: - 私人 FM

    /// 私人 FM 会话（**代次 / 去重 / 续批预算 / 并发合并**）。
    private let fmSession = PersonalFMSession()
    /// 私人 FM 取批失败原因（**点「下一首」可重试**）。
    @Published private(set) var fmError: String?
    /// 取批途中用户按了暂停（**不自动接播**：保护用户的暂停）。
    private var fmPauseRequested = false

    // MARK: - 登录窗口

    private var loginWindow: LoginWindowController?
    /// 退出收束是否已经做过（避免重复 shutdown）。
    private var didShutDown = false

    // MARK: - 初始化

    init() throws {
        let environment = try AlgerEnvironment.make()
        self.environment = environment
        self.player = environment.player
        // 完整网络播放才计数（跳过 / 拖进度不计数）。
        player.onCompletedRemotePlay = { [weak self] item in
            self?.recordCompletedRemotePlay(item)
        }
        // **队列耗尽**：只有私人 FM 会消费（取下一批并自动接播）。
        player.onQueueExhausted = { [weak self] in
            self?.handleQueueExhausted()
        }
        // 用户主动暂停 → 私人 FM **不自动接播**（保护用户的暂停）。
        // **暂停标志只针对在途续批**：没有在途请求时不影响 FM。
        player.onUserPause = { [weak self] in
            guard let self, self.fmSession.isRequestInFlight else { return }
            self.fmPauseRequested = true
        }
        // 恢复 **上次选择的播放顺序**（顺序 / 随机），旧 `native.json` 没有这个
        // 字段时按顺序播放（宽容解码，不会报废旧数据）。
        player.setPlaybackOrder(environment.store.current.settings.playbackOrder)
        forwardPlayerChanges()
        observeQueueEmptied()
        observeSearchText()
    }

    /// 队列被清空时：**收束上下文与侧栏选择**（不留失效的选中项）。
    private func observeQueueEmptied() {
        player.$queue
            .sink { [weak self] queue in
                guard queue.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.handleQueueEmptied()
                }
            }
            .store(in: &cancellables)
    }

    /// 队列空了（用户清空 / 队列被替换成空）：
    /// - 播放上下文回到「无来源」；
    /// - 侧栏若还选着「临时播放」→ 回到探索（**不留失效选中**）；
    /// - 私人 FM 的在途响应 **不得接管队列**。
    private func handleQueueEmptied() {
        setPlaybackContext(.none)
        fmSession.beginSession()
        fmPauseRequested = false
        if selection == .queue {
            selection = .home
        }
    }

    /// 把 **播放器** 的状态变化转发给 `AppModel`。
    ///
    /// 各视图只拿 `EnvironmentObject model`，没有直接观察 `player`：
    /// 不转发的话播放进度 / 暂停 / 当前曲高亮 / 顺序按钮 **都不会刷新**。
    private func forwardPlayerChanges() {
        player.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - 播放顺序（顺序 / 随机）

    /// 当前播放顺序模式。
    var playbackOrder: PlaybackOrder { player.playbackOrder }

    /// 切换播放顺序并 **持久保存**（下次启动仍是这个模式）。
    func setPlaybackOrder(_ order: PlaybackOrder) {
        player.setPlaybackOrder(order)
        do {
            try environment.store.mutate { state in
                state.settings.playbackOrder = order
            }
        } catch {
            banner = .error("保存播放顺序失败：\(Self.describe(error))")
        }
    }

    /// 切换播放顺序（界面上是一个按钮：顺序 ↔ 随机）。
    func togglePlaybackOrder() {
        setPlaybackOrder(player.playbackOrder.toggled)
    }

    // MARK: - 启动

    /// 启动流程：准备路径 → 修复未完成操作 → 读会话 → 读本地库 → 读下载 → 订阅事件。
    func bootstrap() async {
        do {
            let notes = try await environment.applyDataDirectoryDefaults()
            for note in notes { banner = .info(note) }
        } catch {
            banner = .error("路径准备失败：\(Self.describe(error))")
        }
        do {
            let repairs = try environment.library.repairPendingOperations()
            if let first = repairs.first {
                banner = repairs.count == 1 ? .warning(first) : .warning("已修复 \(repairs.count) 项上次未完成的操作")
            }
        } catch {
            banner = .error("修复未完成操作失败：\(Self.describe(error))")
        }
        // 未完成的废纸篓删除：**可定位、可重试**。
        let trashRepairs = environment.trash.repairPending()
        if let first = trashRepairs.first {
            banner = trashRepairs.count == 1 ? .warning(first) : .warning("有 \(trashRepairs.count) 项上次未完成的删除需要处理")
        }
        // 未完成的 **优质替换**（`.committing`）：引用迁移做了一半 → 继续做完。
        let replacementRepairs = await environment.replacement.repairPending()
        if let first = replacementRepairs.first {
            banner = replacementRepairs.count == 1
                ? .warning(first)
                : .warning("有 \(replacementRepairs.count) 项上次未完成的替换需要处理")
        }
        subscribeBridgeEvents()
        await refreshSession()
        refreshLibrary()
        await refreshDownloads()
        // **公开推荐歌单只在探索页加载**（匿名可用，不在这里串行挡住私人 FM）。
        if isLoggedIn {
            await refreshRemotePlaylists()
            await refreshFollowedArtists()
            await refreshHome()
        }
    }

    /// 异步退出前的收束（**后台线程**，不阻塞主线程）。
    func shutdown() async {
        guard !didShutDown else { return }
        didShutDown = true
        let client = environment.client
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                client.shutdown()
                continuation.resume()
            }
        }
    }

    /// 退出流程的最后兜底（同步、有界）。
    func shutdownNow() {
        environment.client.shutdown()
    }

    // MARK: - 搜索

    /// 请求聚焦搜索框（**⌘F**：换 token 就是「再聚焦一次」）。
    func focusSearchField() {
        searchFocusToken = UUID()
    }

    /// 清空搜索（**侧栏换页时**用：搜索 **不能遮住** 目的页）。
    func clearSearch() {
        guard !searchText.isEmpty else { return }
        searchText = ""
    }

    private func observeSearchText() {
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.runSearch()
                }
            }
            .store(in: &cancellables)
    }

    /// 统一搜索：**本地 + 网络**，按来源 ID 去重（有本地版本就只留本地）。
    ///
    /// - 离线时 **本地结果照常可用**，网络失败只影响网络部分；
    /// - 代次令牌保证 **过期结果被丢弃**。
    func runSearch() async {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            searchResults = []
            remoteSearchTotal = 0
            remoteSearchLoaded = 0
            isSearching = false
            return
        }
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        defer { if generation == searchGeneration { isSearching = false } }

        let localMatches = localSongs.filter { track in
            let haystack = "\(track.title) \(track.artist) \(track.album)"
            return haystack.localizedCaseInsensitiveContains(keyword)
        }
        var results: [SearchResult] = localMatches.map { .local($0) }
        searchResults = results
        remoteSearchTotal = 0
        remoteSearchLoaded = 0
        isLoadingMoreResults = false
        // 已有本地版本的网络曲目不再重复出现（身份关联只认来源 ID）。
        let localSourceIDs = Set(localSongs.compactMap { $0.neteaseId > 0 ? $0.neteaseId : nil })

        do {
            let (songs, total) = try await environment.bridge.searchSongs(
                keywords: keyword,
                limit: searchPageSize,
                offset: 0
            )
            guard generation == searchGeneration else { return }
            remoteSearchTotal = total
            remoteSearchLoaded = songs.count
            for song in songs where !localSourceIDs.contains(song.id) {
                results.append(.remote(song))
            }
        } catch {
            guard generation == searchGeneration else { return }
            remoteSearchTotal = 0
            remoteSearchLoaded = 0
            banner = .error("网络搜索失败：\(Self.describe(error))")
        }
        guard generation == searchGeneration else { return }
        searchResults = results
    }

    /// 载入更多搜索结果（分页）。
    func loadMoreSearchResults() async {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !isLoadingMoreResults else { return }
        guard remoteSearchLoaded < remoteSearchTotal else { return }
        let generation = searchGeneration
        isLoadingMoreResults = true
        defer { if generation == searchGeneration { isLoadingMoreResults = false } }
        do {
            let (songs, total) = try await environment.bridge.searchSongs(
                keywords: keyword,
                limit: searchPageSize,
                offset: remoteSearchLoaded
            )
            guard generation == searchGeneration else { return }
            remoteSearchTotal = total
            remoteSearchLoaded += songs.count
            let localSourceIDs = Set(localSongs.compactMap { $0.neteaseId > 0 ? $0.neteaseId : nil })
            let known = Set(searchResults.compactMap { result -> String? in
                if case .remote(let song) = result { return "remote:\(song.id)" }
                return nil
            })
            for song in songs where !localSourceIDs.contains(song.id) && !known.contains("remote:\(song.id)") {
                searchResults.append(.remote(song))
            }
        } catch {
            guard generation == searchGeneration else { return }
            banner = .error("载入更多搜索结果失败：\(Self.describe(error))")
        }
    }

    /// 是否还有更多网络结果。
    var canLoadMoreSearchResults: Bool { remoteSearchLoaded < remoteSearchTotal }

    // MARK: - 会话 / 账号

    func refreshSession() async {
        do {
            let snapshot = try await environment.bridge.sessionSnapshot()
            sessionSnapshot = snapshot
            isLoggedIn = snapshot.loggedIn
            account = snapshot.account
            sessionIssue = snapshot.loadIssue ?? snapshot.downloadLoadIssue
            if let issue = snapshot.loadIssue {
                banner = .error("会话载入异常：\(issue)")
            }
            if let issue = snapshot.downloadLoadIssue {
                banner = .error("下载队列载入异常：\(issue)")
            }
            if let error = snapshot.downloadLastError {
                banner = .warning("下载队列最近一次错误：\(error)")
            }
        } catch {
            sessionIssue = Self.describe(error)
            banner = .error("读取会话失败：\(Self.describe(error))")
        }
    }

    /// 打开网易云登录窗口（**WKWebView 仅用于登录**）。
    func openLoginWindow() {
        if let loginWindow {
            loginWindow.focus()
            return
        }
        let controller = LoginWindowController()
        controller.onCookie = { [weak self] cookie in
            Task { @MainActor in
                await self?.completeLogin(cookie: cookie)
            }
        }
        controller.onClose = { [weak self] in
            self?.loginWindow = nil
        }
        loginWindow = controller
        controller.show()
    }

    /// 登录完成：交给桥接 **校验并落盘**（失败保留原会话）。
    func completeLogin(cookie: String) async {
        do {
            try await environment.bridge.setCookie(cookie)
            await refreshSession()
            await refreshRemotePlaylists()
            await refreshFollowedArtists()
            await refreshHome()
            banner = .info("登录成功")
        } catch {
            banner = .error("登录失败：\(Self.describe(error))")
        }
    }

    /// 注销。
    func logout() async {
        // **先作废在途的关注列表请求**（退出后旧响应不得回写）。
        followedArtistsGeneration += 1
        // **作废在途的雷达请求**（退出后旧账号的推荐不得回写）。
        exploreRadarGeneration += 1
        radarGenerations[ExploreView.radarScope, default: 0] += 1
        exploreRadarTrackIDs = [:]
        radarStates[ExploreView.radarScope] = RadarState()
        // **作废在途的私人 FM 取批**（退出后旧响应不得接管队列）。
        fmSession.beginSession()
        fmPauseRequested = false
        do {
            let cleared = try await environment.bridge.logout()
            await refreshSession()
            account = nil
            isLoggedIn = false
            remotePlaylists = []
            // 关注艺人属于账号数据：退出后必须清空，不能留着旧账号的关注。
            followedArtists = []
            followedArtistsError = "已退出登录"
            await refreshHome()
            banner = .info(cleared ? "已退出登录" : "退出期间登录状态发生变化，已保留当前登录")
        } catch {
            banner = .error("退出登录失败：\(Self.describe(error))")
        }
    }

    // MARK: - 本地资料库

    /// 刷新本地资料库（**逐个歌单读取**，坏的那个单独报错，不整组吞掉）。
    func refreshLibrary() {
        localSongs = environment.library.songs()
        localAlbums = environment.library.albums()
        localArtists = environment.library.artists()
        let (playlists, issues, _) = environment.library.playlistsWithIssues()
        localPlaylists = playlists
        libraryIssues = issues
        let recent = localSongs.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(12)
        homeSections.removeAll { $0.id == "recent" }
        if !recent.isEmpty {
            homeSections.insert(HomeSection(id: "recent", title: "最近存入本地", items: recent.map { .local($0) }), at: 0)
        }
    }

    /// 扫描音乐目录（真实扫描 → 索引）。
    func scanLibrary() async {
        guard !isScanning else { return }
        let folders = environment.store.current.settings.libraryFolders
        guard !folders.isEmpty else {
            banner = .error("尚未设置音乐目录，请先在设置里选择")
            return
        }
        isScanning = true
        defer { isScanning = false }
        do {
            let summary = try await LibraryScanner(client: environment.client, index: environment.index)
                .scan(directories: folders)
            refreshLibrary()
            if summary.errors > 0 {
                let samples = summary.errorSamples.prefix(3).joined(separator: "；")
                let message = "扫描完成：\(summary.scanned) 个文件，\(summary.errors) 个读取失败"
                banner = .warning(samples.isEmpty ? message : "\(message)（\(samples)）")
            } else {
                banner = .info("扫描完成：新增或更新 \(summary.updated) 首")
            }
        } catch {
            banner = .error("扫描失败：\(Self.describe(error))")
        }
    }

    // MARK: - 歌单（本地）

    func createLocalPlaylist(title: String, details: String) {
        do {
            let playlist = try environment.library.createPlaylist(title: title, details: details)
            refreshLibrary()
            selection = .localPlaylist(playlist.id)
            banner = .info("已创建歌单「\(playlist.title)」")
        } catch {
            banner = .error("创建歌单失败：\(Self.describe(error))")
        }
    }

    func renameLocalPlaylist(id: String, title: String, details: String) {
        do {
            try environment.library.updatePlaylist(id: id, title: title, details: details)
            refreshLibrary()
            banner = .info("歌单已更新")
        } catch {
            banner = .error("更新歌单失败：\(Self.describe(error))")
        }
    }

    func deleteLocalPlaylist(id: String) {
        do {
            try environment.library.deletePlaylist(id: id)
            refreshLibrary()
            if playbackContext == .localPlaylist(id) { setPlaybackContext(.none) }
            if selection == .localPlaylist(id) { selection = .home }
            banner = .info("歌单已删除（音频文件保留）")
        } catch {
            banner = .error("删除歌单失败：\(Self.describe(error))")
        }
    }

    @discardableResult
    func addLocalTracksToPlaylist(_ paths: [String], playlistId: String) -> [String] {
        do {
            let entries = paths.map { path -> PlaylistEntry in
                let track = environment.index.track(path: path)
                return PlaylistEntry(
                    path: path,
                    duration: track.map { Double($0.durationMs) / 1000 } ?? 0,
                    displayName: track?.title ?? ""
                )
            }
            let appended = try environment.library.addToPlaylist(id: playlistId, entries: entries)
            refreshLibrary()
            banner = .info(appended.isEmpty ? "曲目已在歌单中" : "已加入歌单")
            return appended.map(\.path)
        } catch {
            banner = .error("加入歌单失败：\(Self.describe(error))")
            return []
        }
    }

    func removeTrackFromPlaylist(playlistId: String, path: String) {
        do {
            try environment.library.removeFromPlaylist(id: playlistId, paths: [path])
            refreshLibrary()
            banner = .info("已从歌单移除（文件保留）")
        } catch {
            banner = .error("移除失败：\(Self.describe(error))")
        }
    }

    /// 把本地歌单重排（**写失败会明确报错**）。
    func moveLocalPlaylistTracks(playlistId: String, fromOffsets: IndexSet, toOffset: Int) {
        do {
            try environment.library.moveInPlaylist(id: playlistId, fromOffsets: fromOffsets, toOffset: toOffset)
            refreshLibrary()
        } catch {
            banner = .error("调整顺序失败：\(Self.describe(error))")
        }
    }

    // MARK: - 歌单（远程，只读）

    /// 刷新网络歌单列表。
    ///
    /// **网络歌单彻底只读**：没有新建 / 改名 / 删除 / 增删曲目 / 排序的入口，
    /// 网络曲目仍然可以加入 **本地歌单** 或 **临时播放**。
    func refreshRemotePlaylists() async {
        guard isLoggedIn else {
            remotePlaylists = []
            return
        }
        do {
            remotePlaylists = try await environment.bridge.userPlaylists()
            if let current = radioPlaylistID, !remotePlaylists.contains(where: { $0.id == current }) {
                radioPlaylistID = remotePlaylists.first?.id
            } else if radioPlaylistID == nil {
                radioPlaylistID = remotePlaylists.first?.id
            }
        } catch {
            banner = .error("读取歌单失败：\(Self.describe(error))")
        }
    }

    // MARK: - 首页推荐

    /// 刷新 **公开推荐歌单**（`/api/playlist/list`，**匿名可用**）。
    ///
    /// - **独立加载**：不等待登录，也不等待私人 FM；
    /// - **失败显示具体原因**并可重试（不伪装成「没有歌单」）。
    func refreshRecommendedPlaylists() async {
        guard !isLoadingRecommendedPlaylists else { return }
        isLoadingRecommendedPlaylists = true
        defer { isLoadingRecommendedPlaylists = false }
        do {
            let playlists = try await environment.bridge.topPlaylists(limit: 12, offset: 0)
            guard !Task.isCancelled else { return }
            recommendedPlaylists = playlists
            recommendedPlaylistsError = nil
        } catch {
            guard !Task.isCancelled else { return }
            recommendedPlaylists = []
            recommendedPlaylistsError = Self.describe(error)
        }
    }

    /// 读取 **已关注艺人** 列表（分页取全）。
    ///
    /// - 未登录 → 清空列表并写明原因（**不是**「没有关注」）；
    /// - 读取失败 → **保留错误原因**（`followedArtistsError`），列表置空；
    /// - 成功 → 列表与错误都更新（成功时错误清空）。
    func refreshFollowedArtists() async {
        // **代次令牌**：本次刷新开始 → 之前在途的响应全部作废。
        followedArtistsGeneration += 1
        let generation = followedArtistsGeneration
        guard isLoggedIn else {
            followedArtists = []
            followedArtistsError = "未登录，无法读取关注艺人"
            isLoadingFollowedArtists = false
            return
        }
        isLoadingFollowedArtists = true
        defer { if generation == followedArtistsGeneration { isLoadingFollowedArtists = false } }
        do {
            let artists = try await environment.bridge.artistSublist()
            // 过期响应 **直接丢弃**（不覆盖更新的状态）。
            guard generation == followedArtistsGeneration else { return }
            followedArtists = artists
            followedArtistsError = nil
        } catch {
            guard generation == followedArtistsGeneration else { return }
            followedArtists = []
            followedArtistsError = Self.describe(error)
            banner = .error("读取关注艺人失败：\(Self.describe(error))")
        }
    }

    /// 刷新首页。
    ///
    /// - **最近存入本地始终显示**（离线、未登录也有）；
    /// - 网络分区需要登录，失败时显示具体错误。
    func refreshHome() async {
        isLoadingHome = true
        defer { isLoadingHome = false }
        var sections: [HomeSection] = []
        var failures: [String] = []

        // 最近存入本地（**不需要网络，也不依赖登录**）。
        let recent = localSongs
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(12)
            .map { HomeSection.Item.local($0) }
        if !recent.isEmpty {
            sections.append(HomeSection(id: "recent", title: "最近存入本地", items: Array(recent)))
        }

        guard isLoggedIn else {
            homeSections = sections
            return
        }

        do {
            let fm = try await environment.bridge.personalFM()
            sections.append(HomeSection(id: "fm", title: "私人 FM", items: fm.map { .remote($0) }))
        } catch {
            let message = "私人 FM：\(Self.describe(error))"
            failures.append(message)
            sections.append(HomeSection(id: "fm", title: "私人 FM", items: [], error: Self.describe(error)))
        }

        // 关注艺人的新歌：**基于真实关注列表**判断「有没有关注」。
        //
        // - 关注列表读取失败 → 显示具体原因，**不**说成「没有关注」；
        // - 关注列表为空（读取成功）→ 确实没有关注任何艺人；
        // - 有关注但暂时没有新歌 → 说明是「暂时没有新歌」，不是「没有关注」。
        do {
            let works = try await environment.bridge.artistNewWorks()
            // 排除已收录到本地的录音（按来源 ID）。
            let localIDs = Set(localSongs.compactMap { $0.neteaseId > 0 ? $0.neteaseId : nil })
            let filtered = works.filter { !localIDs.contains($0.id) }
            let section = HomeSection(id: "artist-works", title: "关注艺人的新歌", items: filtered.map { .remote($0) })
            if let issue = followedArtistsError {
                sections.append(HomeSection(
                    id: section.id,
                    title: section.title,
                    items: section.items,
                    error: "关注艺人列表读取失败：\(issue)"
                ))
            } else if followedArtists.isEmpty {
                sections.append(HomeSection(
                    id: section.id,
                    title: section.title,
                    items: [],
                    error: "还没有关注任何艺人（关注后这里会显示新歌）"
                ))
            } else {
                sections.append(section)
            }
        } catch {
            let message = "关注艺人的新歌：\(Self.describe(error))"
            failures.append(message)
            sections.append(HomeSection(id: "artist-works", title: "关注艺人的新歌", items: [], error: Self.describe(error)))
        }

        // 旧「歌单电台」（`net.intelligenceList`）**不再使用**：
        // 网易对歌单类型有限制 → 改用统一的 **推荐雷达**（相似歌曲）。
        // 兼容入口（桥接命令 / `BridgeService.intelligenceList`）**保留**。

        homeSections = sections
        // 具体错误既进分区，也进提示条（不吞掉原因）。
        if let first = failures.first {
            banner = failures.count == 1
                ? .warning(first)
                : .warning("\(failures.count) 个推荐源不可用：\(first)")
        }
    }

    // MARK: - 推荐雷达（探索页）

    /// 探索页用于取种子的网络歌单（当前选中的；没有就取第一张）。
    var radarSeedPlaylist: RemotePlaylist? {
        remotePlaylists.first { $0.id == radioPlaylistID } ?? remotePlaylists.first
    }

    /// 探索页雷达的 **代次令牌**：切换歌单 / 登出都会作废在途响应。
    private var exploreRadarGeneration = 0
    /// 探索页雷达取到的歌单曲目 ID（按歌单缓存，避免重复读详情）。
    private var exploreRadarTrackIDs: [Int64: [Int64]] = [:]

    /// 加载探索页的 **推荐雷达**（只读；不下载、不改歌单）。
    ///
    /// - **切换歌单**：先清旧结果并发放代次 → 在途的旧响应回来时直接丢弃；
    /// - 返回 / 报错后都要 **核对当前歌单 ID + 代次**；
    /// - `force` = 用户主动刷新（顶部「刷新」）。
    func loadExploreRadar(force: Bool = false) async {
        let scope = ExploreView.radarScope
        guard let playlist = radarSeedPlaylist else {
            exploreRadarGeneration += 1
            radarGenerations[scope, default: 0] += 1
            var state = RadarState()
            state.error = "还没有可用于推荐的网络歌单（登录网易云账号后可以创建或收藏）"
            radarStates[scope] = state
            return
        }
        // 已知曲目 ID（上游给的 `trackIds`，或本次会话读过的）。
        var ids = force ? [] : (exploreRadarTrackIDs[playlist.id] ?? playlist.trackIds)
        let preliminarySignature = radarContentSignature(
            scope: scope,
            id: playlist.id,
            ids: ids
        )
        // 同一内容已经加载过 → 不重复请求，**也不清空已有结果**。
        if !force,
           let existing = radarStates[scope],
           existing.contentSignature == preliminarySignature,
           !existing.isLoading {
            return
        }

        // **先作废旧结果并发放代次**：换歌单后旧推荐立即消失。
        let generation = exploreRadarGeneration + 1
        exploreRadarGeneration = generation
        radarGenerations[scope, default: 0] += 1
        var loading = RadarState()
        loading.isLoading = true
        radarStates[scope] = loading

        if ids.isEmpty {
            // 上游没给 `trackIds` → 读一次歌单详情（**只读**）。
            do {
                let detail = try await environment.bridge.playlistDetail(id: playlist.id)
                // 核对：**歌单没换 + 代次没变** 才认这次响应。
                guard !Task.isCancelled, generation == exploreRadarGeneration,
                      radarSeedPlaylist?.id == playlist.id else { return }
                ids = detail.playlist?.trackIds ?? []
                if ids.isEmpty { ids = detail.songs.map(\.id) }
                exploreRadarTrackIDs[playlist.id] = ids
            } catch {
                guard !Task.isCancelled, generation == exploreRadarGeneration,
                      radarSeedPlaylist?.id == playlist.id else { return }
                var state = RadarState()
                state.error = "读取歌单曲目失败：\(Self.describe(error))"
                radarStates[scope] = state
                return
            }
        }

        let request = RadarRequest(
            scope: scope,
            contentSignature: radarContentSignature(
                scope: scope,
                id: playlist.id,
                ids: ids
            ),
            // **真实来源标题**（雷达分区标题 / 队列标题都用它）。
            title: playlist.name,
            seedSongIDs: Array(ids.prefix(RadarService.Limits.maxSeeds)),
            seedLocalTracks: [],
            sourceSongIDs: Set(ids)
        )
        // 已经走到这里就说明 **确实要重新请求**（内容变了 / 用户强制刷新）。
        await loadRadar(request, force: true)
    }

    /// 雷达请求的内容身份（**歌单 + 全部曲目**：内容变了就重新请求）。
    ///
    /// - 包含 **全部** 曲目 ID（不只是前几条）：改动 / 重排都会换身份；
    /// - 用稳定哈希，避免把整张歌单塞进键里。
    func radarContentSignature(
        scope: String,
        id: AnyHashable,
        ids: [Int64],
        extra: String = ""
    ) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func feed(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            hash ^= 0x2C
            hash = hash &* 0x0000_0100_0000_01B3
        }
        feed(scope)
        feed(String(describing: id))
        feed(String(ids.count))
        for value in ids { feed(String(value)) }
        if !extra.isEmpty { feed(extra) }
        return "\(scope)|\(id)|\(ids.count)|\(String(hash, radix: 16))"
    }

    // MARK: - 推荐雷达

    /// 推荐雷达状态（按分区取；没有就是空状态）。
    func radarState(for scope: String) -> RadarState {
        radarStates[scope] ?? RadarState()
    }

    /// 加载推荐雷达（**只读**：不下载、不改歌单，只给播放队列供曲）。
    ///
    /// - 请求 **按歌单及内容身份管理**：同一份内容不重复请求；
    /// - **代次令牌**：快速切换后，旧响应直接丢弃（不会显示旧推荐）；
    /// - **失败独立**：雷达失败 **不影响** 歌单自身的曲目列表。
    func loadRadar(_ request: RadarRequest, force: Bool = false) async {
        if !force,
           let existing = radarStates[request.scope],
           existing.contentSignature == request.contentSignature,
           !existing.isLoading {
            return
        }
        let generation = (radarGenerations[request.scope] ?? 0) + 1
        radarGenerations[request.scope] = generation
        var loading = RadarState()
        loading.isLoading = true
        radarStates[request.scope] = loading

        // 1) 种子：本地曲目没有来源 ID → 小规模精确搜索（不写库、不改标签）。
        var seeds: [Int64] = []
        var seenSeeds = Set<Int64>()
        for id in request.seedSongIDs where id > 0 && seenSeeds.insert(id).inserted {
            seeds.append(id)
        }
        var resolvedLocalIDs = Set<Int64>()
        for track in request.seedLocalTracks.prefix(RadarService.Limits.maxLocalResolutions) {
            if let id = await resolveNeteaseID(for: track) {
                if seenSeeds.insert(id).inserted { seeds.append(id) }
                resolvedLocalIDs.insert(id)
            }
        }

        // 2) 排除集合：来源歌单 + 本机资料库 + 本应用可见的播放记录。
        var exclusions = RadarService.Exclusions()
        exclusions.neteaseIDs.formUnion(request.sourceSongIDs)
        exclusions.neteaseIDs.formUnion(resolvedLocalIDs)
        for track in localSongs {
            if track.neteaseId > 0 { exclusions.neteaseIDs.insert(track.neteaseId) }
            exclusions.titleArtistKeys.insert(
                RadarService.Identity.key(title: track.displayTitle, artist: track.displayArtist)
            )
        }
        exclusions.neteaseIDs.formUnion(playedNeteaseIDs())

        // 3) 取候选（限量：最多几个种子，每个种子少量候选）。
        var candidates: [RemoteSong] = []
        var failures: [String] = []
        var needsLogin = false
        for seed in seeds.prefix(RadarService.Limits.maxSeeds) {
            do {
                let songs = try await environment.bridge.similarSongs(
                    songId: seed,
                    limit: RadarService.Limits.perSeedLimit,
                    offset: 0
                )
                candidates.append(contentsOf: songs)
            } catch {
                if Self.isNeedLogin(error) {
                    needsLogin = true
                } else {
                    failures.append(Self.describe(error))
                }
            }
        }

        // 过期响应直接丢弃（快速切换歌单不会看到旧推荐）。
        guard !Task.isCancelled, generation == radarGenerations[request.scope] else { return }

        var updated = RadarState()
        updated.contentSignature = request.contentSignature
        updated.items = RadarService.filter(candidates: candidates, excluding: exclusions)
        if updated.items.isEmpty {
            if needsLogin {
                updated.error = "需要登录网易云账号后才能获取推荐"
            } else if let first = failures.first {
                updated.error = first
            } else if seeds.isEmpty {
                updated.emptyReason = "这个歌单里没有可用于推荐的曲目"
            } else {
                updated.emptyReason = "没有找到相似的歌曲"
            }
        } else if let first = failures.first {
            updated.warning = "部分推荐来源不可用：\(first)"
        }
        updated.isLoading = false
        radarStates[request.scope] = updated
    }

    /// 本地曲目 → 网易曲目 ID（**小规模精确搜索**）。
    ///
    /// - 只在 **标题 + 艺人完全一致** 时才认（不会拿错同名艺人）；
    /// - **不写库、不改标签**：只是这次推荐用一下。
    private func resolveNeteaseID(for track: TrackRecord) async -> Int64? {
        let title = track.displayTitle
        let artist = track.displayArtist
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        guard title != TrackRecord.unrecognizedPlaceholder,
              artist != TrackRecord.unrecognizedPlaceholder else { return nil }
        do {
            let (songs, _) = try await environment.bridge.searchSongs(
                keywords: "\(title) \(artist)",
                limit: RadarService.Limits.searchLimit,
                offset: 0
            )
            for song in songs where RadarService.Identity.matches(
                localTitle: title, localArtist: artist, song: song
            ) {
                return song.id
            }
        } catch {
            // 解析失败只是少一个种子 / 少一条排除项，不影响整体推荐。
        }
        return nil
    }

    /// 本应用已记入播放计数的网易曲目 ID。
    ///
    /// **只覆盖本应用可见的记录** —— 不会宣称「网易账号从未听过」。
    private func playedNeteaseIDs() -> Set<Int64> {
        var ids = Set<Int64>()
        let prefix = "netease:"
        for key in environment.store.current.playCounts.keys where key.hasPrefix(prefix) {
            if let id = Int64(key.dropFirst(prefix.count)), id > 0 { ids.insert(id) }
        }
        return ids
    }

    /// 错误是不是「需要登录」。
    static func isNeedLogin(_ error: Error) -> Bool {
        (error as? BridgeClient.BridgeError)?.code == "NeedLogin"
    }

    /// 播放推荐雷达的结果：**保留全部已展示的雷达项**，从被点击的那一首开始。
    ///
    /// 队列里 **只有** 本次展示的雷达结果（不混入歌单原有曲目）；
    /// 起点行为与普通歌单播放一致（`replaceQueue(items, startAt:)`）。
    ///
    /// - Parameter title: **来源歌单的真实标题**（队列入口与队列页头部显示它）。
    func playRadar(_ songs: [RemoteSong], startAt index: Int, title: String) {
        let items = RadarService.playbackItems(songs)
        guard !items.isEmpty else { return }
        setPlaybackContext(.radar(title: title))
        Task { await player.replaceQueue(items, startAt: index) }
    }

    // MARK: - 私人 FM

    /// 播放私人 FM（**从被点击的那张卡片开始**：当前批真实歌曲进队列）。
    ///
    /// - 队列入口与队列页头部都显示「私人 FM」；
    /// - **新会话**：作废之前所有在途取批响应（换卡片 = 重新开始）。
    func playPersonalFM(_ songs: [RemoteSong], startAt index: Int) {
        let items = songs.map { PlaybackItem.remote($0) }
        guard !items.isEmpty else { return }
        setPlaybackContext(.personalFM)
        fmError = nil
        fmPauseRequested = false
        fmSession.beginSession()
        fmSession.register(songs)
        Task { await player.replaceQueue(items, startAt: index) }
    }

    /// 队列耗尽（**只有私人 FM 消费**）：取下一批并自动接播。
    private func handleQueueExhausted() {
        guard case .personalFM = playbackContext else { return }
        Task { await fetchNextPersonalFMBatch() }
    }

    /// 取下一批私人 FM（**成功就接播**；空 / 失败不自动重试，由用户点「下一首」）。
    private func fetchNextPersonalFMBatch() async {
        guard case .personalFM = playbackContext else { return }
        // 用户 **清空了队列** → 不再接管（队列空了 = 用户主动清掉）。
        guard !player.queue.isEmpty else { return }
        // **一次耗尽只发一个请求**（并发合并）；用户点「下一首」会再发起一次。
        guard let generation = fmSession.beginRequest() else { return }
        fmPauseRequested = false
        // **记住请求发出时的当前队列项**：用户按了「上一首」或在 FM 队列里
        // 点了别的曲目 → 这批旧结果 **不得抢播**。
        let anchorEntryID = player.current?.queueEntryId
        defer { fmSession.endRequest(generation: generation) }
        do {
            let songs = try await environment.bridge.personalFM()
            // **旧会话的响应不得接管队列**（换来源 / 换卡片 / 清空 / 退出登录）。
            guard fmSession.accepts(generation: generation),
                  case .personalFM = playbackContext,
                  !player.queue.isEmpty else { return }
            // 用户在取批途中换了曲目 → 旧批不抢播。
            guard player.current?.queueEntryId == anchorEntryID else { return }
            // 暂停标志 **只针对在途续批**（见 `onUserPause`）。
            if fmPauseRequested {
                fmPauseRequested = false
                fmError = "已暂停，没有自动接播下一批"
                return
            }
            let fresh = fmSession.filter(songs)
            guard !fresh.isEmpty else {
                // **空结果 / 全是重复** → 不自动重试（否则会无限请求）。
                fmError = "没有更多私人 FM 了"
                return
            }
            fmSession.register(fresh)
            // **成功时清掉上一次的错误**。
            fmError = nil
            let items = fresh.map { PlaybackItem.remote($0) }
            await player.replaceQueue(items, startAt: 0)
        } catch {
            guard fmSession.accepts(generation: generation) else { return }
            fmError = "获取私人 FM 失败：\(Self.describe(error))"
        }
    }

    // MARK: - 播放

    /// 设置播放上下文（**同时更新队列耗尽策略**）。
    ///
    /// - 私人 FM：**队列耗尽由外部接管**（取下一批并自动接播，
    ///   手动「下一首」也先识别耗尽，不重开普通随机轮）；
    /// - 其他来源：普通行为（随机模式播完一轮会重开一轮）。
    private func setPlaybackContext(_ context: PlaybackContext) {
        playbackContext = context
        player.continuesOnExhaustion = (context == .personalFM)
    }

    func playLocal(_ track: TrackRecord) {
        setPlaybackContext(.none)
        Task { await player.replaceQueue([.local(track)]) }
    }

    func playRemote(_ song: RemoteSong) {
        setPlaybackContext(.none)
        Task { await player.replaceQueue([.remote(song)]) }
    }

    /// 从 **本地歌单** 播放（播放上下文 = 该歌单）。
    func playLocalPlaylist(_ playlist: LocalPlaylist, index: Int) {
        let items: [PlaybackItem] = playlist.entries.map { item -> PlaybackItem in
            if let track = environment.index.track(path: item.path) {
                return .local(track)
            }
            return PlaybackItem(
                title: item.displayName,
                artist: "",
                durationMs: Int64(item.duration * 1000),
                origin: .local(path: item.path)
            )
        }
        setPlaybackContext(.localPlaylist(playlist.id))
        // **开始播放时**选中来源行并展开对应分组（不抢用户后续的浏览）。
        localSectionExpanded = true
        selection = .localPlaylist(playlist.id)
        Task { await player.replaceQueue(items, startAt: index) }
    }

    /// 从 **网络歌单** 播放（播放上下文 = 该歌单）。
    func playRemotePlaylist(_ playlist: RemotePlaylist, song: RemoteSong) {
        setPlaybackContext(.remotePlaylist(playlist.id))
        // **开始播放时**选中来源行并展开对应分组（不抢用户后续的浏览）。
        remoteSectionExpanded = true
        selection = .remotePlaylist(playlist.id)
        Task { await player.replaceQueue([.remote(song)]) }
    }

    func playResult(_ result: SearchResult) {
        switch result {
        case .local(let track): playLocal(track)
        case .remote(let song): playRemote(song)
        }
    }

    // MARK: - 队列入口（侧栏）与来源行

    /// 侧栏的队列入口（**条件入口**：没有队列就不显示）。
    ///
    /// - **播放本地 / 网络歌单时隐藏**：队列就是那张歌单本身，
    ///   播放器条上的队列图标仍可显式访问 **当前实际队列**；
    /// - 雷达 → 「“XX”的推荐雷达」；私人 FM → 「私人 FM」；
    /// - 普通临时队列 → 「临时播放」。
    var queueEntry: String? {
        guard !player.queue.isEmpty else { return nil }
        switch playbackContext {
        case .localPlaylist, .remotePlaylist:
            return nil
        case .none:
            return "临时播放"
        case .radar(let title):
            return title.isEmpty ? "推荐雷达" : "“\(title)”的推荐雷达"
        case .personalFM:
            return "私人 FM"
        }
    }

    /// 队列页 / 队列入口的标题（**按来源显示真实名字**）。
    var queueDisplayTitle: String {
        switch playbackContext {
        case .none:
            return "临时播放"
        case .localPlaylist(let id):
            return localPlaylists.first { $0.id == id }?.title ?? "本地歌单"
        case .remotePlaylist(let id):
            return remotePlaylist(withID: id)?.name ?? "网络歌单"
        case .radar(let title):
            return title.isEmpty ? "推荐雷达" : "“\(title)”的推荐雷达"
        case .personalFM:
            return "私人 FM"
        }
    }

    /// 正在播放的网络歌单。
    private var currentRemoteSourceID: Int64? {
        switch playbackContext {
        case .remotePlaylist(let id): return id
        default: return nil
        }
    }

    /// 网络歌单查找（**收藏的 + 临时预览的**）。
    func remotePlaylist(withID id: Int64) -> RemotePlaylist? {
        remotePlaylists.first { $0.id == id } ?? transientRemotePlaylists.first { $0.id == id }
    }

    /// 侧栏「网络歌单」组显示的行。
    ///
    /// - 正常：**收藏的网络歌单**（+ 公开推荐歌单的临时预览行）；
    /// - 隐藏偏好：**只**显示当前来源行（正在播放 / 正在预览的那一行），
    ///   **设置值不变**。
    var sidebarRemotePlaylists: [RemotePlaylist] {
        var previewID: Int64?
        if case .remotePlaylist(let id) = selection { previewID = id }
        var rows = environment.store.current.settings.hideRemotePlaylists ? [] : remotePlaylists
        for id in [currentRemoteSourceID, previewID].compactMap({ $0 }) where !rows.contains(where: { $0.id == id }) {
            if let playlist = remotePlaylist(withID: id) { rows.append(playlist) }
        }
        return rows
    }

    /// 打开公开推荐歌单（**只读详情**：与已有网络歌单同一条路）。
    ///
    /// - **不写进收藏、不持久化**：只留一个稳定 ID 的临时行。
    func openRecommendedPlaylist(_ playlist: RemotePlaylist) {
        let playingID = currentRemoteSourceID
        transientRemotePlaylists.removeAll { $0.id == playlist.id || $0.id != playingID }
        transientRemotePlaylists.append(playlist)
        remoteSectionExpanded = true
        selection = .remotePlaylist(playlist.id)
    }

    func enqueueResult(_ result: SearchResult) {
        switch result {
        case .local(let track): player.enqueue([.local(track)])
        case .remote(let song): player.enqueue([.remote(song)])
        }
        banner = .info("已加入临时播放")
    }

    /// 把当前队列另存为 **本地歌单**（网络曲目先下载再入单）。
    func saveQueueAsLocalPlaylist(title: String, details: String) async {
        let items = player.queue
        guard !items.isEmpty else {
            banner = .error("临时播放是空的，没有可保存的曲目")
            return
        }
        do {
            let playlist = try environment.library.createPlaylist(title: title, details: details)
            var localEntries: [PlaylistEntry] = []
            var remoteItems: [PlaybackItem] = []
            for item in items {
                switch item.origin {
                case .local(let path):
                    let track = environment.index.track(path: path)
                    localEntries.append(PlaylistEntry(
                        path: path,
                        duration: track.map { Double($0.durationMs) / 1000 } ?? 0,
                        displayName: item.title
                    ))
                case .remote:
                    remoteItems.append(item)
                }
            }
            if !localEntries.isEmpty {
                _ = try environment.library.addToPlaylist(id: playlist.id, entries: localEntries)
            }
            // 网络曲目：**统一审核**（本地已有且质量不低 → 直接入单），否则下载后入单。
            let directory = environment.store.current.settings.downloadDirectory
            var reusedCount = 0
            var queuedCount = 0
            var failures: [String] = []
            for item in remoteItems {
                guard case .remote = item.origin, let song = item.remoteSong else { continue }
                let outcome = await environment.pipeline.requestDownload(
                    song: song,
                    targets: [playlist.id],
                    purpose: .queueSave,
                    directory: directory.isEmpty ? nil : directory
                )
                switch outcome {
                case .reusedLocal:
                    reusedCount += 1
                case .queued:
                    queuedCount += 1
                case .failed(let reason):
                    failures.append("\(song.name)：\(reason)")
                }
            }
            refreshLibrary()
            pendingIntakes = environment.intake.pending
            selection = .localPlaylist(playlist.id)
            if !failures.isEmpty {
                banner = .error("保存队列失败：\(failures.prefix(2).joined(separator: "；"))")
            } else if remoteItems.isEmpty {
                banner = .info("已把队列保存为歌单「\(playlist.title)」")
            } else if queuedCount == 0 {
                banner = .info("已把队列保存为歌单「\(playlist.title)」（\(reusedCount) 首本地已有，直接复用）")
            } else {
                banner = .info("已把队列保存为歌单「\(playlist.title)」（\(queuedCount) 首网络曲目下载完成后自动入单）")
            }
        } catch {
            banner = .error("保存队列失败：\(Self.describe(error))")
        }
    }

    // MARK: - 添加到歌单（默认加入「当前正在播放的歌单」）

    /// 默认添加目标（**当前正在播放的歌单**；没有则用临时队列）。
    ///
    /// 网络歌单是 **只读** 的，不能作为添加目标 → 播放网络歌单时
    /// 「+」默认落到 **临时播放**（网络曲目仍可加入本地歌单）。
    /// **推荐雷达 / 私人 FM** 同样是只读来源 → 也落到临时播放。
    var defaultAdditionTarget: AdditionTarget {
        switch playbackContext {
        case .none: return .queue
        case .localPlaylist(let id): return .localPlaylist(id)
        case .remotePlaylist, .radar, .personalFM: return .queue
        }
    }

    /// 默认添加目标的名称（提示用）。
    var defaultAdditionTargetTitle: String {
        switch defaultAdditionTarget {
        case .queue: return "临时播放"
        case .localPlaylist(let id):
            return localPlaylists.first { $0.id == id }?.title ?? "本地歌单"
        case .newLocalPlaylist: return "新建歌单"
        }
    }

    /// 「+」：默认加入 **当前正在播放的歌单**（没有则加入临时队列）。
    func addToCurrentTarget(_ result: SearchResult) async {
        switch defaultAdditionTarget {
        case .queue:
            lastAddition = enqueueWithReceipt(result)
        case .localPlaylist(let id):
            await addToLocalPlaylist(result, playlistId: id, isDefault: true)
        case .newLocalPlaylist:
            banner = .error("请先新建歌单")
        }
    }

    /// 加入本地歌单（**网络曲目先下载，落盘成功后才入单**）。
    func addToLocalPlaylist(_ result: SearchResult, playlistId: String, isDefault: Bool = false) async {
        switch result {
        case .local(let track):
            let appended = addLocalTracksToPlaylist([track.path], playlistId: playlistId)
            if isDefault {
                lastAddition = AdditionReceipt(
                    target: .localPlaylist(playlistId),
                    localNewlyAdded: appended.isEmpty ? [:] : [playlistId: appended],
                    title: track.title,
                    track: track
                )
            }
        case .remote(let song):
            await addRemoteSongToLocalPlaylist(song, playlistId: playlistId, isDefault: isDefault)
        }
    }

    /// 网络曲目加入本地歌单：**先下载，成功后入单**。
    ///
    /// - 入队前 **持久化入单意图**（按下载任务 / 目标 / 实际路径跟踪确认）；
    /// - **统一审核**：本地已有且质量不低 → 直接入单（不重复下载）。
    func addRemoteSongToLocalPlaylist(
        _ song: RemoteSong,
        playlistId: String,
        isDefault: Bool = false
    ) async {
        let directory = environment.store.current.settings.downloadDirectory
        let outcome = await environment.pipeline.requestDownload(
            song: song,
            targets: [playlistId],
            purpose: .playlistAddition,
            directory: directory.isEmpty ? nil : directory
        )
        switch outcome {
        case .reusedLocal(_, let reason, let added):
            refreshLibrary()
            pendingIntakes = environment.intake.pending
            banner = .info("本地已有该曲目（\(reason)），已直接加入歌单")
            if isDefault {
                lastAddition = AdditionReceipt(
                    target: .localPlaylist(playlistId),
                    localNewlyAdded: added.isEmpty ? [:] : [playlistId: added],
                    title: song.name,
                    song: song
                )
            }
        case .queued:
            banner = .info("已加入下载队列，完成后自动入单")
            if isDefault {
                lastAddition = AdditionReceipt(target: .localPlaylist(playlistId), title: song.name, song: song)
            }
        case .failed(let reason):
            banner = .error(reason)
        }
    }

    /// 「更改添加目标」：**撤回这次默认添加**（只撤回本次新增），再加入新目标。
    func changeAdditionTarget(to target: AdditionTarget) async {
        guard let receipt = lastAddition else {
            banner = .error("没有可更改的添加记录")
            return
        }
        guard target != receipt.target else {
            showingAdditionTargetPicker = false
            return
        }
        guard await undoAddition(receipt) else { return }
        lastAddition = nil
        switch target {
        case .queue:
            if let track = receipt.track {
                lastAddition = enqueueWithReceipt(.local(track))
            } else if let song = receipt.song {
                lastAddition = enqueueWithReceipt(.remote(song))
            }
            banner = .info("已撤回上一次添加，并加入临时播放")
        case .localPlaylist(let id):
            if let track = receipt.track {
                await addToLocalPlaylist(.local(track), playlistId: id, isDefault: true)
            } else if let song = receipt.song {
                await addToLocalPlaylist(.remote(song), playlistId: id, isDefault: true)
            } else {
                banner = .error("找不到曲目「\(receipt.title)」")
            }
        case .newLocalPlaylist:
            banner = .info("已撤回上一次添加，请新建歌单后重新添加")
        }
        if target != .newLocalPlaylist {
            showingAdditionTargetPicker = false
        }
    }

    private func enqueueWithReceipt(_ result: SearchResult) -> AdditionReceipt {
        let item: PlaybackItem
        switch result {
        case .local(let track): item = .local(track)
        case .remote(let song): item = .remote(song)
        }
        player.enqueue([item])
        banner = .info("已加入临时播放")
        return AdditionReceipt(
            target: .queue, queueEntryId: item.queueEntryId,
            title: result.title, song: result.song, track: result.track
        )
    }

    /// 撤回一次添加（**只撤回本次新增**，之前就有的条目不动）。
    private func undoAddition(_ receipt: AdditionReceipt) async -> Bool {
        if let id = receipt.queueEntryId { player.removeQueueEntry(id: id) }
        if case .localPlaylist(let id) = receipt.target, let song = receipt.song {
            do {
                _ = try environment.intake.withdrawPending(taskId: song.id, playlistId: id)
                pendingIntakes = environment.intake.pending
            } catch {
                banner = .error("撤回待入单请求失败：\(Self.describe(error))")
                return false
            }
        }
        if !receipt.localNewlyAdded.isEmpty {
            let removed = environment.intake.undoNewlyAdded(receipt.localNewlyAdded)
            refreshLibrary()
            if removed != receipt.localNewlyAdded {
                banner = .warning("撤回失败：本次新增的条目未能全部移除")
                return false
            }
        }
        return true
    }

    // MARK: - 下载

    func refreshDownloads() async {
        do {
            let tasks = try await environment.bridge.downloadTasks()
            downloadTasks = tasks
            // 入单意图绑定实际路径（**下载完成后才知道路径**）。
            do {
                _ = try environment.intake.bindPaths(tasks: tasks)
            } catch {
                banner = .error("绑定入单路径失败：\(Self.describe(error))")
            }
            // 自动保存与真实下载队列对账（不会永远 pending）。
            do {
                let report = try environment.autoSave.reconcile(with: tasks)
                if !report.becameRetryable.isEmpty {
                    banner = .warning("有 \(report.becameRetryable.count) 首自动保存的曲目已不在下载队列，可重试")
                }
            } catch {
                banner = .error("自动保存对账失败：\(Self.describe(error))")
            }
            autoSavePending = environment.autoSave.pending
            pendingIntakes = environment.intake.pending
            // 上次会话遗留的未完成任务 → 尝试恢复。
            await recoverUnfinishedDownloads(tasks)
        } catch {
            banner = .error("读取下载队列失败：\(Self.describe(error))")
        }
    }

    /// 恢复上次会话遗留的未完成任务（**不丢目标歌单**）。
    private func recoverUnfinishedDownloads(_ tasks: [DownloadTask]) async {
        guard !isRecoveringDownloads else { return }
        isRecoveringDownloads = true
        defer { isRecoveringDownloads = false }
        // **按会话范围**判断：本次进程没碰过的在途任务 = 上次会话遗留 → 恢复。
        for task in tasks where task.isActive && !sessionDownloadTaskIDs.contains(task.id) {
            // 与手动重试共用审核、替换登记和本地入单；重试中的刷新不能递归恢复。
            await retryDownload(id: task.id)
        }
    }

    /// 记录本次进程触碰过的下载任务（**会话范围**）。
    private func touchDownloadTask(_ id: Int64) {
        guard !sessionDownloadTaskIDs.contains(id) else { return }
        sessionDownloadTaskIDs.insert(id)
    }

    func retryDownload(id: Int64) async {
        do {
            let tasks = try await environment.bridge.downloadTasks()
            guard let task = tasks.first(where: { $0.id == id }) else {
                banner = .error("找不到该下载任务")
                return
            }
            // **统一审核（只审一次，避免 TOCTOU 的双审核）**。
            let song = DownloadPipeline.song(from: task)
            let decision = await environment.review.review(song: song)
            switch decision {
            case .reuseLocal(let candidate, _):
                // 本地已有可用文件 → **不重新下载**，直接入单。
                let outcome = await environment.pipeline.completeWithLocalFile(
                    task: task,
                    path: candidate.track.path
                )
                pendingIntakes = environment.intake.pending
                refreshLibrary()
                if outcome.pendingCount > 0 {
                    banner = .warning("「\(task.name)」已入单，但仍有 \(outcome.pendingCount) 个目标待处理")
                } else {
                    banner = .info("「\(task.name)」本地已有可用文件，已直接入单（未重新下载）")
                }
                return
            case .replaceLocal(let candidate, _):
                // 需要升级 → **先登记替换意图**，
                // 否则新文件到达后会变成资料库里的第二份副本。
                await environment.replacement.repairPending()
                do {
                    try environment.replacement.register(neteaseId: song.id, oldPath: candidate.track.path)
                } catch {
                    banner = .error("登记替换意图失败：\(Self.describe(error))")
                    return
                }
            case .downloadNew:
                break
            }
            let result = try await environment.bridge.retryDownload(id: id)
            // **成功重试后才记账**：失败时不算「本次会话」，旧队列仍可继续恢复。
            touchDownloadTask(id)
            // **done 重试补偿**：重试后重新执行入单（之前失败的入单会补上）。
            let outcome = environment.intake.retryPending(taskId: id)
            await refreshDownloads()
            refreshLibrary()
            pendingIntakes = environment.intake.pending
            if outcome.hasFailure {
                banner = .error("下载已重试，但仍有 \(outcome.pending.count) 个入单目标待处理")
            } else if result.recovered {
                banner = .info("已从本地恢复该下载")
            } else {
                banner = .info("已重新加入下载队列")
            }
        } catch {
            banner = .error("重试失败：\(Self.describe(error))")
        }
    }

    /// 重试所有待处理的入单操作。
    func retryPendingIntakes() {
        let outcome = environment.intake.retryPending()
        refreshLibrary()
        pendingIntakes = environment.intake.pending
        if outcome.hasFailure {
            let reasons = outcome.pending.prefix(3)
                .compactMap { $0.lastError }
                .joined(separator: "；")
            banner = .error("仍有 \(outcome.pending.count) 个入单目标待处理\(reasons.isEmpty ? "" : "：\(reasons)")")
        } else {
            banner = .info("待处理入单已全部补入")
        }
    }

    func clearFinishedDownloads() async {
        do {
            try await environment.bridge.clearDownloads(onlyDone: true)
            await refreshDownloads()
            banner = .info("已清除完成的任务")
        } catch {
            banner = .error("清除失败：\(Self.describe(error))")
        }
    }

    /// 下载页与入口使用的任务列表（**会话范围**）。
    ///
    /// 上次会话遗留的 **已完成记录** 不显示；未完成 / 失败的任务仍显示
    /// （可重试、「待处理」入口可达）。**持久记录不受影响**（不清队列）。
    var visibleDownloadTasks: [DownloadTask] {
        DownloadSessionScope.visibleTasks(downloadTasks, touched: sessionDownloadTaskIDs)
    }

    /// 任务是否已被 **本次进程** 接手（会话范围）。
    ///
    /// 旧会话遗留、还没恢复的在途任务 → **不是**本次会话的进度，
    /// 但必须能手动重试（否则只剩一个不可操作的「排队中」）。
    func isCurrentSessionTask(_ task: DownloadTask) -> Bool {
        sessionDownloadTaskIDs.contains(task.id)
    }

    /// 可见任务里的已完成数量（清除按钮的可用性）。
    var visibleCompletedDownloadCount: Int {
        visibleDownloadTasks.filter { $0.isDone }.count
    }

    /// 进行中的任务数（侧栏唯一允许显示数字的地方）。
    var activeDownloadCount: Int {
        DownloadSessionScope.activeCount(tasks: downloadTasks, touched: sessionDownloadTaskIDs)
    }

    /// 待处理数量（失败 + 尚未恢复的旧队列 + 待入单 + 自动保存待重试）。
    var pendingDownloadCount: Int {
        DownloadSessionScope.pendingCount(
            tasks: downloadTasks,
            touched: sessionDownloadTaskIDs,
            pendingIntakes: pendingIntakes.count,
            autoSavePending: autoSavePending.count
        )
    }

    /// 下载入口的显示状态（**没有可显示的状态就隐藏入口**）。
    var downloadEntry: (title: String, badge: Int)? {
        guard let entry = DownloadSessionScope.entry(
            tasks: downloadTasks,
            touched: sessionDownloadTaskIDs,
            pendingIntakes: pendingIntakes.count,
            autoSavePending: autoSavePending.count
        ) else {
            return nil
        }
        return (entry.title, entry.badge)
    }

    // MARK: - 设置

    /// 保存设置（**只提交改动字段**，并且 **等真实保存完成** 再提示成功）。
    func updateSettings(
        quality: String? = nil,
        sources: [String]? = nil,
        downloadDirectory: String? = nil,
        playlistsDirectory: String? = nil,
        libraryFolders: [String]? = nil,
        autoSaveEnabled: Bool? = nil,
        autoSaveThreshold: Int? = nil,
        hideRemotePlaylists: Bool? = nil
    ) async {
        do {
            // 桥接侧设置（音质 / 音源 / 下载目录）**必须等真实返回**。
            if quality != nil || sources != nil || downloadDirectory != nil {
                try await environment.bridge.updateSettings(
                    quality: quality,
                    sources: sources,
                    downloadDirectory: downloadDirectory
                )
            }
            try environment.store.mutate { state in
                if let playlistsDirectory { state.settings.playlistsDirectory = playlistsDirectory }
                if let libraryFolders { state.settings.libraryFolders = libraryFolders }
                if let downloadDirectory { state.settings.downloadDirectory = downloadDirectory }
                if let autoSaveEnabled { state.settings.autoSaveEnabled = autoSaveEnabled }
                if let autoSaveThreshold { state.settings.autoSaveThreshold = max(1, autoSaveThreshold) }
                if let hideRemotePlaylists { state.settings.hideRemotePlaylists = hideRemotePlaylists }
            }
            refreshLibrary()
            // 保存后重新读会话，确保界面显示的是 **真实落盘** 的值。
            await refreshSession()
            banner = .info("设置已保存")
        } catch {
            banner = .error("保存设置失败：\(Self.describe(error))")
        }
    }

    // MARK: - 艺人 / 专辑详情

    /// 艺人详情：**本地上方、网络热门与新作下方**。
    func loadArtistDetail(name: String, remoteID: Int64?) async {
        let key = artistKey(name: name, remoteID: remoteID)
        var data = artistDetails[key] ?? ArtistDetailData()
        data.localTracks = localSongs.filter { $0.artist == name }
        artistDetails[key] = data
        guard let remoteID else { return }
        isLoadingArtistDetail = true
        defer { isLoadingArtistDetail = false }
        do {
            async let hot = environment.bridge.artistTopSongs(id: remoteID)
            async let albums = environment.bridge.artistAlbums(id: remoteID)
            let (hotSongs, remoteAlbums) = try await (hot, albums)
            var updated = artistDetails[key] ?? ArtistDetailData()
            updated.localTracks = data.localTracks
            updated.hotSongs = hotSongs
            updated.albums = remoteAlbums
            updated.error = nil
            artistDetails[key] = updated
        } catch {
            var updated = artistDetails[key] ?? ArtistDetailData()
            updated.localTracks = data.localTracks
            updated.error = Self.describe(error)
            artistDetails[key] = updated
            banner = .error("读取艺人详情失败：\(Self.describe(error))")
        }
    }

    /// 专辑详情（本地曲目 + 网络曲目）。
    func loadAlbumDetail(name: String, artist: String, remoteID: Int64?) async {
        let key = albumKey(name: name, artist: artist, remoteID: remoteID)
        var data = albumDetails[key] ?? AlbumDetailData()
        data.localTracks = localSongs.filter { $0.album == name && (artist.isEmpty || $0.artist == artist) }
        albumDetails[key] = data
        guard let remoteID else { return }
        isLoadingAlbumDetail = true
        defer { isLoadingAlbumDetail = false }
        do {
            let detail = try await environment.bridge.albumDetail(id: remoteID)
            var updated = albumDetails[key] ?? AlbumDetailData()
            updated.localTracks = data.localTracks
            updated.songs = detail.songs
            updated.error = nil
            albumDetails[key] = updated
        } catch {
            var updated = albumDetails[key] ?? AlbumDetailData()
            updated.localTracks = data.localTracks
            updated.error = Self.describe(error)
            albumDetails[key] = updated
            banner = .error("读取专辑详情失败：\(Self.describe(error))")
        }
    }

    func artistKey(name: String, remoteID: Int64?) -> String {
        "\(name)|\(remoteID ?? 0)"
    }

    func albumKey(name: String, artist: String, remoteID: Int64?) -> String {
        "\(artist)|\(name)|\(remoteID ?? 0)"
    }

    // MARK: - 删除本地文件（真实废纸篓）

    /// 删除前的计划（**受影响歌单数**给确认弹窗用）。
    func trashPlan(for track: TrackRecord) -> TrashService.Plan {
        environment.trash.plan(path: track.path, title: track.title.isEmpty ? track.path : track.title)
    }

    /// 确认删除（**真实移入废纸篓**）。
    func confirmTrashDelete(_ track: TrackRecord) async {
        // 正在播放被删的本地文件 → **先停止播放**。
        // 注意：网络曲目 **本地优先** 命中时播放的也是这个文件，
        // 所以要按 **实际加载的路径** 判断，不能只看队列项的来源。
        if player.current?.id == "path:\(track.path)" {
            player.stopPlayback()
        } else {
            // 网络曲目本地优先命中时，播的也是这个文件。
            _ = player.stopIfPlayingLocalFile(path: track.path)
        }
        do {
            let result = try environment.trash.delete(
                path: track.path,
                title: track.title.isEmpty ? track.path : track.title
            )
            refreshLibrary()
            pendingIntakes = environment.intake.pending
            if result.isComplete {
                banner = .info("已移到废纸篓，并清理了 \(result.cleanedPlaylistIds.count) 个歌单引用")
            } else {
                let details = result.cleanupFailures
                    .map { "\($0.key)：\($0.value)" }
                    .joined(separator: "；")
                banner = .warning("文件已移到废纸篓，但引用清理未完成：\(details)")
            }
        } catch {
            // 失败 **不提前清数据**。
            banner = .error("移到废纸篓失败：\(Self.describe(error))")
        }
    }

    // MARK: - 事件

    private func subscribeBridgeEvents() {
        environment.client.onEvent { [weak self] name, payload in
            Task { @MainActor in
                guard let self else { return }
                switch name {
                case "dl":
                    self.handleDownloadEvent(payload)
                case "dl.persistError":
                    let message = payload["error"] as? String ?? "未知错误"
                    self.banner = .error("下载状态保存失败：\(message)")
                case "scan":
                    break
                default:
                    break
                }
            }
        }
    }

    private func handleDownloadEvent(_ payload: [String: Any]) {
        guard let task = DownloadTask.parse(payload) else { return }
        // 桥接在本进程里动过的任务 → 计入会话范围。
        touchDownloadTask(task.id)
        if let index = downloadTasks.firstIndex(where: { $0.id == task.id }) {
            downloadTasks[index] = task
        } else {
            downloadTasks.append(task)
        }
        guard task.isDone, !task.path.isEmpty else { return }
        Task { @MainActor [weak self] in
            await self?.finishDownload(task)
        }
    }

    /// 下载 **落盘成功** 后：补元信息 → 升级替换 → 索引 + 加入目标本地歌单。
    ///
    /// 约定：
    /// - **逐目标汇总**：部分失败不会被成功提示覆盖；
    /// - **索引失败不算成功**；
    /// - 失败目标保留在 **持久待处理** 里，可重试；
    /// - **重复 / 并发的完成事件幂等**（统一流程内部串行化）。
    private func finishDownload(_ task: DownloadTask) async {
        let result = await environment.pipeline.completeDownload(task: task)
        pendingIntakes = environment.intake.pending
        autoSavePending = environment.autoSave.pending
        if var receipt = lastAddition, receipt.song?.id == task.id,
           case .localPlaylist(let id) = receipt.target,
           let paths = result.newlyAdded[id], !paths.isEmpty {
            receipt.localNewlyAdded[id, default: []].append(contentsOf: paths)
            lastAddition = receipt
        }
        refreshLibrary()
        report(result: result, task: task)
    }

    /// 把收尾结果汇总成 **一条** 提示（失败优先，不被成功覆盖）。
    private func report(result: DownloadCompletionResult, task: DownloadTask) {
        var problems: [String] = result.notes
        if let indexError = result.indexError {
            problems.append("写入索引失败：\(indexError)")
        }
        if result.pendingCount > 0 {
            problems.append("有 \(result.pendingCount) 个入单目标待处理")
        }
        if !problems.isEmpty {
            let detail = problems.prefix(3).joined(separator: "；")
            let more = problems.count > 3 ? "（另有 \(problems.count - 3) 项）" : ""
            banner = .error("「\(task.name)」下载完成，但有 \(problems.count) 项未完成：\(detail)\(more)")
            return
        }
        if !result.confirmedPlaylistIds.isEmpty {
            banner = .info("「\(task.name)」已下载完成并加入 \(result.confirmedPlaylistIds.count) 个歌单")
        } else if task.targets.isEmpty {
            banner = .info("「\(task.name)」已下载完成")
        }
    }

    // MARK: - 播放计数 / 自动保存

    /// 完整网络播放计数（**只记完整播完的网络曲目**）。
    private func recordCompletedRemotePlay(_ item: PlaybackItem) {
        guard case .remote(let neteaseId) = item.origin else { return }
        let key = NativeState.playCountKey(neteaseId: neteaseId)
        do {
            try environment.store.mutate { state in
                state.playCounts[key, default: 0] += 1
            }
        } catch {
            banner = .error("保存播放计数失败：\(Self.describe(error))")
            return
        }
        Task { @MainActor [weak self] in
            await self?.evaluateAutoSave(item: item, neteaseId: neteaseId)
        }
    }

    /// 自动保存评估（**阈值降低不会立刻批量下载**，只在完整播放时判断）。
    private func evaluateAutoSave(item: PlaybackItem, neteaseId: Int64) async {
        let title = item.title
        let artist = item.artist
        let durationMs = item.durationMs
        let decision = environment.autoSave.evaluate(
            neteaseId: neteaseId,
            title: title,
            artist: artist,
            durationMs: durationMs
        )
        // `.none` = 不保存；`.enqueue` = 需要下载；
        // **`.reviewExistingLocal` = 本地已有文件 → 也要走审核**（判断要不要升级质量）。
        switch decision {
        case .none:
            return
        case .enqueue, .reviewExistingLocal:
            break
        }
        guard let song = item.remoteSong else {
            // 没有完整曲目数据（例如搜索结果里只有 ID）→ 不猜，交给用户手动下载。
            return
        }
        await enqueueAutoSave(song: song, neteaseId: neteaseId)
    }

    /// 发起自动保存（**走统一审核**：本地已有且质量不低 → 不下载）。
    private func enqueueAutoSave(song: RemoteSong, neteaseId: Int64) async {
        let directory = environment.store.current.settings.downloadDirectory
        let outcome = await environment.pipeline.requestAutoSave(
            song: song,
            directory: directory.isEmpty ? nil : directory
        )
        autoSavePending = environment.autoSave.pending
        switch outcome {
        case .reusedLocal(_, let reason, _):
            banner = .info("「\(song.name)」本地已有文件（\(reason)），已标记为保存完成")
        case .queued:
            await refreshDownloads()
            let count = environment.store.current.playCounts[NativeState.playCountKey(neteaseId: neteaseId)] ?? 0
            banner = .info("「\(song.name)」已完整播放 \(count) 次，已自动加入下载队列")
        case .failed(let reason):
            banner = .error("自动保存失败：\(reason)")
        }
    }

    /// **真正重试**自动保存（不是「再听一遍」）。
    ///
    /// 顺序：
    /// 1. 本地已有该曲目 → 直接标记已保存；
    /// 2. 真实下载队列里还有任务 → 按任务状态处理（进行中 / 失败重试 / 已完成落盘）；
    /// 3. 队列里没有 → **立即重新入队**（先写意图）。
    func retryAutoSave(neteaseId: Int64) async {
        guard let record = environment.autoSave.record(neteaseId: neteaseId) else {
            banner = .error("没有该曲目的自动保存记录")
            return
        }
        // 1) 已经在本地 → 标记已保存。
        if environment.library.matchLocalTrack(neteaseId: neteaseId) != nil {
            do {
                try environment.autoSave.markSaved(neteaseId: neteaseId)
                autoSavePending = environment.autoSave.pending
                banner = .info("「\(record.title)」本地已有文件，已标记为保存完成")
            } catch {
                banner = .error("写入自动保存状态失败：\(Self.describe(error))")
            }
            return
        }
        // 2) 看 **真实下载队列**。
        do {
            let tasks = try await environment.bridge.downloadTasks()
            if let task = tasks.first(where: { $0.id == neteaseId }) {
                if task.isActive {
                    banner = .info("「\(record.title)」仍在下载队列中")
                    return
                }
                if task.isFailed {
                    // **重下载前统一审核一次**：本地已有可用文件就不重下；
                    // 需要升级则先登记替换意图（新文件到达后替换旧文件，不产生第二份）。
                    let song = DownloadPipeline.song(from: task)
                    let decision = await environment.review.review(song: song)
                    switch decision {
                    case .reuseLocal:
                        banner = .info("「\(record.title)」本地已有可用文件，无需重新下载")
                        return
                    case .replaceLocal(let candidate, _):
                        await environment.replacement.repairPending()
                        do {
                            try environment.replacement.register(neteaseId: song.id, oldPath: candidate.track.path)
                        } catch {
                            banner = .error("登记替换意图失败：\(Self.describe(error))")
                            return
                        }
                    case .downloadNew:
                        break
                    }
                    _ = try await environment.bridge.retryDownload(id: task.id)
                    await refreshDownloads()
                    banner = .info("已重新加入下载队列：\(record.title)")
                    return
                }
                if task.isDone, !task.path.isEmpty, FileManager.default.fileExists(atPath: task.path) {
                    // **走统一流程**：索引 / 元信息补全 / 替换 / 入单都要跑一遍
                    // （只标记「已保存」会让文件不进资料库）。
                    let result = await environment.pipeline.completeDownload(task: task)
                    autoSavePending = environment.autoSave.pending
                    refreshLibrary()
                    if result.notes.isEmpty {
                        banner = .info("「\(record.title)」已落盘，已完成入库")
                    } else {
                        banner = .warning(
                            "「\(record.title)」已落盘，但有未完成项：\(result.notes.prefix(2).joined(separator: "；"))"
                        )
                    }
                    return
                }
            }
        } catch {
            banner = .error("读取下载队列失败：\(Self.describe(error))")
            return
        }
        // 3) 队列里没有 → 立即重新入队。
        await enqueueAutoSave(song: record.makeSong(), neteaseId: neteaseId)
    }

    /// 播放次数（网络曲目）。
    func playCount(neteaseId: Int64) -> Int {
        environment.store.current.playCounts[NativeState.playCountKey(neteaseId: neteaseId)] ?? 0
    }

    // MARK: - 元信息（E5）

    /// 打开元信息编辑器（**只有保存成功后才写索引**）。
    func openMetadataEditor(for track: TrackRecord) {
        metadataEditorTrack = track
    }

    /// 元信息保存成功回调：**写索引 + 刷新资料库**。
    func applyMetadataUpdate(_ track: TrackRecord) {
        do {
            try environment.index.upsert(track)
            refreshLibrary()
            banner = .info("已保存「\(track.title)」的元信息")
        } catch {
            banner = .error("写入本地索引失败：\(Self.describe(error))")
        }
    }

    /// 元信息设置文件位置（`<数据根目录>/metadata-settings.json`）。
    var metadataSettingsURL: URL {
        AppPaths.appSupportDir.appendingPathComponent("metadata-settings.json", isDirectory: false)
    }

    // MARK: - 工具

    static func describe(_ error: Error) -> String {
        if let serviceError = error as? BridgeServiceError { return serviceError.description }
        if let libraryError = error as? LocalLibraryError { return libraryError.description }
        if let storeError = error as? NativeStore.StoreError { return storeError.description }
        if let indexError = error as? LibraryIndex.IndexError { return indexError.description }
        if let playlistError = error as? PlaylistFile.PlaylistError { return playlistError.description }
        if let trashError = error as? TrashError { return trashError.description }
        if let bridgeError = error as? BridgeClient.BridgeError { return bridgeError.description }
        if let clientError = error as? BridgeClient.ClientError { return clientError.description }
        if let pathError = error as? AppPathsError { return pathError.description }
        if let environmentError = error as? AlgerEnvironmentError { return environmentError.description }
        return error.localizedDescription
    }
}
