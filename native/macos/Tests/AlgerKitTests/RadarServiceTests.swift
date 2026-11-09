import Foundation
import XCTest

@testable import AlgerKit

/// 推荐雷达的回归测试（**纯逻辑**：身份归一化 / 过滤去重 / 播放队列）。
///
/// 覆盖：
/// - 「标题 + 艺人」的归一化键（顺序无关、同名不同艺人 **不** 混淆）；
/// - 候选过滤（去重、无效 ID、排除已在库 / 已播放的曲目、展示上限）；
/// - 播放队列（**保留全部已展示的雷达项**，起点由 `replaceQueue(startAt:)` 决定）。
final class RadarServiceTests: XCTestCase {

    private func song(
        id: Int64,
        name: String,
        artist: String = "艺人甲",
        album: String = "专辑乙"
    ) -> RemoteSong {
        RemoteSong(
            id: id,
            name: name,
            artists: [RemoteArtist(id: 1, name: artist)],
            album: RemoteAlbum(id: 2, name: album, picUrl: ""),
            durationMs: 1000
        )
    }

    // MARK: - 身份归一化

    /// 标题忽略大小写与多余空白；艺人 **顺序无关**。
    func testIdentityNormalizesTitleAndArtistOrder() {
        let a = RadarService.Identity.key(title: "  Song  Name ", artist: "甲 / 乙")
        let b = RadarService.Identity.key(title: "song name", artist: "乙 / 甲")
        XCTAssertEqual(a, b, "标题大小写 / 空白与艺人顺序都不应影响身份")
    }

    /// **同名不同艺人** 必须是不同的身份（不会把别的艺人的歌当成同一首）。
    func testIdentitySeparatesDifferentArtistsWithSameTitle() {
        let a = RadarService.Identity.key(title: "晴天", artist: "周杰伦")
        let b = RadarService.Identity.key(title: "晴天", artist: "林俊杰")
        XCTAssertNotEqual(a, b, "同名不同艺人不能混成同一首")
    }

    /// 精确匹配：标题 + 艺人集合 **完全一致** 才算同一首。
    func testExactMatchRequiresSameTitleAndArtistSet() {
        let target = song(id: 1, name: "晴天", artist: "周杰伦")
        XCTAssertTrue(RadarService.Identity.matches(localTitle: "晴天", localArtist: "周杰伦", song: target))
        XCTAssertFalse(RadarService.Identity.matches(localTitle: "晴天", localArtist: "林俊杰", song: target))
        XCTAssertFalse(RadarService.Identity.matches(localTitle: "七里香", localArtist: "周杰伦", song: target))
    }

    // MARK: - 过滤

    /// 去重 + 剔除无效 ID + 排除来源歌单 / 本地 / 已播放的曲目。
    func testFilterRemovesDuplicatesInvalidIDsAndExcludedSongs() {
        let candidates = [
            song(id: 10, name: "甲"),
            song(id: 10, name: "甲"),          // 重复
            song(id: 0, name: "无效"),          // 无效 ID
            song(id: 20, name: "乙"),           // 在来源歌单里
            song(id: 30, name: "丙"),           // 本机已收录
            song(id: 40, name: "丁"),           // 本应用已播放
            song(id: 50, name: "戊"),           // 本地无 ID 的同名曲目
            song(id: 60, name: "己"),           // 保留
        ]
        let exclusions = RadarService.Exclusions(
            neteaseIDs: [20, 30, 40],
            titleArtistKeys: [RadarService.Identity.key(title: "戊", artist: "艺人甲")]
        )
        let result = RadarService.filter(candidates: candidates, excluding: exclusions)
        XCTAssertEqual(result.map { $0.id }, [10, 60], "只保留合法且未被排除的曲目（去重后）")
    }

    /// 展示上限：只截断显示，**不丢身份**。
    func testFilterRespectsDisplayLimit() {
        let candidates = (1...10).map { song(id: Int64($0), name: "曲目\($0)") }
        let result = RadarService.filter(
            candidates: candidates,
            excluding: RadarService.Exclusions(),
            limit: 4
        )
        XCTAssertEqual(result.map { $0.id }, [1, 2, 3, 4])
    }

    /// 过滤 **不修改** 输入（只影响显示）。
    func testFilterDoesNotMutateInput() {
        let candidates = [song(id: 10, name: "甲"), song(id: 10, name: "甲")]
        let before = candidates.map { $0.id }
        _ = RadarService.filter(candidates: candidates, excluding: RadarService.Exclusions())
        XCTAssertEqual(candidates.map { $0.id }, before, "候选集合不得被就地修改")
    }

    // MARK: - 播放队列

    /// 播放队列 **保留全部已展示的雷达项**（起点由 `replaceQueue(startAt:)` 决定）。
    func testPlaybackItemsKeepsEveryDisplayedItem() {
        let songs = (1...3).map { song(id: Int64($0), name: "曲目\($0)") }
        let items = RadarService.playbackItems(songs)
        XCTAssertEqual(items.count, 3, "队列保留全部已展示的雷达项")
        XCTAssertEqual(items.map { $0.id }, ["netease:1", "netease:2", "netease:3"])
        XCTAssertEqual(items.map { $0.origin }, [.remote(neteaseId: 1), .remote(neteaseId: 2), .remote(neteaseId: 3)])
    }

    /// 从中间那一首播放：队列不变，**起点**由播放器决定（与歌单播放一致）。
    @MainActor
    func testReplaceQueueStartsAtClickedRadarItemAndKeepsAllItems() async throws {
        let workspace = try TempWorkspace("radar-queue")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.5)
        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: audio, isLocal: false, note: nil) }

        let songs = (1...3).map { song(id: Int64($0), name: "曲目\($0)") }
        let items = RadarService.playbackItems(songs)
        let player = PlayerController(resolver: resolver)
        await player.replaceQueue(items, startAt: 1)

        XCTAssertEqual(player.queue.count, 3, "队列保留全部已展示的雷达项")
        XCTAssertEqual(player.current?.id, "netease:2", "从被点击的那一首开始")
        XCTAssertEqual(player.currentIndex, 1)
    }
}
