import Foundation

/// 曲目行的 **稳定标签**（列表逐行选中用）。
///
/// 规则：
/// - **本地曲目**：绝对路径（排序 / 重排都不影响选中）；
/// - **网络曲目**：网易曲目 ID（稳定 ID，不随标题变化）；
/// - **队列条目**：队列条目 ID（**同一首曲目的多次入队互不影响**）；
/// - **雷达推荐**：独立命名空间（**不与来源歌单自己的曲目 ID 冲突**）。
public enum TrackRowTag: Hashable {
    /// 本地曲目（**绝对路径**）。
    case local(path: String)
    /// 网络曲目（**网易曲目 ID**）。
    case remote(id: Int64)
    /// 队列条目（**队列条目 ID**）。
    case queue(entryID: UUID)
    /// 雷达推荐（**独立命名空间**：不和来源歌单的原曲目冲突）。
    case radar(id: Int64)
}
