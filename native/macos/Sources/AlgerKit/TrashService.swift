import Foundation

/// 一条「删除到废纸篓」的操作日志。
///
/// 顺序保证：**先记日志 → 再移入废纸篓 → 成功后清理索引与所有本地歌单引用**。
/// 中途崩溃 / 失败时日志留在 `native.json` 里，下次启动可定位、可重试。
public struct PendingFileDeletion: Codable, Equatable, Identifiable {

    /// 状态。
    public enum State: String, Codable, Equatable {
        /// 已登记，尚未移入废纸篓。
        case pending
        /// 移入废纸篓失败（可重试）。
        case failed
        /// 已移入废纸篓，但索引 / 歌单清理未完成（可恢复）。
        case cleanupPending
    }

    /// 稳定 ID。
    public var id: String
    /// 音频路径（绝对路径）。
    public var path: String
    /// 显示名。
    public var title: String
    /// 受影响的本地歌单 ID。
    public var playlistIds: [String]
    /// 状态。
    public var state: State
    /// 最近一次错误。
    public var lastError: String?
    /// 登记时间（Unix 秒）。
    public var createdAt: Double
    /// 最近更新时间（Unix 秒）。
    public var updatedAt: Double

    public init(
        id: String? = nil,
        path: String,
        title: String,
        playlistIds: [String] = [],
        state: State = .pending,
        lastError: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970,
        updatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id ?? "del-" + UUID().uuidString.lowercased()
        self.path = path
        self.title = title
        self.playlistIds = playlistIds
        self.state = state
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case title
        case playlistIds
        case state
        case lastError
        case createdAt
        case updatedAt
    }

    /// 宽容解码。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? "del-" + UUID().uuidString.lowercased()
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        playlistIds = try container.decodeIfPresent([String].self, forKey: .playlistIds) ?? []
        state = try container.decodeIfPresent(State.self, forKey: .state) ?? .pending
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt) ?? createdAt
    }
}

/// 废纸篓删除服务：**真实移入废纸篓 + 操作日志 + 索引 / 歌单协调清理**。
///
/// 约定：
/// - **先持久化操作日志**，再调用废纸篓；日志写不成功就 **不删文件**；
/// - 废纸篓失败 → **不提前清索引 / 歌单**，只把失败记进日志（可重试）；
/// - 成功 → 清理索引 + **所有** 本地歌单里的引用（多份 M3U8 逐个清理）；
/// - **不碰远程歌单**（远程条目不受本地删除影响）；
/// - 「从歌单移除」是另一件事（**不删音频**），见 `LocalLibrary.removeFromPlaylist`。
public final class TrashService {

    /// 删除前的计划（用于确认弹窗：显示受影响歌单数）。
    public struct Plan: Equatable {
        /// 音频路径。
        public var path: String
        /// 显示名。
        public var title: String
        /// 受影响的本地歌单（**能读出来** 且含该路径的）。
        public var affectedPlaylists: [LocalPlaylist]
        /// **读不出来** 的歌单 ID（引用情况未知，必须纳入待清理范围）。
        public var unreadablePlaylistIds: [String]
        /// 读取歌单时的具体问题（不吞错误）。
        public var issues: [String]

        /// 受影响歌单数量（**只统计能确认的**）。
        public var affectedPlaylistCount: Int { affectedPlaylists.count }
        /// 是否存在 **无法确认** 引用情况的歌单。
        public var hasUnknownScope: Bool { !unreadablePlaylistIds.isEmpty }
        /// 清理范围（能确认的 + 读不出来的）。
        public var cleanupScopePlaylistIds: [String] {
            affectedPlaylists.map(\.id) + unreadablePlaylistIds
        }
    }

    /// 删除结果。
    public struct Result: Equatable {
        /// 是否已移入废纸篓。
        public var movedToTrash: Bool = false
        /// 是否已从索引移除。
        public var removedFromIndex: Bool = false
        /// 已清理引用的歌单 ID。
        public var cleanedPlaylistIds: [String] = []
        /// 清理失败（歌单 ID → 原因）。
        public var cleanupFailures: [String: String] = [:]

        /// 是否全部完成。
        public var isComplete: Bool {
            movedToTrash && removedFromIndex && cleanupFailures.isEmpty
        }
    }

    /// 废纸篓动作（**可注入**，测试用真实文件 + 注入的失败动作）。
    public typealias TrashAction = (String) throws -> Void

    private let store: NativeStore
    private let index: LibraryIndex
    private let library: LocalLibrary
    private let trash: TrashAction

    public init(
        store: NativeStore,
        index: LibraryIndex,
        library: LocalLibrary,
        trash: @escaping TrashAction = { path in
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
    ) {
        self.store = store
        self.index = index
        self.library = library
        self.trash = trash
    }

    // MARK: - 计划

    /// 计算删除影响（**逐个注册项读取** + 具体 issues）。
    ///
    /// 一个歌单读不出来时：
    /// - 它的引用情况 **无法确认** → 记入 `unreadablePlaylistIds`，
    ///   删除后仍会尝试清理（失败会留在待处理日志里，可重试）；
    /// - **不会** 因此把「受影响歌单数」说成 0 然后假装清理完整。
    public func plan(path: String, title: String? = nil) -> Plan {
        let (playlists, issues, failedIds) = library.playlistsWithIssues()
        let affected = playlists.filter { playlist in
            playlist.entries.contains(where: { $0.path == path })
        }
        let resolvedTitle = title
            ?? library.index.track(path: path).map { $0.title.isEmpty ? path : $0.title }
            ?? path
        return Plan(
            path: path,
            title: resolvedTitle,
            affectedPlaylists: affected,
            unreadablePlaylistIds: failedIds,
            issues: issues
        )
    }

    // MARK: - 删除

    /// 删除一个本地音频文件（**移入废纸篓**）。
    ///
    /// - Throws: 日志写入失败 / 废纸篓失败（此时索引与歌单 **未被改动**）。
    @discardableResult
    public func delete(path: String, title: String? = nil) throws -> Result {
        let plan = plan(path: path, title: title)
        let now = Date().timeIntervalSince1970
        let record = PendingFileDeletion(
            path: path,
            title: plan.title,
            // 读不出来的歌单 **也要** 纳入待清理范围（否则引用会残留）。
            playlistIds: plan.cleanupScopePlaylistIds,
            createdAt: now,
            updatedAt: now
        )
        // 1) **先记日志**（写不成功就不删文件）。
        try store.mutate { state in
            state.pendingFileDeletions.append(record)
        }

        // 2) 移入废纸篓。
        do {
            try trash(path)
        } catch {
            let reason = "移入废纸篓失败：\(Self.describe(error))"
            do {
                try update(recordID: record.id, state: .failed, error: reason)
            } catch let logError {
                // 失败日志也写不进去 → 记录仍是 pending（可见），错误一并报出。
                throw TrashError.trashFailed("\(reason)（失败原因也未能写入日志：\(Self.describe(logError))）")
            }
            throw TrashError.trashFailed(reason)
        }

        // 3) 成功后：清理索引 + 所有本地歌单引用。
        var result = Result()
        result.movedToTrash = true
        result = finishCleanup(record: record, result: result)
        return result
    }

    /// 恢复 / 重试未完成的删除。
    ///
    /// - Returns: 每条操作的处理说明（空数组 = 没有需要处理的）。
    @discardableResult
    public func repairPending() -> [String] {
        var report: [String] = []
        for record in store.current.pendingFileDeletions {
            let exists = FileManager.default.fileExists(atPath: record.path)
            if exists {
                // 文件还在（例如上次废纸篓失败）→ 报告并保留，**不假装删除成功**。
                let message = "上次未完成的删除仍然待处理：\(record.title)（\(record.lastError ?? "文件仍在原处")）"
                do {
                    try update(recordID: record.id, state: .failed, error: record.lastError ?? "文件仍在原处")
                } catch {
                    report.append("\(message)（状态未能写回：\(Self.describe(error))）")
                    continue
                }
                report.append(message)
                continue
            }
            // 文件已不在原处（多半已进废纸篓）→ 补做索引 / 歌单清理。
            var result = Result()
            result.movedToTrash = true
            result = finishCleanup(record: record, result: result)
            if result.cleanupFailures.isEmpty {
                do {
                    try remove(recordID: record.id)
                    report.append("已补齐上次未完成的删除清理：\(record.title)")
                } catch {
                    report.append("已清理索引与歌单，但未能写回操作日志：\(record.title)（\(Self.describe(error))）")
                }
            } else {
                let details = result.cleanupFailures
                    .map { "\($0.key)：\($0.value)" }
                    .joined(separator: "；")
                do {
                    try update(recordID: record.id, state: .cleanupPending, error: details)
                } catch {
                    report.append("上次未完成的删除仍有歌单未清理：\(record.title)（\(details)）（状态未能写回）")
                    continue
                }
                report.append("上次未完成的删除仍有歌单未清理：\(record.title)（\(details)）")
            }
        }
        return report
    }

    /// 待处理的删除操作。
    public var pending: [PendingFileDeletion] { store.current.pendingFileDeletions }

    // MARK: - 内部

    private func finishCleanup(record: PendingFileDeletion, result: Result) -> Result {
        var result = result
        do {
            // 索引里没有这条（文件本来就不在索引）也算 **幂等成功**。
            _ = try index.remove(path: record.path)
            result.removedFromIndex = true
        } catch {
            result.cleanupFailures["索引"] = Self.describe(error)
        }
        for playlistId in record.playlistIds {
            do {
                try library.removeFromPlaylist(id: playlistId, paths: [record.path])
                result.cleanedPlaylistIds.append(playlistId)
            } catch {
                result.cleanupFailures[playlistId] = Self.describe(error)
            }
        }
        if result.cleanupFailures.isEmpty {
            do {
                try remove(recordID: record.id)
            } catch {
                result.cleanupFailures["操作日志"] = Self.describe(error)
            }
        } else {
            let details = result.cleanupFailures
                .map { "\($0.key)：\($0.value)" }
                .joined(separator: "；")
            do {
                try update(recordID: record.id, state: .cleanupPending, error: details)
            } catch {
                result.cleanupFailures["操作日志"] = Self.describe(error)
            }
        }
        return result
    }

    private func update(recordID: String, state status: PendingFileDeletion.State, error: String?) throws {
        let now = Date().timeIntervalSince1970
        try store.mutate { state in
            guard let index = state.pendingFileDeletions.firstIndex(where: { $0.id == recordID }) else { return }
            state.pendingFileDeletions[index].state = status
            state.pendingFileDeletions[index].lastError = error
            state.pendingFileDeletions[index].updatedAt = now
        }
    }

    private func remove(recordID: String) throws {
        try store.mutate { state in
            state.pendingFileDeletions.removeAll { $0.id == recordID }
        }
    }

    static func describe(_ error: Error) -> String {
        if let libraryError = error as? LocalLibraryError { return libraryError.description }
        if let storeError = error as? NativeStore.StoreError { return storeError.description }
        if let indexError = error as? LibraryIndex.IndexError { return indexError.description }
        if let playlistError = error as? PlaylistFile.PlaylistError { return playlistError.description }
        return error.localizedDescription
    }
}

/// 废纸篓删除错误。
public enum TrashError: Error, CustomStringConvertible {
    case trashFailed(String)

    public var description: String {
        switch self {
        case .trashFailed(let message): return message
        }
    }
}
