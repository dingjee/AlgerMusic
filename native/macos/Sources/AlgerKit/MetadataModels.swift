import Foundation

// MARK: - 桥接返回：候选 / 发行 / 曲目 / 封面

/// MusicBrainz 发行版本（**封面按发行版本取**，避免错配不同专辑的封面）。
public struct MetadataRelease: Codable, Equatable, Identifiable {
    /// 发行 ID（MusicBrainz release MBID）。
    public var id: String
    /// 发行标题。
    public var title: String
    /// 发行日期（`YYYY-MM-DD`，未知时为空）。
    public var date: String
    /// 发行国家（未知时为空）。
    public var country: String
    /// 专辑艺人（未知时为空）。
    public var albumArtist: String

    public init(
        id: String,
        title: String = "",
        date: String = "",
        country: String = "",
        albumArtist: String = ""
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.country = country
        self.albumArtist = albumArtist
    }

    /// 从桥接 JSON 解析（没有 `id` 的条目直接丢弃 —— 封面与写回都依赖发行 ID）。
    public static func parse(_ value: Any?) -> MetadataRelease? {
        guard let dict = value as? [String: Any] else { return nil }
        guard let id = JSONValue.string(dict["id"]), !id.isEmpty else { return nil }
        return MetadataRelease(
            id: id,
            title: JSONValue.string(dict["title"]) ?? "",
            date: JSONValue.string(dict["date"]) ?? "",
            country: JSONValue.string(dict["country"]) ?? "",
            albumArtist: JSONValue.string(dict["albumArtist"]) ?? ""
        )
    }
}

/// 发行版本里的一个曲目（用于取曲序 / 碟序）。
public struct MetadataTrack: Equatable, Identifiable {
    /// 录音 ID（MusicBrainz recording MBID）。
    public var recordingId: String
    public var title: String
    public var artist: String
    /// 曲序（未知 0）。
    public var track: Int
    /// 碟序（未知 0）。
    public var disc: Int
    /// 时长（毫秒，未知 0）。
    public var durationMs: Int

    public var id: String { recordingId }

    public init(
        recordingId: String,
        title: String = "",
        artist: String = "",
        track: Int = 0,
        disc: Int = 0,
        durationMs: Int = 0
    ) {
        self.recordingId = recordingId
        self.title = title
        self.artist = artist
        self.track = track
        self.disc = disc
        self.durationMs = durationMs
    }

    public static func parse(_ value: Any?) -> MetadataTrack? {
        guard let dict = value as? [String: Any] else { return nil }
        guard let recordingId = JSONValue.string(dict["recordingId"]), !recordingId.isEmpty else {
            return nil
        }
        return MetadataTrack(
            recordingId: recordingId,
            title: JSONValue.string(dict["title"]) ?? "",
            artist: JSONValue.string(dict["artist"]) ?? "",
            track: JSONValue.int(dict["track"]) ?? 0,
            disc: JSONValue.int(dict["disc"]) ?? 0,
            durationMs: JSONValue.int(dict["durationMs"]) ?? 0
        )
    }
}

/// 一个匹配候选（MusicBrainz 录音 / AcoustID 指纹结果）。
public struct MetadataCandidate: Equatable, Identifiable {
    /// 录音 ID（MusicBrainz recording MBID）。
    public var recordingId: String
    public var title: String
    public var artist: String
    /// 时长（毫秒，未知 0）。
    public var durationMs: Int
    /// 匹配分数（**桥接给的是 0…100 的整数百分制**，这里统一换算成 0…1）。
    ///
    /// 桥接契约：`Candidate.score` 是 `UInt32`，范围固定 0…100
    /// （AcoustID 的原始分数也乘以 100 后上报）。
    /// 因此 **必须除以 100**；后端给 `1` 就是 1%（不是 100%）。
    public var score: Double
    /// ISRC 列表（可能为空）。
    public var isrcs: [String]
    /// 该录音的发行版本列表（**同一录音的不同专辑版本需要用户确认**）。
    public var releases: [MetadataRelease]

    public var id: String { recordingId }

    public init(
        recordingId: String,
        title: String = "",
        artist: String = "",
        durationMs: Int = 0,
        score: Double = 0,
        isrcs: [String] = [],
        releases: [MetadataRelease] = []
    ) {
        self.recordingId = recordingId
        self.title = title
        self.artist = artist
        self.durationMs = durationMs
        self.score = score
        self.isrcs = isrcs
        self.releases = releases
    }

    /// 是否为 **低置信度** 候选（分数过低时绝不自动写回）。
    public var isLowConfidence: Bool { score < MetadataCandidate.lowConfidenceThreshold }

    /// 确认录音后的 **有效置信度**：`min(搜索 / 指纹阶段的分数, lookup 返回的分数)`。
    ///
    /// `meta.lookup` 是按 **精确录音 ID** 查询，分数通常是满分；
    /// 直接用 lookup 的分数会覆盖搜索阶段的低分，
    /// 把「低置信度」悄悄变成高置信度 → 空字段被自动勾选。
    /// 因此必须 **保留原候选的分数**（取更保守的那个）。
    public static func effectiveScore(searchScore: Double, lookupScore: Double) -> Double {
        min(searchScore, lookupScore)
    }

    /// 低置信度阈值（本地 0…1；低于它只提示，不自动采用）。
    public static let lowConfidenceThreshold: Double = 0.5

    public static func parse(_ value: Any?) -> MetadataCandidate? {
        guard let dict = value as? [String: Any] else { return nil }
        guard let recordingId = JSONValue.string(dict["recordingId"]), !recordingId.isEmpty else {
            return nil
        }
        // 百分制 → 0…1（后端固定 0…100，**不做「小于 1 就当 1」的启发式**）。
        let rawScore = JSONValue.double(dict["score"]) ?? 0
        return MetadataCandidate(
            recordingId: recordingId,
            title: JSONValue.string(dict["title"]) ?? "",
            artist: JSONValue.string(dict["artist"]) ?? "",
            durationMs: JSONValue.int(dict["durationMs"]) ?? 0,
            score: rawScore / 100,
            isrcs: JSONValue.stringArray(dict["isrcs"]),
            releases: JSONValue.array(dict["releases"]).compactMap { MetadataRelease.parse($0) }
        )
    }
}

/// Cover Art Archive 封面（**按确认过的发行版本**取）。
public struct MetadataArtwork: Equatable {
    /// 发行 ID。
    public var releaseId: String
    /// MIME 类型（`image/jpeg` / `image/png`）。
    public var mimeType: String
    /// 封面字节（base64 原文）。
    public var artworkBase64: String
    /// 解码后的封面字节（base64 非法时为 nil）。
    public var data: Data? { Data(base64Encoded: artworkBase64) }

    /// 用 base64 原文构造。
    public init(releaseId: String = "", mimeType: String = "", artworkBase64: String = "") {
        self.releaseId = releaseId
        self.mimeType = mimeType
        self.artworkBase64 = artworkBase64
    }

    /// 用已解码的字节构造。
    public init(data: Data, mimeType: String = "", releaseId: String = "") {
        self.releaseId = releaseId
        self.mimeType = mimeType
        self.artworkBase64 = data.base64EncodedString()
    }

    /// 从桥接 JSON（`meta.artwork` 的返回）解析。
    public static func parse(_ value: Any?) -> MetadataArtwork? {
        guard let dict = value as? [String: Any] else { return nil }
        let base64 = JSONValue.string(dict["artworkBase64"]) ?? ""
        guard !base64.isEmpty else { return nil }
        return MetadataArtwork(
            releaseId: JSONValue.string(dict["releaseId"]) ?? "",
            mimeType: JSONValue.string(dict["mimeType"]) ?? "",
            artworkBase64: base64
        )
    }
}

// MARK: - 标签读取结果

/// `tags.read` 的读取结果（**写前基线 / 写后核验**都用它）。
///
/// 字段分两类：
/// - **标准标签**（title / artist / …）：读取结果里一定有（可能是空串）；
/// - **来源关联 ID**（isrc / MusicBrainz 录音与发行 ID / date）：
///   桥接 **可能还没暴露** —— 这时是 `nil`（不是空串）。
///   `nil` 与 `""` 必须区分：`nil` = 读不到 → **无法核验**；`""` = 读到了但是空。
public struct AudioTags: Equatable {
    public var path: String
    /// 容器格式（`mp3` / `flac` / `m4a` / …）。
    public var format: String
    /// 时长（毫秒，未知 0）。
    public var durationMs: Int
    /// 码率（bps，未知 0）。
    public var bitrate: Int
    /// 采样率（Hz，未知 0）。
    public var sampleRate: Int
    /// 位深（bit，未知 0；无损文件用它证明质量，不靠压缩后码率比优劣）。
    public var bitDepth: Int
    /// 实际编码（`alac` / `aac` / `mp3` / `flac` …；空串 = 无法判定）。
    public var codec: String
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var genre: String
    /// 曲序（未知 0）。
    public var track: Int
    /// 碟序（未知 0）。
    public var disc: Int
    /// 发行年份（未知 0）。
    public var year: Int
    /// 发行日期（桥接未暴露时为 nil）。
    public var date: String?
    /// 是否已内嵌封面。
    public var hasArtwork: Bool
    /// 文件大小（字节）。
    public var fileSize: Int
    /// 网易云歌曲 ID（未知 0）。
    public var neteaseId: Int64
    /// ISRC（桥接未暴露时为 nil）。
    public var isrc: String?
    /// MusicBrainz 录音 ID（桥接未暴露时为 nil）。
    public var musicBrainzRecordingId: String?
    /// MusicBrainz 发行 ID（桥接未暴露时为 nil）。
    public var musicBrainzReleaseId: String?

    public init(
        path: String = "",
        format: String = "",
        durationMs: Int = 0,
        bitrate: Int = 0,
        sampleRate: Int = 0,
        bitDepth: Int = 0,
        codec: String = "",
        title: String = "",
        artist: String = "",
        album: String = "",
        albumArtist: String = "",
        genre: String = "",
        track: Int = 0,
        disc: Int = 0,
        year: Int = 0,
        date: String? = nil,
        hasArtwork: Bool = false,
        fileSize: Int = 0,
        neteaseId: Int64 = 0,
        isrc: String? = nil,
        musicBrainzRecordingId: String? = nil,
        musicBrainzReleaseId: String? = nil
    ) {
        self.path = path
        self.format = format
        self.durationMs = durationMs
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.codec = codec
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.track = track
        self.disc = disc
        self.year = year
        self.date = date
        self.hasArtwork = hasArtwork
        self.fileSize = fileSize
        self.neteaseId = neteaseId
        self.isrc = isrc
        self.musicBrainzRecordingId = musicBrainzRecordingId
        self.musicBrainzReleaseId = musicBrainzReleaseId
    }

    /// 从 `tags.read` / `tags.write` 的返回解析（不是对象时返回 nil）。
    public static func parse(_ value: Any?) -> AudioTags? {
        guard let dict = value as? [String: Any] else { return nil }
        return AudioTags(
            path: JSONValue.string(dict["path"]) ?? "",
            format: JSONValue.string(dict["format"]) ?? "",
            durationMs: JSONValue.int(dict["durationMs"]) ?? 0,
            bitrate: JSONValue.int(dict["bitrate"]) ?? 0,
            sampleRate: JSONValue.int(dict["sampleRate"]) ?? 0,
            bitDepth: JSONValue.int(dict["bitDepth"]) ?? 0,
            codec: JSONValue.string(dict["codec"]) ?? "",
            title: JSONValue.string(dict["title"]) ?? "",
            artist: JSONValue.string(dict["artist"]) ?? "",
            album: JSONValue.string(dict["album"]) ?? "",
            albumArtist: JSONValue.string(dict["albumArtist"]) ?? "",
            genre: JSONValue.string(dict["genre"]) ?? "",
            track: JSONValue.int(dict["track"]) ?? 0,
            disc: JSONValue.int(dict["disc"]) ?? 0,
            year: JSONValue.int(dict["year"]) ?? 0,
            date: JSONValue.string(dict["date"]),
            hasArtwork: JSONValue.bool(dict["hasArtwork"]) ?? false,
            fileSize: JSONValue.int(dict["fileSize"]) ?? 0,
            neteaseId: JSONValue.int64(dict["neteaseId"]) ?? 0,
            isrc: JSONValue.string(dict["isrc"]),
            musicBrainzRecordingId: JSONValue.string(dict["musicBrainzRecordingId"]),
            musicBrainzReleaseId: JSONValue.string(dict["musicBrainzReleaseId"])
        )
    }
}

// MARK: - 可写字段

/// 一次元信息写入涉及的字段。
public enum MetadataField: String, CaseIterable, Codable, Equatable, Sendable {
    case title
    case artist
    case album
    case albumArtist
    case genre
    case track
    case disc
    case year
    case date
    case isrc
    case neteaseId
    case musicBrainzRecordingId
    case musicBrainzReleaseId
    case artwork

    /// 中文显示名。
    public var title: String {
        switch self {
        case .title: return "标题"
        case .artist: return "艺人"
        case .album: return "专辑"
        case .albumArtist: return "专辑艺人"
        case .genre: return "流派"
        case .track: return "曲序"
        case .disc: return "碟序"
        case .year: return "年份"
        case .date: return "发行日期"
        case .isrc: return "ISRC"
        case .neteaseId: return "网易歌曲 ID"
        case .musicBrainzRecordingId: return "MusicBrainz 录音 ID"
        case .musicBrainzReleaseId: return "MusicBrainz 发行 ID"
        case .artwork: return "内嵌封面"
        }
    }

    /// 传给 `tags.write` 的 patch 字段名（`nil` = 该字段不走 patch）。
    public var patchKey: String? {
        switch self {
        case .title: return "title"
        case .artist: return "artist"
        case .album: return "album"
        case .albumArtist: return "albumArtist"
        case .genre: return "genre"
        case .track: return "track"
        case .disc: return "disc"
        case .year: return "year"
        case .date: return "date"
        case .isrc: return "isrc"
        case .neteaseId: return "neteaseId"
        case .musicBrainzRecordingId: return "musicBrainzRecordingId"
        case .musicBrainzReleaseId: return "musicBrainzReleaseId"
        case .artwork: return "artworkBase64"
        }
    }

    /// 数值字段（比较与写回时按数值处理）。
    public var isNumeric: Bool {
        switch self {
        case .track, .disc, .year, .neteaseId: return true
        default: return false
        }
    }

    /// 归一化（比较用：去空白；数值去掉前导零）。
    ///
    /// **数值字段的「未知」统一**：`""`（标签里没有这个值）与 `"0"`（显式清零）
    /// 归一化成同一个值 —— 否则「显式写 0 清除」会写成功却被核验误判为失败。
    public func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNumeric {
            // 空串 = 「标签里没有这个值」= 未知，与显式的 0 同义。
            guard let number = Int(trimmed) else {
                return trimmed.isEmpty ? "0" : trimmed
            }
            return String(number)
        }
        return trimmed
    }
}

extension AudioTags {
    /// 字段的当前值。
    ///
    /// - Returns: `nil` = 桥接的读取结果里 **没有** 这个字段（无法核验、也无法判断是否空缺）。
    public func value(for field: MetadataField) -> String? {
        switch field {
        case .title: return title
        case .artist: return artist
        case .album: return album
        case .albumArtist: return albumArtist
        case .genre: return genre
        case .track: return track > 0 ? String(track) : ""
        case .disc: return disc > 0 ? String(disc) : ""
        case .year: return year > 0 ? String(year) : ""
        case .date: return date
        case .isrc: return isrc
        case .neteaseId: return neteaseId > 0 ? String(neteaseId) : ""
        case .musicBrainzRecordingId: return musicBrainzRecordingId
        case .musicBrainzReleaseId: return musicBrainzReleaseId
        case .artwork: return hasArtwork ? "已有封面" : "无封面"
        }
    }
}

// MARK: - 候选方案

/// 已确认的匹配结果（**录音** + **发行** + **封面**）能提供的字段值。
///
/// 未确认的字段是 `nil` —— `nil` 表示「没有这个信息」，**不会**被写成空标签。
public struct MetadataProposal: Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var track: Int?
    public var disc: Int?
    public var year: Int?
    public var date: String?
    public var isrc: String?
    public var neteaseId: Int64?
    public var musicBrainzRecordingId: String?
    public var musicBrainzReleaseId: String?
    /// 封面字节（base64）；只在用户确认嵌入时才带上。
    public var artworkBase64: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        genre: String? = nil,
        track: Int? = nil,
        disc: Int? = nil,
        year: Int? = nil,
        date: String? = nil,
        isrc: String? = nil,
        neteaseId: Int64? = nil,
        musicBrainzRecordingId: String? = nil,
        musicBrainzReleaseId: String? = nil,
        artworkBase64: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.track = track
        self.disc = disc
        self.year = year
        self.date = date
        self.isrc = isrc
        self.neteaseId = neteaseId
        self.musicBrainzRecordingId = musicBrainzRecordingId
        self.musicBrainzReleaseId = musicBrainzReleaseId
        self.artworkBase64 = artworkBase64
    }

    /// 字段的候选值（`nil` = 没有这个信息）。
    public func value(for field: MetadataField) -> String? {
        switch field {
        case .title: return title
        case .artist: return artist
        case .album: return album
        case .albumArtist: return albumArtist
        case .genre: return genre
        case .track: return track.map { String($0) }
        case .disc: return disc.map { String($0) }
        case .year: return year.map { String($0) }
        case .date: return date
        case .isrc: return isrc
        case .neteaseId: return neteaseId.map { String($0) }
        case .musicBrainzRecordingId: return musicBrainzRecordingId
        case .musicBrainzReleaseId: return musicBrainzReleaseId
        case .artwork: return artworkBase64 == nil ? nil : "封面预览"
        }
    }
}

// MARK: - 差异

/// 一条「候选值 vs 当前标签」的差异。
public struct MetadataFieldDifference: Identifiable, Equatable {
    /// 字段。
    public var field: MetadataField
    /// 当前文件里的值（`nil` = 桥接读取结果里没有这个字段）。
    public var current: String?
    /// 候选值。
    public var proposed: String

    public var id: String { field.rawValue }

    public init(field: MetadataField, current: String?, proposed: String) {
        self.field = field
        self.current = current
        self.proposed = proposed
    }

    /// 当前是否为空缺（读得到且为空）。
    public var isMissing: Bool {
        guard let current else { return false }
        return current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 能否核验（读取结果里必须真的有这个字段）。
    public var isVerifiable: Bool { current != nil }

    /// 默认勾选：**仅** 补空缺。
    ///
    /// - 非空字段（手工改过的值）**不默认勾选** —— 覆盖它们必须用户手工勾选；
    /// - 封面永远不默认勾选 —— 嵌入封面是用户显式选择；
    /// - 读不到当前值的字段不默认勾选（保守：不覆盖未知）。
    public var defaultSelected: Bool {
        guard field != .artwork else { return false }
        return isMissing
    }
}

/// 差异计算。
public enum MetadataDifferences {
    /// 计算「候选值」与「当前标签」的差异（只列出 **真的不一样** 的字段）。
    ///
    /// - 默认勾选规则见 `MetadataFieldDifference.defaultSelected`：
    ///   **只补空缺，不覆盖非空**。
    public static func compute(current: AudioTags, proposal: MetadataProposal) -> [MetadataFieldDifference] {
        var result: [MetadataFieldDifference] = []
        for field in MetadataField.allCases {
            guard let proposed = proposal.value(for: field) else { continue }
            // 候选里的空值 = **没有这个信息**，不是「要清空」。
            // （明确写空只走手动编辑通道。）
            guard !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let currentValue = current.value(for: field)
            if let currentValue,
               field.normalize(currentValue) == field.normalize(proposed) {
                continue                        // 没有差异
            }
            result.append(
                MetadataFieldDifference(field: field, current: currentValue, proposed: proposed)
            )
        }
        return result
    }
}

// MARK: - 来源关联

/// 来源关联 ID（网易云歌曲 ID）的合并规则。
///
/// 边界（索引里可能有、音频标签里没有的来源关联）：
/// - 标签里读到 ID → 用标签的；
/// - 标签里是 `0`（未写进文件）且用户 **没有** 勾选来源 ID 字段
///   → **保留原来的关联**（不能因为只改了标题就把索引里的来源关联清零）；
/// - 用户 **显式** 勾选了来源 ID 字段（写成 0 / 清空）→ 才允许清除关联。
public enum MetadataSourceID {
    /// 合并来源 ID。
    public static func merge(tagValue: Int64, explicitlySelected: Bool, original: Int64) -> Int64 {
        if tagValue > 0 { return tagValue }
        if explicitlySelected { return 0 }
        return original
    }
}

// MARK: - 写入

/// 标签写入补丁（对应桥接 `tags.write` 的 `patch`）。
///
/// 规则：
/// - `nil` 字段 **不进字典**（None = 不改，**绝不清空**已有标签）；
/// - `removeArtwork` 是 **非可选** 字段，**必须**出现在字典里
///   （不删封面时显式传 `false`）。
public struct MetadataTagPatch: Equatable {
    /// 封面字节上限（4 MiB）：base64 后约 5.6 MiB，仍在桥接单行上限（8 MiB）内。
    public static let maxArtworkBytes = 4 * 1024 * 1024

    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var track: Int?
    public var disc: Int?
    public var year: Int?
    public var date: String?
    /// 新封面（base64）。
    public var artworkBase64: String?
    /// 移除全部封面（**非可选**：不删时传 false）。
    public var removeArtwork: Bool
    public var neteaseId: Int64?
    public var isrc: String?
    public var musicBrainzRecordingId: String?
    public var musicBrainzReleaseId: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        genre: String? = nil,
        track: Int? = nil,
        disc: Int? = nil,
        year: Int? = nil,
        date: String? = nil,
        artworkBase64: String? = nil,
        removeArtwork: Bool = false,
        neteaseId: Int64? = nil,
        isrc: String? = nil,
        musicBrainzRecordingId: String? = nil,
        musicBrainzReleaseId: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.track = track
        self.disc = disc
        self.year = year
        self.date = date
        self.artworkBase64 = artworkBase64
        self.removeArtwork = removeArtwork
        self.neteaseId = neteaseId
        self.isrc = isrc
        self.musicBrainzRecordingId = musicBrainzRecordingId
        self.musicBrainzReleaseId = musicBrainzReleaseId
    }

    /// 桥接 `tags.write` 的 `patch` 参数。
    public func payload() -> [String: Any] {
        var payload: [String: Any] = [:]
        if let title { payload["title"] = title }
        if let artist { payload["artist"] = artist }
        if let album { payload["album"] = album }
        if let albumArtist { payload["albumArtist"] = albumArtist }
        if let genre { payload["genre"] = genre }
        if let track { payload["track"] = track }
        if let disc { payload["disc"] = disc }
        if let year { payload["year"] = year }
        if let date { payload["date"] = date }
        if let artworkBase64 { payload["artworkBase64"] = artworkBase64 }
        // 非可选字段：**永远**出现（不删封面时显式 false）。
        payload["removeArtwork"] = removeArtwork
        if let neteaseId { payload["neteaseId"] = neteaseId }
        if let isrc { payload["isrc"] = isrc }
        if let musicBrainzRecordingId { payload["musicBrainzRecordingId"] = musicBrainzRecordingId }
        if let musicBrainzReleaseId { payload["musicBrainzReleaseId"] = musicBrainzReleaseId }
        return payload
    }
}

/// 用户勾选的结果（**只有勾选的字段才会写回**）。
public struct MetadataSelection: Equatable {
    /// 勾选的字段 → 目标值。
    public var fields: [MetadataField: String]
    /// 勾选嵌入的封面（base64）；`nil` = 不动封面。
    public var artworkBase64: String?
    /// 是否移除已有封面。
    public var removeArtwork: Bool

    public init(
        fields: [MetadataField: String] = [:],
        artworkBase64: String? = nil,
        removeArtwork: Bool = false
    ) {
        self.fields = fields
        self.artworkBase64 = artworkBase64
        self.removeArtwork = removeArtwork
    }

    /// 是否什么也没选（没有可写的内容）。
    public var isEmpty: Bool { fields.isEmpty && artworkBase64 == nil && !removeArtwork }

    /// 转成写入补丁（**未勾选的字段一律不进补丁**）。
    ///
    /// - Throws: `MetadataError.invalidSelection` —— 数值字段非法（不是整数 / 负数 /
    ///   超出 `u32` 范围）、文本字段为空、或封面数据非法时 **在写入之前** 报错。
    ///   **绝不**把解析失败的数值悄悄丢掉（那样会写了一半再在核验阶段才发现）。
    public func patch() throws -> MetadataTagPatch {
        var patch = MetadataTagPatch()
        patch.removeArtwork = removeArtwork
        if let artworkBase64 {
            guard let data = Data(base64Encoded: artworkBase64), !data.isEmpty else {
                throw MetadataError.invalidSelection("封面数据不是有效的 base64")
            }
            guard data.count <= MetadataTagPatch.maxArtworkBytes else {
                throw MetadataError.artworkTooLarge(
                    bytes: data.count,
                    limit: MetadataTagPatch.maxArtworkBytes
                )
            }
            patch.artworkBase64 = artworkBase64
        }
        for (field, value) in fields {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field {
            case .title:
                patch.title = MetadataSelection.textValue(field: field, value: trimmed)
            case .artist:
                patch.artist = MetadataSelection.textValue(field: field, value: trimmed)
            case .album:
                patch.album = MetadataSelection.textValue(field: field, value: trimmed)
            case .albumArtist:
                patch.albumArtist = MetadataSelection.textValue(field: field, value: trimmed)
            case .genre:
                patch.genre = MetadataSelection.textValue(field: field, value: trimmed)
            case .track:
                patch.track = try MetadataSelection.requireUInt32(field: field, value: trimmed)
            case .disc:
                patch.disc = try MetadataSelection.requireUInt32(field: field, value: trimmed)
            case .year:
                patch.year = try MetadataSelection.requireUInt32(field: field, value: trimmed)
            case .date:
                patch.date = MetadataSelection.textValue(field: field, value: trimmed)
            case .isrc:
                patch.isrc = MetadataSelection.textValue(field: field, value: trimmed)
            case .neteaseId:
                patch.neteaseId = try MetadataSelection.requireNonNegativeInt64(field: field, value: trimmed)
            case .musicBrainzRecordingId:
                patch.musicBrainzRecordingId = MetadataSelection.textValue(field: field, value: trimmed)
            case .musicBrainzReleaseId:
                patch.musicBrainzReleaseId = MetadataSelection.textValue(field: field, value: trimmed)
            case .artwork:
                break        // 封面走 artworkBase64
            }
        }
        return patch
    }

    /// 文本字段：**空串是「明确写空」**（用户清空就是要清空，不当 nil 忽略）。
    ///
    /// 字段 **出现在选择里** 本身就是「要写这个字段」的明确信号；
    /// 因此这里不再拒绝空串（否则用户清空字段就写不进去）。
    private static func textValue(field: MetadataField, value: String) -> String {
        value
    }

    /// 数值字段（`u32`）：必须是整数、非负、不超过 `UInt32.max`。
    ///
    /// **留空 = 显式清零**（写 0 = 未知 / 已清除）：这是用户 **勾选** 之后的明确动作，
    /// 不是「没填就忽略」。非法值（非整数 / 负数 / 超范围）仍然拒绝。
    private static func requireUInt32(field: MetadataField, value: String) throws -> Int {
        guard !value.isEmpty else { return 0 }
        guard let number = Int(value) else {
            throw MetadataError.invalidSelection("字段「\(field.title)」的值「\(value)」不是整数")
        }
        guard number >= 0 else {
            throw MetadataError.invalidSelection("字段「\(field.title)」的值「\(value)」不能为负数")
        }
        guard number <= Int(UInt32.max) else {
            throw MetadataError.invalidSelection("字段「\(field.title)」的值「\(value)」超出 u32 上限")
        }
        return number
    }

    /// 来源 ID（`i64`）：必须是整数、非负；**留空 = 显式清零**。
    private static func requireNonNegativeInt64(field: MetadataField, value: String) throws -> Int64 {
        guard !value.isEmpty else { return 0 }
        guard let number = Int64(value) else {
            throw MetadataError.invalidSelection("字段「\(field.title)」的值「\(value)」不是整数")
        }
        guard number >= 0 else {
            throw MetadataError.invalidSelection("字段「\(field.title)」的值「\(value)」不能为负数")
        }
        return number
    }
}

// MARK: - 封面基线

/// 内嵌封面状态（`tags.artwork` 的读取结果）。
public enum MetadataEmbeddedArtwork: Equatable {
    /// 有内嵌封面（字节）。
    case present(Data)
    /// 文件里没有内嵌封面。
    case none
    /// 读不出来（IO / 协议错误）。
    case unreadable(String)
}

/// 打开编辑器时读到的 **内嵌封面基线**（用于封面冲突比较）。
///
/// - `isLoaded = false`：**没有真的读到**封面 → 不能用来做冲突比较
///   （要改 / 删封面时必须先有基线，否则拒绝写入）；
/// - `isLoaded = true, bytes = nil`：读到了，**文件里本来就没有**内嵌封面。
public struct MetadataArtworkBaseline: Equatable {
    /// 是否真的读过（`false` = 没读过）。
    public let isLoaded: Bool
    /// 读到的封面字节（`nil` = 文件里没有内嵌封面）。
    public let bytes: Data?

    /// 未读取（不能用于冲突比较）。
    public static let notLoaded = MetadataArtworkBaseline(isLoaded: false, bytes: nil)

    /// 已读取（`bytes` 为 nil 表示本来就没有封面）。
    public static func loaded(_ bytes: Data?) -> MetadataArtworkBaseline {
        MetadataArtworkBaseline(isLoaded: true, bytes: bytes)
    }
}

// MARK: - 错误

/// 元信息流程的错误（**界面上必须可见**）。
public enum MetadataError: Error, CustomStringConvertible {
    /// 桥接返回的不是预期形状。
    case invalidResponse(String)
    /// 封面超过上限（发送前 / 接收后都会检查）。
    case artworkTooLarge(bytes: Int, limit: Int)
    /// 用户取消。
    case cancelled
    /// 保存前重读发现文件已被改动（相对打开时的基线）。
    case conflict(String)
    /// 写后重读核验失败（**未能确认保存成功**；写入可能已经发生，不能断言原文件零改动）。
    case verificationFailed(String)
    /// 选择本身不合法（数值非法 / 文本为空 / 封面数据非法）。
    case invalidSelection(String)
    /// 缺少必要配置（AcoustID key / fpcalc 路径等，明确提示，不假成功）。
    case missingConfiguration(String)
    /// 桥接返回的业务错误。
    case bridgeFailure(code: String, message: String)

    public var description: String {
        switch self {
        case .invalidResponse(let message): return "桥接返回无效：\(message)"
        case .artworkTooLarge(let bytes, let limit): return "封面超过 \(limit / 1024 / 1024) MiB 上限（\(bytes) 字节）"
        case .cancelled: return "已取消匹配"
        case .conflict(let message): return "保存冲突：\(message)"
        case .verificationFailed(let message): return "写后核验未通过，未能确认保存成功：\(message)"
        case .invalidSelection(let message): return "选择无效：\(message)"
        case .missingConfiguration(let message): return "缺少配置：\(message)"
        case .bridgeFailure(let code, let message): return "匹配服务失败（\(code)）：\(message)"
        }
    }
}
