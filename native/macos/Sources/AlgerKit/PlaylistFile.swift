import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// M3U8 歌单中的一条记录。
///
/// - `path`：**绝对路径**（载入时按歌单目录解析相对路径；保存时再按需转回相对路径）；
/// - `duration`：时长（秒，未知为 0）；
/// - `displayName`：显示名（保存为 `#EXTINF:` 兼容注释）。
public struct PlaylistEntry: Equatable {
    public var path: String
    public var duration: Double
    public var displayName: String

    public init(path: String, duration: Double = 0, displayName: String = "") {
        self.path = path
        self.duration = duration
        self.displayName = displayName
    }
}

/// UTF-8 M3U8 本地歌单。
///
/// 规则（讨论稿 02 / E1）：
/// - 读取支持 **UTF-8 BOM、CRLF、LF**，中文与空格 **原样保留**（不 trim 路径）；
/// - 路径按 **歌单所在目录** 解析；保存时同卷优先写相对路径（**允许 `../` 跨目录**），跨卷写绝对路径；
/// - 元信息（时长、显示名）按兼容注释 `#EXTINF:` 保存，其他播放器可直接复用；
/// - 写入采用 **同目录唯一临时文件 + fsync + 原子替换**；目标是符号链接 → 拒绝替换；
/// - 文件被外部 **创建 / 删除 / 改写** → 报冲突，**绝不静默覆盖**；
/// - **跨进程写事务**：写入期间持 **协作式 flock**（`<歌单>.lock`），
///   锁覆盖「检查基线 → 原子替换提交」，两个协作进程不会互相 rename 丢更新；
/// - **基线只来自本次提交**：保存成功后基线 = 本次提交字节 + 同一临时 fd 的 fstat，
///   **不重新采集路径** → 外部在提交之后的改写不会被吸收进基线（下一次保存会报冲突）；
/// - 从歌单移除 **只去掉引用，绝不删除音频文件**；
/// - 修改先在内存，save() 才落盘；落盘失败时原文件与内存都不变（失败回滚）。
public final class PlaylistFile {
    /// 歌单错误。
    public enum PlaylistError: Error, CustomStringConvertible {
        /// 与磁盘现状冲突（被外部创建 / 删除 / 改写）。
        case conflict(String)
        /// 写入失败（原文件未改动）。
        case writeFailed(String)
        /// 解析失败。
        case parseFailed(String)
        /// 条目非法（换行、非有限时长等）。
        case invalidEntry(String)
        /// 拒绝写入（保护原文件 / 拒绝替换符号链接）。
        case refused(String)
        /// 另一个进程正持有写锁（有界等待超时）。
        case locked(String)

        public var description: String {
            switch self {
            case .conflict(let message): return "歌单文件冲突：\(message)"
            case .writeFailed(let message): return "歌单写入失败：\(message)"
            case .parseFailed(let message): return "歌单解析失败：\(message)"
            case .invalidEntry(let message): return "歌单条目非法：\(message)"
            case .refused(let message): return "歌单拒绝写入：\(message)"
            case .locked(let message): return "歌单正被其它进程写入：\(message)"
            }
        }
    }

    public private(set) var entries: [PlaylistEntry] = []
    public let fileURL: URL

    /// 等待跨进程写锁的上限（秒）。
    public let lockTimeout: TimeInterval

    private let lock = NSLock()
    /// 载入时的磁盘指纹；保存前必须与当前指纹一致。
    private var baseline: FileFingerprint = .missing

    /// 测试钩子：在 **提交（rename）之后、基线更新之前** 触发一次回调。
    ///
    /// 用来确定性地复现「外部进程在我们提交之后立刻改写歌单」的竞态：
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
    }

    /// 歌单所在目录。
    public var directoryURL: URL { fileURL.deletingLastPathComponent() }

    // MARK: - 载入

    /// 从磁盘载入；文件不存在视为新歌单。
    ///
    /// 只有 **解析成功** 才替换内存状态；解析失败时原状态与原文件都保持不变。
    public func load() throws {
        lock.lock()
        defer { lock.unlock() }
        // 载入时尽力参与共享锁（锁文件不存在就不创建；拿不到也继续：
        // 原子替换保证读到的一定是完整快照）。
        let lockURL = CooperativeFileLock.lockURL(for: fileURL)
        var lockInfo = stat()
        let readLock: CooperativeFileLock? = lstat(lockURL.path, &lockInfo) == 0
            ? (try? CooperativeFileLock.tryAcquire(at: lockURL, exclusive: false))
            : nil
        defer { readLock?.release() }

        // **内容与指纹来自同一次打开**（同一快照），不会出现指纹与内容错配。
        let snapshot = FileReader.snapshot(fileURL)
        switch snapshot.fingerprint {
        case .missing:
            entries = []
            baseline = .missing
            return
        case .unreadable(let reason):
            throw PlaylistError.parseFailed("无法读取歌单文件：\(reason)")
        case .present:
            guard let data = snapshot.contents else {
                throw PlaylistError.parseFailed("无法读取歌单文件：\(fileURL.lastPathComponent)")
            }
            guard let text = PlaylistFile.decodeUTF8(data) else {
                throw PlaylistError.parseFailed("不是有效 UTF-8：\(fileURL.lastPathComponent)")
            }
            let parsed = PlaylistFile.parse(text, relativeTo: directoryURL)
            // 解析成功后才替换状态。
            entries = parsed
            baseline = snapshot.fingerprint
        }
    }

    // MARK: - 修改（只动内存，save() 才落盘）

    /// 追加一条记录。
    public func add(_ entry: PlaylistEntry) throws {
        try PlaylistFile.validate(entry)
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
    }

    /// 批量替换（用于整体编辑；逐条校验）。
    public func replaceEntries(with newEntries: [PlaylistEntry]) throws {
        for entry in newEntries { try PlaylistFile.validate(entry) }
        lock.lock()
        defer { lock.unlock() }
        entries = newEntries
    }

    /// 按路径移除（**只移除引用，不动音频文件**）。
    ///
    /// - Parameter path: 绝对路径或相对歌单目录的路径。
    @discardableResult
    public func remove(path: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let absolute = PlaylistFile.resolve(path, relativeTo: directoryURL)
        let before = entries.count
        entries.removeAll { $0.path == absolute || $0.path == path }
        return entries.count != before
    }

    /// 调整顺序（不依赖 SwiftUI 的 `Array.move`）。
    ///
    /// - Parameters:
    ///   - fromOffsets: 要移动的条目下标。
    ///   - toOffset: 目标下标（原始坐标系）。
    public func move(fromOffsets: IndexSet, toOffset: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        let indices = fromOffsets.sorted()
        guard !indices.isEmpty else { return }
        for index in indices where !entries.indices.contains(index) {
            throw PlaylistError.invalidEntry("序号越界：\(index)")
        }
        var result = entries
        let moving = indices.map { result[$0] }
        for index in indices.reversed() { result.remove(at: index) }
        let removedBefore = indices.filter { $0 < toOffset }.count
        let insertion = max(0, min(toOffset - removedBefore, result.count))
        result.insert(contentsOf: moving, at: insertion)
        entries = result
    }

    // MARK: - 保存

    /// 序列化为 M3U8 文本（相对路径按歌单位置计算）。
    public func serialized() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try serializedLocked()
    }

    /// 原子写入；磁盘文件在 load() 后被其他 App 改动过时抛冲突。
    ///
    /// 全程持有 **协作式写锁**（`<歌单>.lock`）：锁覆盖「检查基线 → 原子替换提交」，
    /// 因此两个协作进程不会同时通过检查再互相 rename（丢更新）。
    /// 保存成功后基线 = **本次提交的指纹**（不再重新采集路径）。
    public func save() throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectoryExists()

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
                throw PlaylistError.locked("\(fileURL.lastPathComponent) 正被其它进程写入")
            case .symlinkRefused:
                throw PlaylistError.refused("锁文件是符号链接，已拒绝：\(lockURL.path)")
            case .notRegularFile:
                throw PlaylistError.refused("锁文件不是普通文件，已拒绝：\(lockURL.path)")
            case .openFailed(let message):
                throw PlaylistError.writeFailed("无法获取写锁：\(message)")
            }
        }
        defer { fileLock.release() }

        let current = FileFingerprint.capture(fileURL)
        if current != baseline {
            throw PlaylistError.conflict(
                "\(fileURL.lastPathComponent) 已被外部创建 / 删除 / 修改，已取消写入以避免覆盖其更改"
            )
        }
        let text = try serializedLocked()
        let data = Data(text.utf8)
        let commit: AtomicFileCommit
        do {
            commit = try AtomicFile.writeContents(data, to: fileURL, permissions: 0o644)
        } catch let error as AtomicFileError {
            switch error {
            case .symlinkRefused:
                throw PlaylistError.refused("歌单路径是符号链接，已拒绝替换：\(fileURL.path)")
            default:
                throw PlaylistError.writeFailed("原文件未改动：\(error.description)")
            }
        }
        // 提交之后、基线更新之前的窗口（测试钩子）。
        afterCommitHook?()
        // 基线 = 本次提交的指纹，**不再重新采集路径**。
        baseline = commit.fingerprint
    }

    private func ensureDirectoryExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PlaylistError.writeFailed("创建父目录失败：\(error.localizedDescription)")
        }
    }

    private func serializedLocked() throws -> String {
        var lines = ["#EXTM3U"]
        for entry in entries {
            try PlaylistFile.validate(entry)
            if entry.duration > 0 || !entry.displayName.isEmpty {
                lines.append("#EXTINF:\(PlaylistFile.formatSeconds(entry.duration)),\(entry.displayName)")
            }
            lines.append(storedPathLocked(for: entry.path))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 路径

    /// 对外展示用绝对路径（相对条目按歌单位置展开）。
    public func resolvedURL(for entry: PlaylistEntry) -> URL {
        URL(fileURLWithPath: PlaylistFile.resolve(entry.path, relativeTo: directoryURL))
    }

    /// 存储形态：同卷优先相对（**允许 `../` 跨目录**），跨卷回退绝对路径。
    private func storedPathLocked(for path: String) -> String {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let directory = directoryURL.standardizedFileURL
        guard PlaylistFile.sameVolume(directory, target) else { return path }
        let relative = PlaylistFile.relativePath(from: directory, to: target)
        return relative.isEmpty ? path : relative
    }

    /// 两个路径是否在同一卷（用设备号判断，不用「首路径分量」这种伪判据）。
    static func sameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = deviceIdentifier(of: lhs), let right = deviceIdentifier(of: rhs) else {
            // 取不到设备号时保守处理：只有目标确实位于目录之下才写相对路径。
            let directory = lhs.standardizedFileURL.path
            let target = rhs.standardizedFileURL.path
            return target == directory || target.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
        }
        return left == right
    }

    /// 取（最近的）已存在祖先目录的设备号（`st_dev`）。
    static func deviceIdentifier(of url: URL) -> UInt64? {
        var current = url.standardizedFileURL
        while true {
            var info = stat()
            if stat(current.path, &info) == 0 { return UInt64(info.st_dev) }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    /// 计算 target 相对 base（目录）的路径（`..` + 普通分量）。
    static func relativePath(from base: URL, to target: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(baseComponents.count, targetComponents.count),
              baseComponents[common] == targetComponents[common] {
            common += 1
        }
        let ups = baseComponents.count - common
        let downs = Array(targetComponents[common...])
        if ups == 0 && downs.isEmpty { return "" }
        return (Array(repeating: "..", count: ups) + downs).joined(separator: "/")
    }

    /// 把（相对或绝对）路径解析成绝对路径。
    static func resolve(_ path: String, relativeTo directory: URL) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL.path
    }

    // MARK: - 解析 / 工具

    /// 校验条目：路径与显示名不得含换行，时长必须是有限非负数。
    static func validate(_ entry: PlaylistEntry) throws {
        if entry.path.isEmpty {
            throw PlaylistError.invalidEntry("路径为空")
        }
        if entry.path.contains("\n") || entry.path.contains("\r") {
            throw PlaylistError.invalidEntry("路径含换行，无法写入 M3U8：\(entry.path)")
        }
        if entry.displayName.contains("\n") || entry.displayName.contains("\r") {
            throw PlaylistError.invalidEntry("显示名含换行，无法写入 M3U8：\(entry.displayName)")
        }
        if !entry.duration.isFinite {
            throw PlaylistError.invalidEntry("时长必须是有限数")
        }
        if entry.duration < 0 {
            throw PlaylistError.invalidEntry("时长不能为负")
        }
    }

    /// 解码 UTF-8（允许 BOM；非法字节返回 nil）。
    static func decodeUTF8(_ data: Data) -> String? {
        var bytes = data
        if bytes.count >= 3,
           bytes[bytes.startIndex] == 0xEF,
           bytes[bytes.startIndex + 1] == 0xBB,
           bytes[bytes.startIndex + 2] == 0xBF {
            bytes = bytes.dropFirst(3)
        }
        return String(data: bytes, encoding: .utf8)
    }

    /// 解析 M3U8 文本（相对路径按 `relativeTo` 解析成绝对路径）。
    static func parse(_ raw: String, relativeTo directory: URL) -> [PlaylistEntry] {
        var result: [PlaylistEntry] = []
        var pendingExtinf: (duration: Double, name: String)?
        for rawLine in PlaylistFile.splitLines(raw) {
            // 只去掉行尾 CR，**不 trim 路径**（中文与空格必须原样保留）。
            var line = Substring(rawLine)
            if line.hasSuffix("\r") { line = line.dropLast() }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF:") {
                    let rest = line.dropFirst("#EXTINF:".count)
                    let parts = rest.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                    let durationText = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "0"
                    let parsed = Double(durationText) ?? 0
                    let name = parts.count > 1 ? String(parts[1]) : ""
                    pendingExtinf = (parsed.isFinite && parsed > 0 ? parsed : 0, name)
                }
                continue
            }
            let absolute = resolve(String(line), relativeTo: directory)
            result.append(PlaylistEntry(
                path: absolute,
                duration: pendingExtinf?.duration ?? 0,
                displayName: pendingExtinf?.name ?? ""
            ))
            pendingExtinf = nil
        }
        return result
    }

    /// 按 CRLF / LF / CR 拆行。
    ///
    /// **不能**用 `split(separator: "\n")`：Swift 里 `"\r\n"` 是 **单个 Character**
    /// （grapheme cluster），那样会把整份 CRLF 文件当成一行，中文与路径全部丢失。
    static func splitLines(_ raw: String) -> [String] {
        var lines: [String] = []
        var buffer = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in raw.unicodeScalars {
            if scalar == "\n" {
                if previousWasCarriageReturn {
                    previousWasCarriageReturn = false
                    continue            // CRLF：行已经在 CR 处结束
                }
                lines.append(String(buffer))
                buffer = String.UnicodeScalarView()
                continue
            }
            previousWasCarriageReturn = false
            if scalar == "\r" {
                lines.append(String(buffer))
                buffer = String.UnicodeScalarView()
                previousWasCarriageReturn = true
                continue
            }
            buffer.append(scalar)
        }
        if !buffer.isEmpty || lines.isEmpty {
            lines.append(String(buffer))
        }
        return lines
    }

    static func formatSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0" }
        if seconds == seconds.rounded(), abs(seconds) < 1e15 {
            return String(Int(seconds))
        }
        return String(seconds)
    }
}
