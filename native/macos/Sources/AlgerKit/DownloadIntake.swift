import Foundation

/// 一条「下载落盘 → 加入本地歌单」的 **待确认记录**。
///
/// 为什么要有它：
/// - 一次下载可以指向 **多个** 本地歌单（Rust 侧会合并同曲目的 targets）；
/// - 入单可能 **部分失败**（一个歌单写失败、另一个成功）；
/// - 入单失败必须 **持久可见**，下次启动能补偿，不能只靠内存里的提示。
///
/// 记录按 **下载任务 / 目标歌单 / 实际路径** 跟踪确认（`trackingKey`）；
/// 每条记录有自己的 `id`（一次意图一条），因此
/// 「已确认之后用户又显式重新添加同一目标」可以表达为 **新意图**，
/// 而「已确认的旧意图」不会被重放复活。
public struct DownloadIntake: Codable, Equatable, Identifiable {

    /// 记录 ID（一次意图一个）。
    public var id: String
    /// 下载任务 ID（网易云曲目 ID）。
    public var taskId: Int64
    /// 目标本地歌单 ID（`NativeStore` 里的稳定 ID）。
    public var playlistId: String
    /// 音频 **实际路径**（尚未落盘时为空串）。
    public var path: String
    /// 显示名。
    public var displayName: String
    /// 时长（毫秒）。
    public var durationMs: Int64
    /// 首次登记时间（Unix 秒）。
    public var createdAt: Double
    /// 最近一次尝试时间（Unix 秒）。
    public var updatedAt: Double
    /// 尝试次数。
    public var attempts: Int
    /// 最近一次失败原因（nil = 没有失败记录）。
    public var lastError: String?
    /// 确认时间（nil = **尚未确认**，即待处理）。
    public var confirmedAt: Double?
    /// 是否被更新的意图取代（取代后不再自动重放，但 **证据保留**）。
    public var superseded: Bool
    /// **撤回** 时间（nil = 没有被撤回）。
    ///
    /// 撤回 = 用户把「下载落到某个歌单」这个目标取消了（改目标 / 取消添加）。
    /// 撤回与「被新意图取代」是两回事：
    /// - 被取代：用户又添加了一次，旧的意图作废；
    /// - 撤回：用户 **不要** 这个目标了 → 之后 **不能** 因为
    ///   Rust 侧过期的 `task.targets` 又把它加回去，
    ///   除非用户 **显式** 重新添加（`registerIntent` → 新意图）。
    public var withdrawnAt: Double?

    public init(
        id: String = "intent-" + UUID().uuidString.lowercased(),
        taskId: Int64,
        playlistId: String,
        path: String = "",
        displayName: String,
        durationMs: Int64,
        createdAt: Double = Date().timeIntervalSince1970,
        updatedAt: Double = Date().timeIntervalSince1970,
        attempts: Int = 0,
        lastError: String? = nil,
        confirmedAt: Double? = nil,
        superseded: Bool = false,
        withdrawnAt: Double? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.playlistId = playlistId
        self.path = path
        self.displayName = displayName
        self.durationMs = durationMs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attempts = attempts
        self.lastError = lastError
        self.confirmedAt = confirmedAt
        self.superseded = superseded
        self.withdrawnAt = withdrawnAt
    }

    /// 跟踪键：**下载任务 / 目标歌单 / 实际路径**。
    public var trackingKey: String { DownloadIntake.trackingKey(taskId: taskId, playlistId: playlistId, path: path) }

    /// 跟踪键。
    public static func trackingKey(taskId: Int64, playlistId: String, path: String) -> String {
        "\(taskId)|\(playlistId)|\(path)"
    }

    /// 是否已经确认入单。
    public var isConfirmed: Bool { confirmedAt != nil }

    /// 是否处于待处理状态（有记录、没确认、没被取代）。
    public var isPending: Bool { confirmedAt == nil && !superseded }

    /// 是否被 **撤回**（用户取消了这个目标）。
    public var isWithdrawn: Bool { withdrawnAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id
        case taskId
        case playlistId
        case path
        case displayName
        case durationMs
        case createdAt
        case updatedAt
        case attempts
        case lastError
        case confirmedAt
        case superseded
        case withdrawnAt
    }

    /// 宽容解码（旧文件缺字段时用默认值，不整体报废）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? "intent-" + UUID().uuidString.lowercased()
        taskId = try container.decodeIfPresent(Int64.self, forKey: .taskId) ?? 0
        playlistId = try container.decodeIfPresent(String.self, forKey: .playlistId) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        durationMs = try container.decodeIfPresent(Int64.self, forKey: .durationMs) ?? 0
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt) ?? createdAt
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        confirmedAt = try container.decodeIfPresent(Double.self, forKey: .confirmedAt)
        superseded = try container.decodeIfPresent(Bool.self, forKey: .superseded) ?? false
        withdrawnAt = try container.decodeIfPresent(Double.self, forKey: .withdrawnAt)
    }
}

/// 下载入单服务：**持久化 + 可恢复 + 不重复加入 + 不复活已确认的旧意图**。
///
/// 约定：
/// - 每条记录按 **下载任务 / 目标歌单 / 实际路径** 跟踪确认；
/// - **索引写入失败不算成功**：索引失败时目标保持待处理，不确认；
/// - 目标歌单入单失败 → 该目标保持待处理并记录原因，**其它目标的成功不会被它覆盖**；
/// - 已确认的记录 **不会** 在重放时被重新加入（用户后来手动移除的条目不会被复活）；
/// - 用户 **显式** 重新添加同一目标 → 登记为 **新意图**，允许再次入单；
/// - **撤回**（`withdrawPending`）：用户取消某个目标 → 持久 `superseded`，
///   之后既不会被重放，也 **不会** 因为 Rust 侧过期的 `task.targets` 被重建；
///   重新添加必须走显式 `registerIntent`；
/// - 服务只依赖 `NativeStore` + `LocalLibrary`，**可在隔离目录里用真实文件验证**。
public final class DownloadIntakeService {

    /// 一次入单尝试的结果。
    public struct Outcome {
        /// 已确认（成功入单）的记录。
        public var confirmed: [DownloadIntake] = []
        /// 仍待处理的记录（含失败原因）。
        public var pending: [DownloadIntake] = []
        /// 索引写入错误（nil = 索引正常）。
        public var indexError: String?
        /// **本次真正新增** 的路径（按歌单 ID 分组）——用于「更改目标时只撤回本次新增」。
        public var newlyAdded: [String: [String]] = [:]
        /// **跳过** 的记录（没有加入任何歌单）：
        /// - 已确认过 → 不复活旧意图；
        /// - 已被 **撤回** → 用户撤掉了这个目标，Rust 侧的旧 targets 不得把它加回来。
        public var skipped: [DownloadIntake] = []

        /// 是否全部成功。
        public var isFullySuccessful: Bool { pending.isEmpty && indexError == nil }
        /// 是否有失败（部分失败也算失败）。
        public var hasFailure: Bool { !isFullySuccessful }
    }

    private let store: NativeStore
    private let library: LocalLibrary

    public init(store: NativeStore, library: LocalLibrary) {
        self.store = store
        self.library = library
    }

    // MARK: - 查询

    /// 全部入单记录。
    public var records: [DownloadIntake] { store.current.downloadIntakes }

    /// 待处理（未确认、未被取代）的记录。
    public var pending: [DownloadIntake] { records.filter { $0.isPending } }

    /// 待处理数量。
    public var pendingCount: Int { pending.count }

    // MARK: - 登记意图

    /// 登记一次 **显式** 的入单意图（**下载之前**）。
    ///
    /// 同一 (任务, 歌单) 上更早的未确认意图会被标记为「已取代」：
    /// 证据保留，但不再自动重放（避免把用户后来手动移除的条目复活）。
    ///
    /// - Throws: 持久化失败（调用方 **不得** 继续入队）。
    public func registerIntent(
        taskId: Int64,
        targets: [String],
        displayName: String,
        durationMs: Int64
    ) throws {
        guard !targets.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try store.mutate { state in
            for playlistId in targets {
                for index in state.downloadIntakes.indices
                where state.downloadIntakes[index].taskId == taskId
                    && state.downloadIntakes[index].playlistId == playlistId
                    && state.downloadIntakes[index].isPending {
                    state.downloadIntakes[index].superseded = true
                    state.downloadIntakes[index].updatedAt = now
                    state.downloadIntakes[index].lastError = "已被新的添加请求取代"
                }
                state.downloadIntakes.append(DownloadIntake(
                    taskId: taskId,
                    playlistId: playlistId,
                    path: "",
                    displayName: displayName,
                    durationMs: durationMs,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }
    }

    /// 把 **实际路径** 绑定到尚未落盘的意图（下载完成时调用）。
    ///
    /// - Returns: 绑定的记录数。
    @discardableResult
    public func bindPaths(tasks: [DownloadTask]) throws -> Int {
        let usable = tasks.filter { !$0.path.isEmpty }
        guard !usable.isEmpty else { return 0 }
        let now = Date().timeIntervalSince1970
        var bound = 0
        try store.mutate { state in
            for task in usable {
                for index in state.downloadIntakes.indices
                where state.downloadIntakes[index].taskId == task.id
                    && state.downloadIntakes[index].path.isEmpty
                    && !state.downloadIntakes[index].superseded {
                    state.downloadIntakes[index].path = task.path
                    state.downloadIntakes[index].updatedAt = now
                    bound += 1
                }
            }
        }
        return bound
    }

    // MARK: - 撤回

    /// 撤回某个下载任务对某个目标歌单的 **待处理意图**（用户改目标 / 取消添加）。
    ///
    /// - 撤回是 **持久** 的：意图标记 `superseded = true` + `withdrawnAt`，
    ///   之后
    ///   - 不会被 `retryPending` 重放；
    ///   - **不会** 因为 Rust 侧过期的 `task.targets` 被重新建成意图
    ///     （`performIntake` 会跳过已撤回的目标）。
    /// - 用户 **显式** 重新添加（`registerIntent`）→ 产生 **新意图** → 可以再次入单。
    /// - 已经 **确认** 的记录不受影响（那一步已经入单完成，撤回没有意义）。
    ///
    /// - Returns: 被撤回的意图 ID（没有待处理意图时为空数组）。
    @discardableResult
    public func withdrawPending(taskId: Int64, playlistId: String) throws -> [String] {
        let now = Date().timeIntervalSince1970
        var withdrawn: [String] = []
        try store.mutate { state in
            var hasPending = false
            for index in state.downloadIntakes.indices
            where state.downloadIntakes[index].taskId == taskId
                && state.downloadIntakes[index].playlistId == playlistId
                && state.downloadIntakes[index].isPending {
                hasPending = true
                state.downloadIntakes[index].superseded = true
                state.downloadIntakes[index].withdrawnAt = now
                state.downloadIntakes[index].updatedAt = now
                state.downloadIntakes[index].lastError = "已撤回添加目标"
                withdrawn.append(state.downloadIntakes[index].id)
            }
            if hasPending { return }
            // **没有待处理意图**（例如旧版本直接入队、没登记过意图）：
            // 仍然要留下 **撤回痕迹**，否则 Rust 侧过期的 targets 会让
            // `performIntake` 重新建意图，把用户撤掉的目标又加回去。
            // 只有当 **最新** 记录本身就是撤回状态时才不重复留痕
            // （否则「重加 → 完成 → 再撤回」会漏掉这次的撤回）。
            let latest = state.downloadIntakes.last { $0.taskId == taskId && $0.playlistId == playlistId }
            if latest?.isWithdrawn == true { return }
            let marker = DownloadIntake(
                taskId: taskId,
                playlistId: playlistId,
                path: "",
                displayName: "",
                durationMs: 0,
                createdAt: now,
                updatedAt: now,
                lastError: "已撤回添加目标",
                superseded: true,
                withdrawnAt: now
            )
            state.downloadIntakes.append(marker)
        }
        return withdrawn
    }

    /// 某目标是否已经被 **撤回**（且之后没有显式重新登记）。
    ///
    /// 判断依据：该目标的 **最新** 记录是否带撤回标记。
    /// `registerIntent` 会追加 **新** 记录（没有撤回标记）→ 不算撤回。
    public func isWithdrawn(taskId: Int64, playlistId: String) -> Bool {
        latestRecord(taskId: taskId, playlistId: playlistId)?.isWithdrawn ?? false
    }

    /// 某目标的 **最新** 记录。
    ///
    /// 按 **持久数组的追加顺序** 取最后一条（不看时间戳）：
    /// 时钟回拨、同一秒内多次写入都会让时间排序选错记录，
    /// 而追加顺序就是「后写入的在前」的确定顺序。
    public func latestRecord(taskId: Int64, playlistId: String) -> DownloadIntake? {
        records.last { $0.taskId == taskId && $0.playlistId == playlistId }
    }

    // MARK: - 入单

    /// 对一次 **已落盘** 的下载执行入单（索引 + 目标歌单）。
    ///
    /// - Parameters:
    ///   - taskId: 下载任务 ID。
    ///   - targets: 目标本地歌单 ID。
    ///   - path: 音频实际路径。
    ///   - title / artist / album: 写进索引的元信息。
    ///   - durationMs: 时长。
    ///   - neteaseId: 来源 ID（写进索引；默认等于 `taskId`）。
    /// - Returns: 逐目标结果（成功 / 待处理 / 跳过 / 索引错误）。
    ///
    /// **已撤回** 的目标会被 **跳过**（不重建意图、不入单）：
    /// Rust 侧事件里的 `targets` 可能是 **撤回之前** 的旧值，
    /// 不能因为它就把用户撤掉的目标又加回去。
    @discardableResult
    public func performIntake(
        taskId: Int64,
        targets: [String],
        path: String,
        title: String,
        artist: String,
        album: String,
        durationMs: Int64,
        neteaseId: Int64? = nil
    ) throws -> Outcome {
        var outcome = Outcome()

        // 0) 确保每个目标都有 **未确认** 的记录（没有就补一条）。
        //    这样索引写失败时目标 **仍然有持久待处理记录**（可定位、可重试）。
        for playlistId in targets {
            if newestPendingRecord(taskId: taskId, playlistId: playlistId) != nil { continue }
            if confirmedRecord(taskId: taskId, playlistId: playlistId, path: path) != nil { continue }
            // **已撤回** 的目标：不得按 Rust 侧的旧 targets 重建意图
            // （用户撤掉了这个目标，旧事件不得把它加回来）。
            // 要重新添加必须显式 `registerIntent`（新意图）。
            if isWithdrawn(taskId: taskId, playlistId: playlistId) { continue }
            _ = try createRecord(
                taskId: taskId,
                playlistId: playlistId,
                path: path,
                displayName: "\(title) - \(artist)",
                durationMs: durationMs
            )
        }

        // 1) 索引：**失败不算成功**（目标保持待处理，错误可见）。
        let indexError = writeIndex(
            path: path,
            neteaseId: neteaseId ?? taskId,
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs
        )
        if let indexError {
            outcome.indexError = indexError
            let affected = records.filter {
                $0.taskId == taskId && targets.contains($0.playlistId) && $0.isPending
            }
            let writeError = markFailedReporting(
                affected.map(\.id),
                error: "写入本地索引失败：\(indexError)"
            )
            outcome.pending = affected.map { failedSnapshot($0, error: "写入本地索引失败：\(indexError)", writeError: writeError) }
            return outcome
        }

        // 2) 逐目标入单（**部分失败不影响其它目标**）。
        for playlistId in targets {
            let candidate = newestPendingRecord(taskId: taskId, playlistId: playlistId)
            if let candidate {
                let record = bindPath(candidate, path: path)
                outcome = merge(outcome, act(on: record))
            } else if let confirmed = confirmedRecord(taskId: taskId, playlistId: playlistId, path: path) {
                // **已确认过**：不复活（用户后来手动移除的条目不会被加回来）。
                outcome.skipped.append(confirmed)
            } else if let withdrawn = latestRecord(taskId: taskId, playlistId: playlistId), withdrawn.isWithdrawn {
                // **已撤回**：不重建意图、不入单（用户撤掉了这个目标）。
                outcome.skipped.append(withdrawn)
            } else {
                // 意图丢失（例如旧版本入队）：补一条记录再入单。
                let record = try createRecord(
                    taskId: taskId,
                    playlistId: playlistId,
                    path: path,
                    displayName: "\(title) - \(artist)",
                    durationMs: durationMs
                )
                outcome = merge(outcome, act(on: record))
            }
        }
        return outcome
    }

    /// 重试所有待处理记录（**启动重放** / 手动补偿）。
    @discardableResult
    public func retryPending() -> Outcome {
        var outcome = Outcome()
        for record in pending {
            outcome = merge(outcome, act(on: record))
        }
        return outcome
    }

    /// 重试某个下载任务的所有待处理记录（**done 重试补偿**）。
    @discardableResult
    public func retryPending(taskId: Int64) -> Outcome {
        var outcome = Outcome()
        for record in pending where record.taskId == taskId {
            outcome = merge(outcome, act(on: record))
        }
        return outcome
    }

    /// 撤回「本次新增」的条目（**只撤回本次新增**）。
    ///
    /// 之前就在歌单里的条目 **不会** 被删掉。
    @discardableResult
    public func undoNewlyAdded(_ newlyAdded: [String: [String]]) -> [String: [String]] {
        var removed: [String: [String]] = [:]
        for (playlistId, paths) in newlyAdded where !paths.isEmpty {
            do {
                try library.removeFromPlaylist(id: playlistId, paths: paths)
                removed[playlistId] = paths
            } catch {
                // 撤回失败：保留记录，交由界面提示（不假装撤回成功）。
                continue
            }
        }
        return removed
    }

    // MARK: - 内部

    private func merge(_ outcome: Outcome, _ other: Outcome) -> Outcome {
        var result = outcome
        result.confirmed.append(contentsOf: other.confirmed)
        result.pending.append(contentsOf: other.pending)
        result.skipped.append(contentsOf: other.skipped)
        for (key, paths) in other.newlyAdded {
            result.newlyAdded[key, default: []].append(contentsOf: paths)
        }
        if result.indexError == nil {
            result.indexError = other.indexError
        }
        return result
    }

    /// 对一条记录执行入单。
    private func act(on record: DownloadIntake) -> Outcome {
        var outcome = Outcome()
        guard FileManager.default.fileExists(atPath: record.path) else {
            let reason = "文件不存在：\(record.path)"
            outcome.pending.append(failedSnapshot(record, error: reason, writeError: markFailedReporting([record.id], error: reason)))
            return outcome
        }
        let entry = PlaylistEntry(
            path: record.path,
            duration: Double(record.durationMs) / 1000,
            displayName: record.displayName
        )
        do {
            let appended = try library.addToPlaylist(id: record.playlistId, entries: [entry])
            do {
                try markConfirmed([record.id])
                outcome.confirmed.append(record)
            } catch {
                // 入单本身成功，但 **确认状态写不进去** → 保持待处理。
                // 重试不会重复加入（本地歌单按路径去重），但状态必须可见。
                outcome.pending.append(failedSnapshot(
                    record,
                    error: "写入入单确认状态失败：\(Self.describe(error))",
                    writeError: nil
                ))
            }
            if !appended.isEmpty {
                outcome.newlyAdded[record.playlistId, default: []].append(contentsOf: appended.map(\.path))
            }
        } catch {
            let reason = Self.describe(error)
            outcome.pending.append(failedSnapshot(
                record,
                error: reason,
                writeError: markFailedReporting([record.id], error: reason)
            ))
        }
        return outcome
    }

    private func newestPendingRecord(taskId: Int64, playlistId: String) -> DownloadIntake? {
        // 按 **持久数组的追加顺序** 取最后一条待处理记录
        // （时钟回拨 / 同秒多次写入时时间排序会选错记录）。
        records.last { $0.taskId == taskId && $0.playlistId == playlistId && $0.isPending }
    }

    private func confirmedRecord(taskId: Int64, playlistId: String, path: String) -> DownloadIntake? {
        records.first {
            $0.taskId == taskId && $0.playlistId == playlistId && $0.path == path && $0.isConfirmed
        }
    }

    private func bindPath(_ record: DownloadIntake, path: String) -> DownloadIntake {
        guard record.path != path else { return record }
        let now = Date().timeIntervalSince1970
        try? store.mutate { state in
            guard let index = state.downloadIntakes.firstIndex(where: { $0.id == record.id }) else { return }
            state.downloadIntakes[index].path = path
            state.downloadIntakes[index].updatedAt = now
        }
        var updated = record
        updated.path = path
        return updated
    }

    private func createRecord(
        taskId: Int64,
        playlistId: String,
        path: String,
        displayName: String,
        durationMs: Int64
    ) throws -> DownloadIntake {
        let now = Date().timeIntervalSince1970
        let record = DownloadIntake(
            taskId: taskId,
            playlistId: playlistId,
            path: path,
            displayName: displayName,
            durationMs: durationMs,
            createdAt: now,
            updatedAt: now
        )
        try store.mutate { state in
            state.downloadIntakes.append(record)
        }
        return record
    }

    private func writeIndex(
        path: String,
        neteaseId: Int64,
        title: String,
        artist: String,
        album: String,
        durationMs: Int64
    ) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let format = URL(fileURLWithPath: path).pathExtension.lowercased()
        do {
            try library.index.upsert(TrackRecord(
                path: path,
                neteaseId: neteaseId,
                title: title,
                artist: artist,
                album: album,
                durationMs: UInt64(max(0, durationMs)),
                format: format,
                size: size,
                modifiedAt: modified
            ))
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    private func markConfirmed(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try store.mutate { state in
            for index in state.downloadIntakes.indices where ids.contains(state.downloadIntakes[index].id) {
                state.downloadIntakes[index].confirmedAt = now
                state.downloadIntakes[index].lastError = nil
                state.downloadIntakes[index].updatedAt = now
                state.downloadIntakes[index].attempts += 1
            }
        }
    }

    private func markFailed(_ ids: [String], error: String) throws {
        guard !ids.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try store.mutate { state in
            for index in state.downloadIntakes.indices where ids.contains(state.downloadIntakes[index].id) {
                state.downloadIntakes[index].lastError = error
                state.downloadIntakes[index].updatedAt = now
                state.downloadIntakes[index].attempts += 1
            }
        }
    }

    /// 记录失败原因（**返回写盘错误**，不吞）。
    private func markFailedReporting(_ ids: [String], error: String) -> String? {
        do {
            try markFailed(ids, error: error)
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    /// 带失败原因的记录快照（用于结果展示，不写盘）。
    private func failedSnapshot(_ record: DownloadIntake, error: String, writeError: String?) -> DownloadIntake {
        var copy = record
        copy.lastError = writeError.map { "\(error)（失败原因未能写回：\($0)）" } ?? error
        return copy
    }

    static func describe(_ error: Error) -> String {
        if let libraryError = error as? LocalLibraryError { return libraryError.description }
        if let storeError = error as? NativeStore.StoreError { return storeError.description }
        if let indexError = error as? LibraryIndex.IndexError { return indexError.description }
        if let playlistError = error as? PlaylistFile.PlaylistError { return playlistError.description }
        return error.localizedDescription
    }
}
