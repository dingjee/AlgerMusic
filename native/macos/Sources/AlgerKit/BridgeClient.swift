import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// alger-bridge 子进程客户端（JSON 行协议）。
///
/// 协议（与 `crates/alger-bridge` 一致）：
/// - 请求：`{"id":1,"m":"net.search","p":{...}}`
/// - 响应：`{"id":1,"ok":true,"r":...}` / `{"id":1,"ok":false,"e":{"code":"...","message":"..."}}`
/// - 事件：`{"ev":"dl","p":{...}}`
///
/// 生命周期与并发约定：
/// - **单写者**：请求行全部经同一条串行写队列写入 stdin，绝不交叉；
/// - **stdin fd 单一所有者**：写与关闭都发生在写队列上，关闭之后不再有任何写入，
///   不会出现「关了又被写」或 fd 号被复用后写到别的文件；
/// - **写入有界**：写端非阻塞，写入用短轮询 + 截止时间，管道背压不会挂死 writer；
/// - **按 id 配对**：响应与请求一一对应，乱序到达也能正确配对；
/// - **恰好一次结算**：超时、取消、EOF、子进程异常退出、写入失败，
///   每个请求 **只结算一次**（先到者为准，其余忽略）；
/// - **终态拒绝新调用**：子进程结束后再调用立即失败，不会静默挂起；
/// - **事件回调在锁外**：事件在独立回调队列触发，回调里可以安全地再次调用本客户端；
/// - **shutdown 幂等、有界**：重复调用安全，总耗时受限，并且 **精确回收自己启动的那个子进程**；
/// - **不回传凭证**：Cookie 只存在于子进程的会话文件，本客户端既不读取也不打印。
public final class BridgeClient: @unchecked Sendable {

    // MARK: - 错误

    /// 桥接返回的业务错误（`e.code` / `e.message`）。
    public struct BridgeError: Error, CustomStringConvertible {
        public let code: String
        public let message: String
        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
        public var description: String { "[\(code)] \(message)" }
    }

    /// 客户端自身的错误。
    public enum ClientError: Error, CustomStringConvertible {
        /// 终态：子进程结束 / EOF / 主动关闭。
        case closed(String)
        /// 请求超时。
        case timeout(TimeInterval)
        /// 调用方取消。
        case cancelled
        /// 写入子进程失败（管道断开等）。
        case writeFailed(String)
        /// 协议错误（无法解析的行、超长行等）。
        case protocolError(String)
        /// 无法启动子进程。
        case launchFailed(String)

        public var description: String {
            switch self {
            case .closed(let message): return "桥接已结束：\(message)"
            case .timeout(let seconds): return "请求超时（\(seconds) 秒）"
            case .cancelled: return "请求已取消"
            case .writeFailed(let message): return "写入子进程失败：\(message)"
            case .protocolError(let message): return "协议错误：\(message)"
            case .launchFailed(let message): return "无法启动桥接子进程：\(message)"
            }
        }
    }

    /// 下载任务事件（桥接 `ev:"dl"`）。原始 payload 原样保留。
    public struct DownloadEvent {
        public let raw: [String: Any]
        public init(raw: [String: Any]) { self.raw = raw }
    }

    /// 客户端参数。
    public struct Configuration {
        /// 单个请求的默认超时（秒）。
        public var requestTimeout: TimeInterval = 30
        /// shutdown 等待子进程自行退出的上限（秒）。
        public var shutdownTimeout: TimeInterval = 5
        /// SIGTERM 后等待退出的上限（秒）。
        public var terminateGrace: TimeInterval = 1
        /// 单次写入 stdin 的上限（秒）；管道背压超过这个时间就判定写入失败。
        public var writeTimeout: TimeInterval = 10
        /// 单行协议数据的最大字节数（超出视为协议错误）。
        public var maxLineBytes = 8 * 1024 * 1024
        public init() {}
    }

    // MARK: - 内部状态

    private struct PendingRequest {
        var continuation: CheckedContinuation<Any, Error>
        var timeoutItem: DispatchWorkItem?
        var method: String
    }

    private enum ShutdownState: Int {
        case idle = 0
        case running = 1
        case finished = 2
    }

    /// 裸管道：父进程 **独占** 两端的 fd 所有权。
    ///
    /// 不用 Foundation 的 `Pipe`/`FileHandle`：那两者的「关闭记账」与真实 fd
    /// 状态可能不一致（被提前 `close()` 的 fd 号被系统复用后，`FileHandle`
    /// 析构会再关一次，误伤无关文件）。这里每个 fd 都有 **唯一所有者**：
    /// - 读端 → 交给读线程（线程退出时关闭）；
    /// - 写端 → 交给写队列（`StdinWriter`）或由本类在启动后关闭；
    /// - **启动失败时** 由 `deinit` 兜底关闭，绝不泄漏。
    private final class RawPipe {
        private(set) var readDescriptor: Int32
        private(set) var writeDescriptor: Int32
        private var ownsRead = true
        private var ownsWrite = true
        private let readIdentity: (inode: UInt64, device: UInt64)
        private let writeIdentity: (inode: UInt64, device: UInt64)

        static func make() throws -> RawPipe {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard pipe(&descriptors) == 0 else {
                throw ClientError.launchFailed("创建管道失败：\(String(cString: strerror(errno)))")
            }
            // 子进程 exec 后不继承父进程的这些端点（FD_CLOEXEC）。
            for descriptor in descriptors {
                let flags = fcntl(descriptor, F_GETFD)
                if flags >= 0 {
                    _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
                }
            }
            return RawPipe(readDescriptor: descriptors[0], writeDescriptor: descriptors[1])
        }

        private init(readDescriptor: Int32, writeDescriptor: Int32) {
            self.readDescriptor = readDescriptor
            self.writeDescriptor = writeDescriptor
            var info = stat()
            self.readIdentity = fstat(readDescriptor, &info) == 0
                ? (UInt64(info.st_ino), UInt64(info.st_dev))
                : (0, 0)
            self.writeIdentity = fstat(writeDescriptor, &info) == 0
                ? (UInt64(info.st_ino), UInt64(info.st_dev))
                : (0, 0)
        }

        /// 把读端的所有权交给读线程（我们不再关闭它）。
        func takeReadDescriptor() -> Int32 {
            ownsRead = false
            return readDescriptor
        }

        /// 把写端的所有权交给写队列（我们不再关闭它）。
        func takeWriteDescriptor() -> Int32 {
            ownsWrite = false
            return writeDescriptor
        }

        /// 关闭读端（带身份核对：绝不误关已被系统复用的 fd 号）。
        func closeReadEnd() {
            guard ownsRead else { return }
            ownsRead = false
            BridgeClient.closeIfOwned(descriptor: readDescriptor, identity: readIdentity)
        }

        /// 关闭写端（带身份核对：绝不误关已被系统复用的 fd 号）。
        func closeWriteEnd() {
            guard ownsWrite else { return }
            ownsWrite = false
            BridgeClient.closeIfOwned(descriptor: writeDescriptor, identity: writeIdentity)
        }

        deinit {
            closeReadEnd()
            closeWriteEnd()
        }
    }

    private let process: Process
    private let configuration: Configuration
    /// stdin 写端：**唯一的写入者 / 关闭者**。
    private let stdinWriter: StdinWriter

    /// 状态队列：所有共享状态的唯一临界区。
    private let stateQueue = DispatchQueue(label: "alger.bridge.client.state")
    /// 回调队列：事件与终止通知在此触发，**绝不在状态队列内执行用户回调**。
    private let callbackQueue = DispatchQueue(label: "alger.bridge.client.callback")
    /// 计时器队列：请求超时。
    private let timerQueue = DispatchQueue(label: "alger.bridge.client.timer", attributes: .concurrent)
    private let stateKey = DispatchSpecificKey<UInt8>()

    private var nextID: UInt64 = 1
    private var pending: [UInt64: PendingRequest] = [:]
    /// 取消先于注册到达的请求 id（等待登记的窗口）。
    private var cancelledBeforeRegistration: Set<UInt64> = []
    private var eventHandler: ((String, [String: Any]) -> Void)?
    private var eventObservers: [UUID: (String, [String: Any]) -> Void] = [:]
    private var terminationHandler: ((ClientError) -> Void)?
    private var readBuffer = Data()
    private var terminalError: ClientError?
    private var stderrTail = Data()
    private var settledCount = 0
    private var childEnvironment: [String: String]?
    /// 子进程是否 **真的** 启动过（没启动过就不能 wait/terminate）。
    private var didLaunch = false

    /// 活跃读线程计数（测试用：读线程必须能退出，不能永久等待）。
    private static let readerStateLock = NSLock()
    private static var activeReaderThreads = 0

    /// 当前活跃的读线程数（测试用）。
    static var activeReaderThreadCount: Int {
        readerStateLock.lock()
        defer { readerStateLock.unlock() }
        return activeReaderThreads
    }

    private static func enterReaderThread() {
        readerStateLock.lock()
        activeReaderThreads += 1
        readerStateLock.unlock()
    }

    private static func leaveReaderThread() {
        readerStateLock.lock()
        activeReaderThreads -= 1
        readerStateLock.unlock()
    }

    private let shutdownLock = NSLock()
    private var shutdownState: ShutdownState = .idle
    private let shutdownFinished = DispatchSemaphore(value: 0)
    private let childExitSemaphore = DispatchSemaphore(value: 0)

    // MARK: - 启动

    /// 启动桥接子进程。
    ///
    /// - Parameters:
    ///   - executableURL: `alger-bridge` 二进制路径。
    ///   - arguments: 子进程参数（例如 `["--session-path", "/abs/path/session.json"]`）。
    ///   - environment: 追加到当前环境（**保留其它变量，不改 HOME**）。
    /// - Throws: 无法启动子进程时抛出 `ClientError.launchFailed`。
    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        configuration: Configuration = Configuration()
    ) throws {
        self.configuration = configuration
        self.process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
            childEnvironment = merged
        }

        // 自己建管道：fd 的所有权完全在我们手里。
        //
        // 不用 Foundation 的 `Pipe`/`FileHandle`：那两者的「关闭记账」与真实 fd
        // 状态可能不一致（被提前 `close()` 的 fd 号被系统复用后，`FileHandle`
        // 析构会再关一次，误伤无关文件）。
        //
        // 任一步失败都会把 **已经建好的端点** 关掉（`RawPipe.deinit` 兜底），
        // 不留悬空 fd，也不留等待中的读线程。
        let stdinPipe = try RawPipe.make()
        let stdoutPipe = try RawPipe.make()
        let stderrPipe = try RawPipe.make()

        // stdin 写端：**唯一的写入者 / 关闭者**。
        // 非阻塞与 SIGPIPE 抑制必须真的生效，失败要显式报错（不能静默退回阻塞写）。
        let writer = try StdinWriter(descriptor: stdinPipe.writeDescriptor)
        self.stdinWriter = writer
        _ = stdinPipe.takeWriteDescriptor()   // 写端所有权交给写队列（我们不再关闭）

        // stdout / stderr 读端：交给读线程（线程是唯一所有者）。
        self.stdoutDescriptor = stdoutPipe.takeReadDescriptor()
        self.stderrDescriptor = stderrPipe.takeReadDescriptor()

        // 交给 Foundation 的 FileHandle 用 `closeOnDealloc: false`：
        // 关不关、什么时候关，全部由我们决定。
        process.standardInput = FileHandle(fileDescriptor: stdinPipe.readDescriptor, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: stdoutPipe.writeDescriptor, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: stderrPipe.writeDescriptor, closeOnDealloc: false)

        process.terminationHandler = { [weak self] finished in
            self?.handleChildExit(finished)
        }

        stateQueue.setSpecific(key: stateKey, value: 1)
        startReader(descriptor: stdoutDescriptor, isError: false)
        startReader(descriptor: stderrDescriptor, isError: true)

        do {
            try process.run()
            didLaunch = true
        } catch {
            // 启动失败：把端点都关掉。
            //  - stdin 写端交给写队列关闭；
            //  - stdout / stderr 写端关闭后，两个读线程会收到 EOF 并退出
            //    （**不得** 让读线程永久等待）。
            writer.close(timeout: 1)
            stdinPipe.closeReadEnd()
            stdoutPipe.closeWriteEnd()
            stderrPipe.closeWriteEnd()
            throw ClientError.launchFailed("\(executableURL.path)：\(error.localizedDescription)")
        }

        // 父进程 **不用的** 端点：留着它们父进程就成了 reader/writer：
        //   - 子进程关掉 stdin → 写不会 EPIPE（父进程还在读）；
        //   - 子进程退出 → 读不会 EOF（父进程还握着写端）。
        // 启动后带身份核对地关闭（绝不误关已被复用的 fd）。
        stdinPipe.closeReadEnd()
        stdoutPipe.closeWriteEnd()
        stderrPipe.closeWriteEnd()
    }

    /// stdout 读端（读线程独占）。
    private let stdoutDescriptor: Int32
    /// stderr 读端（读线程独占）。
    private let stderrDescriptor: Int32

    deinit {
        shutdown()
    }

    // MARK: - 公开状态

    /// 子进程是否还在运行。
    public var isRunning: Bool { process.isRunning }

    /// 子进程 pid（用于精确回收，绝不按进程名终止）。
    public var childProcessIdentifier: Int32? { process.processIdentifier }

    /// 是否已进入终态（终态后拒绝新调用）。
    public var isTerminated: Bool { syncState { terminalError != nil } }

    /// 终态原因（未终止时为 nil）。
    public var terminationReason: ClientError? { syncState { terminalError } }

    /// 子进程 stderr 的尾部（诊断用，桥接只输出进程级信息，不含凭证）。
    public var diagnostics: String {
        syncState { String(data: stderrTail, encoding: .utf8) ?? "" }
    }

    /// 当前在途请求数（测试用）。
    var pendingRequestCount: Int { syncState { pending.count } }

    /// 已结算的请求总数（测试用：每个请求 **只结算一次**）。
    var settledRequestCount: Int { syncState { settledCount } }

    /// 传给子进程的环境（测试用：确认没有改 HOME，只是追加显式参数）。
    var launchedEnvironment: [String: String]? { syncState { childEnvironment } }

    /// 当前是否运行在状态队列上（测试用：事件回调必须为 false）。
    var isOnStateQueue: Bool { DispatchQueue.getSpecific(key: stateKey) != nil }

    /// stdin 写端 fd（测试用：验证关闭后不再复用）。
    var stdinWriteDescriptor: Int32 { stdinWriter.descriptor }

    /// stdin 写端是否已经关闭（测试用）。
    var stdinWriteEndClosed: Bool { stdinWriter.isClosed }

    // MARK: - 调用

    /// 调用一个方法，等待配对响应。
    ///
    /// - Parameters:
    ///   - method: 方法名（例如 `app.hello`）。
    ///   - params: 参数对象。
    ///   - timeout: 本次请求的超时（秒）；`nil` 用配置默认值，`.infinity` 不限时。
    public func call(
        _ method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> Any {
        let id = try reserveID()
        let limit = timeout ?? configuration.requestTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                stateQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: ClientError.closed("客户端已释放"))
                        return
                    }
                    self.registerLocked(
                        id: id,
                        method: method,
                        continuation: continuation,
                        timeout: limit
                    )
                    self.enqueueWriteLocked(id: id, method: method, params: params)
                }
            }
        } onCancel: { [weak self] in
            self?.cancelRequest(id: id)
        }
    }

    /// 强类型便捷入口：要求响应是 JSON 对象。
    public func callDictionary(
        _ method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> [String: Any] {
        let value = try await call(method, params: params, timeout: timeout)
        guard let dict = value as? [String: Any] else {
            throw BridgeError(code: "Decode", message: "响应不是对象：\(type(of: value))")
        }
        return dict
    }

    /// 订阅事件（`ev` 字段值 → payload）。回调在 **状态队列之外** 触发。
    public func onEvent(_ handler: @escaping (String, [String: Any]) -> Void) {
        syncState { eventHandler = handler }
    }

    /// 订阅终止通知。回调在 **状态队列之外** 触发。
    public func onTermination(_ handler: @escaping (ClientError) -> Void) {
        syncState { terminationHandler = handler }
    }

    // MARK: - 关闭

    /// 关闭子进程。
    ///
    /// - 幂等：重复调用安全，第二次立即返回；
    /// - 有界：总耗时不超过 `shutdownTimeout + terminateGrace + 2` 秒；
    /// - 精确回收：只对自己启动的那个 pid 发送信号，不按进程名终止；
    /// - 关闭后所有在途请求都会被结算（`ClientError.closed`）。
    public func shutdown() {
        shutdownLock.lock()
        switch shutdownState {
        case .finished:
            shutdownLock.unlock()
            return
        case .running:
            shutdownLock.unlock()
            let budget = configuration.shutdownTimeout + configuration.terminateGrace + 2
            _ = shutdownFinished.wait(timeout: .now() + budget)
            return
        case .idle:
            shutdownState = .running
            shutdownLock.unlock()
        }

        performShutdown()

        shutdownLock.lock()
        shutdownState = .finished
        shutdownLock.unlock()
        shutdownFinished.signal()
    }

    private func performShutdown() {
        // 1. 进入终态：拒绝新调用 **并结算所有在途请求**。
        //    必须走 finishLocked：直接写 terminalError 会让后续 finishLocked
        //    因「已是终态」提前返回，在途请求就永远结算不了（挂死）。
        let alive = syncState { () -> Bool in
            self.finishLocked(.closed("客户端已关闭"))
            return process.isRunning
        }

        // 2. 关闭写闸门：拒绝新的写入，并让在途写入尽快放弃。
        //    写队列随后排空，关闭请求才能及时写出去。
        stdinWriter.beginDraining()

        if alive {
            // 3. 先请子进程自行退出。
            writeShutdownRequest()
            if !waitForChildExit(timeout: configuration.shutdownTimeout) {
                // 4. 兜底：只终止自己启动的精确 pid。
                if process.isRunning { process.terminate() }
                if !waitForChildExit(timeout: configuration.terminateGrace), process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = waitForChildExit(timeout: 1)
                }
            }
        }

        // 5. 回收子进程（不按名字终止其它进程）。
        //    只在子进程 **确实启动过** 时才 wait（没启动过的 Process 调用
        //    `waitUntilExit()` 会抛异常）。
        if didLaunch && !process.isRunning {
            process.waitUntilExit()
        }

        // 6. 关闭 stdin 写端：**只有写队列能关**（排在所有已排队写入之后），
        //    因此不会有写在关闭之后才发起，也不会有关闭时正在写的 fd。
        stdinWriter.close(timeout: configuration.terminateGrace + 2)
    }

    private func writeShutdownRequest() {
        let payload = Data(#"{"id":0,"m":"app.shutdown","p":{}}"#.utf8) + Data([0x0A])
        // 有界等待写队列：写队列若卡住（例如管道写满），不能拖死关闭流程。
        _ = stdinWriter.writeDuringDrain(payload, timeout: 1)
    }

    private func waitForChildExit(timeout: TimeInterval) -> Bool {
        childExitSemaphore.wait(timeout: .now() + timeout) == .success
    }

    // MARK: - 请求内部

    private func reserveID() throws -> UInt64 {
        try syncState {
            if let terminal = terminalError { throw terminal }
            let id = nextID
            nextID &+= 1
            return id
        }
    }

    /// 登记请求（**必须在状态队列内**）。
    private func registerLocked(
        id: UInt64,
        method: String,
        continuation: CheckedContinuation<Any, Error>,
        timeout: TimeInterval
    ) {
        if let terminal = terminalError {
            resumeLocked(continuation, result: .failure(terminal))
            return
        }
        if cancelledBeforeRegistration.remove(id) != nil {
            resumeLocked(continuation, result: .failure(ClientError.cancelled))
            return
        }
        var item: DispatchWorkItem?
        if timeout.isFinite && timeout > 0 {
            let work = DispatchWorkItem { [weak self] in
                self?.stateQueue.async {
                    self?.settleLocked(id: id, result: .failure(ClientError.timeout(timeout)))
                }
            }
            item = work
            timerQueue.asyncAfter(deadline: .now() + timeout, execute: work)
        }
        pending[id] = PendingRequest(
            continuation: continuation,
            timeoutItem: item,
            method: method
        )
    }

    /// 写请求行（**必须在状态队列内发起**，实际写入走串行写队列）。
    private func enqueueWriteLocked(id: UInt64, method: String, params: [String: Any]) {
        let payload: Data
        do {
            var object: [String: Any] = ["id": id, "m": method]
            if !params.isEmpty { object["p"] = params }
            payload = try JSONSerialization.data(
                withJSONObject: object,
                options: [.fragmentsAllowed, .sortedKeys]
            )
        } catch {
            settleLocked(id: id, result: .failure(ClientError.writeFailed("请求无法序列化：\(error.localizedDescription)")))
            return
        }
        let line = payload + Data([0x0A])
        // 写入由写队列串行执行；写端 fd 只有写队列会碰。
        stdinWriter.enqueueWrite(line, timeout: configuration.writeTimeout) { [weak self] error in
            guard let error else { return }
            guard let self else { return }
            let message = (error as? ClientError)?.description ?? error.localizedDescription
            self.stateQueue.async {
                self.settleLocked(id: id, result: .failure(ClientError.writeFailed(message)))
                self.finishLocked(.closed("写入子进程失败：\(message)"))
            }
        }
    }

    private func cancelRequest(id: UInt64) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if let entry = self.pending.removeValue(forKey: id) {
                entry.timeoutItem?.cancel()
                self.resumeLocked(entry.continuation, result: .failure(ClientError.cancelled))
            } else if self.cancelledBeforeRegistration.count > 64 {
                self.cancelledBeforeRegistration.remove(self.cancelledBeforeRegistration.first!)
                self.cancelledBeforeRegistration.insert(id)
            } else {
                self.cancelledBeforeRegistration.insert(id)
            }
        }
    }

    /// 结算一个请求（**必须在状态队列内**）。已结算的 id 被忽略 → 恰好一次。
    private func settleLocked(id: UInt64, result: Result<Any, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutItem?.cancel()
        resumeLocked(entry.continuation, result: result)
    }

    /// 恢复一个请求的 continuation（**每个请求只会走到这里一次**）。
    private func resumeLocked(_ continuation: CheckedContinuation<Any, Error>, result: Result<Any, Error>) {
        settledCount += 1
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    // MARK: - 读取与解析

    private func startReader(descriptor: Int32, isError: Bool) {
        let thread = Thread { [weak self] in
            // 读端归本线程所有：**退出时一定关闭**（含 self 已释放的路径），
            // 不会有第二个线程关同一个 fd，也不会误关被系统复用的 fd 号。
            defer {
                close(descriptor)
                BridgeClient.leaveReaderThread()
            }
            BridgeClient.enterReaderThread()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    let chunk = Data(buffer[0..<count])
                    guard let self else { break }
                    self.stateQueue.async {
                        if isError {
                            self.appendDiagnosticsLocked(chunk)
                        } else {
                            self.consumeLocked(chunk)
                        }
                    }
                    continue
                }
                if count == 0 { break }               // EOF
                if errno == EINTR { continue }
                break                                   // 读取错误：按 EOF 处理
            }
            guard let self else { return }
            if !isError {
                self.stateQueue.async { self.finishLocked(.closed("桥接输出流已结束")) }
            }
        }
        thread.name = isError ? "alger.bridge.stderr" : "alger.bridge.stdout"
        thread.start()
    }

    private func appendDiagnosticsLocked(_ chunk: Data) {
        stderrTail.append(chunk)
        let limit = 16 * 1024
        if stderrTail.count > limit {
            stderrTail.removeFirst(stderrTail.count - limit)
        }
    }

    /// 消费 stdout 分片（**必须在状态队列内**）。
    private func consumeLocked(_ chunk: Data) {
        readBuffer.append(chunk)
        if readBuffer.count > configuration.maxLineBytes {
            let overflow = readBuffer.count
            readBuffer.removeAll(keepingCapacity: false)
            finishLocked(.protocolError("单行协议数据超过 \(configuration.maxLineBytes) 字节（收到 \(overflow) 字节）"))
            return
        }
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer[readBuffer.startIndex..<newlineIndex]
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            handleLineLocked(Data(line))
            if terminalError != nil { return }
        }
    }

    private func handleLineLocked(_ line: Data) {
        guard !line.isEmpty else { return }
        guard
            let object = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]),
            let dict = object as? [String: Any]
        else {
            // 无法解析的行：忽略（桥接对坏请求行会回一个没有 id 的错误对象）。
            return
        }
        if let event = dict["ev"] as? String {
            let payload = dict["p"] as? [String: Any] ?? [:]
            deliverEvent(event, payload)
            return
        }
        guard let number = dict["id"] as? NSNumber else { return }
        let id = number.uint64Value
        if dict["ok"] as? Bool == true {
            settleLocked(id: id, result: .success(dict["r"] ?? NSNull()))
        } else {
            let error = dict["e"] as? [String: Any]
            settleLocked(
                id: id,
                result: .failure(BridgeError(
                    code: error?["code"] as? String ?? "Unknown",
                    message: error?["message"] as? String ?? "未知错误"
                ))
            )
        }
    }

    /// 事件回调：**在状态队列之外** 触发（回调里可以安全地再次调用本客户端）。
    private func deliverEvent(_ name: String, _ payload: [String: Any]) {
        let handlers = syncState { Array(eventObservers.values) + (eventHandler.map { [$0] } ?? []) }
        callbackQueue.async { handlers.forEach { $0(name, payload) } }
    }

    /// 独立订阅，不替换应用的下载等事件处理器。
    public func addEventObserver(_ handler: @escaping (String, [String: Any]) -> Void) -> UUID {
        let id = UUID()
        syncState { eventObservers[id] = handler }
        return id
    }

    public func removeEventObserver(_ id: UUID) {
        syncState { _ = eventObservers.removeValue(forKey: id) }
    }

    /// 请求完成后等待此前的流式事件处理完成，再提交索引。
    public func drainEvents() async {
        await withCheckedContinuation { continuation in
            stateQueue.async {
                self.callbackQueue.async { continuation.resume() }
            }
        }
    }

    // MARK: - 终态

    /// 子进程退出。
    private func handleChildExit(_ finished: Process) {
        let reason: String
        switch finished.terminationReason {
        case .exit:
            reason = "子进程已退出（状态 \(finished.terminationStatus)）"
        case .uncaughtSignal:
            reason = "子进程被信号 \(finished.terminationStatus) 终止"
        @unknown default:
            reason = "子进程已结束"
        }
        childExitSemaphore.signal()
        stateQueue.async { [weak self] in
            self?.finishLocked(.closed(reason))
        }
    }

    /// 进入终态并结算所有在途请求（**必须在状态队列内**）。
    private func finishLocked(_ error: ClientError) {
        guard terminalError == nil else { return }
        terminalError = error
        let outstanding = pending
        pending.removeAll()
        for (_, entry) in outstanding {
            entry.timeoutItem?.cancel()
            resumeLocked(entry.continuation, result: .failure(error))
        }
        if let handler = terminationHandler {
            callbackQueue.async { handler(error) }
        }
    }

    // MARK: - 管道辅助

    /// 关闭一个仍然归我们所有的 fd（带身份核对：绝不误关被系统复用的 fd 号）。
    private static func closeIfOwned(descriptor: Int32, identity: (inode: UInt64, device: UInt64)) {
        guard identity.inode != 0 else { return }
        guard fcntl(descriptor, F_GETFD) != -1 else { return }   // 已经关了
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              UInt64(info.st_ino) == identity.inode,
              UInt64(info.st_dev) == identity.device else { return }
        close(descriptor)
    }

    // MARK: - 状态队列辅助

    /// 在状态队列上执行一段代码。
    ///
    /// 已经在状态队列上时 **直接执行**（不再 `sync`），
    /// 因此不存在 `queue.sync` 重入死锁。
    private func syncState<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: stateKey) != nil {
            return try body()
        }
        return try stateQueue.sync(execute: body)
    }
}
