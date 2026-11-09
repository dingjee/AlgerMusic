import Foundation

/// 本地专辑分组（只归组本地文件）。
public struct LocalAlbum: Identifiable, Equatable {
    /// 稳定 ID（专辑名 + 专辑艺人）。
    public var id: String { "\(albumArtist)|\(name)" }
    public var name: String
    public var albumArtist: String
    public var tracks: [TrackRecord]

    public init(name: String, albumArtist: String, tracks: [TrackRecord]) {
        self.name = name
        self.albumArtist = albumArtist
        self.tracks = tracks
    }
}

/// 本地艺人分组（只归组本地文件）。
public struct LocalArtist: Identifiable, Equatable {
    /// 稳定 ID（艺人名）。
    public var id: String { name }
    public var name: String
    public var tracks: [TrackRecord]

    public init(name: String, tracks: [TrackRecord]) {
        self.name = name
        self.tracks = tracks
    }
}

/// 本地歌单（注册表元信息 + M3U8 条目）。
public struct LocalPlaylist: Identifiable, Equatable {
    /// 稳定 ID（创建后不变）。
    public var id: String
    public var title: String
    public var details: String
    /// M3U8 文件位置。
    public var fileURL: URL
    /// 曲目（绝对路径）。
    public var entries: [PlaylistEntry]

    public init(id: String, title: String, details: String, fileURL: URL, entries: [PlaylistEntry]) {
        self.id = id
        self.title = title
        self.details = details
        self.fileURL = fileURL
        self.entries = entries
    }

    public var trackCount: Int { entries.count }
}

/// 本地资料库服务：索引（`library/index.json`）+ 本地歌单（`native.json` 注册表 + M3U8）。
///
/// 职责边界：
/// - **索引**（`LibraryIndex`）只存路径与元信息快照；
/// - **歌单注册表**（`NativeStore`）存稳定 ID / 标题 / 描述；
/// - **歌单内容**（M3U8）由 `PlaylistFile` 负责（原子写 + 冲突检测）；
/// - **移出歌单只去掉引用，绝不删除音频文件**；
/// - **破坏性操作先登记意图**（`pendingOperations`），中断后可恢复，
///   绝不出现「文件已删、注册表还在」的假成功。
public final class LocalLibrary {
    public let index: LibraryIndex
    public let store: NativeStore

    public init(index: LibraryIndex, store: NativeStore) {
        self.index = index
        self.store = store
    }

    // MARK: - 资料库分组

    /// 本地歌曲（按标题 + 艺人排序）。
    public func songs() -> [TrackRecord] {
        index.tracks.sorted { lhs, rhs in
            let left = (lhs.title, lhs.artist)
            let right = (rhs.title, rhs.artist)
            if left.0 != right.0 { return left.0 < right.0 }
            return left.1 < right.1
        }
    }

    /// 本地专辑分组。
    ///
    /// 分组名统一用 `TrackRecord.displayAlbum` / `displayArtist`
    /// （缺失标签 → `Unrecognized`），**不**再出现「未知专辑」这类另一套说法。
    public func albums() -> [LocalAlbum] {
        var groups: [String: (albumArtist: String, name: String, tracks: [TrackRecord])] = [:]
        var order: [String] = []
        for track in index.tracks {
            let name = track.displayAlbum
            let artist = track.displayArtist
            let key = "\(artist)|\(name)"
            if groups[key] == nil {
                groups[key] = (artist, name, [])
                order.append(key)
            }
            groups[key]?.tracks.append(track)
        }
        return order
            .compactMap { key -> LocalAlbum? in
                guard let group = groups[key] else { return nil }
                return LocalAlbum(name: group.name, albumArtist: group.albumArtist, tracks: group.tracks)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 本地艺人分组（缺失艺人 → `Unrecognized`）。
    public func artists() -> [LocalArtist] {
        var groups: [String: [TrackRecord]] = [:]
        for track in index.tracks {
            let name = track.displayArtist
            groups[name, default: []].append(track)
        }
        return groups
            .map { LocalArtist(name: $0.key, tracks: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - 身份关联（**只认明确来源 ID**）

    /// 按 **来源 ID** 找本地文件（网络曲目 → 本地文件的唯一自动关联方式）。
    ///
    /// **不做**「标题 + 艺人」之类的模糊匹配：同名不同录音、翻唱、现场版
    /// 都会因此被当成同一首歌自动替换成错误的文件。
    /// 其它关联必须由用户 **明确确认**（见 `confirmAssociation`）。
    ///
    /// - Returns: 命中的本地记录；文件已不存在时返回 nil。
    public func matchLocalTrack(neteaseId: Int64) -> TrackRecord? {
        guard neteaseId > 0 else { return nil }
        guard let track = index.track(neteaseId: neteaseId) else { return nil }
        guard FileManager.default.fileExists(atPath: track.path) else { return nil }
        return track
    }

    /// 明确确认关联：把网络曲目 ID 绑定到本地文件（写回索引）。
    ///
    /// 这是 **用户显式动作** 才会走的路径（例如下载完成后登记来源 ID）。
    public func confirmAssociation(localPath: String, neteaseId: Int64) throws {
        guard neteaseId > 0 else { return }
        try index.upsert(TrackRecord(
            path: localPath,
            neteaseId: neteaseId,
            title: index.track(path: localPath)?.title ?? "",
            artist: index.track(path: localPath)?.artist ?? "",
            album: index.track(path: localPath)?.album ?? "",
            durationMs: index.track(path: localPath)?.durationMs ?? 0,
            format: index.track(path: localPath)?.format ?? "",
            size: index.track(path: localPath)?.size ?? 0,
            modifiedAt: index.track(path: localPath)?.modifiedAt ?? 0
        ))
    }

    // MARK: - 本地歌单

    /// 歌单目录（来自设置；未配置时使用默认目录）。
    public func playlistsDirectory() -> URL {
        let configured = store.current.settings.playlistsDirectory
        if !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return AppPaths.defaultPlaylistsDir
    }

    /// 某个注册项 **真实所在** 的 M3U8 位置。
    ///
    /// 注册项记了自己的目录（创建时的真实位置），
    /// 因此改了全局「歌单目录」之后，**既有歌单仍然留在原处并可访问**；
    /// 老版本记录没有目录字段，回退到当前全局目录。
    public func playlistFileURL(for record: LocalPlaylistRecord) -> URL {
        if !record.directory.isEmpty {
            return URL(fileURLWithPath: record.directory, isDirectory: true)
                .appendingPathComponent(record.fileName, isDirectory: false)
        }
        return playlistsDirectory().appendingPathComponent(record.fileName, isDirectory: false)
    }

    /// 全部本地歌单（含条目）。
    public func playlists() throws -> [LocalPlaylist] {
        playlistsWithIssues().playlists
    }

    /// 全部本地歌单 **以及每个歌单的具体读取问题**。
    ///
    /// 一个歌单读不出来 **不能** 让整组显示为空（`try?` 会把整组吞掉）：
    /// 这里逐个读，坏的那个单独报错，其余照常返回。
    ///
    /// - Returns: 可读的歌单、读取问题、**读不出来的歌单 ID**（删除清理要覆盖它们）。
    public func playlistsWithIssues() -> (playlists: [LocalPlaylist], issues: [String], failedPlaylistIds: [String]) {
        let records = store.current.playlists
        var playlists: [LocalPlaylist] = []
        var issues: [String] = []
        var failedPlaylistIds: [String] = []
        for record in records {
            let fileURL = playlistFileURL(for: record)
            let playlistFile = PlaylistFile(fileURL: fileURL)
            do {
                try playlistFile.load()
                playlists.append(LocalPlaylist(
                    id: record.id,
                    title: record.title,
                    details: record.details,
                    fileURL: fileURL,
                    entries: playlistFile.entries
                ))
            } catch {
                issues.append("歌单「\(record.title)」读取失败：\(Self.describe(error))")
                failedPlaylistIds.append(record.id)
            }
        }
        return (playlists, issues, failedPlaylistIds)
    }

    /// 单个歌单。
    public func playlist(id: String) throws -> LocalPlaylist? {
        guard let record = store.current.playlists.first(where: { $0.id == id }) else { return nil }
        let fileURL = playlistFileURL(for: record)
        let playlistFile = PlaylistFile(fileURL: fileURL)
        try playlistFile.load()
        return LocalPlaylist(
            id: record.id,
            title: record.title,
            details: record.details,
            fileURL: fileURL,
            entries: playlistFile.entries
        )
    }

    /// 新建歌单（稳定 ID + 标题 + 描述 + 空 M3U8）。
    @discardableResult
    public func createPlaylist(title: String, details: String = "") throws -> LocalPlaylist {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalLibraryError.invalidTitle("歌单名称不能为空")
        }
        let id = "pl-" + UUID().uuidString.lowercased()
        let fileName = id + ".m3u8"
        let now = Date().timeIntervalSince1970
        // 记录 **真实目录**：之后改全局目录也不会让这个歌单「找不到文件」。
        let directory = playlistsDirectory().path
        let record = LocalPlaylistRecord(
            id: id,
            title: trimmed,
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            fileName: fileName,
            directory: directory,
            createdAt: now,
            updatedAt: now
        )
        // 先写 M3U8（空歌单），再登记：文件写失败时不会留下「有登记无文件」的幽灵歌单。
        let fileURL = playlistsDirectory().appendingPathComponent(fileName, isDirectory: false)
        let playlistFile = PlaylistFile(fileURL: fileURL)
        try playlistFile.load()
        try playlistFile.save()
        do {
            try store.mutate { state in
                state.playlists.append(record)
            }
        } catch {
            // 登记失败 → 删掉刚建的文件；删不掉就登记一条待恢复操作。
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } catch let cleanupError {
                try? store.mutate { state in
                    state.pendingOperations.append(PendingOperation(
                        kind: .deletePlaylist,
                        playlistId: id,
                        fileName: fileName,
                        details: "新建歌单登记失败后的清理：\(cleanupError.localizedDescription)"
                    ))
                }
            }
            throw error
        }
        return LocalPlaylist(id: id, title: record.title, details: record.details, fileURL: fileURL, entries: [])
    }

    /// 改标题 / 描述（**稳定 ID 不变**）。
    public func updatePlaylist(id: String, title: String?, details: String?) throws {
        var found = false
        try store.mutate { state in
            guard let position = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            found = true
            if let title {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw LocalLibraryError.invalidTitle("歌单名称不能为空")
                }
                state.playlists[position].title = trimmed
            }
            if let details {
                state.playlists[position].details = details.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            state.playlists[position].updatedAt = Date().timeIntervalSince1970
        }
        guard found else { throw LocalLibraryError.notFound("歌单不存在：\(id)") }
    }

    /// 删除歌单（**只删 M3U8 与注册表条目，不删音频文件**）。
    ///
    /// 顺序：**先登记删除意图** → 删文件 → 更新注册表并清掉意图。
    /// 中途失败时意图留在 `pendingOperations` 里，下次启动可修复，
    /// 不会出现「文件没了但注册表还在」的假成功。
    public func deletePlaylist(id: String) throws {
        guard let record = store.current.playlists.first(where: { $0.id == id }) else {
            throw LocalLibraryError.notFound("歌单不存在：\(id)")
        }
        let fileURL = playlistFileURL(for: record)
        let operation = PendingOperation(
            kind: .deletePlaylist,
            playlistId: id,
            fileName: record.fileName,
            details: "删除歌单「\(record.title)」"
        )
        try store.mutate { state in
            state.pendingOperations.append(operation)
        }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try store.mutate { state in
                state.playlists.removeAll { $0.id == id }
                state.pendingOperations.removeAll { $0.id == operation.id }
            }
        } catch {
            // 意图保留在日志里：可恢复。
            throw error
        }
    }

    /// 加入曲目（**网络曲目必须先下载成功**，由调用方保证）。
    ///
    /// - 同批条目 **按路径去重**（同一批里重复的路径只保留一条）。
    /// - Returns: **本次真正新增** 的条目（之前就在歌单里的不会出现在结果里），
    ///   供「更改添加目标时只撤回本次新增」使用。
    @discardableResult
    public func addToPlaylist(id: String, entries: [PlaylistEntry]) throws -> [PlaylistEntry] {
        guard !entries.isEmpty else { return [] }
        guard let record = store.current.playlists.first(where: { $0.id == id }) else {
            throw LocalLibraryError.notFound("歌单不存在：\(id)")
        }
        let fileURL = playlistFileURL(for: record)
        let playlistFile = PlaylistFile(fileURL: fileURL)
        try playlistFile.load()
        var existing = Set(playlistFile.entries.map(\.path))
        var appended: [PlaylistEntry] = []
        for entry in entries {
            // 同批去重 + 与已有条目去重。
            guard !existing.contains(entry.path) else { continue }
            existing.insert(entry.path)
            appended.append(entry)
        }
        guard !appended.isEmpty else { return [] }
        for entry in appended { try playlistFile.add(entry) }
        // 顺序：先落 M3U8（失败则没有不一致，无需留日志）→ 登记意图 → 更新注册表并清意图。
        try playlistFile.save()
        let operation = PendingOperation(
            kind: .touchPlaylist,
            playlistId: id,
            fileName: record.fileName,
            details: "加入 \(appended.count) 首曲目"
        )
        try store.mutate { state in
            state.pendingOperations.append(operation)
        }
        do {
            try store.mutate { state in
                state.pendingOperations.removeAll { $0.id == operation.id }
                guard let position = state.playlists.firstIndex(where: { $0.id == id }) else { return }
                state.playlists[position].updatedAt = Date().timeIntervalSince1970
            }
        } catch {
            // 意图保留在日志里：可恢复（歌单内容已改、注册表时间待补）。
            throw error
        }
        return appended
    }

    /// 从歌单移除（**只去掉引用，不删音频文件**）。
    public func removeFromPlaylist(id: String, paths: [String]) throws {
        guard !paths.isEmpty else { return }
        guard let record = store.current.playlists.first(where: { $0.id == id }) else {
            throw LocalLibraryError.notFound("歌单不存在：\(id)")
        }
        let fileURL = playlistFileURL(for: record)
        let playlistFile = PlaylistFile(fileURL: fileURL)
        try playlistFile.load()
        var changed = false
        for path in paths {
            if try playlistFile.remove(path: path) { changed = true }
        }
        guard changed else { return }
        try playlistFile.save()
        let operation = PendingOperation(
            kind: .touchPlaylist,
            playlistId: id,
            fileName: record.fileName,
            details: "移除 \(paths.count) 首曲目"
        )
        try store.mutate { state in
            state.pendingOperations.append(operation)
        }
        do {
            try store.mutate { state in
                state.pendingOperations.removeAll { $0.id == operation.id }
                guard let position = state.playlists.firstIndex(where: { $0.id == id }) else { return }
                state.playlists[position].updatedAt = Date().timeIntervalSince1970
            }
        } catch {
            throw error
        }
    }

    /// 调整歌单内顺序。
    public func moveInPlaylist(id: String, fromOffsets: IndexSet, toOffset: Int) throws {
        guard let record = store.current.playlists.first(where: { $0.id == id }) else {
            throw LocalLibraryError.notFound("歌单不存在：\(id)")
        }
        let fileURL = playlistFileURL(for: record)
        let playlistFile = PlaylistFile(fileURL: fileURL)
        try playlistFile.load()
        try playlistFile.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try playlistFile.save()
        let operation = PendingOperation(
            kind: .touchPlaylist,
            playlistId: id,
            fileName: record.fileName,
            details: "调整顺序"
        )
        try store.mutate { state in
            state.pendingOperations.append(operation)
        }
        do {
            try store.mutate { state in
                state.pendingOperations.removeAll { $0.id == operation.id }
                guard let position = state.playlists.firstIndex(where: { $0.id == id }) else { return }
                state.playlists[position].updatedAt = Date().timeIntervalSince1970
            }
        } catch {
            throw error
        }
    }

    /// 把歌单里的一个路径换成另一个（**保持条目位置**）。
    ///
    /// 用于「优质替换」：文件换了位置 / 换了文件名后，
    /// 歌单里的引用必须跟着走，且 **顺序不变**。
    ///
    /// - Returns: 是否真的改了（歌单里没有这个路径 → false）。
    @discardableResult
    public func replacePathInPlaylist(id: String, from oldPath: String, to newPath: String) throws -> Bool {
        guard oldPath != newPath else { return false }
        guard let record = store.current.playlists.first(where: { $0.id == id }) else {
            throw LocalLibraryError.notFound("歌单不存在：\(id)")
        }
        let fileURL = playlistFileURL(for: record)
        let playlistFile = PlaylistFile(fileURL: fileURL)
        try playlistFile.load()
        var entries = playlistFile.entries
        var changed = false
        for position in entries.indices where entries[position].path == oldPath {
            entries[position].path = newPath
            changed = true
        }
        guard changed else { return false }
        try playlistFile.replaceEntries(with: entries)
        try playlistFile.save()
        let operation = PendingOperation(
            kind: .touchPlaylist,
            playlistId: id,
            fileName: record.fileName,
            details: "替换曲目路径"
        )
        try store.mutate { state in
            state.pendingOperations.append(operation)
        }
        do {
            try store.mutate { state in
                state.pendingOperations.removeAll { $0.id == operation.id }
                guard let position = state.playlists.firstIndex(where: { $0.id == id }) else { return }
                state.playlists[position].updatedAt = Date().timeIntervalSince1970
            }
        } catch {
            throw error
        }
        return true
    }

    // MARK: - 待恢复操作

    /// 引用了某个音频路径的本地歌单（逐个读，坏的那个单独报错）。
    public func playlists(containingPath path: String) -> (playlists: [LocalPlaylist], issues: [String], failedPlaylistIds: [String]) {
        var matched: [LocalPlaylist] = []
        let (playlists, issues, failedIds) = playlistsWithIssues()
        for playlist in playlists where playlist.entries.contains(where: { $0.path == path }) {
            matched.append(playlist)
        }
        return (matched, issues, failedIds)
    }

    /// 当前未完成的操作（启动时展示给用户）。
    public func pendingOperations() -> [PendingOperation] {
        store.current.pendingOperations
    }

    /// 修复未完成的操作。
    ///
    /// - `deletePlaylist`：删除残留文件 + 清掉注册表条目；
    /// - `touchPlaylist`：补上注册表的修改时间。
    ///
    /// - Returns: 修复说明（空数组 = 没有需要修复的）。
    @discardableResult
    public func repairPendingOperations() throws -> [String] {
        let operations = store.current.pendingOperations
        guard !operations.isEmpty else { return [] }
        var report: [String] = []
        for operation in operations {
            switch operation.kind {
            case .deletePlaylist:
                // 用注册项里的 **真实目录**（改了全局目录也不会找错文件）。
                let fileURL: URL
                if let record = store.current.playlists.first(where: { $0.id == operation.playlistId }) {
                    fileURL = playlistFileURL(for: record)
                } else {
                    fileURL = playlistsDirectory().appendingPathComponent(operation.fileName, isDirectory: false)
                }
                do {
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        try FileManager.default.removeItem(at: fileURL)
                    }
                    try store.mutate { state in
                        state.playlists.removeAll { $0.id == operation.playlistId }
                        state.pendingOperations.removeAll { $0.id == operation.id }
                    }
                    report.append("已完成上次未完成的删除：\(operation.details)")
                } catch {
                    report.append("上次未完成的删除仍然失败：\(operation.details)（\(error.localizedDescription)）")
                }
            case .touchPlaylist:
                do {
                    try store.mutate { state in
                        state.pendingOperations.removeAll { $0.id == operation.id }
                        guard let position = state.playlists.firstIndex(where: { $0.id == operation.playlistId }) else { return }
                        state.playlists[position].updatedAt = Date().timeIntervalSince1970
                    }
                    report.append("已补齐上次未完成的歌单更新：\(operation.details)")
                } catch {
                    report.append("上次未完成的歌单更新仍然失败：\(operation.details)（\(error.localizedDescription)）")
                }
            }
        }
        return report
    }
}

/// 本地资料库错误。
public enum LocalLibraryError: Error, CustomStringConvertible {
    case invalidTitle(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .invalidTitle(let message): return message
        case .notFound(let message): return message
        }
    }
}

extension LocalLibrary {
    /// 统一的错误描述（界面提示用）。
    static func describe(_ error: Error) -> String {
        if let libraryError = error as? LocalLibraryError { return libraryError.description }
        if let storeError = error as? NativeStore.StoreError { return storeError.description }
        if let indexError = error as? LibraryIndex.IndexError { return indexError.description }
        if let playlistError = error as? PlaylistFile.PlaylistError { return playlistError.description }
        return error.localizedDescription
    }
}
