import Foundation

// MARK: - 元信息补全接缝

/// 下载落盘后的 **元信息补全**（补空字段 + 真实读取文件）。
///
/// 实现方是元信息会话的 `MetadataCompletionService`
/// （`completeDownloaded(path:source:)`）。
/// 这里只声明协议，下载流程不依赖具体实现（测试可注入假实现）。
public protocol DownloadMetadataCompleting: AnyObject {
    /// 补齐空字段并返回 **真实读取** 的标签。
    ///
    /// - Throws: 网络 / IO 失败（调用方必须自己决定是否降级）。
    func completeDownloaded(path: String, source: RemoteSong?) async throws -> AudioTags
}

// MARK: - 请求结果

/// 一次下载请求的 **目的**。
public enum DownloadPurpose: String, Equatable {
    /// 加入本地歌单。
    case playlistAddition
    /// 队列另存为本地歌单。
    case queueSave
    /// 自动保存（完整在线播放达阈值）。
    case autoSave
}

/// 统一下载入口的结果。
public enum DownloadRequestOutcome: Equatable {
    /// **复用本地已有文件**（没有下载）。
    case reusedLocal(path: String, reason: String, addedPaths: [String])
    /// 已入队（等待落盘）。
    case queued(reason: String)
    /// 失败（**没有入队**；用户文件未被动过）。
    case failed(String)

    /// 是否真的发起了下载。
    public var didQueue: Bool {
        if case .queued = self { return true }
        return false
    }

    /// 失败原因（nil = 没有失败）。
    public var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

/// 一次下载 **收尾** 的结果。
public struct DownloadCompletionResult {
    /// 最终存活并入库的文件路径。
    public var path: String
    /// 是否发生了「优质替换」（新文件替换旧文件）。
    public var replaced: Bool
    /// 过程中的提示（补全失败 / 替换被拒 / 废纸篓失败 …）。
    public var notes: [String]
    /// 成功入单的本地歌单 ID。
    public var confirmedPlaylistIds: [String]
    /// 仍待处理的入单目标数。
    public var pendingCount: Int
    /// 索引写入错误（nil = 正常）。
    public var indexError: String?
    /// 本次真正新增的路径（按歌单 ID）。
    public var newlyAdded: [String: [String]]

    public init(
        path: String = "",
        replaced: Bool = false,
        notes: [String] = [],
        confirmedPlaylistIds: [String] = [],
        pendingCount: Int = 0,
        indexError: String? = nil,
        newlyAdded: [String: [String]] = [:]
    ) {
        self.path = path
        self.replaced = replaced
        self.notes = notes
        self.confirmedPlaylistIds = confirmedPlaylistIds
        self.pendingCount = pendingCount
        self.indexError = indexError
        self.newlyAdded = newlyAdded
    }
}

// MARK: - 串行闸门

/// 串行闸门：保证 **同一时刻只有一个** 下载收尾在跑。
///
/// 重复的「下载完成」事件与并发事件都必须排队执行
/// → 收尾逻辑天然 **幂等**（不会并发迁移同一批引用）。
private final class AsyncGate {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if held {
                waiters.append(continuation)
                lock.unlock()
            } else {
                held = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            held = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

// MARK: - 下载流程

/// **统一下载流程**：所有下载入口（加入歌单 / 队列另存 / 自动保存 / 重试）
/// 都走这里，**审核 → 登记 → 入队 → 落盘 → 补全 → 替换 → 入单** 一条路。
///
/// 硬规则：
/// - **审核在前**：本地已有且质量不低 → 复用本地，**不重复下载**；
/// - **登记在前**：入单意图 / 替换意图 **写不成功就不入队**（失败无法补偿）；
/// - **实测在后**：下载完成后 **先补元信息并实读**，再决定升级 / 入库 / 入单；
/// - **升级是事务**：新文件必须实测更好才替换旧文件，失败 **旧文件原样保留**；
/// - **重复事件幂等**：同一个任务重复完成只生效一次。
public final class DownloadPipeline {

    private let library: LocalLibrary
    private let intake: DownloadIntakeService
    private let review: DownloadReviewService
    private let replacement: DownloadReplacementService
    private let autoSave: AutoSaveService
    private let bridge: BridgeService
    private let metadataCompletion: DownloadMetadataCompleting?

    private let gate = AsyncGate()
    private let cacheLock = NSLock()
    /// 已完成的任务（`任务 ID|路径` → 结果）：重复事件直接复用结果。
    ///
    /// **有界**（最多 32 条）：只用来避免重复事件重复做网络与写盘，
    /// 真正的幂等依据仍是 `DownloadIntakeService` 与 `pendingReplacements`。
    private var completed: [String: DownloadCompletionResult] = [:]
    private var completedOrder: [String] = []
    private static let cacheLimit = 32

    public init(
        library: LocalLibrary,
        intake: DownloadIntakeService,
        review: DownloadReviewService,
        replacement: DownloadReplacementService,
        autoSave: AutoSaveService,
        bridge: BridgeService,
        metadataCompletion: DownloadMetadataCompleting? = nil
    ) {
        self.library = library
        self.intake = intake
        self.review = review
        self.replacement = replacement
        self.autoSave = autoSave
        self.bridge = bridge
        self.metadataCompletion = metadataCompletion
    }

    // MARK: - 请求（统一入口）

    /// 请求一次下载（**所有入口都走这里**）。
    ///
    /// - Parameters:
    ///   - song: 网络曲目。
    ///   - targets: 目标本地歌单 ID（可为空 = 只落盘不入单）。
    ///   - purpose: 目的（影响自动保存登记）。
    ///   - directory: 下载目录（空 = 用设置里的默认）。
    /// - Returns: 结果（复用本地 / 已入队 / 失败）。
    public func requestDownload(
        song: RemoteSong,
        targets: [String],
        purpose: DownloadPurpose,
        directory: String?
    ) async -> DownloadRequestOutcome {
        // 1) **统一审核**：本地已有就复用，质量可能更高才下载。
        let decision = await review.review(song: song)
        switch decision {
        case .reuseLocal(let candidate, let reason):
            return reuseLocal(candidate: candidate, reason: reason, song: song, targets: targets)
        case .replaceLocal(let candidate, let reason):
            // **先把上一轮中断的替换收尾**（否则 `register` 会拒绝新意图）。
            await replacement.repairPending()
            // 登记「优质替换」意图（**写不成功就不入队**）。
            do {
                try replacement.register(neteaseId: song.id, oldPath: candidate.track.path)
            } catch {
                return .failed("登记替换意图失败：\(Self.describe(error))")
            }
            return await enqueue(song: song, targets: targets, purpose: purpose, directory: directory, reason: reason)
        case .downloadNew(let reason):
            return await enqueue(song: song, targets: targets, purpose: purpose, directory: directory, reason: reason)
        }
    }

    /// 自动保存请求（**也走统一审核**）。
    ///
    /// - 本地已有文件 → 审核质量：可证实更高才升级，否则 **标记为已保存**（不下载）。
    public func requestAutoSave(song: RemoteSong, directory: String?) async -> DownloadRequestOutcome {
        let outcome = await requestDownload(
            song: song,
            targets: [],
            purpose: .autoSave,
            directory: directory
        )
        switch outcome {
        case .reusedLocal:
            // 本地已有文件 → 记为已保存（不再下载）。
            do {
                try autoSave.markSaved(neteaseId: song.id)
            } catch {
                return .failed("写入自动保存状态失败：\(Self.describe(error))")
            }
        case .queued, .failed:
            break
        }
        return outcome
    }

    /// 复用本地已有文件（**不下载**）：把本地文件加入目标歌单。
    private func reuseLocal(
        candidate: LocalAudioCandidate,
        reason: String,
        song: RemoteSong,
        targets: [String]
    ) -> DownloadRequestOutcome {
        // 安全网：文件必须真的存在（不能把已删除的条目加进歌单）。
        guard FileManager.default.fileExists(atPath: candidate.track.path) else {
            return .failed("本地文件已不存在：\(candidate.track.path)")
        }
        var added: [String] = []
        for playlistId in targets {
            let duration = candidate.track.durationMs > 0
                ? candidate.track.durationMs
                : UInt64(max(0, song.durationMs))
            do {
                let appended = try library.addToPlaylist(id: playlistId, entries: [PlaylistEntry(
                    path: candidate.track.path,
                    duration: Double(duration) / 1000,
                    displayName: "\(song.name) - \(song.artistText)"
                )])
                added.append(contentsOf: appended.map(\.path))
            } catch {
                return .failed("加入歌单失败：\(Self.describe(error))")
            }
        }
        return .reusedLocal(path: candidate.track.path, reason: reason, addedPaths: added)
    }

    /// 真正入队（**先登记意图，再入队**）。
    private func enqueue(
        song: RemoteSong,
        targets: [String],
        purpose: DownloadPurpose,
        directory: String?,
        reason: String
    ) async -> DownloadRequestOutcome {
        // 1) 入单意图（写不成功就不入队）。
        if !targets.isEmpty {
            do {
                try intake.registerIntent(
                    taskId: song.id,
                    targets: targets,
                    displayName: "\(song.name) - \(song.artistText)",
                    durationMs: song.durationMs
                )
            } catch {
                return .failed("登记入单意图失败：\(Self.describe(error))")
            }
        }
        // 2) 自动保存登记（去重 + 失败可重试）。
        if purpose == .autoSave {
            do {
                try autoSave.markEnqueued(
                    neteaseId: song.id,
                    title: song.name,
                    artist: song.artistText,
                    durationMs: song.durationMs,
                    artistNames: song.artists.map(\.name),
                    albumName: song.album.name
                )
            } catch {
                return .failed("登记自动保存失败：\(Self.describe(error))")
            }
        }
        // 3) 入队。
        do {
            let note = try await bridge.enqueueDownload(
                song: song,
                directory: directory?.isEmpty == true ? nil : directory,
                targets: targets
            )
            return .queued(reason: note?.isEmpty == false ? note! : reason)
        } catch {
            if purpose == .autoSave {
                do {
                    try autoSave.markFailed(neteaseId: song.id, error: Self.describe(error))
                } catch {
                    return .failed("自动保存失败且状态未能写回：\(Self.describe(error))")
                }
            }
            return .failed("加入下载队列失败：\(Self.describe(error))")
        }
    }

    // MARK: - 完成（统一收尾）

    /// 下载 **落盘成功** 后的收尾：补元信息 → 升级替换 → 索引 / 入单。
    ///
    /// - Parameters:
    ///   - task: 已完成的任务。
    ///   - source: 曲目来源（nil = 由任务信息重建）。
    /// - Returns: 收尾结果（**重复事件幂等**：同一个任务只生效一次）。
    public func completeDownload(
        task: DownloadTask,
        source: RemoteSong? = nil
    ) async -> DownloadCompletionResult {
        await gate.acquire()
        defer { gate.release() }
        let key = Self.cacheKey(for: task)
        if let cached = cachedResult(for: key) {
            return cached
        }
        let result = await performCompletion(task: task, source: source ?? Self.song(from: task))
        // **只缓存干净成功的结果**：有失败 / 部分入单 / 索引错误的必须能重试。
        if Self.isFullySuccessful(result) {
            storeResult(key: key, result: result)
        }
        return result
    }

    /// 缓存键：任务 ID + 路径 + **任务创建 / 更新时间**。
    ///
    /// 只用 `任务 ID|路径` 会把 **新一轮下载**（同名路径复用）误判成重复事件，
    /// 因此必须带上能区分「同一轮」与「新一轮」的时间戳。
    static func cacheKey(for task: DownloadTask) -> String {
        "\(task.id)|\(task.path)|\(task.createdAt)|\(task.updatedAt)"
    }

    /// 是否 **完全成功**（可以缓存，避免重复事件重复处理）。
    static func isFullySuccessful(_ result: DownloadCompletionResult) -> Bool {
        result.notes.isEmpty && result.pendingCount == 0 && result.indexError == nil
    }

    /// 用 **已有的本地文件** 完成一次下载任务（**不下载、不替换**）。
    ///
    /// 用途：重试 / 恢复时发现本地已有可用文件 → 直接入单，不重新下载。
    public func completeWithLocalFile(
        task: DownloadTask,
        path: String
    ) async -> DownloadCompletionResult {
        await gate.acquire()
        defer { gate.release() }
        guard FileManager.default.fileExists(atPath: path) else {
            return DownloadCompletionResult(path: path, notes: ["本地文件不存在：\(path)"])
        }
        var result = await performIntake(task: task, path: path, notes: [], replaced: false)
        // 自动保存：**只在真的入单成功** 时才记为已保存。
        applyAutoSaveState(taskId: task.id, result: &result, path: path)
        return result
    }

    /// 真正的收尾流程。
    private func performCompletion(
        task: DownloadTask,
        source: RemoteSong?
    ) async -> DownloadCompletionResult {
        var notes: [String] = []
        // **先解存活路径**：重复 / 迟到的事件可能带着 **已被弃掉** 的新文件
        // （例如替换被放弃后 Rust 又重放了一次「完成」事件）。
        // 没有本次替换意图时，一律用 **存活路径**（旧的或已提交的新文件）。
        let hasIntent = replacement.pending(neteaseId: task.id) != nil
            || replacement.committing(neteaseId: task.id) != nil
        var path = task.path
        if !hasIntent, let surviving = replacement.survivingPath(neteaseId: task.id) {
            path = surviving
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return DownloadCompletionResult(path: path, notes: ["下载已完成但文件不存在：\(path)"])
        }

        // 1) **元信息补全 + 实读**（补空字段，保留已有非空标签与封面）。
        var tags: AudioTags?
        if let completer = metadataCompletion {
            do {
                tags = try await completer.completeDownloaded(path: path, source: source)
            } catch {
                // 补全失败 **不阻断** 落盘与入单，但必须说出来。
                notes.append("元信息补全失败：\(Self.describe(error))")
            }
        }

        // 2) **优质替换**（登记过才处理）。
        var replaced = false
        let hasReplacement = replacement.pending(neteaseId: task.id) != nil
            || replacement.committing(neteaseId: task.id) != nil
        if hasReplacement {
            let outcome = await replacement.commit(
                neteaseId: task.id,
                newPath: path,
                newTags: tags
            )
            switch outcome {
            case .committed(let surviving):
                replaced = true
                path = surviving
            case .committedWithWarning(let surviving, let warning):
                replaced = true
                path = surviving
                notes.append(warning)
            case .discarded(let reason):
                notes.append(reason)
                if let oldPath = replacement.oldPath(neteaseId: task.id),
                   FileManager.default.fileExists(atPath: oldPath) {
                    path = oldPath
                }
            case .failed(let reason):
                notes.append(reason)
                if let oldPath = replacement.oldPath(neteaseId: task.id),
                   FileManager.default.fileExists(atPath: oldPath) {
                    path = oldPath
                }
            }
        }

        // 3) **索引 + 入单**（用存活文件的真实标签）。
        var result = await performIntake(task: task, path: path, notes: notes, replaced: replaced)

        // 4) 自动保存：**只在真的落盘并入单成功** 时才记为已保存。
        //    索引失败 / 文件缺失 / 入单未完成 → **不假装已保存**（保持可重试）。
        applyAutoSaveState(taskId: task.id, result: &result, path: path)
        return result
    }

    /// 自动保存状态：**只在真的落盘并入单成功** 时才记为已保存。
    ///
    /// - 索引失败 / 文件缺失 / 入单未完成 → 记为 **失败（可重试）**，
    ///   绝不假装已保存。
    private func applyAutoSaveState(
        taskId: Int64,
        result: inout DownloadCompletionResult,
        path: String
    ) {
        guard autoSave.record(neteaseId: taskId)?.state == .pending else { return }
        let failure = Self.autoSaveFailureReason(result: result, path: path)
        do {
            if let failure {
                try autoSave.markFailed(neteaseId: taskId, error: failure)
                result.notes.append(failure)
            } else {
                try autoSave.markSaved(neteaseId: taskId)
            }
        } catch {
            result.notes.append("写入自动保存状态失败：\(Self.describe(error))")
        }
    }

    /// 自动保存不能记为「已保存」的原因（nil = 可以记为已保存）。
    static func autoSaveFailureReason(result: DownloadCompletionResult, path: String) -> String? {
        if !FileManager.default.fileExists(atPath: path) {
            return "文件不存在，未能标记为已保存：\(path)"
        }
        if let indexError = result.indexError {
            return "写入本地索引失败，未能标记为已保存：\(indexError)"
        }
        if result.pendingCount > 0 {
            return "仍有 \(result.pendingCount) 个入单目标待处理，未能标记为已保存"
        }
        return nil
    }

    /// 写索引 + 逐目标入单。
    private func performIntake(
        task: DownloadTask,
        path: String,
        notes: [String],
        replaced: Bool
    ) async -> DownloadCompletionResult {
        var result = DownloadCompletionResult(path: path, replaced: replaced, notes: notes)
        guard FileManager.default.fileExists(atPath: path) else {
            result.notes.append("文件不存在：\(path)")
            return result
        }
        // 标签：优先 **实读** 文件（补全后写进去的也算）。
        let tags = await review.readTags(path: path) ?? AudioTags(path: path)
        do {
            let outcome = try intake.performIntake(
                taskId: task.id,
                targets: task.targets,
                path: path,
                title: tags.title.isEmpty ? task.name : tags.title,
                artist: tags.artist.isEmpty ? task.artist : tags.artist,
                album: tags.album.isEmpty ? task.album : tags.album,
                durationMs: tags.durationMs > 0 ? Int64(tags.durationMs) : task.durationMs,
                neteaseId: task.id
            )
            // **幂等口径**：已确认的目标也算「已入单」（重复事件报同样的结果）。
            result.confirmedPlaylistIds = task.targets.filter { playlistId in
                intake.latestRecord(taskId: task.id, playlistId: playlistId)?.isConfirmed == true
            }
            result.pendingCount = outcome.pending.count
            result.indexError = outcome.indexError
            result.newlyAdded = outcome.newlyAdded
        } catch {
            result.notes.append("下载入单失败：\(Self.describe(error))")
        }
        return result
    }

    // MARK: - 内部

    private func cachedResult(for key: String) -> DownloadCompletionResult? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return completed[key]
    }

    private func storeResult(key: String, result: DownloadCompletionResult) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if completed[key] == nil {
            completedOrder.append(key)
        }
        completed[key] = result
        // **有界**：超出上限就丢掉最旧的一条（避免状态无限增长）。
        while completedOrder.count > Self.cacheLimit {
            let oldest = completedOrder.removeFirst()
            completed.removeValue(forKey: oldest)
        }
    }

    /// 由任务信息重建曲目（重启后没有原始 `RemoteSong` 时用）。
    public static func song(from task: DownloadTask) -> RemoteSong {
        RemoteSong(
            id: task.id,
            name: task.name,
            artists: task.artist.isEmpty ? [] : [RemoteArtist(id: 0, name: task.artist)],
            album: RemoteAlbum(id: 0, name: task.album, picUrl: ""),
            durationMs: task.durationMs
        )
    }

    static func describe(_ error: Error) -> String {
        if let serviceError = error as? BridgeServiceError { return serviceError.description }
        if let libraryError = error as? LocalLibraryError { return libraryError.description }
        if let storeError = error as? NativeStore.StoreError { return storeError.description }
        if let indexError = error as? LibraryIndex.IndexError { return indexError.description }
        if let playlistError = error as? PlaylistFile.PlaylistError { return playlistError.description }
        if let bridgeError = error as? BridgeClient.BridgeError { return bridgeError.description }
        if let clientError = error as? BridgeClient.ClientError { return clientError.description }
        if let metadataError = error as? MetadataError { return metadataError.description }
        return error.localizedDescription
    }
}
