import Foundation

/// 播放上下文：**当前正在播放的曲目来自哪个来源**。
///
/// 「加号」默认加入这里指向的来源，而不是当前浏览的页面：
/// - `localPlaylist`：本地歌单（**唯一可写入的目标**）；
/// - `remotePlaylist`：网络歌单（**只读** → 默认加到临时播放）；
/// - `radar(title:)`：某个歌单的 **推荐雷达**（只读来源 → 默认加到临时播放）；
/// - `personalFM`：**私人 FM**（一批批返回 → 默认加到临时播放）。
public enum PlaybackContext: Equatable {
    case none
    case localPlaylist(String)
    case remotePlaylist(Int64)
    /// 推荐雷达（**带真实来源标题**：队列入口与队列页头部都显示它）。
    case radar(title: String)
    /// 私人 FM。
    case personalFM

    /// 来源标题（**队列入口 / 队列页头部**用）。
    ///
    /// - 雷达 → 「“XX”的推荐雷达」；
    /// - 私人 FM → 「私人 FM」；
    /// - 本地 / 网络歌单 → 这里只给出标识（**显示名由界面按歌单解析**）。
    public var title: String {
        switch self {
        case .none: return "临时播放"
        case .localPlaylist(let id): return id
        case .remotePlaylist(let id): return "网络歌单 \(id)"
        case .radar(let title): return title.isEmpty ? "推荐雷达" : "“\(title)”的推荐雷达"
        case .personalFM: return "私人 FM"
        }
    }

    /// 是否是 **只读来源**（网络歌单 / 雷达 / 私人 FM）。
    ///
    /// 只读来源 **不能作为添加目标** → 「+」默认落到临时播放。
    public var isReadOnlySource: Bool {
        switch self {
        case .none, .localPlaylist: return false
        case .remotePlaylist, .radar, .personalFM: return true
        }
    }
}
