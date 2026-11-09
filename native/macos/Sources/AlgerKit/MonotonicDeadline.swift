import Foundation

/// 单调时钟（`CLOCK_MONOTONIC`）超时工具。
///
/// 规则：
/// - **一律用单调时钟**：系统时间被改动（NTP 校正、用户改表）时，
///   超时上界依然成立，不会突然变成「永远等不到」或「立刻超时」；
/// - **入参先收敛**：`UInt64(Double.nan)` 与 `UInt64(Double.infinity)` 都会
///   触发 Swift 运行时崩溃，因此所有公开的超时入参都必须先经过 `sanitize`。
enum MonotonicDeadline {
    /// 超时的上限（秒）：超过这个值按上限算，避免纳秒换算溢出。
    static let maximumSeconds: TimeInterval = 3600

    /// 把超时秒数收敛成 **有限且在范围内** 的值（NaN / inf 都不允许）。
    static func sanitize(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite else { return 0 }
        return min(max(timeout, 0), maximumSeconds)
    }

    /// 当前单调时钟（纳秒）。
    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// 超时对应的纳秒数（已收敛，转换安全）。
    static func nanoseconds(timeout: TimeInterval) -> UInt64 {
        UInt64(sanitize(timeout) * 1_000_000_000)
    }

    /// 截止时间（纳秒）：现在 + 超时。
    static func deadline(timeout: TimeInterval) -> UInt64 {
        now() &+ nanoseconds(timeout: timeout)
    }
}
