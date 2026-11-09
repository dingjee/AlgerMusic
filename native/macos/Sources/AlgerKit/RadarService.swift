import Foundation

/// 推荐雷达的 **纯逻辑** 部分：身份归一化、候选过滤、播放队列构造。
///
/// 设计约束（**与界面无关**，可单独单测）：
/// - **只读**：雷达只调用只读接口（`net.similarSongs`），不写库、不下载；
/// - **不造数据**：候选全部来自上游真实返回；空结果与失败分别如实上报；
/// - **稳定身份**：去重与排除都按 **网易曲目 ID** / **标题+艺人** 判定，
///   名称变化不会影响已选中的稳定 ID。
public enum RadarService {

    // MARK: - 限额

    /// 请求与展示的限额（**限量**：不放大上游压力，也不刷屏）。
    public enum Limits {
        /// 最多用多少个种子曲目做相似查询。
        public static let maxSeeds = 3
        /// 每个种子请求多少条候选。
        public static let perSeedLimit = 20
        /// 最多展示多少条推荐。
        public static let maxDisplay = 12
        /// 本地无来源 ID 的曲目，最多做多少次精确搜索解析。
        public static let maxLocalResolutions = 3
        /// 单次精确搜索取多少条候选。
        public static let searchLimit = 5
    }

    // MARK: - 身份

    /// 「标题 + 艺人」的归一化键。
    ///
    /// - 标题：去首尾空白 + 折叠内部空白 + 忽略大小写；
    /// - 艺人：按常见分隔符（`/`、`、`、`,`、`&`、`feat.`）拆成 **集合**
    ///   （顺序无关）→ 同一个组合的不同写法得到同一个键。
    public enum Identity {
        /// 归一化一段文本。
        public static func normalize(_ text: String) -> String {
            let folded = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            return folded
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        /// 艺人名拆分（去重 + 排序 → 顺序无关）。
        public static func artistTokens(_ artist: String) -> [String] {
            var text = artist
            for separator in ["、", "，", ",", "&", "＆", " feat. ", " feat ", " Feat. "] {
                text = text.replacingOccurrences(of: separator, with: "/")
            }
            var seen = Set<String>()
            var tokens: [String] = []
            for raw in text.components(separatedBy: "/") {
                let token = normalize(raw)
                guard !token.isEmpty, seen.insert(token).inserted else { continue }
                tokens.append(token)
            }
            return tokens.sorted()
        }

        /// 本地曲目（标题 + 艺人）的键。
        public static func key(title: String, artist: String) -> String {
            let normalizedTitle = normalize(title)
            let tokens = artistTokens(artist)
            return ([normalizedTitle] + tokens).joined(separator: "\u{1F}")
        }

        /// 网络曲目的键。
        public static func key(song: RemoteSong) -> String {
            key(title: song.name, artist: song.artistText)
        }

        /// **精确匹配**：本地曲目与网络曲目是不是同一首。
        ///
        /// 标题必须完全一致，艺人 **集合** 也必须完全一致
        /// → 同名不同艺人 / 合作版 vs 单人版都不会被误认成同一首。
        public static func matches(
            localTitle: String,
            localArtist: String,
            song: RemoteSong
        ) -> Bool {
            key(title: localTitle, artist: localArtist) == key(song: song)
        }
    }

    // MARK: - 排除集合

    /// 推荐结果的排除集合。
    public struct Exclusions {
        /// 明确排除的网易曲目 ID。
        ///
        /// 来源：来源歌单的全部曲目 ID、本机资料库里已收录的曲目、
        /// 本应用已记入播放计数的曲目。
        public var neteaseIDs: Set<Int64>
        /// 本地已有的「标题 + 艺人」键（**没有来源 ID 的本地曲目**也要排除）。
        public var titleArtistKeys: Set<String>

        public init(neteaseIDs: Set<Int64> = [], titleArtistKeys: Set<String> = []) {
            self.neteaseIDs = neteaseIDs
            self.titleArtistKeys = titleArtistKeys
        }
    }

    // MARK: - 过滤

    /// 过滤候选曲目：**去重 → 剔除无效 ID → 排除已在库 / 已播放的曲目**。
    ///
    /// - 顺序保持上游返回顺序（先到先得）；
    /// - 只影响 **显示**，不动任何数据；
    /// - `limit` 是展示上限（<= 0 表示不限制）。
    public static func filter(
        candidates: [RemoteSong],
        excluding: Exclusions,
        limit: Int = Limits.maxDisplay
    ) -> [RemoteSong] {
        var seen = Set<Int64>()
        var result: [RemoteSong] = []
        for song in candidates {
            guard song.id > 0 else { continue }
            guard !excluding.neteaseIDs.contains(song.id) else { continue }
            guard !excluding.titleArtistKeys.contains(Identity.key(song: song)) else { continue }
            guard seen.insert(song.id).inserted else { continue }
            result.append(song)
            if limit > 0, result.count >= limit { break }
        }
        return result
    }

    // MARK: - 播放队列

    /// 推荐结果的播放队列：**保留全部已展示的雷达项**。
    ///
    /// - 不混入歌单原有曲目、不混入其它分区的推荐；
    /// - 播放起点由调用方交给 `PlaybackController.replaceQueue(items, startAt:)`
    ///   （**与普通歌单播放的起点行为一致**）。
    public static func playbackItems(_ songs: [RemoteSong]) -> [PlaybackItem] {
        songs.map { PlaybackItem.remote($0) }
    }
}
