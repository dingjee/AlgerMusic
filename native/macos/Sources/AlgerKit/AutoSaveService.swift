import Foundation

/// 一条自动保存记录（按网易云曲目 ID 去重）。
///
/// 自动保存 = 「完整在线播放达阈值后自动落盘」。
/// 记录用于：**不重复下载**、**失败可重试**、**跨会话可见**。
public struct AutoSaveRecord: Codable, Equatable, Identifiable {

    /// 记录状态。
    public enum State: String, Codable, Equatable {
        /// 已发起下载，等待落盘。
        case pending
        /// 已落盘（本地已有文件）。
        case saved
        /// 下载失败，可重试。
        case failed
    }

    /// 稳定 ID（`"netease:<id>"`）。
    public var id: String
    /// 网易云曲目 ID。
    public var neteaseId: Int64
    /// 标题。
    public var title: String
    /// 艺人（显示用，拼接后的文本）。
    public var artist: String
    /// 艺人名列表（重建曲目用）。
    public var artistNames: [String]
    /// 专辑名（重建曲目用）。
    public var albumName: String
    /// 时长（毫秒）。
    public var durationMs: Int64
    /// 状态。
    public var state: State
    /// 尝试次数。
    public var attempts: Int
    /// 最近一次失败原因。
    public var lastError: String?
    /// 首次登记时间（Unix 秒）。
    public var createdAt: Double
    /// 最近更新时间（Unix 秒）。
    public var updatedAt: Double

    public init(
        id: String? = nil,
        neteaseId: Int64,
        title: String,
        artist: String,
        artistNames: [String] = [],
        albumName: String = "",
        durationMs: Int64,
        state: State = .pending,
        attempts: Int = 0,
        lastError: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970,
        updatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id ?? NativeState.playCountKey(neteaseId: neteaseId)
        self.neteaseId = neteaseId
        self.title = title
        self.artist = artist
        self.artistNames = artistNames
        self.albumName = albumName
        self.durationMs = durationMs
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 由记录 **重建曲目**（重试时不需要用户再听一遍）。
    public func makeSong() -> RemoteSong {
        RemoteSong(
            id: neteaseId,
            name: title,
            artists: artistNames.map { RemoteArtist(id: 0, name: $0) },
            album: RemoteAlbum(id: 0, name: albumName, picUrl: ""),
            durationMs: durationMs
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case neteaseId
        case title
        case artist
        case artistNames
        case albumName
        case durationMs
        case state
        case attempts
        case lastError
        case createdAt
        case updatedAt
    }

    /// 宽容解码。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let neteaseId = try container.decodeIfPresent(Int64.self, forKey: .neteaseId) ?? 0
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? NativeState.playCountKey(neteaseId: neteaseId)
        self.neteaseId = neteaseId
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        artistNames = try container.decodeIfPresent([String].self, forKey: .artistNames) ?? []
        albumName = try container.decodeIfPresent(String.self, forKey: .albumName) ?? ""
        durationMs = try container.decodeIfPresent(Int64.self, forKey: .durationMs) ?? 0
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .pending
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt) ?? createdAt
    }
}

/// 自动保存服务：**阈值判断 + 去重 + 失败可重试**。
///
/// 规则（产品规格）：
/// - 默认开启、阈值 **3 次**；设置里可调 / 可关；
/// - 只统计 **完整在线播放**（跳过、拖进度到结尾、本地播放都不算）；
/// - 次数 **跨会话累计**；
/// - **调低阈值不会立刻批量下载历史歌曲** —— 只在后续完整播放时判断；
/// - 已在本地（按来源 ID 关联）的曲目不再下载；
/// - 下载失败进入 **待处理**，可重试。
public final class AutoSaveService {

    /// 一次评估的结果。
    public enum Decision: Equatable {
        /// 不需要自动保存。
        case none(reason: String)
        /// 需要发起下载。
        case enqueue
        /// **本地已有文件** → 交给「下载前审核」判断要不要升级质量。
        ///
        /// 以前这里直接 `return .none("已有本地文件")`，会 **绕开质量升级**：
        /// 本地是低码率版本时永远不会换成更好的版本。
        case reviewExistingLocal(reason: String)
    }

    private let store: NativeStore
    private let library: LocalLibrary

    public init(store: NativeStore, library: LocalLibrary) {
        self.store = store
        self.library = library
    }

    // MARK: - 查询

    /// 全部记录。
    public var records: [AutoSaveRecord] { store.current.autoSaveRecords }

    /// 待处理（失败待重试）的记录。
    public var pending: [AutoSaveRecord] { records.filter { $0.state == .failed } }

    /// 某首曲目的记录。
    public func record(neteaseId: Int64) -> AutoSaveRecord? {
        records.first { $0.neteaseId == neteaseId }
    }

    /// 已保存（已落盘）的曲目 ID 集合。
    public var savedNeteaseIds: Set<Int64> {
        Set(records.filter { $0.state == .saved }.map(\.neteaseId))
    }

    // MARK: - 评估

    /// 评估「这次完整播放」是否该触发自动保存。
    ///
    /// - Parameters:
    ///   - neteaseId: 曲目 ID。
    ///   - title / artist / durationMs: 曲目信息（登记用）。
    /// - Returns: 决策。
    public func evaluate(
        neteaseId: Int64,
        title: String,
        artist: String,
        durationMs: Int64
    ) -> Decision {
        let settings = store.current.settings
        guard settings.autoSaveEnabled else {
            return .none(reason: "自动保存已关闭")
        }
        let threshold = max(1, settings.autoSaveThreshold)
        let count = store.current.playCounts[NativeState.playCountKey(neteaseId: neteaseId)] ?? 0
        guard count >= threshold else {
            return .none(reason: "播放次数 \(count)/\(threshold)")
        }
        // 已在本地（**按来源 ID 关联**）→ 交给下载审核判断质量，**不直接跳过**
        // （直接跳过会让低码率的本地版本永远得不到升级）。
        if library.matchLocalTrack(neteaseId: neteaseId) != nil {
            if let existing = record(neteaseId: neteaseId) {
                switch existing.state {
                case .saved:
                    return .none(reason: "已经保存过")
                case .pending:
                    return .none(reason: "已经在下载队列中")
                case .failed:
                    return .reviewExistingLocal(reason: "本地已有文件，重新审核质量")
                }
            }
            return .reviewExistingLocal(reason: "本地已有文件，审核是否需要升级质量")
        }
        if let existing = record(neteaseId: neteaseId) {
            switch existing.state {
            case .saved:
                return .none(reason: "已经保存过")
            case .pending:
                return .none(reason: "已经在下载队列中")
            case .failed:
                return .enqueue
            }
        }
        return .enqueue
    }

    // MARK: - 状态更新

    /// 登记「已发起下载」（**必须在真正入队之前落盘**，否则去重登记会丢）。
    ///
    /// - Throws: 持久化失败（调用方 **不得** 继续入队，也不能当成成功）。
    public func markEnqueued(
        neteaseId: Int64,
        title: String,
        artist: String,
        durationMs: Int64,
        artistNames: [String] = [],
        albumName: String = ""
    ) throws {
        let now = Date().timeIntervalSince1970
        try store.mutate { state in
            if let index = state.autoSaveRecords.firstIndex(where: { $0.neteaseId == neteaseId }) {
                state.autoSaveRecords[index].state = .pending
                state.autoSaveRecords[index].attempts += 1
                state.autoSaveRecords[index].lastError = nil
                state.autoSaveRecords[index].updatedAt = now
                state.autoSaveRecords[index].title = title
                state.autoSaveRecords[index].artist = artist
                if !artistNames.isEmpty { state.autoSaveRecords[index].artistNames = artistNames }
                if !albumName.isEmpty { state.autoSaveRecords[index].albumName = albumName }
            } else {
                state.autoSaveRecords.append(AutoSaveRecord(
                    neteaseId: neteaseId,
                    title: title,
                    artist: artist,
                    artistNames: artistNames,
                    albumName: albumName,
                    durationMs: durationMs,
                    state: .pending,
                    attempts: 1,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }
    }

    /// 登记「已落盘」。
    ///
    /// - Throws: 持久化失败（调用方必须显示错误，**不能假装已保存**）。
    public func markSaved(neteaseId: Int64) throws {
        let now = Date().timeIntervalSince1970
        try store.mutate { state in
            guard let index = state.autoSaveRecords.firstIndex(where: { $0.neteaseId == neteaseId }) else { return }
            state.autoSaveRecords[index].state = .saved
            state.autoSaveRecords[index].lastError = nil
            state.autoSaveRecords[index].updatedAt = now
        }
    }

    /// 登记「下载失败」（待处理，可重试）。
    ///
    /// - Throws: 持久化失败（调用方必须显示错误）。
    public func markFailed(neteaseId: Int64, error: String) throws {
        let now = Date().timeIntervalSince1970
        try store.mutate { state in
            if let index = state.autoSaveRecords.firstIndex(where: { $0.neteaseId == neteaseId }) {
                state.autoSaveRecords[index].state = .failed
                state.autoSaveRecords[index].lastError = error
                state.autoSaveRecords[index].updatedAt = now
                state.autoSaveRecords[index].attempts += 1
            } else {
                state.autoSaveRecords.append(AutoSaveRecord(
                    neteaseId: neteaseId,
                    title: "",
                    artist: "",
                    durationMs: 0,
                    state: .failed,
                    attempts: 1,
                    lastError: error,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }
    }

    /// 清掉一条记录（用户手动重试时用）。
    public func clear(neteaseId: Int64) throws {
        try store.mutate { state in
            state.autoSaveRecords.removeAll { $0.neteaseId == neteaseId }
        }
    }

    // MARK: - 与真实下载队列对账

    /// 对账结果。
    public struct ReconcileReport: Equatable {
        /// 仍在下载队列里（保持待处理）。
        public var stillDownloading: [Int64] = []
        /// 队列里已无对应任务（转为 **可重试的失败**，不会永远 pending）。
        public var becameRetryable: [Int64] = []
        /// 已落盘（转为已保存）。
        public var becameSaved: [Int64] = []
    }

    /// 与 **真实下载队列** 对账（启动时调用）。
    ///
    /// 规则：
    /// - 记录是「已发起下载」但队列里 **没有** 对应任务 → 转为失败（可重试），
    ///   不会永远停在 pending；
    /// - 任务已完成且文件存在 → 转为已保存；
    /// - 任务仍在进行 → 保持 pending。
    ///
    /// - Throws: 持久化失败。
    @discardableResult
    public func reconcile(with tasks: [DownloadTask]) throws -> ReconcileReport {
        var report = ReconcileReport()
        for record in records where record.state == .pending {
            guard let task = tasks.first(where: { $0.id == record.neteaseId }) else {
                try markFailed(neteaseId: record.neteaseId, error: "下载任务已不在队列中，可以重新下载")
                report.becameRetryable.append(record.neteaseId)
                continue
            }
            if task.isActive {
                report.stillDownloading.append(record.neteaseId)
                continue
            }
            if task.isDone {
                if !task.path.isEmpty, FileManager.default.fileExists(atPath: task.path) {
                    try markSaved(neteaseId: record.neteaseId)
                    report.becameSaved.append(record.neteaseId)
                } else {
                    try markFailed(neteaseId: record.neteaseId, error: "下载任务已完成但文件不存在")
                    report.becameRetryable.append(record.neteaseId)
                }
                continue
            }
            // 失败任务：保持可重试。
            try markFailed(neteaseId: record.neteaseId, error: task.error ?? "下载失败")
            report.becameRetryable.append(record.neteaseId)
        }
        return report
    }
}
