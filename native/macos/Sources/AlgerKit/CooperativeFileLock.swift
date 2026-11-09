import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// 协作式跨进程文件锁（`flock`）。
///
/// 语义（与 Rust 侧 dlq 的 `downloads.json.lock` 一致）：
/// - 锁文件与目标 **同目录**（`<目标名>.lock`），所有进程用同一条路径；
/// - **永不删除**：锁文件是常驻 sidecar（删掉会让并发进程锁到不同的 inode）；
/// - **拒绝符号链接**：`O_NOFOLLOW` + 预先 `lstat` + 打开后核对 inode/dev；
/// - **必须是普通文件**：`fstat` 校验，目录 / FIFO / 设备一律拒绝；
/// - **不截断**：只 `O_RDWR|O_CREAT`，**没有 `O_TRUNC`**（已有内容必须保持不变）；
/// - **有界等待**：单调时钟计时 + `LOCK_NB` 轮询，超过上限就失败（绝不无限期挂住调用方）；
/// - 锁 **覆盖整个事务**：从「检查基线」一直到「原子替换提交」都在锁内，
///   两个协作进程不可能同时通过检查再互相 rename（丢更新）。
///
/// 边界：**只有同样遵守这把锁的进程才会互斥**。普通播放器 / 脚本不认识这把锁，
/// 因此调用方 **必须** 继续保留「外部修改检测」（指纹比对）与冲突提示。
/// 本锁 **不是** 通用 compare-and-swap，只是协作式互斥。
public final class CooperativeFileLock {
    /// 取锁失败的原因。
    public enum LockError: Error, CustomStringConvertible {
        /// 锁文件是符号链接（拒绝跟随）。
        case symlinkRefused(String)
        /// 锁文件不是普通文件（目录 / FIFO / 设备）。
        case notRegularFile(String)
        /// 打不开锁文件。
        case openFailed(String)
        /// 有界等待超时（另一个进程还持着锁）。
        case timeout(String)

        public var description: String {
            switch self {
            case .symlinkRefused(let m): return "锁文件是符号链接，已拒绝：\(m)"
            case .notRegularFile(let m): return "锁文件不是普通文件，已拒绝：\(m)"
            case .openFailed(let m): return "打开锁文件失败：\(m)"
            case .timeout(let m): return "等待文件锁超时：\(m)"
            }
        }
    }

    /// 锁文件路径（与目标同目录，常驻 sidecar）。
    public static func lockURL(for target: URL) -> URL {
        target.deletingLastPathComponent()
            .appendingPathComponent(target.lastPathComponent + ".lock", isDirectory: false)
    }

    /// 尝试获取锁（等待上限 `timeout` 秒）。
    ///
    /// - Parameters:
    ///   - exclusive: `true` = 排他锁（写事务）；`false` = 共享锁（读）。
    ///   - timeout: 最长等待秒数（>= 0）；超时抛 `.timeout`。
    public static func acquire(
        at url: URL,
        timeout: TimeInterval,
        exclusive: Bool
    ) throws -> CooperativeFileLock {
        // 1) 预先检查：锁文件不能是符号链接。
        var pathInfo = stat()
        if lstat(url.path, &pathInfo) == 0 {
            if pathInfo.st_mode & S_IFMT == S_IFLNK {
                throw LockError.symlinkRefused(url.path)
            }
        }

        // 2) 打开锁文件：不截断、不跟随软链。
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw LockError.symlinkRefused(url.path)
            }
            throw LockError.openFailed("\(url.path)：\(String(cString: strerror(errno)))")
        }

        // 3) 打开后核对身份：fd 必须是普通文件，且与路径当前的 inode/dev 一致
        //    （避免在 open 之前路径被换掉，锁到了别人的文件上）。
        var fdInfo = stat()
        guard fstat(descriptor, &fdInfo) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw LockError.openFailed("\(url.path)：\(reason)")
        }
        guard fdInfo.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw LockError.notRegularFile(url.path)
        }
        var currentInfo = stat()
        guard lstat(url.path, &currentInfo) == 0,
              currentInfo.st_ino == fdInfo.st_ino,
              currentInfo.st_dev == fdInfo.st_dev else {
            close(descriptor)
            throw LockError.openFailed("\(url.path)：锁文件在打开期间被替换")
        }

        // 4) 取锁：单调时钟 + 非阻塞轮询（有界）。
        let mode = exclusive ? LOCK_EX : LOCK_SH
        let deadline = MonotonicDeadline.deadline(timeout: timeout)
        while true {
            if flock(descriptor, mode | LOCK_NB) == 0 {
                return CooperativeFileLock(descriptor: descriptor)
            }
            if errno == EINTR { continue }          // 被信号打断：重试
            if errno != EWOULDBLOCK {
                let reason = String(cString: strerror(errno))
                close(descriptor)
                throw LockError.openFailed("\(url.path)：\(reason)")
            }
            if MonotonicDeadline.now() >= deadline {
                close(descriptor)
                throw LockError.timeout("\(url.path)（等待 \(MonotonicDeadline.sanitize(timeout)) 秒）")
            }
            // 有界轮询：间隔很小，退出延迟低。
            CooperativeFileLock.sleep(milliseconds: 5)
        }
    }

    /// 不等待地尝试取锁（拿不到立刻失败）。
    public static func tryAcquire(
        at url: URL,
        exclusive: Bool
    ) throws -> CooperativeFileLock {
        try acquire(at: url, timeout: 0, exclusive: exclusive)
    }

    private let descriptor: Int32
    private let releaseLock = NSLock()
    private var released = false

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// 释放锁（关闭 fd 即释放 `flock`）。
    ///
    /// **只有一个所有者**（拿到锁的那个调用方）：释放动作加锁且幂等，
    /// 因此重复释放不会二次 `close` 一个可能已被系统复用的 fd 号。
    func release() {
        releaseLock.lock()
        if released {
            releaseLock.unlock()
            return
        }
        released = true
        releaseLock.unlock()
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit {
        release()
    }

    /// 可被信号打断的睡眠（EINTR 继续睡完剩下的时间）。
    private static func sleep(milliseconds: Int) {
        var remaining = milliseconds
        while remaining > 0 {
            var request = timespec(
                tv_sec: Int(remaining / 1000),
                tv_nsec: Int((remaining % 1000) * 1_000_000)
            )
            var left = timespec()
            let result = nanosleep(&request, &left)
            if result == 0 { return }
            if errno != EINTR { return }
            // EINTR：内核把剩余时间写回 left，继续睡完。
            remaining = Int(left.tv_sec) * 1000 + Int(left.tv_nsec) / 1_000_000
        }
    }
}
