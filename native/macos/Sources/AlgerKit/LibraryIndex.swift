import Foundation

/// 本地曲库的一条索引记录。
public struct TrackRecord: Codable, Equatable, Identifiable {
    /// 稳定标识（= 文件路径）。
    public var id: String { path }
    public var path: String
    /// 网易云歌曲 ID（标签或下载关联写入，0 = 未知）。
    public var neteaseId: Int64
    public var title: String
    public var artist: String
    public var album: String
    public var durationMs: UInt64
    public var format: String
    public var size: UInt64
    public var modifiedAt: Double

    public init(
        path: String,
        neteaseId: Int64 = 0,
        title: String = "",
        artist: String = "",
        album: String = "",
        durationMs: UInt64 = 0,
        format: String = "",
        size: UInt64 = 0,
        modifiedAt: Double = 0
    ) {
        self.path = path
        self.neteaseId = neteaseId
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.format = format
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

// MARK: - 展示名（缺失标签的统一占位）

extension TrackRecord {
    /// 缺失标签时的统一占位文案（艺人 / 专辑）。
    ///
    /// **全库统一**：分组、列表、详情都用它，避免「未知艺人」「未识别」
    /// 之类的说法在同一个界面里混着出现。
    public static let unrecognizedPlaceholder = "Unrecognized"

    /// 展示用标题。
    ///
    /// - 有标签 → 用标签；
    /// - 旧索引里 **把绝对路径写成了标题** → 规范化成文件名（去扩展名）；
    /// - 没有标签 → 用 **文件名去扩展名**（绝对路径也一样：只取最后一段）。
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // 标题其实是一个路径 → 只显示文件名。
            if TrackRecord.looksLikePath(trimmed) {
                return TrackRecord.basenameWithoutExtension(path: trimmed)
            }
            return trimmed
        }
        return TrackRecord.basenameWithoutExtension(path: path)
    }

    /// 文本是否像一个 **文件路径**（绝对路径或 `file://` URL）。
    public static func looksLikePath(_ text: String) -> Bool {
        if text.hasPrefix("/") { return true }
        return text.lowercased().hasPrefix("file://")
    }

    /// 展示用艺人（缺失时为 `Unrecognized`）。
    public var displayArtist: String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.unrecognizedPlaceholder : trimmed
    }

    /// 展示用专辑（缺失时为 `Unrecognized`）。
    public var displayAlbum: String {
        let trimmed = album.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.unrecognizedPlaceholder : trimmed
    }

    /// 从（可能是绝对路径的）文件路径取 **不含扩展名** 的文件名。
    ///
    /// - `/Music/周杰伦 - 晴天.mp3` → `周杰伦 - 晴天`
    /// - `晴天.mp3` → `晴天`
    /// - 路径为空 → 空串（不编造名字）。
    public static func basenameWithoutExtension(path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // `file://` URL → 先转成路径再取文件名。
        if trimmed.lowercased().hasPrefix("file://") {
            trimmed = URL(string: trimmed)?.path ?? trimmed
        }
        var name = (trimmed as NSString).lastPathComponent
        // 末尾多余的斜杠（目录路径）不应被当成文件名的一部分。
        while name.count > 1, name.hasSuffix("/") {
            name = String(name.dropLast())
        }
        guard !name.isEmpty, name != "/" else { return "" }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty {
            name = (name as NSString).deletingPathExtension
        }
        return name
    }
}

/// 持久文件索引（`library/index.json`）。
///
/// 数据规则（E1）：
/// - **三种载入状态严格区分**：
///   - 不存在 → 空索引，可写；
///   - 损坏（JSON 解析失败）→ 保留原文件、拒绝写入（保护用户数据）；
///   - 读失败（权限 / IO 错误）→ 同样拒绝写入，**绝不**当成「不存在」而覆盖原文件；
/// - **事务语义**：先落盘成功、再发布内存。写失败时内存与磁盘都不变；
/// - **串行**：所有修改经同一把锁，读改写不会丢更新；
/// - **跨进程写事务**：写入期间持 **协作式 flock**（`<index>.lock`），
///   锁覆盖「检查基线 → 原子替换提交」，两个协作进程不会互相 rename 丢更新；
/// - **外部修改检测**：保存前比对磁盘指纹（内容摘要），被外部改过就报冲突，绝不覆盖；
/// - **基线只来自本次提交**：保存成功后基线 = 本次提交字节 + 同一临时 fd 的 fstat，
///   **不重新采集路径** → 外部在提交之后的改写不会被吸收进基线（下一次保存会报冲突）；
/// - **符号链接不替换**；
/// - 索引只存路径与元信息快照，**不缓存凭证**。
public final class LibraryIndex {
    /// 索引错误。
    public enum IndexError: Error, CustomStringConvertible {
        /// 文件损坏（解析失败）。
        case corrupt(String)
        /// 文件读不出来（权限 / IO）。
        case unreadable(String)
        /// 写入失败（原文件未改动）。
        case writeFailed(String)
        /// 与磁盘现状冲突（被外部改过）。
        case conflict(String)
        /// 拒绝写入（保护原文件 / 拒绝替换符号链接）。
        case refused(String)
        /// 另一个进程正持有写锁（有界等待超时）。
        case locked(String)

        public var description: String {
            switch self {
            case .corrupt(let message): return "索引损坏：\(message)"
            case .unreadable(let message): return "索引无法读取：\(message)"
            case .writeFailed(let message): return "索引写入失败：\(message)"
            case .conflict(let message): return "索引冲突：\(message)"
            case .refused(let message): return "索引拒绝写入：\(message)"
            case .locked(let message): return "索引正被其它进程写入：\(message)"
            }
        }
    }

    /// 载入状态。
    public enum LoadState: Equatable {
        /// 文件不存在（首次运行）。
        case missing
        /// 正常载入。
        case loaded
        /// 文件损坏：保留原文件、拒绝写入。
        case corrupt(String)
        /// 文件读不出来：保留原文件、拒绝写入。
        case unreadable(String)

        /// 是否允许写入。
        public var isWritable: Bool {
            switch self {
            case .missing, .loaded: return true
            case .corrupt, .unreadable: return false
            }
        }
    }

    public let fileURL: URL

    /// 载入状态。
    public private(set) var loadState: LoadState

    /// 载入问题描述（损坏 / 读失败时非空）。
    public private(set) var loadIssue: String?

    /// 等待跨进程写锁的上限（秒）。
    public let lockTimeout: TimeInterval

    private let lock = NSLock()
    private var state: [TrackRecord] = []
    /// 载入时的磁盘指纹；保存前必须与当前指纹一致。
    private var baseline: FileFingerprint = .missing

    /// 测试钩子：在 **提交（rename）之后、基线更新之前** 触发一次回调。
    ///
    /// 用来确定性地复现「外部进程在我们提交之后立刻改写文件」的竞态：
    /// 旧实现会在这个窗口里重新采集路径，把外部改写吸收进基线。
    var afterCommitHook: (() -> Void)?

    /// 当前基线指纹（测试用：必须描述「本实例读入 / 提交的那份字节」，
    /// 而不是提交之后重新采集的路径指纹）。
    var currentBaseline: FileFingerprint {
        lock.lock()
        defer { lock.unlock() }
        return baseline
    }

    public init(fileURL: URL, lockTimeout: TimeInterval = 5) {
        self.fileURL = fileURL
        self.lockTimeout = lockTimeout
        let loaded = LibraryIndex.read(fileURL: fileURL)
        self.loadState = loaded.state
        self.state = loaded.tracks
        self.baseline = loaded.fingerprint
        self.loadIssue = loaded.issue
    }

    // MARK: - 读取

    /// 当前索引内容（快照）。
    public var tracks: [TrackRecord] {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func track(path: String) -> TrackRecord? {
        lock.lock()
        defer { lock.unlock() }
        return state.first { $0.path == path }
    }

    /// 按来源 ID 精确关联（下载来源关联的主查询）。
    public func track(neteaseId: Int64) -> TrackRecord? {
        guard neteaseId > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return state.first { $0.neteaseId == neteaseId }
    }

    /// 重新载入磁盘内容（用户在外部修好损坏文件后调用）。
    @discardableResult
    public func reload() -> LoadState {
        lock.lock()
        defer { lock.unlock() }
        let loaded = LibraryIndex.read(fileURL: fileURL)
        loadState = loaded.state
        state = loaded.tracks
        baseline = loaded.fingerprint
        loadIssue = loaded.issue
        return loadState
    }

    // MARK: - 修改（事务式）

    /// 事务式修改：在副本上执行闭包，**落盘成功后才发布到内存**。
    ///
    /// - Throws: 载入有问题、磁盘被外部改过、锁被占用或写入失败时抛出，内存与磁盘都保持原样。
    public func mutate(_ body: (inout [TrackRecord]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureWritableLocked()
        var candidate = state
        body(&candidate)
        let committed = try persistLocked(candidate)
        // 提交之后、基线更新之前的窗口（测试钩子）。
        afterCommitHook?()
        state = candidate
        // 基线 = 本次提交的指纹，**不再重新采集路径**。
        baseline = committed
    }

    /// 增或改（按路径）。标签变化不改路径，直接 upsert。
    public func upsert(_ record: TrackRecord) throws {
        try mutate { tracks in
            if let index = tracks.firstIndex(where: { $0.path == record.path }) {
                tracks[index] = record
            } else {
                tracks.append(record)
            }
        }
    }

    /// 文件已不存在 / 主动移出曲库时移除（**不删除音频文件**）。
    @discardableResult
    public func remove(path: String) throws -> Bool {
        var removed = false
        try mutate { tracks in
            let before = tracks.count
            tracks.removeAll { $0.path == path }
            removed = tracks.count != before
        }
        return removed
    }

    /// 把当前内存内容落盘（与外部修改冲突时报错）。
    public func save() throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureWritableLocked()
        let committed = try persistLocked(state)
        afterCommitHook?()
        // 基线 = 本次提交的指纹，**不再重新采集路径**。
        baseline = committed
    }

    // MARK: - 内部

    private func ensureWritableLocked() throws {
        switch loadState {
        case .missing, .loaded:
            return
        case .corrupt(let reason):
            throw IndexError.refused("索引已损坏，保留原文件并拒绝写入：\(reason)")
        case .unreadable(let reason):
            throw IndexError.refused("索引无法读取，保留原文件并拒绝写入：\(reason)")
        }
    }

    /// 落盘（**全程持有跨进程写锁**）：检查基线 → 写临时文件 → 原子替换。
    ///
    /// - Returns: 本次提交的指纹（调用方用它更新基线）。
    private func persistLocked(_ candidate: [TrackRecord]) throws -> FileFingerprint {
        try ensureDirectoryExists()

        // 协作式写锁：覆盖「检查基线 → 替换提交」全过程。
        let lockURL = CooperativeFileLock.lockURL(for: fileURL)
        let fileLock: CooperativeFileLock
        do {
            fileLock = try CooperativeFileLock.acquire(
                at: lockURL,
                timeout: lockTimeout,
                exclusive: true
            )
        } catch let error as CooperativeFileLock.LockError {
            switch error {
            case .timeout:
                throw IndexError.locked("\(fileURL.lastPathComponent) 正被其它进程写入")
            case .symlinkRefused:
                throw IndexError.refused("锁文件是符号链接，已拒绝：\(lockURL.path)")
            case .notRegularFile:
                throw IndexError.refused("锁文件不是普通文件，已拒绝：\(lockURL.path)")
            case .openFailed(let message):
                throw IndexError.writeFailed("无法获取写锁：\(message)")
            }
        }
        defer { fileLock.release() }

        let current = FileFingerprint.capture(fileURL)
        if current != baseline {
            throw IndexError.conflict(
                "\(fileURL.lastPathComponent) 已被外部创建 / 删除 / 修改，已取消写入以避免覆盖其更改"
            )
        }
        let data: Data
        do {
            data = try JSONEncoder.algerPretty.encode(candidate)
        } catch {
            throw IndexError.writeFailed("索引序列化失败：\(error.localizedDescription)")
        }
        do {
            let commit = try AtomicFile.writeContents(data, to: fileURL, permissions: 0o600)
            return commit.fingerprint
        } catch let error as AtomicFileError {
            switch error {
            case .symlinkRefused:
                throw IndexError.refused("索引路径是符号链接，已拒绝替换：\(fileURL.path)")
            default:
                throw IndexError.writeFailed("原文件未改动：\(error.description)")
            }
        }
    }

    private func ensureDirectoryExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw IndexError.writeFailed("创建父目录失败：\(error.localizedDescription)")
        }
    }

    private static func read(
        fileURL: URL
    ) -> (state: LoadState, tracks: [TrackRecord], fingerprint: FileFingerprint, issue: String?) {
        // 载入时尽力参与共享锁（锁文件不存在就不创建；拿不到也继续：
        // 原子替换保证读到的一定是完整快照）。
        withReadLock(fileURL: fileURL) {
            // **内容与指纹来自同一次打开**（同一快照），不会出现指纹与内容错配。
            let snapshot = FileReader.snapshot(fileURL)
            switch snapshot.fingerprint {
            case .missing:
                return (.missing, [], .missing, nil)
            case .unreadable(let reason):
                return (
                    .unreadable(reason),
                    [],
                    snapshot.fingerprint,
                    "索引无法读取（\(reason)），已保留原文件并拒绝写入"
                )
            case .present:
                guard let data = snapshot.contents else {
                    return (
                        .unreadable("无法读取索引内容"),
                        [],
                        snapshot.fingerprint,
                        "索引无法读取，已保留原文件并拒绝写入"
                    )
                }
                do {
                    let tracks = try JSONDecoder().decode([TrackRecord].self, from: data)
                    return (.loaded, tracks, snapshot.fingerprint, nil)
                } catch {
                    // 损坏：保留原文件（不删、不改、不覆盖），拒绝写入。
                    return (
                        .corrupt(error.localizedDescription),
                        [],
                        snapshot.fingerprint,
                        "索引解析失败（\(error.localizedDescription)）；已保留原文件并拒绝写入"
                    )
                }
            }
        }
    }

    /// 载入时的共享锁（尽力而为）。
    private static func withReadLock<T>(fileURL: URL, _ body: () -> T) -> T {
        let lockURL = CooperativeFileLock.lockURL(for: fileURL)
        var info = stat()
        guard lstat(lockURL.path, &info) == 0 else { return body() }
        guard let lock = try? CooperativeFileLock.tryAcquire(at: lockURL, exclusive: false) else {
            return body()
        }
        defer { lock.release() }
        return body()
    }
}

extension JSONEncoder {
    static var algerPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
