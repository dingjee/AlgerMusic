import Foundation

/// 下载任务的 **会话范围**（本次进程 vs 上次会话遗留）。
///
/// 产品规则（侧栏入口 + 下载页）：
/// - **本次进程触碰过的任务**（桥接 `dl` 事件 / 成功重试）才算「本次会话的记录」；
/// - **上次会话遗留的已完成记录** 不显示：既不进下载页列表，也不进侧栏入口
///   （完全退出后重启，「已下载」为空）；
/// - **上次会话遗留的未完成 / 失败任务** 仍显示：可重试，「待处理」入口保持可达；
/// - **持久记录一律保留**：这里只过滤 **界面**，不清下载队列、不删已下载音乐、
///   不动库索引与登录设置。
///
/// 为什么 **不用时间戳** 判断「本次会话」：
/// - 桥接载入时会把上次遗留的 `running` 任务改成 `queued` 并刷新 `updatedAt`
///   （见 `crates/alger-core/src/dlq.rs`）→ 用时间戳会把 **旧任务** 当成本次会话：
///   旧任务不再自动恢复，入口还会误报「正在下载」；
/// - 旧记录可能 **没有时间戳**（0）→ 时间戳判断必然失准。
public enum DownloadSessionScope {

    /// 侧栏下载入口的显示状态。
    public struct Entry: Equatable {
        /// 入口标题（「正在下载 / 待处理 / 已下载」）。
        public var title: String
        /// 入口角标（只有「正在下载 / 待处理」有数字）。
        public var badge: Int

        public init(title: String, badge: Int) {
            self.title = title
            self.badge = badge
        }
    }

    /// 展示用任务列表（**隐藏上次会话遗留的已完成记录**）。
    ///
    /// - Parameters:
    ///   - tasks: 桥接返回的 **完整** 任务列表（含上次会话遗留的记录）。
    ///   - touched: 本次进程触碰过的任务 ID。
    /// - Returns: 保持原顺序的展示列表。
    public static func visibleTasks(_ tasks: [DownloadTask], touched: Set<Int64>) -> [DownloadTask] {
        tasks.filter { task in
            // 未完成 / 失败的任务（旧会话遗留的也算）始终可见：可重试、待处理可见。
            guard task.isDone else { return true }
            // 已完成的任务只有「本次进程触碰过」才可见。
            return touched.contains(task.id)
        }
    }

    /// 进行中的任务数（**只算本次进程** 在途的任务）。
    public static func activeCount(tasks: [DownloadTask], touched: Set<Int64>) -> Int {
        visibleTasks(tasks, touched: touched)
            .filter { $0.isActive && touched.contains($0.id) }
            .count
    }

    /// 待处理数量：失败任务 + **尚未恢复的旧队列** + 待入单 + 自动保存待重试。
    ///
    /// 这几类都需要用户去下载页处理 → 统一归到「待处理」，入口保持可达。
    public static func pendingCount(
        tasks: [DownloadTask],
        touched: Set<Int64>,
        pendingIntakes: Int = 0,
        autoSavePending: Int = 0
    ) -> Int {
        let visible = visibleTasks(tasks, touched: touched)
        let failed = visible.filter { $0.isFailed }.count
        // 旧队列还没恢复 → 同样算「待处理」（**不能**当成「已下载」）。
        let unrecovered = visible.filter { $0.isActive && !touched.contains($0.id) }.count
        return failed + unrecovered + max(0, pendingIntakes) + max(0, autoSavePending)
    }

    /// 侧栏下载入口（`nil` = **不显示入口**）。
    ///
    /// 状态优先级：**正在下载（本次进程在途）→ 待处理（可处理的事）→ 已下载**。
    /// - Important: 「已下载」**只在本次进程确实完成过下载时**出现；
    ///   旧队列没恢复、还有待入单 / 自动保存待重试时都显示「待处理」。
    public static func entry(
        tasks: [DownloadTask],
        touched: Set<Int64>,
        pendingIntakes: Int = 0,
        autoSavePending: Int = 0
    ) -> Entry? {
        let active = activeCount(tasks: tasks, touched: touched)
        if active > 0 { return Entry(title: "正在下载", badge: active) }
        let pending = pendingCount(
            tasks: tasks,
            touched: touched,
            pendingIntakes: pendingIntakes,
            autoSavePending: autoSavePending
        )
        if pending > 0 { return Entry(title: "待处理", badge: pending) }
        // 「已下载」必须有 **本次进程** 的完成记录（旧记录不算）。
        let doneThisSession = visibleTasks(tasks, touched: touched).contains { $0.isDone }
        if doneThisSession { return Entry(title: "已下载", badge: 0) }
        return nil
    }
}
