import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// 子进程 stdin 写端：**唯一的写入者，也是唯一的关闭者**。
///
/// 设计（E1 必修 2 / 独立审查约束）：
/// - **单一所有权**：写端 fd 由本类 **独占**——它来自我们自己 `pipe(2)` 出来的原始 fd，
///   **没有任何 Foundation `Pipe` / `FileHandle` 引用它**（因此不存在
///   「FileHandle 析构时再 close 一次已被系统复用的 fd 号」这种误关），
///   `close(fd)` 只在写队列上发生且 **只发生一次**；
/// - **非阻塞有界**：写端是 `O_NONBLOCK`，写入用 `poll` 短轮询 + 截止时间，
///   管道背压时在截止时间（或关闭取消）后放弃，**writer 一定会退出**；
/// - **关闭可打断**：进入关闭流程后在途写立即放弃，队列不会堵在一次背压写上；
/// - **终态后拒绝排队**：终态之后排队的写入在 **碰 fd 之前** 就被拒绝；
/// - **不改全局信号**：断管道靠 fd 级 `F_SETNOSIGPIPE`（返回 `EPIPE`），
///   不改进程级信号处置，也不影响其它 fd。
final class StdinWriter {
    /// 写入失败的原因。
    enum ChannelError: Error, CustomStringConvertible {
        /// 写端已关闭 / 正在关闭（不会再碰 fd）。
        case closed(String)
        /// 写入本身失败（断管道、超时等）。
        case failed(String)

        var description: String {
            switch self {
            case .closed(let message): return "stdin 写端已关闭：\(message)"
            case .failed(let message): return "stdin 写入失败：\(message)"
            }
        }
    }

    /// 写端 fd（测试可见）。**关闭之后不得再被使用**。
    let descriptor: Int32

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let stateLock = NSLock()
    /// 关闭闸门：拒绝新的普通写入。
    private var draining = false
    /// fd 已关闭：任何写入都不得再碰 fd。
    private var closed = false
    /// 在途写的取消标志（关闭时置位）。
    private var abortRequested = false

    init(descriptor: Int32, label: String = "alger.bridge.client.stdin") throws {
        // 非阻塞：写永远不会因为管道满而无限期卡住。
        // **失败必须显式报错**：静默退回阻塞写会让 writer 挂死（违反「有界」）。
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            throw ChannelError.failed("无法读取 fd 标志（errno \(errno)）")
        }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw ChannelError.failed("设置 O_NONBLOCK 失败（errno \(errno)）")
        }
        // 断管道时写端返回 EPIPE，而不是给整个进程发 SIGPIPE（signal 13）。
        // 只作用于这一个 fd，不改全局信号处置。同样不允许静默失败。
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) >= 0 else {
            throw ChannelError.failed("设置 F_SETNOSIGPIPE 失败（errno \(errno)）")
        }
        self.descriptor = descriptor
        self.queue = DispatchQueue(label: label)
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    /// 当前是否正在关闭（测试可见）。
    var isDraining: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return draining
    }

    /// 写端是否已经关闭。
    var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    /// 排队写入（串行；有界）。
    ///
    /// - Parameters:
    ///   - data: 要写入的字节（协议行）。
    ///   - timeout: 这次写入的截止时间（秒）；超时按背压失败处理。
    ///   - completion: 完成回调（在写队列上触发；失败时带错误）。
    func enqueueWrite(_ data: Data, timeout: TimeInterval, completion: ((Error?) -> Void)? = nil) {
        queue.async { [self] in
            var failure: Error?
            do {
                try writeOnQueue(data, timeout: timeout, allowDuringDrain: false)
            } catch {
                failure = error
            }
            completion?(failure)
        }
    }

    /// 写关闭请求：允许在「正在关闭」状态下写入（普通写入此时已被拒绝）。
    ///
    /// 等待有上界：写队列若卡住也不能拖死关闭流程。
    @discardableResult
    func writeDuringDrain(_ data: Data, timeout: TimeInterval) -> Error? {
        let bounded = StdinWriter.sanitize(timeout)
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        queue.async { [self] in
            do {
                try writeOnQueue(data, timeout: bounded, allowDuringDrain: true)
            } catch {
                failure = error
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + bounded + 1) == .success {
            return failure
        }
        return ChannelError.failed("写入超时（等待 \(bounded) 秒）")
    }

    /// 关闭闸门：拒绝新的普通写入，并要求在途写入尽快放弃。
    func beginDraining() {
        stateLock.lock()
        draining = true
        abortRequested = true
        stateLock.unlock()
    }

    /// 关闭写端（**唯一关闭者**：写队列自己）。
    ///
    /// 关闭动作排在所有已排队写入之后，因此：
    /// - 不会有写在 fd 关闭之后才发起；
    /// - 不会有写正在 fd 上时另一个线程把它关掉；
    /// - 关闭之后所有写入都在 **碰 fd 之前** 被拒绝。
    ///
    /// - Returns: 是否在超时前完成关闭。
    @discardableResult
    func close(timeout: TimeInterval) -> Bool {
        let bounded = StdinWriter.sanitize(timeout)
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [self] in
            closeDescriptorIfNeeded()
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + bounded) == .success
    }

    /// **唯一一次** 关闭 fd：加锁且幂等，因此重复关闭不会二次 `close`
    /// 一个可能已被系统复用的 fd 号。
    private func closeDescriptorIfNeeded() {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()
        // 这个 fd 只有本类持有（没有任何 FileHandle 引用它）。
        Darwin.close(descriptor)
    }

    deinit {
        // 兜底：写队列里没有待执行的块时（块会强引用 self），
        // 说明不会再有写入，此刻关闭 fd 是安全的。
        closeDescriptorIfNeeded()
    }

    // MARK: - 内部

    /// 在写队列上执行一次写入（**只有写队列能碰 fd**）。
    private func writeOnQueue(_ data: Data, timeout: TimeInterval, allowDuringDrain: Bool) throws {
        // 1) 闸门：终态 / 关闭后 **不再碰 fd**。
        stateLock.lock()
        let isClosed = closed
        let isDraining = draining
        let shouldAbort = abortRequested
        stateLock.unlock()
        if isClosed {
            throw ChannelError.closed("写端已关闭")
        }
        if isDraining && !allowDuringDrain {
            throw ChannelError.closed("客户端正在关闭，写入已取消")
        }
        if shouldAbort && !allowDuringDrain {
            throw ChannelError.closed("写入在关闭时被取消")
        }

        // 2) 非阻塞写入循环：短轮询 + 截止时间 + 关闭取消。
        let deadline = MonotonicDeadline.deadline(timeout: timeout)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var offset = 0
            while offset < raw.count {
                if !allowDuringDrain && abortRequestedNow() {
                    throw ChannelError.closed("写入在关闭时被取消")
                }
                let now = MonotonicDeadline.now()
                if now >= deadline {
                    throw ChannelError.failed("写入超时（管道背压）")
                }
                let remaining = Double(deadline - now) / 1_000_000_000

                // 等可写：最多 50ms 一片，便于及时响应取消。
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let slice = max(0.001, min(remaining, 0.05))
                let ready = poll(&pollDescriptor, 1, Int32(slice * 1000))
                if ready == 0 {
                    continue                       // 还没就绪 → 回到循环检查取消 / 截止
                }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw ChannelError.failed("等待可写失败（errno \(errno)）")
                }
                if (pollDescriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
                    throw ChannelError.failed("管道已断开")
                }
                let written = write(self.descriptor, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw ChannelError.failed(
                        "写入失败（errno \(errno)：\(String(cString: strerror(errno)))）"
                    )
                }
                offset += written
            }
        }
    }

    private func abortRequestedNow() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return abortRequested
    }

    /// 把超时秒数换算成单调时钟截止时间（纳秒）。
    ///
    /// **先验证 finite / 范围**：`UInt64(Double.nan)` 与 `UInt64(Double.infinity)`
    /// 都会触发运行时崩溃，因此这里先把非法值收敛掉。
    static func deadlineNanoseconds(timeout: TimeInterval) -> UInt64 {
        MonotonicDeadline.nanoseconds(timeout: timeout)
    }

    /// 把外部传入的超时收敛成 **有限且在范围内** 的值（NaN / inf 都不允许）。
    static func sanitize(_ timeout: TimeInterval) -> TimeInterval {
        MonotonicDeadline.sanitize(timeout)
    }
}
