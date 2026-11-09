import Foundation

// MARK: - 音频质量（实测优先，候选不冒充实测）

/// 音频编码的 **类别**。
///
/// - `lossless`：明确无损（FLAC / ALAC / PCM / WavPack / APE）；
/// - `lossy`：明确有损（MP3 / AAC / Vorbis / Opus）；
/// - `unknown`：**判不出来**（`m4a` 既可能是 ALAC 也可能是 AAC；`ogg` 可能是
///   Vorbis / Opus / FLAC；`wma` 可能是 WMA Lossless）。
///
/// `unknown` 必须 **当作最保守的一档**：本地是 `unknown` 时 **不允许** 被替换。
public enum AudioCodecClass: String, Equatable {
    case lossless
    case lossy
    case unknown
}

/// 质量结论的 **证据强度**。
///
/// - `measured`：**实测** —— 编码 / 采样率 / 位深 / 码率来自 **真实解析**
///   （本地文件的 `tags.read`，或桥接 **真的探测** 到的远端字段）；
/// - `hint`：**提示** —— 只知道 **容器** 与上游探测到的码率。
///   容器后缀 **不是** 编码探测（`m4a` 可能是 ALAC 也可能是 AAC），
///   因此提示 **只能** 用来做「要不要下载」的预判，
///   **不能** 当成「真实音质」提交替换。
public enum AudioQualityEvidence: String, Equatable {
    case measured
    case hint
}

/// 一个音频文件的 **质量**。
///
/// 约定：
/// - `bitrate` 来自 **真实标签**（bps，与远端 `ResolvedAudio.br` 同单位）；
/// - `codec` 来自 **真实解析**（不是扩展名）；
/// - **不**用扩展名推断「有损文件的比特率优劣」；
/// - `evidence` 说明这份结论有多硬：`candidate` 只能用来做
///   **下载前的候选判断**，最终结论必须来自 **下载后的实测**。
public struct AudioQuality: Equatable {
    /// 码率（bps；0 = 未知）。
    public var bitrate: Int
    /// 采样率（Hz；0 = 未知）。
    public var sampleRate: Int
    /// 位深（bit；0 = 未知）。
    public var bitDepth: Int
    /// 容器格式（小写，例如 `flac` / `mp3` / `m4a`）。
    public var format: String
    /// 实际编码（`alac` / `aac` / `mp3` / `flac` …；空串 = 未暴露）。
    public var codec: String
    /// 证据强度。
    public var evidence: AudioQualityEvidence

    public init(
        bitrate: Int,
        sampleRate: Int = 0,
        bitDepth: Int = 0,
        format: String = "",
        codec: String = "",
        evidence: AudioQualityEvidence = .measured
    ) {
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.format = format.lowercased()
        self.codec = codec.lowercased()
        self.evidence = evidence
    }

    /// 编码类别。
    public var codecClass: AudioCodecClass {
        // 1) 真实编码优先。
        switch codec {
        case "alac", "flac", "pcm", "pcm_s16le", "pcm_s16be", "wavpack", "ape", "aiff":
            return .lossless
        case "aac", "mp3", "vorbis", "opus":
            return .lossy
        default:
            break
        }
        // 2) 没有真实编码 → 按 **容器** 判断（判不出来的容器 → unknown）。
        return AudioQuality.containerClass(format)
    }

    /// 容器 → 编码类别（**只有确定时才给结论**）。
    ///
    /// - `flac` / `wav` / `aiff` / `ape` / `wv`：容器本身就只能是无损；
    /// - `mp3` / `aac` / `opus`：容器本身就只能是有损；
    /// - `m4a` / `ogg` / `wma` …：容器里能装多种编码 → **unknown**。
    public static func containerClass(_ format: String) -> AudioCodecClass {
        switch format.lowercased() {
        case "flac", "wav", "wave", "aiff", "aif", "ape", "wv":
            return .lossless
        case "mp3", "aac", "opus":
            return .lossy
        default:
            return .unknown
        }
    }

    /// 由本地标签实测得到（`tags.read` 的真实字段）。
    public static func measured(tags: AudioTags) -> AudioQuality {
        AudioQuality(
            bitrate: tags.bitrate,
            sampleRate: tags.sampleRate,
            bitDepth: tags.bitDepth,
            format: tags.format,
            codec: tags.codec,
            evidence: .measured
        )
    }

    /// 由 **解析出的播放地址** 得到。
    ///
    /// - 桥接 **真的探测到** 编码 / PCM 属性时（`codec` 非空）→ `measured`；
    /// - 只有容器与码率时 → `hint`（**不能**当成真实音质）。
    ///
    /// - Important: 容器 **只是提示**：`m4a` 可能是 ALAC 也可能是 AAC，
    ///   `ogg` 可能是 Vorbis / Opus / FLAC → 它们的编码类别是 `unknown`。
    public static func remote(_ audio: ResolvedAudio) -> AudioQuality {
        let path = URL(string: audio.url)?.path ?? audio.url
        let container = (path as NSString).pathExtension.lowercased()
        let hasRealCodec = !audio.codec.trimmingCharacters(in: .whitespaces).isEmpty
        return AudioQuality(
            bitrate: audio.bitrate,
            sampleRate: audio.sampleRate,
            bitDepth: audio.bitDepth,
            format: container,
            codec: hasRealCodec ? audio.codec : "",
            evidence: hasRealCodec ? .measured : .hint
        )
    }

    /// 是否 **可证实** 高于另一个质量（**双方都必须是实测**）。
    ///
    /// **方向**：`self` 是 **新的 / 待替换的** 那个，`other` 是 **现有的** 那个。
    /// （`newQuality.isProvablyHigher(than: oldQuality)` = 「新的能不能证实比旧的好」）
    ///
    /// 规则：
    /// - **任一编码未知** → 不可证实（保守，绝不猜）：
    ///   未知的 ALAC（`m4a` 没探测到编码）**不得**被替换；
    /// - 新的是无损、旧的是有损 → 可证实更高；
    /// - 新的是有损、旧的是无损 → **不可证实更高**（无损不会被有损替换）；
    /// - 双方都是无损 → **不能** 按压缩后码率比优劣：
    ///   必须 **采样率与位深都已知**、**都不下降**、且 **至少一项提升**
    ///   （96 kHz/16 bit 与 44.1 kHz/24 bit 属于取舍，**不算**可证实更高）；
    /// - 双方都是有损 → **只有同一个编码** 才比实测码率
    ///   （MP3 与 AAC 的码率不可直接比 → 跨有损编码不能替换）；
    ///   没有实测码率 → 不可证实。
    public func isProvablyHigher(than other: AudioQuality) -> Bool {
        // 严格结论只认 **实测**：提示不能用来提交替换。
        guard evidence == .measured, other.evidence == .measured else { return false }
        return compareClasses(with: other)
    }

    /// 在 **现有证据** 下是否可能比另一个质量更高（**允许提示参与**）。
    ///
    /// 用途：**下载前** 的预判（提示只用来决定「要不要下载」）。
    /// 下载之后必须用 **实测** 再确认一次（`isProvablyHigher`），
    /// 否则弃新复用旧。
    public func isPossibleUpgrade(than other: AudioQuality) -> Bool {
        compareClasses(with: other)
    }

    /// 类别比较（无损 / 有损 / 未知 的规则）。
    private func compareClasses(with other: AudioQuality) -> Bool {
        let mine = codecClass
        let theirs = other.codecClass
        // 任一编码判不出来 → 不可证实。
        guard mine != .unknown, theirs != .unknown else { return false }
        switch (mine, theirs) {
        case (.lossless, .lossless):
            return isLosslessProvablyHigher(than: other)
        case (.lossless, .lossy):
            // 新的无损、旧的有损 → 无损确实更高。
            return true
        case (.lossy, .lossless):
            // 新的有损、旧的无损 → 不允许替换。
            return false
        case (.lossy, .lossy):
            // 跨有损编码 → 码率不可直接比 → 不可证实。
            guard codecIdentity == other.codecIdentity else { return false }
            guard bitrate > 0, other.bitrate > 0 else { return false }
            return bitrate > other.bitrate
        default:
            // 含 unknown → 不可证实（上面已提前返回，这里只是穷尽）。
            return false
        }
    }

    /// 编码标识（用于「同编码才比码率」）：真实编码优先，没有就用容器。
    public var codecIdentity: String {
        if !codec.isEmpty { return codec }
        return format
    }

    /// 两个无损文件之间：用 **采样率 / 位深** 证明高低。
    ///
    /// 必须：都已知、都不下降、且至少一项提升。
    private func isLosslessProvablyHigher(than other: AudioQuality) -> Bool {
        guard sampleRate > 0, other.sampleRate > 0, bitDepth > 0, other.bitDepth > 0 else {
            return false
        }
        guard sampleRate >= other.sampleRate, bitDepth >= other.bitDepth else { return false }
        return sampleRate > other.sampleRate || bitDepth > other.bitDepth
    }

    /// 展示用描述（提示用）。
    public var description: String {
        let rate = bitrate > 0 ? "\(bitrate / 1000) kbps" : "码率未知"
        let kind: String
        switch codecClass {
        case .lossless: kind = "无损"
        case .lossy: kind = "有损"
        case .unknown: kind = "编码未知"
        }
        let depth = bitDepth > 0 ? " / \(bitDepth) bit" : ""
        let sample = sampleRate > 0 ? " / \(sampleRate) Hz" : ""
        let evidence = evidence == .hint ? "（容器提示，待实测确认）" : ""
        return "\(kind) \(rate)\(sample)\(depth)\(evidence)"
    }
}

// MARK: - 本地候选

/// 本地已存在的 **候选版本**。
public struct LocalAudioCandidate: Equatable {
    /// 命中方式。
    public enum MatchKind: String, Equatable {
        /// 按 **来源 ID** 关联（唯一可信的方式）。
        case sourceID
        /// 保守的「标题 + 艺人 + 时长 / 专辑」匹配。
        case titleArtist
    }

    public var track: TrackRecord
    public var matchKind: MatchKind

    public init(track: TrackRecord, matchKind: MatchKind) {
        self.track = track
        self.matchKind = matchKind
    }

    /// 命中方式的中文说明。
    public var matchDescription: String {
        switch matchKind {
        case .sourceID: return "来源 ID 关联"
        case .titleArtist: return "标题 / 艺人 / 时长匹配"
        }
    }
}

// MARK: - 协议（便于测试注入）

/// 读取本地音频标签（实测码率 / 编码 / 采样率）。
public protocol AudioTagReading: AnyObject {
    func readAudioTags(path: String) async throws -> AudioTags
}

/// 解析网络播放地址（拿到 **上游探测** 的码率与可选的编码字段）。
public protocol AudioSourceResolving: AnyObject {
    func resolve(song: RemoteSong) async throws -> ResolvedAudio
}

/// 把旧文件的 **标签与封面** 保留到新文件（优质替换不能丢用户手工元信息）。
public protocol TagPreserving: AnyObject {
    /// - Throws: 写入 / 核验失败（调用方必须 **保留旧文件**）。
    func preserveTags(from oldPath: String, to newPath: String) async throws
}

/// 迁移 **内存里** 的播放引用（队列 / 当前曲目）。
///
/// 替换后旧文件会被移走，队列里还指向旧路径的条目就会指向一个不存在的文件
///（「上一首」「临时播放」会播不出来）→ 必须一起改掉。
@MainActor
public protocol PlaybackReferenceUpdating: AnyObject {
    /// 把指向 `oldPath` 的本地条目改成 `newPath`（**不打断当前播放**）。
    func updateLocalPath(from oldPath: String, to newPath: String)
}

// MARK: - 审核结果

/// 下载前的 **本地审核** 结果。
public enum DownloadReviewDecision: Equatable {
    /// 复用本地已有文件（**不下载**）。
    case reuseLocal(LocalAudioCandidate, reason: String)
    /// 本地有文件，但远端版本 **可能是** 更高质量 → 先下载验证，再替换。
    case replaceLocal(LocalAudioCandidate, reason: String)
    /// 本地没有对应文件 → 直接下载。
    case downloadNew(reason: String)

    /// 是否需要下载。
    public var needsDownload: Bool {
        switch self {
        case .reuseLocal: return false
        case .replaceLocal, .downloadNew: return true
        }
    }

    /// 本地候选（复用 / 替换时非空）。
    public var candidate: LocalAudioCandidate? {
        switch self {
        case .reuseLocal(let candidate, _), .replaceLocal(let candidate, _): return candidate
        case .downloadNew: return nil
        }
    }
}

// MARK: - 审核服务

/// 下载前的 **统一本地审核**。
///
/// 规则（硬要求）：
/// - **ID 优先**：先按来源 ID 关联；没有再按 **保守** 的
///   「标题 + 艺人 + 时长 / 专辑」匹配；
/// - 保守匹配 **必须** 至少有一项可判定（时长双方已知且近似 / 专辑双方已知且相等），
///   两边都未知时 **不自动合并**；
/// - **现场版 / 混音版 / 伴奏版** 等 **不同录音** 一律不合并
///   （版本标记不一致 → 直接排除）；
/// - 本地已有版本 **质量不低** → **复用本地**，不重复下载；
/// - 只有远端版本 **可能更高** 才更新（结论以 **下载后的实测** 为准）；
/// - **不** 凭扩展名推断有损比特率优劣，也 **不** 凭 URL 后缀冒充真实编码；
/// - 读不出 / 解析失败 → **保守复用本地** 并说明原因（不猜）。
public final class DownloadReviewService {

    private let library: LocalLibrary
    private let tagReader: AudioTagReading
    private let resolver: AudioSourceResolving

    public init(library: LocalLibrary, tagReader: AudioTagReading, resolver: AudioSourceResolving) {
        self.library = library
        self.tagReader = tagReader
        self.resolver = resolver
    }

    // MARK: - 匹配

    /// 找出本地已有的候选版本（**ID 优先**）。
    public func findLocalCandidate(song: RemoteSong) -> LocalAudioCandidate? {
        if let track = library.matchLocalTrack(neteaseId: song.id) {
            return LocalAudioCandidate(track: track, matchKind: .sourceID)
        }
        guard let track = library.songs().first(where: { Self.conservativelyMatches($0, song: song) }) else {
            return nil
        }
        return LocalAudioCandidate(track: track, matchKind: .titleArtist)
    }

    /// 保守匹配：**标题 + 艺人** 必须一致，且 **至少** 有一项可判定。
    ///
    /// - 时长：双方都已知时差值 ≤ 2 秒才算同一首；明确冲突 → 不匹配；
    /// - 专辑：双方都已知且不一致 → **不匹配**（避免把别的专辑版本当成本地已有）；
    /// - **时长与专辑都未知 → 不匹配**（不能凭标题就自动合并）；
    /// - **版本标记**（现场版 / 混音版 / 伴奏版…）不一致 → **不匹配**
    ///   （那是 **不同的录音**，即使标题与时长都像）。
    public static func conservativelyMatches(_ track: TrackRecord, song: RemoteSong) -> Bool {
        let title = normalized(track.title)
        guard !title.isEmpty, title == normalized(song.name) else { return false }
        guard artistsMatch(track.artist, song: song) else { return false }
        // **不同录音**（现场 / 混音 / 伴奏…）不合并。
        guard versionMarkers(track.title) == versionMarkers(song.name) else { return false }

        var durationKnown = false
        if track.durationMs > 0, song.durationMs > 0 {
            let delta = abs(Int64(track.durationMs) - song.durationMs)
            guard delta <= 2_000 else { return false }
            durationKnown = true
        }
        let localAlbum = normalized(track.album)
        let remoteAlbum = normalized(song.album.name)
        var albumKnown = false
        if !localAlbum.isEmpty, !remoteAlbum.isEmpty {
            guard localAlbum == remoteAlbum else { return false }
            albumKnown = true
        }
        // **至少** 有一项可判定，否则不自动合并。
        return durationKnown || albumKnown
    }

    /// 艺人是否一致（**只认同一批艺人**，不做包含式猜测）。
    private static func artistsMatch(_ localArtist: String, song: RemoteSong) -> Bool {
        let local = normalized(localArtist)
        guard !local.isEmpty else { return false }
        let remoteNames = song.artists.map { normalized($0.name) }.filter { !$0.isEmpty }
        guard !remoteNames.isEmpty else { return false }
        let localParts = Set(splitArtists(localArtist).map(normalized).filter { !$0.isEmpty })
        if localParts == Set(remoteNames) { return true }
        if local == normalized(song.artistText) { return true }
        if remoteNames.count == 1, local == remoteNames[0] { return true }
        return false
    }

    /// 拆分艺人文本（常见分隔符）。
    private static func splitArtists(_ text: String) -> [String] {
        var parts = text
        for separator in ["/", "&", ",", "、", ";", "|"] {
            parts = parts.replacingOccurrences(of: separator, with: "\u{1}")
        }
        return parts
            .split(separator: "\u{1}", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// 归一化（比较用）：小写、去空白、去常见标点。
    public static func normalized(_ text: String) -> String {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.filter { $0.isLetter || $0.isNumber }
    }

    /// 标题里的 **版本标记**（现场版 / 混音版 / 伴奏版 …）。
    ///
    /// 标记集合不同 → **不同的录音** → 不得当成同一首。
    public static func versionMarkers(_ title: String) -> Set<String> {
        let text = title.lowercased()
        var markers: Set<String> = []
        for marker in Self.versionMarkerWords where text.contains(marker) {
            markers.insert(marker)
        }
        return markers
    }

    /// 版本标记词表（**只收「一定是另一种录音」的词**）。
    ///
    /// `remaster` 不在表内：重制版是 **同一段录音**，不是另一种录音。
    private static let versionMarkerWords: [String] = [
        "live", "livehouse", "现场", "演唱会", "不插电",
        "remix", "mix", "混音", "dj版",
        "伴奏", "instrumental", "karaoke", "卡拉ok",
        "acoustic", "unplugged", "原声",
        "demo", "小样",
        "radioedit", "radio edit", "电台版",
    ]

    // MARK: - 审核

    /// 审核一次下载请求。
    ///
    /// - Returns: 审核结果（复用 / 替换 / 直接下载），**从不猜**。
    public func review(song: RemoteSong) async -> DownloadReviewDecision {
        guard let candidate = findLocalCandidate(song: song) else {
            return .downloadNew(reason: "本地没有对应的曲目")
        }
        // 索引里可能有 **已被删除** 的条目 → 那种「本地已有」不能当真。
        guard FileManager.default.fileExists(atPath: candidate.track.path) else {
            return .downloadNew(reason: "本地索引里的文件已不存在，重新下载")
        }
        // 本地质量：**实测**（读不到标签就不猜）。
        guard let localQuality = await measureQuality(path: candidate.track.path) else {
            return .reuseLocal(
                candidate,
                reason: "读不出本地文件的标签，无法证实远端版本更好，保留本地版本"
            )
        }
        // 远端质量：桥接 **探测** 到的码率与可选编码字段。
        let remoteQuality: AudioQuality
        do {
            let resolved = try await resolver.resolve(song: song)
            remoteQuality = AudioQuality.remote(resolved)
        } catch {
            return .reuseLocal(
                candidate,
                reason: "无法确认远端版本质量（\(Self.describe(error))），保留本地版本"
            )
        }
        if remoteQuality.isPossibleUpgrade(than: localQuality) {
            let evidence = remoteQuality.evidence == .measured
                ? "远端版本质量更高"
                : "远端版本可能是更高质量（只有容器提示，下载后实测确认）"
            return .replaceLocal(
                candidate,
                reason: "\(evidence)（远端 \(remoteQuality.description) / 本地 \(localQuality.description)）"
            )
        }
        return .reuseLocal(
            candidate,
            reason: "本地版本质量不低（本地 \(localQuality.description) / 远端 \(remoteQuality.description)），复用本地文件"
        )
    }

    /// 实测本地文件的质量（读不出标签 → nil）。
    public func measureQuality(path: String) async -> AudioQuality? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let tags = try await tagReader.readAudioTags(path: path)
            return AudioQuality.measured(tags: tags)
        } catch {
            return nil
        }
    }

    /// 读取本地文件的标签（身份核验用）。
    public func readTags(path: String) async -> AudioTags? {
        do {
            return try await tagReader.readAudioTags(path: path)
        } catch {
            return nil
        }
    }

    static func describe(_ error: Error) -> String {
        if let bridgeError = error as? BridgeClient.BridgeError { return bridgeError.description }
        if let clientError = error as? BridgeClient.ClientError { return clientError.description }
        if let serviceError = error as? BridgeServiceError { return serviceError.description }
        return error.localizedDescription
    }
}

// MARK: - 标签保留

/// 用桥接把旧文件的 **标签与封面** 写进新文件。
///
/// 规则（**用户手工改过的东西不能被上游标签覆盖**）：
/// - 旧文件的 **非空** 标签 **优先**写进新文件（即使新文件已经带了上游标签）；
/// - 旧文件有内嵌封面 → 把封面字节带到新文件（旧封面优先）；
/// - 写完 **重新读取核验**：字段逐项比对，封面 **按实际字节** 比对
///   （只看 `hasArtwork` 布尔不够：旧图换成新图仍然是 true）；
/// - 核验不过 → 抛错（调用方必须 **保留旧文件**）。
public final class MetadataTagPreserver: TagPreserving {
    private let service: MetadataService

    public init(service: MetadataService) {
        self.service = service
    }

    public func preserveTags(from oldPath: String, to newPath: String) async throws {
        let oldTags = try await service.readTags(path: oldPath)
        let newTags = try await service.readTags(path: newPath)
        // 旧文件的非空标签 **优先**（新文件已有上游标签也不覆盖）。
        let fields = Self.preservedFields(old: oldTags, new: newTags)
        // 封面：旧文件有 → 带到新文件（旧封面优先）。
        var artworkBase64: String?
        var artworkBytes: Data?
        if oldTags.hasArtwork {
            switch try await service.embeddedArtworkState(path: oldPath, tags: oldTags) {
            case .present(let data):
                artworkBytes = data
                artworkBase64 = data.base64EncodedString()
            case .none:
                artworkBase64 = nil
            case .unreadable(let message):
                throw MetadataError.conflict("读不出旧文件的内嵌封面：\(message)")
            }
        }
        guard !fields.isEmpty || artworkBase64 != nil else { return }
        let applied = MetadataSelection(
            fields: fields,
            artworkBase64: artworkBase64,
            removeArtwork: false
        )
        _ = try await service.writeTags(path: newPath, patch: applied.patch())
        // 写后核验：新文件必须真的有这些值。
        let verified = try await service.readTags(path: newPath)
        for (field, expected) in applied.fields {
            guard let actual = verified.value(for: field),
                  field.normalize(actual) == field.normalize(expected) else {
                throw MetadataError.verificationFailed("写后重读没有保留字段「\(field.title)」")
            }
        }
        // 封面：**实读字节**核验（布尔不算数）。
        if let artworkBytes {
            switch try await service.embeddedArtworkState(path: newPath, tags: verified) {
            case .present(let actual):
                guard actual == artworkBytes else {
                    throw MetadataError.verificationFailed("写后重读的封面与原封面不是同一份数据")
                }
            case .none:
                throw MetadataError.verificationFailed("写后重读没有内嵌封面")
            case .unreadable(let message):
                throw MetadataError.verificationFailed("写后重读封面失败：\(message)")
            }
        }
    }

    /// 旧文件里 **应当保留** 的字段（非空；与新文件已相同的跳过，避免无谓写入）。
    static func preservedFields(old: AudioTags, new: AudioTags) -> [MetadataField: String] {
        var fields: [MetadataField: String] = [:]
        for field in MetadataField.allCases where field != .artwork {
            guard let oldValue = old.value(for: field),
                  !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let newValue = new.value(for: field) ?? ""
            if field.normalize(newValue) == field.normalize(oldValue) { continue }
            fields[field] = oldValue
        }
        return fields
    }
}

// MARK: - 优质替换（下载验证 → 迁移引用 → 提交）

/// 「优质替换」的错误（**每一条都要能显示给用户**）。
public enum DownloadReplacementError: Error, CustomStringConvertible {
    /// 被拒绝（路径 / 身份 / 质量 / 冲突）。
    case rejected(String)

    public var description: String {
        switch self {
        case .rejected(let message): return message
        }
    }
}

/// 「优质替换」的提交结果。
public enum ReplacementOutcome: Equatable {
    /// 已替换：存活文件在 `path`（**引用已全部迁移**）。
    case committed(path: String)
    /// 已替换，但 **收尾状态没写回去**（替换本身成功；记录仍是「提交中」，可恢复）。
    case committedWithWarning(path: String, warning: String)
    /// 新版本不比旧版本好 → **保留旧文件**。
    case discarded(reason: String)
    /// 失败（**旧文件原样保留**，引用未迁移）。
    case failed(String)

    /// 替换是否已经生效（存活文件路径）。
    public var survivingPath: String? {
        switch self {
        case .committed(let path), .committedWithWarning(let path, _): return path
        case .discarded, .failed: return nil
        }
    }
}

/// 优质替换服务：**先完整下载并验证，再迁移引用并提交**。
///
/// 流程（每一步都可回滚）：
/// 1. 校验路径（同一个路径 / 同一个 inode / 符号链接 → 拒绝）；
/// 2. 查 **旧文件指纹**（登记之后被改过 → 拒绝替换）；
/// 3. 核验 **同一个录音**（来源 ID / 时长 / 标题 / 艺人 / 版本标记）；
/// 4. **实测**质量：新版本必须 **可证实** 更高（否则弃新复用旧）；
/// 5. **保留旧文件的标签与封面**（写进新文件并实读核验）；
/// 6. 持久化「提交中」意图（可恢复）；
/// 7. 迁移引用：索引 / 本地歌单 / 入单记录 / 内存播放队列 → **新文件路径**；
/// 8. 全部成功后才把旧文件移入废纸篓，并标记完成。
///
/// 任一步失败 → **旧文件原样保留**，记录留在待处理里可重试。
public final class DownloadReplacementService {

    /// 废纸篓动作（**可注入**：测试用隔离目录，绝不写真实用户废纸篓）。
    public typealias TrashAction = (String) throws -> Void

    private let store: NativeStore
    private let index: LibraryIndex
    private let library: LocalLibrary
    private let intake: DownloadIntakeService
    private let review: DownloadReviewService
    private let tagPreserver: TagPreserving?
    /// 内存里的播放引用（队列 / 当前曲目）也要跟着迁移。
    private let playbackReferences: PlaybackReferenceUpdating?
    /// 移入废纸篓（**可注入**，失败会被记录下来并留待恢复）。
    private let trash: TrashAction

    public init(
        store: NativeStore,
        index: LibraryIndex,
        library: LocalLibrary,
        intake: DownloadIntakeService,
        review: DownloadReviewService,
        tagPreserver: TagPreserving? = nil,
        playbackReferences: PlaybackReferenceUpdating? = nil,
        trash: @escaping TrashAction = { path in
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
    ) {
        self.store = store
        self.index = index
        self.library = library
        self.intake = intake
        self.review = review
        self.tagPreserver = tagPreserver
        self.playbackReferences = playbackReferences
        self.trash = trash
    }

    // MARK: - 登记

    /// 登记一次「优质替换」意图（**必须在入队下载之前**落盘）。
    ///
    /// 登记时记下 **旧文件的指纹**：下载期间用户改了旧文件 → 提交时必须拒绝。
    ///
    /// - Important: **不删除**同曲的 `.committing` 记录 ——
    ///   那是上一轮 **中断** 的迁移，删掉就永久丢失了恢复依据。
    ///   同曲已有 `.committing` 时 **直接拒绝** 新意图：
    ///   应当先让 `repairPending()` 把上一轮收尾，
    ///   否则会出现两条事务互相打架、旧迁移变成孤儿文件。
    public func register(neteaseId: Int64, oldPath: String) throws {
        if let interrupted = store.current.pendingReplacements.last(where: {
            $0.neteaseId == neteaseId && $0.state == .committing
        }) {
            throw DownloadReplacementError.rejected(
                "曲目 \(neteaseId) 上一轮替换还没收尾（记录 \(interrupted.id)），已拒绝新的替换请求；请先完成上次未完成的替换"
            )
        }
        let now = Date().timeIntervalSince1970
        let fingerprint = FileFingerprint.capture(URL(fileURLWithPath: oldPath))
        try store.mutate { state in
            // 同一曲目只保留一条 **待处理** 记录（新的覆盖旧的）。
            state.pendingReplacements.removeAll { $0.neteaseId == neteaseId && $0.state == .pending }
            state.pendingReplacements.append(PendingReplacement(
                neteaseId: neteaseId,
                oldPath: oldPath,
                oldFingerprint: DownloadReplacementService.fingerprintDigest(fingerprint),
                createdAt: now
            ))
        }
    }

    /// 某曲目的待处理替换记录。
    public func pending(neteaseId: Int64) -> PendingReplacement? {
        store.current.pendingReplacements.last {
            $0.neteaseId == neteaseId && $0.state == .pending
        }
    }

    /// 某曲目的 **提交中** 记录（崩溃恢复用）。
    public func committing(neteaseId: Int64) -> PendingReplacement? {
        store.current.pendingReplacements.last {
            $0.neteaseId == neteaseId && $0.state == .committing
        }
    }

    /// 全部待处理替换（界面提示用）。
    public var pendingRecords: [PendingReplacement] {
        store.current.pendingReplacements.filter { $0.state == .pending }
    }

    /// 某曲目 **最近一条** 替换记录的旧文件路径（nil = 没有记录）。
    ///
    /// 替换失败 / 放弃时用它回到 **仍然可用的旧文件**。
    public func oldPath(neteaseId: Int64) -> String? {
        store.current.pendingReplacements.last { $0.neteaseId == neteaseId }?.oldPath
    }

    /// 某曲目当前 **存活** 的文件路径（nil = 没有记录 / 还没定）。
    ///
    /// - `.committed` → **新** 文件路径；
    /// - `.discarded`（新版本被弃）→ **旧** 文件路径；
    /// - `.pending` / `.committing` → 旧文件路径（还没定，但旧文件仍然可用）。
    ///
    /// 用途：**重复 / 迟到** 的「下载完成」事件可能带着 **已被弃掉** 的新文件路径，
    /// 必须先解出存活路径再判断文件是否存在（否则会误报「文件不存在」，
    /// 或者把已弃掉的文件重新入单）。
    public func survivingPath(neteaseId: Int64) -> String? {
        guard let latest = store.current.pendingReplacements.last(where: {
            $0.neteaseId == neteaseId
        }) else { return nil }
        switch latest.state {
        case .committed:
            return latest.newPath.isEmpty ? latest.oldPath : latest.newPath
        case .discarded, .pending, .committing:
            return latest.oldPath.isEmpty ? nil : latest.oldPath
        }
    }

    // MARK: - 提交

    /// 提交一次替换（下载完成 → 验证 → 迁移引用 → 提交）。
    ///
    /// - Parameters:
    ///   - neteaseId: 曲目 ID。
    ///   - newPath: 新下载文件的路径。
    ///   - newTags: 已读好的新文件标签（避免重复读；nil = 现场读）。
    /// - Returns: 提交结果（失败时 **旧文件原样保留**）。
    @discardableResult
    public func commit(
        neteaseId: Int64,
        newPath: String,
        newTags: AudioTags? = nil
    ) async -> ReplacementOutcome {
        // **本次意图优先**：只有 pending / committing 记录才是「这一轮」的替换。
        //
        // 不能拿 **任意历史 committed 记录** 来判断幂等：
        // 那样第二次质量升级（新文件路径不同）会被旧记录挡住，永远升不了级。
        guard let record = pending(neteaseId: neteaseId) ?? committing(neteaseId: neteaseId) else {
            // 没有本次意图 → 只有「同曲目 + 同新文件」的重复完成才按幂等成功处理。
            if let committed = store.current.pendingReplacements.last(where: {
                $0.neteaseId == neteaseId && $0.state == .committed && $0.newPath == newPath
            }) {
                return .committed(path: committed.newPath)
            }
            return .failed("没有待处理的替换记录")
        }
        let oldPath = record.oldPath

        // 1) 路径校验：**同一个路径 / 同一个 inode / 符号链接** 一律拒绝。
        switch validatePaths(oldPath: oldPath, newPath: newPath) {
        case .failure(let error):
            markFailed(neteaseId: neteaseId, reason: error.description)
            return .failed(error.description)
        case .success:
            break
        }

        // 2) 旧文件指纹冲突检查（下载期间用户改过旧文件 → 不动它）。
        if !record.oldFingerprint.isEmpty {
            let current = DownloadReplacementService.fingerprintDigest(
                FileFingerprint.capture(URL(fileURLWithPath: oldPath))
            )
            guard current == record.oldFingerprint else {
                var message = "本地文件在下载期间被改动，已放弃替换（保留原文件）"
                if let note = quarantineNewFile(
                    neteaseId: neteaseId,
                    newPath: newPath,
                    oldPath: oldPath,
                    reason: "替换已放弃"
                ) {
                    message += "；\(note)"
                }
                markFailed(neteaseId: neteaseId, reason: message)
                return .failed(message)
            }
        }

        // 3) 同一个录音的身份核验（来源 ID / 时长 / 标题 / 艺人 / 版本标记）。
        guard let oldTags = await review.readTags(path: oldPath) else {
            let message = "读不出本地文件的标签，无法确认是不是同一首，保留原文件"
            markFailed(neteaseId: neteaseId, reason: message)
            return .failed(message)
        }
        let resolvedNewTags: AudioTags
        if let newTags {
            resolvedNewTags = newTags
        } else if let read = await review.readTags(path: newPath) {
            resolvedNewTags = read
        } else {
            var message = "读不出新下载文件的标签，无法确认是不是同一首，保留原文件"
            if let note = quarantineNewFile(
                neteaseId: neteaseId,
                newPath: newPath,
                oldPath: oldPath,
                reason: "无法核验"
            ) {
                message += "；\(note)"
            }
            markFailed(neteaseId: neteaseId, reason: message)
            return .failed(message)
        }
        switch verifySameRecording(old: oldTags, new: resolvedNewTags) {
        case .failure(let error):
            markFailed(neteaseId: neteaseId, reason: error.description)
            return .failed(error.description)
        case .success:
            break
        }

        // 4) 质量：新版本必须 **实测** 且 **可证实** 更高。
        guard let newQuality = await review.measureQuality(path: newPath) else {
            let message = "读不出新下载文件的标签，无法确认质量，保留原文件"
            markFailed(neteaseId: neteaseId, reason: message)
            return .failed(message)
        }
        guard let oldQuality = await review.measureQuality(path: oldPath) else {
            let message = "读不出本地文件的标签，无法确认质量，保留原文件"
            markFailed(neteaseId: neteaseId, reason: message)
            return .failed(message)
        }
        guard newQuality.isProvablyHigher(than: oldQuality) else {
            var reason = "新下载版本不比本地版本好（本地 \(oldQuality.description) / 新 \(newQuality.description)）"
            markDiscarded(neteaseId: neteaseId, reason: reason)
            // 弃掉的新文件：移入废纸篓（移不走就留着，并记下来）。
            do {
                try trashFile(at: newPath)
            } catch {
                reason += "；新下载文件未能移入废纸篓：\(Self.describe(error))"
                markDiscarded(neteaseId: neteaseId, reason: reason)
                let fingerprint = DownloadReplacementService.fingerprintDigest(
                    FileFingerprint.capture(URL(fileURLWithPath: newPath))
                )
                setPendingTrash(recordID: record.id, path: newPath, fingerprint: fingerprint)
            }
            return .discarded(reason: reason)
        }

        // 5) 保留旧文件的标签与封面（写进新文件并实读核验）。
        if let tagPreserver {
            do {
                try await tagPreserver.preserveTags(from: oldPath, to: newPath)
            } catch {
                var message = "保留原标签失败，未替换（保留原文件）：\(Self.describe(error))"
                if let note = quarantineNewFile(
                    neteaseId: neteaseId,
                    newPath: newPath,
                    oldPath: oldPath,
                    reason: "替换未完成"
                ) {
                    message += "；\(note)"
                }
                markFailed(neteaseId: neteaseId, reason: message)
                return .failed(message)
            }
        }

        // 5b) **保留之后重读**新文件的标签：索引必须反映 **最终** 的标签
        //     （用保留前的快照会把用户手工标签漏在索引里）。
        let finalTags: AudioTags
        if let reread = await review.readTags(path: newPath) {
            finalTags = reread
        } else {
            let message = "保留标签后读不出新文件的标签，未替换（保留原文件）"
            markFailed(neteaseId: neteaseId, reason: message)
            return .failed(message)
        }

        // 6) 持久化「提交中」意图（崩溃后可恢复）。
        //    同时记下 **新文件的指纹**：恢复时必须确认它还是当初那个。
        let newFingerprint = DownloadReplacementService.fingerprintDigest(
            FileFingerprint.capture(URL(fileURLWithPath: newPath))
        )
        do {
            try store.mutate { state in
                guard let position = state.pendingReplacements.lastIndex(where: { $0.id == record.id }) else { return }
                state.pendingReplacements[position].newPath = newPath
                state.pendingReplacements[position].state = .committing
                state.pendingReplacements[position].newFingerprint = newFingerprint
                state.pendingReplacements[position].pendingTrashPath = ""
                state.pendingReplacements[position].pendingTrashFingerprint = ""
                state.pendingReplacements[position].lastError = nil
            }
        } catch {
            let message = "写入替换状态失败，未替换（保留原文件）：\(Self.describe(error))"
            markFailed(neteaseId: neteaseId, reason: message)
            return .failed(message)
        }

        // 7) 迁移引用（索引 / 本地歌单 / 入单记录 / 内存播放队列）。
        var migration = MigrationState(oldTrack: index.track(path: oldPath))
        do {
            try await migrateReferences(&migration, from: oldPath, to: newPath, newTags: finalTags)
        } catch {
            // **全量回滚**：已经迁过去的引用全部退回来（旧文件还在，不会丢数据）。
            let rollbackErrors = await rollback(migration, oldPath: oldPath, newPath: newPath)
            var message = "迁移引用失败，已回滚并保留原文件：\(Self.describe(error))"
            if !rollbackErrors.isEmpty {
                message += "（回滚也未完全成功：\(rollbackErrors.joined(separator: "；"))）"
            }
            markFailed(neteaseId: neteaseId, reason: message)
            return .failed(message)
        }

        // 8) 标记完成（**旧文件待移入废纸篓**；移不走就留着，下次启动再试）。
        do {
            try store.mutate { state in
                guard let position = state.pendingReplacements.lastIndex(where: { $0.id == record.id }) else { return }
                state.pendingReplacements[position].state = .committed
                state.pendingReplacements[position].pendingTrashPath = oldPath
                state.pendingReplacements[position].lastError = nil
            }
        } catch {
            let warning = "替换已完成，但写入完成状态失败（记录仍为「提交中」，下次启动可恢复）：\(Self.describe(error))"
            return .committedWithWarning(path: newPath, warning: warning)
        }

        // 9) 旧文件移入废纸篓（**失败不算替换失败**：新文件已在位，引用已迁移）。
        //    移之前记下 **旧文件的指纹**：恢复时必须确认路径上的还是那个文件。
        let trashFingerprint = DownloadReplacementService.fingerprintDigest(
            FileFingerprint.capture(URL(fileURLWithPath: oldPath))
        )
        try? store.mutate { state in
            guard let position = state.pendingReplacements.lastIndex(where: { $0.id == record.id }) else { return }
            state.pendingReplacements[position].pendingTrashPath = oldPath
            state.pendingReplacements[position].pendingTrashFingerprint = trashFingerprint
        }
        do {
            try trashFile(at: oldPath)
            try? store.mutate { state in
                guard let position = state.pendingReplacements.lastIndex(where: { $0.id == record.id }) else { return }
                state.pendingReplacements[position].pendingTrashPath = ""
                state.pendingReplacements[position].pendingTrashFingerprint = ""
            }
            return .committed(path: newPath)
        } catch {
            let reason = "旧文件未能移入废纸篓：\(Self.describe(error))"
            try? store.mutate { state in
                guard let position = state.pendingReplacements.lastIndex(where: { $0.id == record.id }) else { return }
                state.pendingReplacements[position].lastError = reason
            }
            return .committedWithWarning(path: newPath, warning: reason)
        }
    }

    // MARK: - 启动恢复

    /// 恢复上次 **未完成** 的替换（`.committing` 状态）。
    ///
    /// **恢复必须重新核验**（不能只看「新文件还在」就删旧文件）：
    /// - 路径校验（不同路径 / 不同 inode / 非符号链接）；
    /// - 旧文件指纹仍与登记时一致（用户改过 → 不动它）；
    /// - 新文件指纹仍与提交时一致（被换掉 / 损坏 → 不动旧文件）；
    /// - 新文件 **能读出完整标签**，且与旧文件 **是同一首录音**、质量 **可证实更高**；
    /// - 任何一项 **不确定** → **两个文件都保留** 并报错（绝不删唯一的好文件）。
    ///
    /// - Returns: 每条记录的处理说明（空数组 = 没有需要恢复的）。
    @discardableResult
    public func repairPending() async -> [String] {
        var report: [String] = []
        for record in store.current.pendingReplacements where record.state == .committing {
            let newPath = record.newPath
            guard !newPath.isEmpty else {
                try? markFailed(neteaseId: record.neteaseId, reason: "替换记录缺少新文件路径，已放弃")
                report.append("上次未完成的替换缺少新文件路径，已放弃（旧文件保留）")
                continue
            }
            guard FileManager.default.fileExists(atPath: newPath) else {
                try? markFailed(neteaseId: record.neteaseId, reason: "新文件已不存在，保留原文件")
                report.append("上次未完成的替换找不到新文件，已保留原文件")
                continue
            }
            let oldExists = FileManager.default.fileExists(atPath: record.oldPath)

            // 1) 路径校验（**同路径 / 同 inode / 符号链接** 一律不恢复）。
            switch validatePaths(oldPath: record.oldPath, newPath: newPath) {
            case .failure(let error):
                report.append("上次未完成的替换未恢复（\(error.description)）；两个文件都已保留")
                continue
            case .success:
                break
            }

            // 2) 旧文件指纹：用户改过 → 不动它（保留两边）。
            if oldExists, !record.oldFingerprint.isEmpty {
                let current = DownloadReplacementService.fingerprintDigest(
                    FileFingerprint.capture(URL(fileURLWithPath: record.oldPath))
                )
                guard current == record.oldFingerprint else {
                    report.append("上次未完成的替换未恢复（旧文件已被改动）；两个文件都已保留")
                    continue
                }
            }

            // 3) 新文件指纹：必须还是提交时那一个（防止被换掉 / 损坏）。
            if !record.newFingerprint.isEmpty {
                let current = DownloadReplacementService.fingerprintDigest(
                    FileFingerprint.capture(URL(fileURLWithPath: newPath))
                )
                guard current == record.newFingerprint else {
                    report.append("上次未完成的替换未恢复（新文件已被改动或损坏）；两个文件都已保留")
                    continue
                }
            }

            // 4) 身份与质量核验：**读不出标签就不恢复**（不猜、不删旧文件）。
            var newTags = AudioTags(path: newPath)
            if let read = await review.readTags(path: newPath) {
                newTags = read
            } else if oldExists {
                report.append("上次未完成的替换未恢复（读不出新文件的标签）；两个文件都已保留")
                continue
            }
            if oldExists {
                guard let oldTags = await review.readTags(path: record.oldPath) else {
                    report.append("上次未完成的替换未恢复（读不出旧文件的标签）；两个文件都已保留")
                    continue
                }
                switch verifySameRecording(old: oldTags, new: newTags) {
                case .failure(let error):
                    report.append("上次未完成的替换未恢复（\(error.description)）；两个文件都已保留")
                    continue
                case .success:
                    break
                }
                guard let newQuality = await review.measureQuality(path: newPath),
                      let oldQuality = await review.measureQuality(path: record.oldPath),
                      newQuality.isProvablyHigher(than: oldQuality) else {
                    report.append("上次未完成的替换未恢复（无法证实新文件更好）；两个文件都已保留")
                    continue
                }
            }

            // 5) 迁移引用（**幂等**：重跑一次不会重复迁移）。
            var migration = MigrationState(oldTrack: index.track(path: record.oldPath))
            do {
                try await migrateReferences(&migration, from: record.oldPath, to: newPath, newTags: newTags)
            } catch {
                report.append("上次未完成的替换仍未能迁移引用：\(Self.describe(error))")
                continue
            }
            do {
                try store.mutate { state in
                    guard let position = state.pendingReplacements.lastIndex(where: { $0.id == record.id }) else { return }
                    state.pendingReplacements[position].state = .committed
                    state.pendingReplacements[position].pendingTrashPath = oldExists ? record.oldPath : ""
                    state.pendingReplacements[position].pendingTrashFingerprint = oldExists ? record.oldFingerprint : ""
                }
            } catch {
                report.append("上次未完成的替换已迁移引用，但状态未能写回：\(Self.describe(error))")
                continue
            }
            guard oldExists else {
                report.append("已补齐上次未完成的替换：\(record.oldPath) → \(newPath)")
                continue
            }
            do {
                try trashFile(at: record.oldPath)
                try? store.mutate { state in
                    guard let position = state.pendingReplacements.lastIndex(where: { $0.id == record.id }) else { return }
                    state.pendingReplacements[position].pendingTrashPath = ""
                    state.pendingReplacements[position].pendingTrashFingerprint = ""
                }
                report.append("已补齐上次未完成的替换：\(record.oldPath) → \(newPath)")
            } catch {
                report.append("上次未完成的替换已补齐，但旧文件未能移入废纸篓：\(Self.describe(error))")
            }
        }
        // **废纸篓待清理** 的文件（替换成功 / 弃掉新版本，但移入废纸篓失败）
        // → 再试一次（**必须先核对指纹**：路径上的文件可能已被用户换掉）。
        for record in store.current.pendingReplacements where !record.pendingTrashPath.isEmpty {
            let current = DownloadReplacementService.fingerprintDigest(
                FileFingerprint.capture(URL(fileURLWithPath: record.pendingTrashPath))
            )
            if !record.pendingTrashFingerprint.isEmpty, current != record.pendingTrashFingerprint {
                report.append("待清理的文件已被改动，未移入废纸篓：\(record.pendingTrashPath)")
                continue
            }
            do {
                try trashFile(at: record.pendingTrashPath)
                try store.mutate { state in
                    guard let position = state.pendingReplacements.lastIndex(where: { $0.id == record.id }) else { return }
                    state.pendingReplacements[position].pendingTrashPath = ""
                    state.pendingReplacements[position].pendingTrashFingerprint = ""
                }
                report.append("已清理上次未能移入废纸篓的文件：\(record.pendingTrashPath)")
            } catch {
                report.append("上次未能移入废纸篓的文件仍在原处：\(record.pendingTrashPath)（\(Self.describe(error))）")
            }
        }
        return report
    }

    // MARK: - 内部

    /// 路径校验（同一个路径 / 同一个 inode / 符号链接 → 拒绝）。
    private func validatePaths(oldPath: String, newPath: String) -> Result<Void, DownloadReplacementError> {
        let oldURL = URL(fileURLWithPath: oldPath).standardizedFileURL
        let newURL = URL(fileURLWithPath: newPath).standardizedFileURL
        guard oldURL.path != newURL.path else {
            return .failure(.rejected("新下载文件与本地文件是同一个路径，拒绝替换"))
        }
        var oldInfo = stat()
        guard lstat(oldURL.path, &oldInfo) == 0 else {
            return .failure(.rejected("本地文件不存在：\(oldURL.path)"))
        }
        var newInfo = stat()
        guard lstat(newURL.path, &newInfo) == 0 else {
            return .failure(.rejected("新下载文件不存在：\(newURL.path)"))
        }
        guard oldInfo.st_mode & S_IFMT != S_IFLNK, newInfo.st_mode & S_IFMT != S_IFLNK else {
            return .failure(.rejected("涉及符号链接，拒绝替换"))
        }
        // **同一个文件**（同设备 + 同 inode）→ 拒绝。
        //
        // 方向必须写对：`dev/inode` **相同** 才是同一个文件；
        // 不同就是不同文件（正常的新下载文件）→ 必须放行。
        let sameInode = oldInfo.st_dev == newInfo.st_dev && oldInfo.st_ino == newInfo.st_ino
        guard !sameInode else {
            return .failure(.rejected("新下载文件与本地文件是同一个文件（同一 inode），拒绝替换"))
        }
        return .success(())
    }

    /// 同一个录音的身份核验。
    ///
    /// 身份由 **来源 ID / 时长 / 艺人 / 版本标记** 判定：
    /// - **标题不作为身份判定**：旧文件里的标题可能是用户手工改过的
    ///   （例如「晴天 (Remastered)」），替换时要 **保留旧标题**，
    ///   不能因为标题不同就拒绝升级；
    /// - 但 **版本标记**（现场 / 混音 / 伴奏…）不同 → **不同的录音**，必须拒绝。
    private func verifySameRecording(old: AudioTags, new: AudioTags) -> Result<Void, DownloadReplacementError> {
        // 来源 ID：双方都知道时必须一致。
        if old.neteaseId > 0, new.neteaseId > 0, old.neteaseId != new.neteaseId {
            return .failure(.rejected("新下载文件不是同一首（来源 ID 不一致），保留原文件"))
        }
        // 时长：必须都知道且接近。
        guard old.durationMs > 0, new.durationMs > 0 else {
            return .failure(.rejected("无法确认新旧文件时长一致，保留原文件"))
        }
        let delta = abs(old.durationMs - new.durationMs)
        guard delta <= 2_000 else {
            return .failure(.rejected("新下载文件时长与本地文件相差 \(delta) ms，不是同一首，保留原文件"))
        }
        // 艺人：双方都知道时必须一致（不同艺人 → 不是同一首）。
        let oldArtist = DownloadReviewService.normalized(old.artist)
        let newArtist = DownloadReviewService.normalized(new.artist)
        if !oldArtist.isEmpty, !newArtist.isEmpty, oldArtist != newArtist {
            return .failure(.rejected("新下载文件艺人与本地文件不一致，不是同一首，保留原文件"))
        }
        // 版本标记（现场 / 混音 / 伴奏…）：不一致 → **不同的录音**，拒绝。
        let oldMarkers = DownloadReviewService.versionMarkers(old.title)
        let newMarkers = DownloadReviewService.versionMarkers(new.title)
        guard oldMarkers == newMarkers else {
            return .failure(.rejected("新下载文件与本地文件的版本标记不一致（现场版 / 混音版），不是同一首录音，保留原文件"))
        }
        return .success(())
    }

    /// 迁移过程中已经改动的部分（**用于全量回滚**）。
    private struct MigrationState {
        var oldTrack: TrackRecord?
        /// 迁移前 **新路径** 上已有的条目（没有则 nil）——回滚时原样恢复。
        var previousNewTrack: TrackRecord?
        var indexMigrated = false
        var migratedPlaylistIds: [String] = []
        var intakesMigrated = false
        var playbackMigrated = false
    }

    /// 迁移引用（**幂等**：可以重复执行）。
    ///
    /// - 索引：旧条目换成新路径的条目（**来源 ID 保留**），一次事务完成；
    /// - 本地歌单：**保持条目位置**；
    /// - 入单记录：路径变了，确认状态跟着走；
    /// - 内存播放队列：跟着改（不打断当前播放）。
    private func migrateReferences(
        _ migration: inout MigrationState,
        from oldPath: String,
        to newPath: String,
        newTags: AudioTags
    ) async throws {
        try migrateIndex(&migration, from: oldPath, to: newPath, newTags: newTags)
        try migratePlaylists(&migration, from: oldPath, to: newPath)
        try migrateIntakes(&migration, from: oldPath, to: newPath)
        await migratePlayback(&migration, from: oldPath, to: newPath)
    }

    /// 索引迁移：旧条目换成新路径的条目（**来源 ID 保留**）。
    ///
    /// - Important: **不得用空记录覆盖已存在的条目**。
    ///   旧条目可能已经被上一次迁移删掉（`oldTrack == nil`），
    ///   此时新路径上 **可能已经有** 迁移好的条目（带来源 ID 与用户手工标签）——
    ///   直接覆盖会 **清空来源 ID 与整条元信息**。
    ///   因此：旧记录缺失时 **合并** 新路径上已有的条目，只刷新可确认的字段。
    private func migrateIndex(
        _ migration: inout MigrationState,
        from oldPath: String,
        to newPath: String,
        newTags: AudioTags
    ) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: newPath)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        // **一次事务**：新条目写进去、旧条目同时移除（不会留下两份索引）。
        var previous: TrackRecord?
        try index.mutate { tracks in
            // 基准：旧条目 → 新路径上已有条目 → 空记录（**只补，不覆盖**）。
            var record = migration.oldTrack
            if let position = tracks.firstIndex(where: { $0.path == newPath }) {
                previous = tracks[position]
                if record == nil { record = tracks[position] }
            }
            var updated = record ?? TrackRecord(path: newPath)
            updated.path = newPath
            updated.size = size
            updated.modifiedAt = modified
            // 只用 **非空** 的实测标签刷新（空值不清空已有内容）。
            if !newTags.title.isEmpty { updated.title = newTags.title }
            if !newTags.artist.isEmpty { updated.artist = newTags.artist }
            if !newTags.album.isEmpty { updated.album = newTags.album }
            if newTags.durationMs > 0 { updated.durationMs = UInt64(newTags.durationMs) }
            if !newTags.format.isEmpty { updated.format = newTags.format }
            // **来源 ID**：优先已有记录，其次新文件标签里读到的。
            if updated.neteaseId <= 0, newTags.neteaseId > 0 { updated.neteaseId = newTags.neteaseId }
            if let position = tracks.firstIndex(where: { $0.path == newPath }) {
                tracks[position] = updated
            } else {
                tracks.append(updated)
            }
            tracks.removeAll { $0.path == oldPath }
        }
        migration.previousNewTrack = previous
        migration.indexMigrated = true
    }

    /// 本地歌单迁移（**保持条目位置**）。
    private func migratePlaylists(
        _ migration: inout MigrationState,
        from oldPath: String,
        to newPath: String
    ) throws {
        let (playlists, issues, _) = library.playlistsWithIssues()
        // 有歌单读不出来 → 不做部分迁移（避免只迁一半）。
        guard issues.isEmpty else {
            throw LocalLibraryError.notFound("有歌单读取失败，未迁移引用")
        }
        for playlist in playlists where playlist.entries.contains(where: { $0.path == oldPath }) {
            try library.replacePathInPlaylist(id: playlist.id, from: oldPath, to: newPath)
            migration.migratedPlaylistIds.append(playlist.id)
        }
    }

    /// 入单记录迁移（路径变了，确认状态跟着走）。
    private func migrateIntakes(
        _ migration: inout MigrationState,
        from oldPath: String,
        to newPath: String
    ) throws {
        try store.mutate { state in
            for index in state.downloadIntakes.indices where state.downloadIntakes[index].path == oldPath {
                state.downloadIntakes[index].path = newPath
            }
        }
        migration.intakesMigrated = true
    }

    /// 内存播放队列迁移（**不打断当前播放**）。
    private func migratePlayback(
        _ migration: inout MigrationState,
        from oldPath: String,
        to newPath: String
    ) async {
        await playbackReferences?.updateLocalPath(from: oldPath, to: newPath)
        migration.playbackMigrated = true
    }

    /// **全量回滚**：把已经迁过去的引用全部退回来。
    ///
    /// - Returns: 回滚失败的原因（空数组 = 全部回滚成功）。
    private func rollback(_ migration: MigrationState, oldPath: String, newPath: String) async -> [String] {
        var problems: [String] = []
        if migration.indexMigrated {
            do {
                try index.mutate { tracks in
                    if let oldTrack = migration.oldTrack {
                        // 恢复旧条目（**路径改回旧路径**；迁移时删掉的那条就此还原）。
                        if let position = tracks.firstIndex(where: { $0.path == newPath }) {
                            tracks[position] = oldTrack
                        } else {
                            tracks.append(oldTrack)
                        }
                    } else if let previous = migration.previousNewTrack {
                        // 恢复迁移 **前** 新路径上的条目（不丢来源 ID 与手工标签）。
                        if let position = tracks.firstIndex(where: { $0.path == newPath }) {
                            tracks[position] = previous
                        } else {
                            tracks.append(previous)
                        }
                    } else {
                        // 迁移前新路径上没有条目 → 删掉迁移新建的那条。
                        tracks.removeAll { $0.path == newPath }
                    }
                }
            } catch {
                problems.append("索引回滚失败：\(Self.describe(error))")
            }
        }
        for playlistId in migration.migratedPlaylistIds {
            do {
                try library.replacePathInPlaylist(id: playlistId, from: newPath, to: oldPath)
            } catch {
                problems.append("歌单 \(playlistId) 回滚失败：\(Self.describe(error))")
            }
        }
        if migration.intakesMigrated {
            do {
                try store.mutate { state in
                    for index in state.downloadIntakes.indices where state.downloadIntakes[index].path == newPath {
                        state.downloadIntakes[index].path = oldPath
                    }
                }
            } catch {
                problems.append("入单记录回滚失败：\(Self.describe(error))")
            }
        }
        if migration.playbackMigrated {
            let references = playbackReferences
            await references?.updateLocalPath(from: newPath, to: oldPath)
        }
        return problems
    }

    /// 记录失败原因（**保留待处理状态**，可重试）。
    private func markFailed(neteaseId: Int64, reason: String) {
        try? store.mutate { state in
            guard let position = state.pendingReplacements.lastIndex(where: {
                $0.neteaseId == neteaseId && $0.state != .committed
            }) else { return }
            state.pendingReplacements[position].state = .pending
            state.pendingReplacements[position].lastError = reason
        }
    }

    /// 放弃替换（新版本不比旧版本好）。
    private func markDiscarded(neteaseId: Int64, reason: String) {
        try? store.mutate { state in
            guard let position = state.pendingReplacements.lastIndex(where: {
                $0.neteaseId == neteaseId && $0.state != .committed
            }) else { return }
            state.pendingReplacements[position].state = .discarded
            state.pendingReplacements[position].lastError = reason
        }
    }

    /// 把文件移入废纸篓（**可注入**；移不走就抛错，绝不删用户文件）。
    private func trashFile(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try trash(path)
    }

    /// 记下「还有文件没移进废纸篓」（下次启动再试）。
    ///
    /// **必须带指纹**：路径上的文件可能已经被用户换成别的文件，
    /// 只凭路径就删会误删用户自己的文件。
    private func setPendingTrash(recordID: String, path: String, fingerprint: String) {
        try? store.mutate { state in
            guard let position = state.pendingReplacements.lastIndex(where: { $0.id == recordID }) else { return }
            state.pendingReplacements[position].pendingTrashPath = path
            state.pendingReplacements[position].pendingTrashFingerprint = fingerprint
        }
    }

    /// 把 **替换失败后遗留的新下载文件** 隔离掉。
    ///
    /// - 只处理 **普通文件**（符号链接 / 目录 / 与旧文件同一个都不动）；
    /// - 移入废纸篓（**可恢复**）；移不走就记下 **指纹** 待下次启动处理；
    /// - 记录指纹 → 恢复时先核对，**不会误删用户后来改过的文件**。
    ///
    /// - Returns: 说明（nil = 没有可隔离的文件）。
    private func quarantineNewFile(
        neteaseId: Int64,
        newPath: String,
        oldPath: String,
        reason: String
    ) -> String? {
        guard newPath != oldPath else { return nil }
        var info = stat()
        guard lstat(newPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        guard FileManager.default.fileExists(atPath: newPath) else { return nil }
        let fingerprint = DownloadReplacementService.fingerprintDigest(
            FileFingerprint.capture(URL(fileURLWithPath: newPath))
        )
        do {
            try trashFile(at: newPath)
            return "新下载的文件已移入废纸篓（\(reason)）"
        } catch {
            if let record = store.current.pendingReplacements.last(where: { $0.neteaseId == neteaseId }) {
                setPendingTrash(recordID: record.id, path: newPath, fingerprint: fingerprint)
            }
            return "新下载的文件未能移入废纸篓，仍在原处：\(newPath)（\(Self.describe(error))）"
        }
    }

    /// 指纹摘要（用于冲突检测）。
    static func fingerprintDigest(_ fingerprint: FileFingerprint) -> String {
        switch fingerprint {
        case .present(let size, let sha256, _, _, _, _):
            return "\(size):\(sha256)"
        case .missing:
            return ""
        case .unreadable:
            return ""
        }
    }

    static func describe(_ error: Error) -> String {
        if let atomicError = error as? AtomicFileError { return atomicError.description }
        if let indexError = error as? LibraryIndex.IndexError { return indexError.description }
        if let storeError = error as? NativeStore.StoreError { return storeError.description }
        if let libraryError = error as? LocalLibraryError { return libraryError.description }
        if let playlistError = error as? PlaylistFile.PlaylistError { return playlistError.description }
        if let metadataError = error as? MetadataError { return metadataError.description }
        return error.localizedDescription
    }
}
