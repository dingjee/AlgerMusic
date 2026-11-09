import Foundation

/// 播放顺序模式。
///
/// - `ordered`：按歌单 / 队列的原始顺序播放（默认）；
/// - `shuffle`：随机播放（同一首不会连续重复，除非队列里只有它）。
public enum PlaybackOrder: String, Codable, Equatable, CaseIterable, Sendable {
    case ordered
    case shuffle

    /// 中文显示名。
    public var title: String {
        switch self {
        case .ordered: return "顺序播放"
        case .shuffle: return "随机播放"
        }
    }

    /// 另一种模式（界面上的切换按钮用）。
    public var toggled: PlaybackOrder {
        self == .ordered ? .shuffle : .ordered
    }
}

/// 原生端设置（`native.json` 的 `settings` 段）。
///
/// 与 Rust 侧 `session.json` **完全分离**：这里只放原生端自己的东西
/// （设置、播放计数、本地歌单注册表），**不含任何凭证**。
/// 两条数据线互不覆盖，升级不会破坏已有会话 schema。
public struct NativeSettings: Codable, Equatable {
    /// 本地歌单目录（M3U8 存放处）。
    public var playlistsDirectory: String
    /// 参与扫描的音乐目录。
    public var libraryFolders: [String]
    /// 下载目录。
    public var downloadDirectory: String
    /// 自动保存开关（完整在线播放达阈值后自动落盘）。
    public var autoSaveEnabled: Bool
    /// 自动保存阈值（完整在线播放次数）。
    public var autoSaveThreshold: Int
    /// 是否隐藏远程歌单分组。
    public var hideRemotePlaylists: Bool
    /// 播放顺序模式（**上次选择的顺序 / 随机** 会持久保存）。
    public var playbackOrder: PlaybackOrder

    public init(
        playlistsDirectory: String = "",
        libraryFolders: [String] = [],
        downloadDirectory: String = "",
        autoSaveEnabled: Bool = true,
        autoSaveThreshold: Int = 3,
        hideRemotePlaylists: Bool = false,
        playbackOrder: PlaybackOrder = .ordered
    ) {
        self.playlistsDirectory = playlistsDirectory
        self.libraryFolders = libraryFolders
        self.downloadDirectory = downloadDirectory
        self.autoSaveEnabled = autoSaveEnabled
        self.autoSaveThreshold = autoSaveThreshold
        self.hideRemotePlaylists = hideRemotePlaylists
        self.playbackOrder = playbackOrder
    }

    private enum CodingKeys: String, CodingKey {
        case playlistsDirectory
        case libraryFolders
        case downloadDirectory
        case autoSaveEnabled
        case autoSaveThreshold
        case hideRemotePlaylists
        case playbackOrder
    }

    /// 宽容解码：缺字段用默认值（旧版本文件不会因为缺字段而整体报废）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playlistsDirectory = try container.decodeIfPresent(String.self, forKey: .playlistsDirectory) ?? ""
        libraryFolders = try container.decodeIfPresent([String].self, forKey: .libraryFolders) ?? []
        downloadDirectory = try container.decodeIfPresent(String.self, forKey: .downloadDirectory) ?? ""
        autoSaveEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSaveEnabled) ?? true
        let threshold = try container.decodeIfPresent(Int.self, forKey: .autoSaveThreshold) ?? 3
        autoSaveThreshold = max(1, threshold)
        hideRemotePlaylists = try container.decodeIfPresent(Bool.self, forKey: .hideRemotePlaylists) ?? false
        // 旧版本文件没有这个字段 → 默认顺序播放（不猜、不报错）。
        playbackOrder = try container.decodeIfPresent(PlaybackOrder.self, forKey: .playbackOrder) ?? .ordered
    }
}

/// 本地歌单注册表条目（`native.json` 的 `playlists` 段）。
///
/// **稳定 ID**：一旦创建就不再变化（即使歌单改名、改描述、重排曲目）。
/// M3U8 文件本身存不下标题 / 描述 / ID，因此注册表是唯一的元信息来源，
/// 歌单文件用 `<id>.m3u8` 命名，二者靠 `fileName` 关联。
public struct LocalPlaylistRecord: Codable, Equatable, Identifiable {
    /// 稳定 ID（`pl-<uuid>`，创建后不再变化）。
    public var id: String
    /// 歌单标题。
    public var title: String
    /// 歌单描述。
    public var details: String
    /// M3U8 文件名（相对歌单目录）。
    public var fileName: String
    /// **该歌单 M3U8 实际所在目录**（绝对路径）。
    ///
    /// 改了全局「歌单目录」后，**既有歌单仍然留在原处并可访问**：
    /// 注册表记的是每个歌单的 **真实位置**，不是只有一个全局目录。
    /// 空串 = 老版本记录（回退到当前全局目录）。
    public var directory: String
    /// 创建时间（Unix 秒）。
    public var createdAt: Double
    /// 最近更新时间（Unix 秒）。
    public var updatedAt: Double

    public init(
        id: String,
        title: String,
        details: String = "",
        fileName: String,
        directory: String = "",
        createdAt: Double,
        updatedAt: Double
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.fileName = fileName
        self.directory = directory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case details
        case fileName
        case directory
        case createdAt
        case updatedAt
    }

    /// 宽容解码：缺字段用默认值 / 空串。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "未命名歌单"
        details = try container.decodeIfPresent(String.self, forKey: .details) ?? ""
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        directory = try container.decodeIfPresent(String.self, forKey: .directory) ?? ""
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
    }
}

/// 待恢复的操作（`native.json` 的 `pendingOperations` 段）。
///
/// **可恢复日志**：破坏性操作（删除歌单文件）先登记意图，再执行；
/// 登记失败 / 中断 / 进程被杀时，日志里留下未完成操作，
/// 下次启动可以 **修复**，不会留下「文件没了但注册表还在」的不一致状态。
public struct PendingOperation: Codable, Equatable, Identifiable {
    /// 操作种类：
    /// - `deletePlaylist`：歌单文件已删（或待删），注册表条目需要一起清掉；
    /// - `touchPlaylist`：歌单内容已更新，注册表的修改时间待补。
    public enum Kind: String, Codable, Equatable {
        case deletePlaylist
        case touchPlaylist
    }

    /// 操作 ID。
    public var id: String
    /// 种类。
    public var kind: Kind
    /// 目标歌单 ID。
    public var playlistId: String
    /// 目标文件名（相对歌单目录）。
    public var fileName: String
    /// 登记时间（Unix 秒）。
    public var createdAt: Double
    /// 说明（失败原因等）。
    public var details: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: Kind,
        playlistId: String,
        fileName: String,
        createdAt: Double = Date().timeIntervalSince1970,
        details: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.playlistId = playlistId
        self.fileName = fileName
        self.createdAt = createdAt
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case playlistId
        case fileName
        case createdAt
        case details
    }

    /// 宽容解码。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .touchPlaylist
        playlistId = try container.decodeIfPresent(String.self, forKey: .playlistId) ?? ""
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        details = try container.decodeIfPresent(String.self, forKey: .details) ?? ""
    }
}

/// 待提交的「优质替换」（**先完整下载并验证，再原子替换**本地旧文件）。
///
/// 约定：
/// - 登记在 **入队下载之前**（写不成功就不入队，否则失败无法补偿）；
/// - 下载完成 → **实测** 新旧质量：新文件确实更好才原子替换；
/// - 替换失败 → **旧文件原样保留**，记录留在待处理里可重试；
/// - 替换成功后索引与歌单引用仍然指向 **同一个路径**（内容被替换，路径不变）。
public struct PendingReplacement: Codable, Equatable, Identifiable {
    /// 状态。
    public enum State: String, Codable, Equatable {
        /// 已登记，等待下载完成。
        case pending
        /// 正在提交（引用迁移中；崩溃后可恢复）。
        case committing
        /// 已提交（替换成功）。
        case committed
        /// 已放弃（新版本不比旧版本好，保留旧文件）。
        case discarded
    }

    public var id: String
    /// 网易云曲目 ID（= 下载任务 ID）。
    public var neteaseId: Int64
    /// 被替换的旧文件路径。
    public var oldPath: String
    /// 登记时旧文件的指纹摘要（`大小:sha256`；提交前查冲突）。
    public var oldFingerprint: String
    /// 新下载文件的路径（下载完成前为空串）。
    public var newPath: String
    /// 登记时间（Unix 秒）。
    public var createdAt: Double
    /// 状态。
    public var state: State
    /// 最近一次失败原因。
    public var lastError: String?
    /// **替换成功但旧文件还没移进废纸篓** 的路径（空串 = 没有待清理）。
    ///
    /// 废纸篓动作失败 **不算替换失败**（新文件已在位、引用已迁移），
    /// 只是旧文件还留在原处 → 记在这里，下次启动再试一次。
    /// 不会因此重复入单（入单状态与本字段无关）。
    public var pendingTrashPath: String
    /// **待清理文件** 的指纹摘要（`大小:sha256`）。
    ///
    /// 恢复时 **必须** 比对：路径上的文件可能已经被用户换成别的文件，
    /// 只凭路径就删会误删用户的文件。
    public var pendingTrashFingerprint: String
    /// **新下载文件** 在提交时的指纹摘要（`大小:sha256`）。
    ///
    /// 崩溃恢复时用来确认「新文件还是当初那个」（没有被换掉 / 损坏）。
    public var newFingerprint: String

    public init(
        id: String = "replace-" + UUID().uuidString.lowercased(),
        neteaseId: Int64,
        oldPath: String,
        oldFingerprint: String = "",
        newPath: String = "",
        createdAt: Double = Date().timeIntervalSince1970,
        state: State = .pending,
        lastError: String? = nil,
        pendingTrashPath: String = "",
        pendingTrashFingerprint: String = "",
        newFingerprint: String = ""
    ) {
        self.id = id
        self.neteaseId = neteaseId
        self.oldPath = oldPath
        self.oldFingerprint = oldFingerprint
        self.newPath = newPath
        self.createdAt = createdAt
        self.state = state
        self.lastError = lastError
        self.pendingTrashPath = pendingTrashPath
        self.pendingTrashFingerprint = pendingTrashFingerprint
        self.newFingerprint = newFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case neteaseId
        case oldPath
        case oldFingerprint
        case newPath
        case createdAt
        case state
        case lastError
        case pendingTrashPath
        case pendingTrashFingerprint
        case newFingerprint
    }

    /// 宽容解码（旧文件缺字段用默认值）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? "replace-" + UUID().uuidString.lowercased()
        neteaseId = try container.decodeIfPresent(Int64.self, forKey: .neteaseId) ?? 0
        oldPath = try container.decodeIfPresent(String.self, forKey: .oldPath) ?? ""
        oldFingerprint = try container.decodeIfPresent(String.self, forKey: .oldFingerprint) ?? ""
        newPath = try container.decodeIfPresent(String.self, forKey: .newPath) ?? ""
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .pending
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        pendingTrashPath = try container.decodeIfPresent(String.self, forKey: .pendingTrashPath) ?? ""
        pendingTrashFingerprint = try container.decodeIfPresent(String.self, forKey: .pendingTrashFingerprint) ?? ""
        newFingerprint = try container.decodeIfPresent(String.self, forKey: .newFingerprint) ?? ""
    }
}

/// 原生端持久状态（`native.json`）。
///
/// **不含凭证**：Cookie 只在 Rust 侧 `session.json` 与内存中。
public struct NativeState: Codable, Equatable {
    /// 数据格式版本。
    public static let currentVersion = 1

    public var version: Int
    /// 设置。
    public var settings: NativeSettings
    /// 本地歌单注册表。
    public var playlists: [LocalPlaylistRecord]
    /// 完整网络播放次数：`"netease:<id>"` → 次数。
    public var playCounts: [String: Int]
    /// 待恢复的操作（可恢复日志）。
    public var pendingOperations: [PendingOperation]
    /// 下载落盘后的入单记录（按「任务 / 目标 / 路径」跟踪确认）。
    public var downloadIntakes: [DownloadIntake]
    /// 自动保存记录（按网易云曲目 ID 去重与重试）。
    public var autoSaveRecords: [AutoSaveRecord]
    /// 待完成 / 失败的废纸篓删除操作（**先记日志再删文件**）。
    public var pendingFileDeletions: [PendingFileDeletion]
    /// 待提交的「优质替换」（下载完成后验证并原子替换旧文件）。
    public var pendingReplacements: [PendingReplacement]

    public init(
        version: Int = NativeState.currentVersion,
        settings: NativeSettings = NativeSettings(),
        playlists: [LocalPlaylistRecord] = [],
        playCounts: [String: Int] = [:],
        pendingOperations: [PendingOperation] = [],
        downloadIntakes: [DownloadIntake] = [],
        autoSaveRecords: [AutoSaveRecord] = [],
        pendingFileDeletions: [PendingFileDeletion] = [],
        pendingReplacements: [PendingReplacement] = []
    ) {
        self.version = version
        self.settings = settings
        self.playlists = playlists
        self.playCounts = playCounts
        self.pendingOperations = pendingOperations
        self.downloadIntakes = downloadIntakes
        self.autoSaveRecords = autoSaveRecords
        self.pendingFileDeletions = pendingFileDeletions
        self.pendingReplacements = pendingReplacements
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case settings
        case playlists
        case playCounts
        case pendingOperations
        case downloadIntakes
        case autoSaveRecords
        case pendingFileDeletions
        case pendingReplacements
    }

    /// 宽容解码：缺字段用默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? NativeState.currentVersion
        settings = try container.decodeIfPresent(NativeSettings.self, forKey: .settings) ?? NativeSettings()
        playlists = try container.decodeIfPresent([LocalPlaylistRecord].self, forKey: .playlists) ?? []
        playCounts = try container.decodeIfPresent([String: Int].self, forKey: .playCounts) ?? [:]
        pendingOperations = try container.decodeIfPresent([PendingOperation].self, forKey: .pendingOperations) ?? []
        downloadIntakes = try container.decodeIfPresent([DownloadIntake].self, forKey: .downloadIntakes) ?? []
        autoSaveRecords = try container.decodeIfPresent([AutoSaveRecord].self, forKey: .autoSaveRecords) ?? []
        pendingFileDeletions = try container.decodeIfPresent([PendingFileDeletion].self, forKey: .pendingFileDeletions) ?? []
        pendingReplacements = try container.decodeIfPresent([PendingReplacement].self, forKey: .pendingReplacements) ?? []
    }

    /// 播放次数的键（网络曲目）。
    public static func playCountKey(neteaseId: Int64) -> String { "netease:\(neteaseId)" }

    /// 播放次数的键（本地曲目按路径）。
    public static func playCountKey(path: String) -> String { "path:\(path)" }
}
