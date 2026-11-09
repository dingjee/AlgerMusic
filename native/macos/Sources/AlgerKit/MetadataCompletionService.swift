import Foundation

// MARK: - 搜索提示

/// 自动补全用的 **搜索提示**。
///
/// 重要：提示只用来 **搜索**，**绝不** 直接写进标签 ——
///
/// 文件名推断出来的「艺人 - 标题」只能当作查询词，
/// 真正写进标签的值必须来自 **被严格匹配确认** 的录音。
public struct MetadataCompletionQuery: Equatable {
    /// 查询标题。
    public var title: String
    /// 查询艺人。
    public var artist: String

    public init(title: String = "", artist: String = "") {
        self.title = title
        self.artist = artist
    }
}

// MARK: - 统一建议

/// 自动补全的 **统一建议**（下载补全与编辑器共用同一套规则）。
public struct MetadataCompletionProposal: Equatable {

    /// 建议来源。
    public enum Source: Equatable {
        /// 没有补任何东西。
        case none
        /// 可信下载来源（`RemoteSong`）。
        case trustedSource
        /// 严格匹配到的 MusicBrainz 录音。
        case recording
        /// 两者都用上了（各补一部分）。
        case trustedSourceAndRecording
    }

    /// 结果状态。
    ///
    /// 语义是 **整体结果**，必须与 `values`（实际会填入的字段）一致：
    /// - `.completed`：按预期完成（补齐了字段，或标签本来就完整）；
    /// - `.completedWithWarning`：**可信来源那部分已经补上**，但外部匹配被拒绝
    ///   （歧义 / 低置信 / 不同版本 / 信息不足）；
    /// - 其余状态：什么都没补。
    public enum Status: Equatable {
        /// 完成（可能补了 0 个字段）。
        case completed
        /// 完成，但 **外部匹配** 被拒绝（可信来源补上的部分仍然算数）。
        case completedWithWarning(String)
        /// 没有可信候选（不写任何东西）。
        case noMatch(String)
        /// 候选有歧义（多个同样精确的候选）→ **拒绝自动选择**。
        case ambiguous(String)
        /// 候选置信度不足 → **拒绝自动填写**。
        case lowConfidence(String)
        /// 与文件里已有的来源 ID 冲突 → **拒绝自动写入**。
        case sourceIDConflict(String)
    }

    /// 结果状态。
    public var status: Status
    /// 建议来源。
    public var source: Source
    /// 要补的空字段 → 目标值（**只包含真正缺失的字段**）。
    public var values: [MetadataField: String]
    /// 面向用户的 **简短** 说明（界面直接显示；**不解释算法**）。
    public var note: String
    /// 详细原因（诊断 / 报告用；不直接显示给用户）。
    public var detail: String

    public init(
        status: Status,
        source: Source = .none,
        values: [MetadataField: String] = [:],
        note: String = "",
        detail: String = ""
    ) {
        self.status = status
        self.source = source
        self.values = values
        self.note = note
        self.detail = detail.isEmpty ? note : detail
    }

    /// 是否有可采纳的建议。
    public var hasValues: Bool { !values.isEmpty }

    /// 是否按预期完成（含「完成了但外部匹配被拒绝」）。
    public var isCompleted: Bool {
        switch status {
        case .completed, .completedWithWarning: return true
        default: return false
        }
    }

    /// 是否有需要提醒用户的部分（外部匹配被拒绝）。
    public var hasWarning: Bool {
        if case .completedWithWarning = status { return true }
        return false
    }
}

// MARK: - 服务

/// 元信息 **自动补全** 服务（保守、可解释、不假成功）。
///
/// 目标：下载完成后把 **可信** 的歌曲信息补进 **空字段**，
/// **不覆盖** 任何已有的非空标签，**永不** 动封面。
///
/// 硬规则：
/// - **可信来源优先**：`RemoteSong`（下载来源）提供来源 ID / 标题 / 艺人 / 专辑，
///   **只补空字段**；
/// - **来源 ID 冲突**：文件里已有的来源 ID 与可信来源不一致 → **整体拒绝**（一个字段都不写）；
/// - **占位与路径不写**：`Unrecognized` / `未知歌曲` / 绝对路径 一律不进标签；
/// - **标签够用就不再问外部**：核心字段（标题 / 艺人 / 专辑）齐了就不请求 MusicBrainz
///   （避免每首歌都打一次 MusicBrainz）；
/// - **缺字段才严格匹配**：标题 + 艺人 + 时长三者都严格对上才采纳；
///   多个同样精确的候选 → **拒绝自动选择**（歧义）；
///   低置信 / 不同版本（live、remix …）→ **拒绝自动填写**；
/// - **网络 / IO 失败明确抛出**：绝不假成功，也绝不静默改文件；
/// - **写前基线 + 写后核验**：复用 `MetadataApplyService`
///   （保存前重读做冲突检查 → 写入 → 写后重读严格核验）。
public final class MetadataCompletionService {

    // MARK: 常量

    /// 时长容差（毫秒）：超过就不认为是同一个录音（保守）。
    public static let durationToleranceMs = 2_000

    /// **自动写入** 的置信度下限（0…1）。
    ///
    /// 与人工候选的阈值（`MetadataCandidate.lowConfidenceThreshold` = 0.5）**分开**：
    /// 0.5 是「值得让人看一眼」的门槛，自动写回必须更保守。
    public static let autoWriteConfidenceThreshold: Double = 0.90

    /// 搜索返回条数上限（MusicBrainz 契约默认 25）。
    public static let searchLimit = 25

    /// **可补齐** 的字段全集。
    ///
    /// 不含封面（封面只能来自确认过的发行版本）、曲序 / 碟序（需要发行曲目表，
    /// 自动补全不猜）、流派（搜索候选里没有可靠来源）。
    public static let completableFields: [MetadataField] = [
        .title, .artist, .album, .albumArtist, .year, .date, .isrc,
        .neteaseId, .musicBrainzRecordingId, .musicBrainzReleaseId,
    ]

    /// **核心字段**：这三个齐了就认为「标签够用」，不再请求 MusicBrainz。
    public static let identifyingFields: [MetadataField] = [.title, .artist, .album]

    // MARK: 依赖

    /// 桥接客户端（**唯一**外部依赖）。
    public let client: BridgeClient
    /// 元信息服务（读标签 / 搜索候选）。
    private let service: MetadataService
    /// 写回服务（写前冲突检查 + 写后核验）。
    private let applyService: MetadataApplyService

    public init(client: BridgeClient) {
        self.client = client
        let service = MetadataService(client: client)
        self.service = service
        self.applyService = MetadataApplyService(service: service)
    }

    // MARK: - 下载后补全

    /// 下载完成后补全空字段（**只补空缺，绝不覆盖已有非空标签与封面**）。
    ///
    /// - Parameters:
    ///   - path: 落盘的音频文件路径（**只写标签，不移动 / 不重命名**）。
    ///   - source: 可信的下载来源（`RemoteSong`）；`nil` 表示没有可信来源。
    /// - Returns: **写后真实重读** 的标签；没有可补内容时返回 **原标签**（原样，不假成功）。
    /// - Throws: 网络 / IO / 写后核验失败 **明确抛出**（调用方显示原因，不阻塞播放）。
    @discardableResult
    public func completeDownloaded(path: String, source: RemoteSong? = nil) async throws -> AudioTags {
        // 1) 读原标签（写前基线）；读不到就是 IO / 桥接错误 → 抛。
        let baseline = try await service.readTags(path: path)

        // 2) 统一建议（可信来源优先，缺字段才严格匹配 MusicBrainz）。
        let suggestion = try await proposal(for: baseline, source: source)

        // 3) 没有可补的内容 → 原样返回（**不改文件**）。
        guard !suggestion.values.isEmpty else { return baseline }

        // 4) 写前冲突检查 + 写入 + 写后核验（复用 ApplyService）。
        let selection = MetadataSelection(fields: suggestion.values)
        return try await applyService.apply(path: path, baseline: baseline, selection: selection)
    }

    // MARK: - 统一建议

    /// 生成 **统一建议**（供编辑器使用；**只填草稿，不写文件**）。
    ///
    /// - Parameters:
    ///   - tags: 当前标签（编辑器里的写前基线）。
    ///   - source: 可信来源（`RemoteSong`）；`nil` 表示没有可信来源。
    ///   - query: 额外的搜索提示（例如从文件名推断的「艺人 - 标题」）。
    ///     **只用于搜索**，绝不直接写进标签。
    /// - Throws: 网络 / 桥接失败 **明确抛出**（不假成功）。
    public func proposal(
        for tags: AudioTags,
        source: RemoteSong? = nil,
        query: MetadataCompletionQuery? = nil
    ) async throws -> MetadataCompletionProposal {
        // 1) 已经完整 → 什么外部服务都不请求。
        let missing = Self.missingFields(in: tags)
        guard !missing.isEmpty else {
            return MetadataCompletionProposal(
                status: .completed,
                source: .none,
                note: "信息已经完整，无需补充。",
                detail: "标签已经完整，没有请求任何外部服务。"
            )
        }

        // 2) 可信来源优先（只补空字段）。
        var values: [MetadataField: String] = [:]
        var usedTrusted = false
        if let source {
            if let conflict = Self.sourceIDConflict(tags: tags, source: source) {
                return MetadataCompletionProposal(
                    status: .sourceIDConflict(conflict),
                    source: .none,
                    note: "与来源信息不一致，未自动补充。",
                    detail: "来源 ID 冲突（\(conflict)），已拒绝自动补全（没有写入任何字段）。"
                )
            }
            for (field, value) in Self.trustedValues(from: source) where missing.contains(field) {
                values[field] = value
                usedTrusted = true
            }
        }

        // 3) 核心字段还缺 → 才去严格匹配 MusicBrainz。
        let stillMissingCore = Self.identifyingFields.contains { field in
            missing.contains(field) && values[field] == nil
        }
        guard stillMissingCore else {
            // 核心信息齐了 → **不请求** MusicBrainz（避免每首歌都打一次）。
            return MetadataCompletionProposal(
                status: .completed,
                source: usedTrusted ? .trustedSource : .none,
                values: values,
                note: Self.filledNote(values.count),
                detail: values.isEmpty
                    ? "核心信息已完整，没有可补的空字段（没有请求 MusicBrainz）。"
                    : "已按可信来源补齐 \(values.count) 个空字段（没有请求 MusicBrainz）。"
            )
        }

        // 4) 组装严格查询（标题 + 艺人 + 时长缺一不可）。
        guard let request = Self.makeRequest(tags: tags, source: source, values: values, hint: query) else {
            return Self.rejection(
                status: .noMatch("缺少标题、艺人或时长，无法确认录音。"),
                userReason: "没有找到确定的结果，未自动补充。",
                values: values,
                usedTrusted: usedTrusted
            )
        }

        // 5) 严格匹配（网络失败 → 抛出，不假成功）。
        let candidates = try await service.search(
            title: request.title,
            artist: request.artist,
            durationMs: request.durationMs,
            limit: Self.searchLimit
        )

        let strict = Self.strictMatches(candidates: candidates, request: request)
        switch strict.count {
        case 0:
            return Self.rejection(
                candidates: candidates,
                request: request,
                values: values,
                usedTrusted: usedTrusted
            )
        case 1:
            // 唯一精确候选 → 采纳（仍然只补空字段）。
            let candidate = strict[0]
            for (field, value) in Self.recordingValues(candidate: candidate, tags: tags)
            where missing.contains(field) && values[field] == nil {
                values[field] = value
            }
            return MetadataCompletionProposal(
                status: .completed,
                source: usedTrusted ? .trustedSourceAndRecording : .recording,
                values: values,
                note: Self.filledNote(values.count),
                detail: "已按严格匹配（标题 + 艺人 + 时长 + 置信度）补齐 \(values.count) 个空字段。"
            )
        default:
            // 多个同样精确的候选 → **拒绝自动选择**。
            return Self.rejection(
                status: .ambiguous(
                    "找到 \(strict.count) 个标题、艺人、时长都完全一致的候选，无法确定是哪一个。"
                ),
                userReason: "有多个可能的结果，未自动补充。",
                values: values,
                usedTrusted: usedTrusted
            )
        }
    }

    // MARK: - 文件名提示

    /// 从文件名提取 **搜索草稿**（严格「艺人 - 标题」）。
    ///
    /// - 只在文件名里 **恰好有一个** ` - ` 分隔符时才算数；
    /// - 结果 **只用于搜索**，绝不直接写进标签（不能靠文件名断定录音）。
    public static func filenameQuery(path: String) -> MetadataCompletionQuery? {
        let name = TrackRecord.basenameWithoutExtension(path: path)
        guard !name.isEmpty else { return nil }
        let parts = name.components(separatedBy: " - ")
        guard parts.count == 2 else { return nil }
        let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isPlaceholder(artist), !isPlaceholder(title) else { return nil }
        return MetadataCompletionQuery(title: title, artist: artist)
    }

    // MARK: - 内部：字段判定

    /// **缺失** 的可补字段（只算「桥接读得到且为空」的字段）。
    ///
    /// 桥接 **读不到** 的字段（`nil`）不算缺失 —— 读不到就 **无法核验**，
    /// 写了也不能确认写成功，索性不碰。
    static func missingFields(in tags: AudioTags) -> [MetadataField] {
        completableFields.filter { field in
            guard let value = tags.value(for: field) else { return false }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 来源 ID 冲突（文件里的来源 ID 与可信来源不一致）。
    static func sourceIDConflict(tags: AudioTags, source: RemoteSong) -> String? {
        guard tags.neteaseId > 0, source.id > 0, tags.neteaseId != source.id else { return nil }
        return "文件里的来源 ID \(tags.neteaseId) 与可信来源 \(source.id) 不一致"
    }

    /// 可信来源能提供的字段（**只补空缺**，由调用方筛选）。
    static func trustedValues(from source: RemoteSong) -> [MetadataField: String] {
        var values: [MetadataField: String] = [:]
        if source.id > 0 { values[.neteaseId] = String(source.id) }
        if !isPlaceholder(source.name) { values[.title] = source.name }
        let artist = source.artistText
        if !isPlaceholder(artist) { values[.artist] = artist }
        if !isPlaceholder(source.album.name) { values[.album] = source.album.name }
        return values
    }

    /// 严格匹配到的录音能提供的字段。
    static func recordingValues(candidate: MetadataCandidate, tags: AudioTags) -> [MetadataField: String] {
        var values: [MetadataField: String] = [:]
        if !candidate.title.isEmpty { values[.title] = candidate.title }
        if !candidate.artist.isEmpty { values[.artist] = candidate.artist }
        if !candidate.recordingId.isEmpty { values[.musicBrainzRecordingId] = candidate.recordingId }
        // ISRC：**只有唯一值**才自动填（多个 ISRC 说明还有别的版本 / 地区条目 → 歧义）。
        if candidate.isrcs.count == 1 {
            let isrc = candidate.isrcs[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if !isrc.isEmpty { values[.isrc] = isrc }
        }
        // 发行版本：**只有能唯一确定**时才填（同一录音的多个专辑版本不猜）。
        if let release = uniqueRelease(in: candidate, tags: tags) {
            if !release.title.isEmpty { values[.album] = release.title }
            if !release.albumArtist.isEmpty { values[.albumArtist] = release.albumArtist }
            if !release.date.isEmpty { values[.date] = release.date }
            if let year = Self.year(from: release.date) { values[.year] = String(year) }
            if !release.id.isEmpty { values[.musicBrainzReleaseId] = release.id }
        }
        return values
    }

    /// 唯一能确定的发行版本（**猜不到就返回 nil**）。
    ///
    /// 规则（任何一条不满足都不填发行版本相关的字段）：
    /// - 文件里 **已有专辑名** → 必须 **唯一** 对上某个发行版本
    ///   （对不上说明是别的专辑，绝不把发行 ID / 日期配到别的专辑上）；
    /// - 文件里 **已有发行 ID** → 必须与选中的发行版本一致；
    /// - 没有任何线索 → 只有 **唯一** 一个发行版本时才能确定。
    static func uniqueRelease(in candidate: MetadataCandidate, tags: AudioTags) -> MetadataRelease? {
        let releases = candidate.releases
        guard !releases.isEmpty else { return nil }
        let existingReleaseId = (tags.musicBrainzReleaseId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let album = tags.album.trimmingCharacters(in: .whitespacesAndNewlines)

        let matched: [MetadataRelease]
        if !album.isEmpty {
            // 已有专辑名 → 只认专辑名对得上的发行版本。
            matched = releases.filter { normalize($0.title) == normalize(album) }
            guard matched.count == 1 else { return nil }
        } else if !existingReleaseId.isEmpty {
            matched = releases.filter { $0.id == existingReleaseId }
            guard matched.count == 1 else { return nil }
        } else {
            // 没有任何线索 → 只有唯一发行版本才算确定。
            guard releases.count == 1 else { return nil }
            matched = releases
        }
        let release = matched[0]
        // 已有发行 ID 与选中的不一致 → 不确定，不填。
        if !existingReleaseId.isEmpty, release.id != existingReleaseId { return nil }
        return release
    }

    // MARK: - 内部：严格匹配

    /// 严格查询（标题 + 艺人 + 时长）。
    struct Request: Equatable {
        var title: String
        var artist: String
        var durationMs: Int
    }

    /// 组装严格查询：可信来源 > 已有标签 > 搜索提示。
    static func makeRequest(
        tags: AudioTags,
        source: RemoteSong?,
        values: [MetadataField: String],
        hint: MetadataCompletionQuery?
    ) -> Request? {
        let title = firstUsable(values[.title], tags.title, hint?.title)
        let artist = firstUsable(values[.artist], tags.artist, hint?.artist)
        // 时长以 **文件自己的** 为准（文件才是这段音频）；文件读不到时才用来源时长。
        let durationMs = tags.durationMs > 0 ? tags.durationMs : Int(source?.durationMs ?? 0)
        guard let title, let artist, durationMs > 0 else { return nil }
        return Request(title: title, artist: artist, durationMs: durationMs)
    }

    /// 严格匹配的候选：标题、艺人、时长都要对上，且置信度 **足够高**。
    ///
    /// 置信度门槛用 **自动写入专用** 的 `autoWriteConfidenceThreshold`（0.90），
    /// **不沿用** 人工候选的 0.5 —— 人工候选只要让人看见就行，自动写回必须更保守。
    static func strictMatches(candidates: [MetadataCandidate], request: Request) -> [MetadataCandidate] {
        guard request.durationMs > 0 else { return [] }
        return candidates.filter { candidate in
            guard candidate.durationMs > 0 else { return false }
            guard abs(candidate.durationMs - request.durationMs) <= durationToleranceMs else { return false }
            guard candidate.score >= autoWriteConfidenceThreshold else { return false }
            // 标题 **严格相等** → live / remix /  remaster 等不同版本自然被排除。
            guard normalize(candidate.title) == normalize(request.title) else { return false }
            guard artistsMatch(candidate.artist, request.artist) else { return false }
            return true
        }
    }

    /// 没有严格匹配时的拒绝理由（区分「置信度不足」和「不同版本」）。
    ///
    /// **可信来源已经补上的部分仍然算数**：状态是 `completedWithWarning`，
    /// 说明与 `values`（实际会填入的字段）必须一致。
    static func rejection(
        candidates: [MetadataCandidate],
        request: Request,
        values: [MetadataField: String],
        usedTrusted: Bool
    ) -> MetadataCompletionProposal {
        let sameName = candidates.filter { candidate in
            normalize(candidate.title) == normalize(request.title)
                && artistsMatch(candidate.artist, request.artist)
        }
        // 同名但时长对不上 → 多半是不同版本（live / remix）。
        let sameVersion = sameName.filter { candidate in
            candidate.durationMs > 0
                && abs(candidate.durationMs - request.durationMs) <= durationToleranceMs
        }
        guard !sameVersion.isEmpty else {
            return rejection(
                status: .noMatch(sameName.isEmpty
                    ? "没有找到标题与艺人都完全一致的候选。"
                    : "候选时长与文件不一致（可能是 live / remix 等不同版本）。"),
                userReason: "没有找到确定的结果，未自动补充。",
                values: values,
                usedTrusted: usedTrusted
            )
        }
        // 时长对得上，但置信度不到自动写入的门槛。
        let best = sameVersion.map(\.score).max() ?? 0
        return rejection(
            status: .lowConfidence(
                "候选置信度不足（最高 \(Int((best * 100).rounded()))%，自动写入要求 ≥ \(Int(autoWriteConfidenceThreshold * 100))%）。"
            ),
            userReason: "匹配结果不够确定，未自动补充。",
            values: values,
            usedTrusted: usedTrusted
        )
    }

    /// 统一的拒绝出口（**状态与实际填入的字段必须一致**）。
    static func rejection(
        status: MetadataCompletionProposal.Status,
        userReason: String,
        values: [MetadataField: String],
        usedTrusted: Bool
    ) -> MetadataCompletionProposal {
        let reason: String
        switch status {
        case .noMatch(let message), .lowConfidence(let message), .ambiguous(let message):
            reason = message
        default:
            reason = ""
        }
        let source: MetadataCompletionProposal.Source = usedTrusted ? .trustedSource : .none
        // 可信来源补上的部分 **安全**，照样算数；只是外部匹配那部分被拒绝了。
        if values.isEmpty {
            return MetadataCompletionProposal(
                status: status,
                source: source,
                values: [:],
                note: userReason,
                detail: reason
            )
        }
        return MetadataCompletionProposal(
            status: .completedWithWarning(reason),
            source: source,
            values: values,
            note: filledNote(values.count),
            detail: "已按可信来源补齐 \(values.count) 个空字段；外部匹配未采纳（\(reason)）"
        )
    }

    /// 面向用户的简短说明（**不解释算法**）。
    static func filledNote(_ count: Int) -> String {
        guard count > 0 else { return "没有可补充的空白信息。" }
        return "已补充 \(count) 项空白信息，保存前可预览。"
    }

    // MARK: - 内部：文本工具

    /// 归一化（与 Rust 侧 `normalize` 同一套：只保留字母数字 + 小写）。
    static func normalize(_ text: String) -> String {
        var result = ""
        for character in text.lowercased() {
            guard character.isLetter || character.isNumber else { continue }
            result.append(character)
        }
        return result
    }

    /// 艺人是否一致（**分人比较**：多人合作要逐个对上）。
    ///
    /// `A / B` 与 `A & B` 视为同一组；`A` 与 `A & B` **不同**（保守拒绝）。
    static func artistsMatch(_ candidate: String, _ query: String) -> Bool {
        let candidateParts = artistParts(candidate)
        let queryParts = artistParts(query)
        guard !candidateParts.isEmpty, !queryParts.isEmpty else { return false }
        return candidateParts == queryParts
    }

    /// 艺人拆分成「人」的集合（分隔符：`/`、`&`、`,`、`、`、`feat.`、`ft.` …）。
    static func artistParts(_ text: String) -> Set<String> {
        var working = text
        for separator in ["/", "&", ",", "、", "feat.", "ft.", "featuring"] {
            working = working.replacingOccurrences(of: separator, with: "|")
        }
        var parts: Set<String> = []
        for piece in working.components(separatedBy: "|") {
            let normalized = normalize(piece)
            if !normalized.isEmpty { parts.insert(normalized) }
        }
        return parts
    }

    /// 占位 / 路径样式的值（**绝不写进标签**）。
    static func isPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // 绝对路径 / file:// —— 旧索引里标题曾经是路径。
        if TrackRecord.looksLikePath(trimmed) { return true }
        let normalized = trimmed.lowercased()
        if normalized == TrackRecord.unrecognizedPlaceholder.lowercased() { return true }
        let placeholders = [
            "未知歌曲", "未知专辑", "未知艺人", "未知",
            "unknown", "unknown song", "unknown album", "unknown artist",
            "null", "none",
        ]
        return placeholders.contains(normalized)
    }

    /// 从 `YYYY-MM-DD` 取年份。
    static func year(from date: String) -> Int? {
        let trimmed = date.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        return Int(trimmed.prefix(4))
    }

    /// 第一个可用（非空、非占位）的值。
    static func firstUsable(_ candidates: String?...) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isPlaceholder(trimmed) else { continue }
            return trimmed
        }
        return nil
    }
}
