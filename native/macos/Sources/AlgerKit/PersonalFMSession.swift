import Foundation

/// 私人 FM 会话（**批次 / 代次 / 去重 / 续批预算 / 并发合并**）。
///
/// 网易的私人 FM 本身 **一批批返回**（每次几首），因此播放到当前批末尾时
/// 需要再取一批。这个类型只管 **「能不能取、取了要不要用」**：
///
/// - **代次**：`beginSession()` 作废之前所有在途响应 —— 换来源、播放另一张
///   FM 卡片、清空队列、退出登录之后，**旧响应不得接管队列**；
/// - **去重**：本会话已经入队的曲目 ID 不再重复入队（**有界历史**）；
///   同一批内部的重复 ID 也一起去掉；
/// - **续批预算**：**一次耗尽只发一个请求** —— 空结果 / 失败 **不自动重试**
///   （由用户点「下一首」再发起一次新的续批）；**成功续批可以一直持续**，
///   不存在「听满 N 批就永久停掉」；
/// - **并发合并**：同一时刻只允许一个在途请求（重复触发不会并发取批）。
public final class PersonalFMSession {

    /// 会话上限（**默认值**）。
    public struct Limits {
        /// 去重历史最多记多少个曲目 ID（超出后按先进先出淘汰）。
        public var historyLimit: Int

        public init(historyLimit: Int = 400) {
            self.historyLimit = max(1, historyLimit)
        }

        public static let `default` = Limits()
    }

    public let limits: Limits

    /// 当前会话代次（**每次 `beginSession()` 自增**）。
    public private(set) var generation: Int = 0
    /// 本会话发起过的取批次数（**诊断用**：成功续批可持续，没有 lifetime 上限）。
    public private(set) var requestCount: Int = 0
    /// 是否有一个在途取批请求（**并发合并**）。
    public private(set) var isRequestInFlight: Bool = false

    /// 去重历史（**先进先出**：超出 `historyLimit` 淘汰最早的）。
    private var seenOrder: [Int64] = []
    private var seenIDs: Set<Int64> = []

    public init(limits: Limits = .default) {
        self.limits = limits
    }

    /// 开启新会话（**作废之前所有在途响应**；清空去重历史与请求计数）。
    ///
    /// - Returns: 新的代次（取批时带上它，回来时校验）。
    @discardableResult
    public func beginSession() -> Int {
        generation += 1
        requestCount = 0
        isRequestInFlight = false
        seenOrder.removeAll()
        seenIDs.removeAll()
        return generation
    }

    /// 登记已经入队的曲目（进去重历史）。
    public func register(_ songs: [RemoteSong]) {
        for song in songs { remember(song.id) }
    }

    /// 标记一次取批开始（**一次耗尽续批只发一个请求**）。
    ///
    /// - Returns: 本次请求的 **代次**（收尾时用 `endRequest(generation:)` 带上）；
    ///   **并发合并**（已有在途请求）时返回 `nil`。
    @discardableResult
    public func beginRequest() -> Int? {
        guard !isRequestInFlight else { return nil }
        isRequestInFlight = true
        requestCount += 1
        return generation
    }

    /// 标记取批结束（**只对同一代次生效**）。
    ///
    /// - 旧代次的请求收尾 **不得** 结束新会话的在途请求（否则会并发取批）。
    public func endRequest(generation: Int) {
        guard generation == self.generation else { return }
        isRequestInFlight = false
    }

    /// 过滤一批：去掉 **本会话已经见过** 的曲目，以及 **同一批内部的重复 ID**
    /// （顺序稳定；去重用本地副本，不污染会话历史）。
    public func filter(_ songs: [RemoteSong]) -> [RemoteSong] {
        var known = seenIDs
        var result: [RemoteSong] = []
        for song in songs {
            guard song.id > 0, !known.contains(song.id) else { continue }
            known.insert(song.id)
            result.append(song)
        }
        return result
    }

    /// 这个响应是否仍然属于当前会话（**旧响应不得接管队列**）。
    public func accepts(generation: Int) -> Bool {
        generation == self.generation
    }

    /// 记住一个曲目 ID（**有界历史**）。
    private func remember(_ id: Int64) {
        guard id > 0, seenIDs.insert(id).inserted else { return }
        seenOrder.append(id)
        while seenOrder.count > limits.historyLimit {
            let removed = seenOrder.removeFirst()
            seenIDs.remove(removed)
        }
    }
}
