import Foundation
import CryptoKit

#if canImport(Darwin)
import Darwin
#endif

/// 原子落盘失败的原因。
public enum AtomicFileError: Error, CustomStringConvertible {
    case parentDirectoryFailed(String)
    case temporaryFileFailed(String)
    case writeFailed(String)
    case syncFailed(String)
    case symlinkRefused(String)
    case notRegularFile(String)
    case replaceFailed(String)

    public var description: String {
        switch self {
        case .parentDirectoryFailed(let m): return "创建父目录失败：\(m)"
        case .temporaryFileFailed(let m): return "创建临时文件失败：\(m)"
        case .writeFailed(let m): return "写入失败：\(m)"
        case .syncFailed(let m): return "同步失败：\(m)"
        case .symlinkRefused(let m): return "拒绝替换符号链接：\(m)"
        case .notRegularFile(let m): return "目标不是普通文件：\(m)"
        case .replaceFailed(let m): return "原子替换失败：\(m)"
        }
    }
}

/// 磁盘文件指纹。
///
/// 用 **内容摘要（SHA-256）+ inode + 设备号 + 大小 + mtime**，
/// 而不是「mtime + 大小」：外部工具原地改写文件后回写时间戳时，
/// 「同大小 + 同 mtime」的替换必须仍能被检出（Rust 侧 E1-4 同理）。
public enum FileFingerprint: Equatable {
    case missing
    case present(
        size: Int,
        sha256: String,
        inode: UInt64,
        device: UInt64,
        modifiedAt: Double,
        permissions: UInt16
    )
    case unreadable(String)

    /// 文件是否存在（存在且可读）。
    public var exists: Bool {
        if case .present = self { return true }
        return false
    }

    /// 权限位（仅普通文件有意义）。
    public var permissions: UInt16? {
        if case .present(_, _, _, _, _, let mode) = self { return mode }
        return nil
    }

    /// 采集指纹。**内容与指纹来自同一次打开**（同一快照，见 `FileReader.snapshot`）。
    public static func capture(_ url: URL) -> FileFingerprint {
        FileReader.snapshot(url).fingerprint
    }

    /// 由「本次提交的字节」+「同一个 fd 的 fstat」构造指纹。
    ///
    /// 这是 **提交指纹** 的唯一来源：提交后 **不得** 再回到路径上重新采集，
    /// 否则外部在 rename 之后写入的内容会被吸收进基线，
    /// 下一次保存就会静默覆盖外部改动。
    static func of(data: Data, stat info: stat) -> FileFingerprint {
        let digest = FileFingerprint.digest(of: data)
        return .present(
            size: data.count,
            sha256: digest,
            inode: UInt64(info.st_ino),
            device: UInt64(info.st_dev),
            modifiedAt: FileFingerprint.modifiedAt(info),
            permissions: UInt16(info.st_mode & 0o7777)
        )
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func modifiedAt(_ info: stat) -> Double {
        Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }
}

/// 单次打开读到的文件快照。
///
/// **内容与指纹必须来自同一个 fd**：先 `fstat` 再把同一个 fd 读干净，
/// 中间不重新按路径打开，因此不会出现「指纹是旧内容、内容是新内容」的错配。
public struct FileSnapshot {
    public let fingerprint: FileFingerprint
    /// 文件内容（读取失败时为 nil）。
    public let contents: Data?
    /// 读取失败原因（`fingerprint` 为 `.unreadable` 时非空）。
    public let issue: String?

    public init(fingerprint: FileFingerprint, contents: Data?, issue: String?) {
        self.fingerprint = fingerprint
        self.contents = contents
        self.issue = issue
    }

    /// 文件不存在。
    public static let missing = FileSnapshot(fingerprint: .missing, contents: nil, issue: nil)
}

/// 一次打开、一次读全的文件读取器。
public enum FileReader {
    /// 打开文件并一次性读完：**内容与指纹来自同一 fd 的同一快照**。
    ///
    /// - 不存在 → `.missing`；
    /// - 打不开 / 读不完 / 不是普通文件 → `.unreadable`；
    /// - 成功 → `.present`（内容摘要就是这批字节的摘要）。
    ///
    /// **必须带 `O_NONBLOCK`**：否则打开 FIFO（命名管道）会一直阻塞到有写端，
    /// 读取一个「不是文件」的路径就可能把调用方永久挂住。
    /// 打开之后再用 `fstat` 判断是不是普通文件，不是就明确拒绝。
    public static func snapshot(_ url: URL) -> FileSnapshot {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { return .missing }
            let reason = String(cString: strerror(errno))
            return FileSnapshot(
                fingerprint: .unreadable(reason),
                contents: nil,
                issue: reason
            )
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let reason = String(cString: strerror(errno))
            return FileSnapshot(fingerprint: .unreadable(reason), contents: nil, issue: reason)
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFDIR {
            return FileSnapshot(fingerprint: .unreadable("目标是目录"), contents: nil, issue: "目标是目录")
        }
        if type != S_IFREG {
            // FIFO / socket / 设备：内容没有意义，直接拒绝（不阻塞、不读取）。
            return FileSnapshot(
                fingerprint: .unreadable("目标不是普通文件"),
                contents: nil,
                issue: "目标不是普通文件"
            )
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return read(descriptor, base, raw.count)
            }
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                continue
            }
            if count == 0 { break }                    // EOF
            if errno == EINTR { continue }
            let reason = String(cString: strerror(errno))
            return FileSnapshot(fingerprint: .unreadable(reason), contents: nil, issue: reason)
        }

        let fingerprint = FileFingerprint.of(data: buffer, stat: info)
        return FileSnapshot(fingerprint: fingerprint, contents: buffer, issue: nil)
    }
}

/// 一次原子提交的结果。
public struct AtomicFileCommit {
    /// 被 `rename` 消耗的临时文件路径（仅供诊断）。
    public let temporaryURL: URL
    /// 本次提交产生的指纹（提交字节 + 同一临时 fd 的 fstat）。
    public let fingerprint: FileFingerprint
}

/// 原子写入工具。
///
/// 规则（与 Rust 侧 session / dlq 落盘语义一致）：
/// - 临时文件与目标 **同目录**，唯一名字，`O_CREAT|O_EXCL`（绝不覆盖他人文件）；
/// - 临时文件先以 0600 建立，写完再 `fchmod` 成目标权限（避免半成品被他人读到）；
/// - 写完 `fsync`，再 `rename` 原子替换，最后 `fsync` 目录；
/// - 目标是 **符号链接** 或非普通文件 → 明确拒绝替换；
/// - 任何失败都不动原文件，临时文件被清理（失败回滚）；
/// - **返回本次提交的指纹**：调用方据此更新基线，**不得** 再按路径重新采集。
public enum AtomicFile {
    /// 唯一临时文件名（同目录）。
    public static func temporaryURL(inDirectory directory: URL, prefix: String = ".alger-tmp") -> URL {
        directory.appendingPathComponent(
            "\(prefix)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            isDirectory: false
        )
    }

    /// 把 `data` 原子写入 `url`。
    ///
    /// - Parameters:
    ///   - permissions: 新建文件时的权限（已存在文件默认保留原权限）。
    ///   - preserveExistingPermissions: 目标已存在时是否沿用其权限位。
    /// - Returns: 本次提交的指纹（由提交字节与 **同一临时 fd 的 fstat** 组成）。
    @discardableResult
    public static func writeContents(
        _ data: Data,
        to url: URL,
        permissions: Int = 0o600,
        preserveExistingPermissions: Bool = true
    ) throws -> AtomicFileCommit {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AtomicFileError.parentDirectoryFailed(error.localizedDescription)
        }

        // 目标检查：符号链接 / 非普通文件 → 拒绝替换（绝不替换符号链接）。
        var target = stat()
        if lstat(url.path, &target) == 0 {
            let type = target.st_mode & S_IFMT
            if type == S_IFLNK {
                throw AtomicFileError.symlinkRefused(url.path)
            }
            if type != S_IFREG {
                throw AtomicFileError.notRegularFile(url.path)
            }
        }

        // 最终权限：已存在则沿用，否则用调用方给定的值。
        var mode = mode_t(permissions & 0o7777)
        if preserveExistingPermissions, target.st_mode & S_IFMT == S_IFREG {
            mode = mode_t(target.st_mode & 0o7777)
        }

        let temp = temporaryURL(inDirectory: directory)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else {
            throw AtomicFileError.temporaryFileFailed(String(cString: strerror(errno)))
        }
        var closed = false
        defer {
            if !closed { close(fd) }
            if fm.fileExists(atPath: temp.path) {
                try? fm.removeItem(at: temp)
            }
        }

        try writeAll(fd: fd, data: data)
        if fchmod(fd, mode) != 0 {
            throw AtomicFileError.writeFailed(String(cString: strerror(errno)))
        }
        if fsync(fd) != 0 {
            throw AtomicFileError.syncFailed(String(cString: strerror(errno)))
        }

        // 提交指纹：**同一个 fd** 的 fstat + 本次写入的字节。
        // rename 之后文件仍在同一个 inode 上，因此这份指纹就是路径上文件的样子，
        // 但它 **不是** 「重新采集路径」的结果 → 外部的后续改写不会被吸收。
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw AtomicFileError.syncFailed(String(cString: strerror(errno)))
        }
        let fingerprint = FileFingerprint.of(data: data, stat: info)

        close(fd)
        closed = true

        if rename(temp.path, url.path) != 0 {
            throw AtomicFileError.replaceFailed(String(cString: strerror(errno)))
        }

        // 目录 fsync：让 rename 本身落盘。
        let dirFD = open(directory.path, O_RDONLY)
        if dirFD >= 0 {
            _ = fsync(dirFD)
            close(dirFD)
        }
        return AtomicFileCommit(temporaryURL: temp, fingerprint: fingerprint)
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AtomicFileError.writeFailed(String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }

    /// 用另一个文件的内容 **原子替换** 目标文件（**流式**，不把整个文件读进内存）。
    ///
    /// 语义：
    /// - 临时文件与目标 **同目录**（保证 `rename` 不跨文件系统）；
    /// - 先把源文件内容 **完整写入** 临时文件并 `fsync`，再 `rename` 原子替换；
    /// - 目标是符号链接 / 非普通文件 → 明确拒绝；
    /// - **任何失败都不动原文件**（临时文件被清理）。
    ///
    /// 用于「下载到更好的版本 → 原地替换旧文件」：
    /// 路径不变 → **索引与歌单引用天然一致**。
    public static func replaceFile(
        at url: URL,
        withContentsOf source: URL,
        permissions: Int = 0o644,
        preserveExistingPermissions: Bool = true
    ) throws -> AtomicFileCommit {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AtomicFileError.parentDirectoryFailed(error.localizedDescription)
        }

        // 源文件必须是可读的普通文件。
        let sourceFD = open(source.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard sourceFD >= 0 else {
            throw AtomicFileError.writeFailed("无法读取源文件：\(String(cString: strerror(errno)))")
        }
        defer { close(sourceFD) }
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0 else {
            throw AtomicFileError.writeFailed("无法读取源文件属性：\(String(cString: strerror(errno)))")
        }
        guard sourceInfo.st_mode & S_IFMT == S_IFREG else {
            throw AtomicFileError.notRegularFile(source.path)
        }

        // 目标检查：符号链接 / 非普通文件 → 拒绝替换。
        var target = stat()
        if lstat(url.path, &target) == 0 {
            let type = target.st_mode & S_IFMT
            if type == S_IFLNK {
                throw AtomicFileError.symlinkRefused(url.path)
            }
            if type != S_IFREG {
                throw AtomicFileError.notRegularFile(url.path)
            }
        }

        var mode = mode_t(permissions & 0o7777)
        if preserveExistingPermissions, target.st_mode & S_IFMT == S_IFREG {
            mode = mode_t(target.st_mode & 0o7777)
        }

        let temp = temporaryURL(inDirectory: directory)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else {
            throw AtomicFileError.temporaryFileFailed(String(cString: strerror(errno)))
        }
        var closed = false
        defer {
            if !closed { close(fd) }
            if fm.fileExists(atPath: temp.path) {
                try? fm.removeItem(at: temp)
            }
        }

        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var digest = SHA256()
        var written = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(sourceFD, base, raw.count)
            }
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                digest.update(data: chunk)
                try writeAll(fd: fd, data: chunk)
                written += count
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw AtomicFileError.writeFailed(String(cString: strerror(errno)))
        }

        if fchmod(fd, mode) != 0 {
            throw AtomicFileError.writeFailed(String(cString: strerror(errno)))
        }
        if fsync(fd) != 0 {
            throw AtomicFileError.syncFailed(String(cString: strerror(errno)))
        }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw AtomicFileError.syncFailed(String(cString: strerror(errno)))
        }
        // 提交指纹：本次写入的字节摘要 + 同一个 fd 的 fstat。
        let committed = FileFingerprint.present(
            size: written,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            inode: UInt64(info.st_ino),
            device: UInt64(info.st_dev),
            modifiedAt: FileFingerprint.modifiedAt(info),
            permissions: UInt16(info.st_mode & 0o7777)
        )

        close(fd)
        closed = true

        if rename(temp.path, url.path) != 0 {
            throw AtomicFileError.replaceFailed(String(cString: strerror(errno)))
        }

        let dirFD = open(directory.path, O_RDONLY)
        if dirFD >= 0 {
            _ = fsync(dirFD)
            close(dirFD)
        }
        return AtomicFileCommit(temporaryURL: temp, fingerprint: committed)
    }
}
