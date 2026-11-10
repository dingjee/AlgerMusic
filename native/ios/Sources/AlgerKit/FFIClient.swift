import CAlgerFFI
import Foundation

/// FFI 客户端错误。
public enum FFIClientError: Error, LocalizedError {
    /// init 失败（路径不合法 / 运行时起不来）；带 Rust 侧原因。
    case initFailed(String)
    /// 桥接返回的业务错误（code 供分流：NeedLogin / Network / Decode…）。
    case bridge(code: String, message: String)
    /// 客户端已关闭（shutdown / 释放后未完成）。
    case closed
    /// 调用超时（兜底保护；正常路径不应触发）。
    case timeout(method: String)

    public var errorDescription: String? {
        switch self {
        case .initFailed(let m): return "桥接初始化失败：\(m)"
        case .bridge(_, let m): return m
        case .closed: return "桥接已关闭"
        case .timeout(let m): return "请求超时：\(m)"
        }
    }
}

/// 全局行注册表：C 回调无 context 指针，靠 **进程级唯一 id** 把响应行
/// 路由回发起客户端；事件（无 id）广播给全部存活客户端。
///
/// 单实例是常态（一个 App 一个桥接）；多实例时响应仍按 id 精确路由，
/// 事件广播是已文档化的取舍（下载事件由各自队列状态去重）。
final class FFIRegistry {
    final class WeakClient {
        weak var value: FFIClient?
        init(_ value: FFIClient) { self.value = value }
    }

    struct PendingEntry {
        weak var client: FFIClient?
        let continuation: CheckedContinuation<Any, Error>
    }

    static let shared = FFIRegistry()

    /// 所有回调行都在这条串行队列上解析与分发（顺序与 Rust 外发一致）。
    let lineQueue = DispatchQueue(label: "alger.ffi.lines")

    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var pending: [UInt64: PendingEntry] = [:]
    private var clients: [WeakClient] = []

    private init() {}

    /// 注册全局行回调（进程一次）。Swift 并发安全：用 once 语义。
    func installHandlerOnce() {
        alger_ffi_set_handler({ raw in FFIRegistry.shared.deliver(rawLine: raw) })
    }

    /// 行回调（任意 Rust 工作线程触发）：取走所有权 → 串行分发。
    private func deliver(rawLine: UnsafePointer<CChar>?) {
        // 无论解析成败都 free（与 Swift 侧约定一致）。
        guard let rawLine else { return }
        let line = String(cString: rawLine)
        free(UnsafeMutableRawPointer(mutating: rawLine))
        lineQueue.async {
            self.dispatch(line)
        }
    }

    private func dispatch(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return }
        if let rawID = dict["id"], let id = Self.uint64(rawID) {
            let entry: PendingEntry?
            lock.lock()
            entry = pending.removeValue(forKey: id)
            lock.unlock()
            guard let entry else { return }
            if dict["ok"] as? Bool == true {
                entry.continuation.resume(returning: dict["r"] ?? NSNull())
            } else {
                let e = dict["e"] as? [String: Any]
                entry.continuation.resume(throwing: FFIClientError.bridge(
                    code: e?["code"] as? String ?? "Unknown",
                    message: e?["message"] as? String ?? "未知错误"
                ))
            }
        } else if let event = dict["ev"] as? String {
            let params = dict["p"] as? [String: Any] ?? [:]
            let targets: [FFIClient]
            lock.lock()
            clients.removeAll { $0.value == nil }
            targets = clients.compactMap { $0.value }
            lock.unlock()
            for target in targets {
                target.deliverEvent(name: event, params: params)
            }
        }
    }

    private static func uint64(_ raw: Any) -> UInt64? {
        switch raw {
        case let n as NSNumber: return n.uint64Value
        case let s as String: return UInt64(s)
        default: return nil
        }
    }

    // MARK: - 客户端侧 API（可在任意线程调用）

    func addClient(_ client: FFIClient) {
        lock.lock()
        clients.append(WeakClient(client))
        lock.unlock()
    }

    func removeClient(_ client: FFIClient) {
        lock.lock()
        clients.removeAll { $0.value === client || $0.value == nil }
        // 注意：**不动 pending**——shutdown 时由 failPending 负责恢复并清理
        // 该客户端的续体；这里提前过滤会导致续体永久泄漏（调用悬挂）。
        lock.unlock()
    }

    /// 分配进程级唯一请求 id 并登记续体。
    func registerPending(_ continuation: CheckedContinuation<Any, Error>, client: FFIClient) -> UInt64 {
        lock.lock()
        nextID &+= 1
        let id = nextID
        pending[id] = PendingEntry(client: client, continuation: continuation)
        lock.unlock()
        return id
    }

    /// 调用结束（成功 / 异常 / 超时）后兜底清理：响应行迟到时直接丢弃。
    func clearPending(_ id: UInt64) {
        lock.lock()
        pending.removeValue(forKey: id)
        lock.unlock()
    }

    /// shutdown 时失败该客户端所有未完成调用。
    func failPending(for client: FFIClient, error: FFIClientError) {
        lock.lock()
        let entries = pending.filter { $0.value.client === client }
        lock.unlock()
        guard !entries.isEmpty else { return }
        lock.lock()
        for (id, _) in entries { pending.removeValue(forKey: id) }
        lock.unlock()
        for (_, entry) in entries {
            entry.continuation.resume(throwing: error)
        }
    }
}

/// 进程内桥接客户端（iOS FFI 传输；协议语义同 macOS stdio BridgeClient）。
///
/// - **每个调用恰好一个结果**：按 id 配对续体；超时 / 关闭都会终结续体；
/// - **线程模型**：所有 Rust 回调行进串行 `lineQueue` 解析，续体在
///   `call` 的 Task 上恢复（continuation 不指定队列，跟随调用方）；
/// - **句柄生命周期**：`shutdown()` / `deinit` 后句柄作废，不得再调用。
public final class FFIClient: @unchecked Sendable {
    /// 单次调用兜底超时（秒）；正常响应远快于此，仅防悬挂泄漏。
    public var callTimeoutSeconds: TimeInterval = 120

    private let registry = FFIRegistry.shared
    private let handleLock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private var eventHandlers: [(String, [String: Any]) -> Void] = []
    private let eventLock = NSLock()

    /// 打开实例。`sessionPath` 必须绝对（App 容器内）；否则抛
    /// `.initFailed`（fail closed，绝不回落默认路径）。
    public init(sessionPath: String) throws {
        registry.installHandlerOnce()
        guard let h = sessionPath.withCString({ alger_ffi_init($0) }) else {
            let reason: String
            if let p = alger_ffi_last_error() {
                reason = String(cString: p)
            } else {
                reason = "未知原因"
            }
            throw FFIClientError.initFailed(reason)
        }
        handle = h
        registry.addClient(self)
    }

    deinit { shutdown() }

    /// 发起一次协议调用，返回响应的 `r` 值（字典 / 数组 / 标量）。
    @discardableResult
    public func call(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        let h = lockedHandle()
        let registry = self.registry
        let timeout = callTimeoutSeconds
        return try await withThrowingTaskGroup(of: Any.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let id = registry.registerPending(continuation, client: self)
                    // 先登记续体再发请求：响应不可能先于登记到达。
                    let paramsJSON = (try? JSONSerialization.data(withJSONObject: params))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                    paramsJSON.withCString { p in
                        method.withCString { m in
                            alger_ffi_call(h, id, m, p)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw FFIClientError.timeout(method: method)
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// 订阅协议事件（`dl` / `scan` / …）。回调在串行 lineQueue 上。
    public func onEvent(_ handler: @escaping (String, [String: Any]) -> Void) {
        eventLock.lock()
        eventHandlers.append(handler)
        eventLock.unlock()
    }

    /// 关闭：失败所有在途调用，有界收束 Rust 侧（含下载队列）并释放句柄。
    /// 幂等。
    public func shutdown() {
        handleLock.lock()
        guard let h = handle else { handleLock.unlock(); return }
        handle = nil
        handleLock.unlock()
        registry.removeClient(self)
        registry.failPending(for: self, error: .closed)
        alger_ffi_shutdown(h)
    }

    /// 当前未完成调用数（诊断 / 测试用）。
    public var pendingCount: Int {
        registry.pendingCountFor(self)
    }

    fileprivate func deliverEvent(name: String, params: [String: Any]) {
        eventLock.lock()
        let handlers = eventHandlers
        eventLock.unlock()
        for handler in handlers {
            handler(name, params)
        }
    }

    private func lockedHandle() -> UnsafeMutableRawPointer {
        handleLock.lock()
        let h = handle
        handleLock.unlock()
        guard let h else { fatalError("FFIClient 已关闭") }
        return UnsafeMutableRawPointer(h)
    }
}

extension FFIRegistry {
    func pendingCountFor(_ client: FFIClient) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.filter { $0.value.client === client }.count
    }
}
