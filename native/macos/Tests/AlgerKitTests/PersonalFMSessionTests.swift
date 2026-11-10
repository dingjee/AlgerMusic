import Foundation
import XCTest

@testable import AlgerKit

/// 私人 FM 会话（**代次 / 去重 / 续批预算 / 并发合并**）的回归。
final class PersonalFMSessionTests: XCTestCase {

    private func song(_ id: Int64, _ name: String = "曲目") -> RemoteSong {
        RemoteSong(
            id: id,
            name: name,
            artists: [RemoteArtist(id: 1, name: "艺人")],
            album: RemoteAlbum(id: 2, name: "专辑", picUrl: ""),
            durationMs: 1000
        )
    }

    /// 新会话 **作废** 之前的在途响应（旧代次不得接管队列）。
    func testNewSessionInvalidatesOldResponses() {
        let session = PersonalFMSession()
        let first = session.beginSession()
        XCTAssertTrue(session.accepts(generation: first))

        let second = session.beginSession()
        XCTAssertNotEqual(first, second, "新会话必须换代号")
        XCTAssertFalse(session.accepts(generation: first), "旧代次的响应必须被拒绝")
        XCTAssertTrue(session.accepts(generation: second))
    }

    /// 去重：本会话见过的 ID 不再入队；**同一批内部的重复**也要去掉。
    func testFilterRemovesSeenAndIntraBatchDuplicates() {
        let session = PersonalFMSession()
        session.register([song(1), song(2)])

        let fresh = session.filter([
            song(2),      // 之前批次已有
            song(3),
            song(3),      // 同一批内部重复
            song(4),
            song(1),      // 之前批次已有
        ])
        XCTAssertEqual(fresh.map(\.id), [3, 4], "去重后应只剩新曲目：\(fresh.map(\.id))")
    }

    /// 去重历史 **有界**：超出上限后淘汰最早的（不会无限增长）。
    func testDedupeHistoryIsBounded() {
        let session = PersonalFMSession(limits: .init(historyLimit: 2))
        session.register([song(1), song(2), song(3)])
        let fresh = session.filter([song(1), song(2), song(3)])
        XCTAssertEqual(fresh.map(\.id), [1], "最早的 1 应被淘汰，2 / 3 仍在历史里")
    }

    /// 并发合并：同一时刻只允许一个在途请求。
    func testConcurrentRequestsAreMerged() {
        let session = PersonalFMSession()
        let generation = session.beginRequest()
        XCTAssertNotNil(generation, "第一次请求应当发出")
        XCTAssertNil(session.beginRequest(), "在途请求期间必须合并（不再发第二个）")
        session.endRequest(generation: generation!)
        XCTAssertNotNil(session.beginRequest(), "收尾后可以再发一次")
    }

    /// **旧代次的收尾不得结束新会话的在途请求**（否则会并发取批）。
    func testOldGenerationCannotEndNewRequest() {
        let session = PersonalFMSession()
        let old = session.beginRequest()
        XCTAssertNotNil(old)

        // 换来源 / 换卡片 → 新会话（代次自增）。
        let new = session.beginSession()
        let fresh = session.beginRequest()
        XCTAssertNotNil(fresh, "新会话可以发起自己的请求")

        // 旧请求这时才回来 → 不得把新请求的在途标记清掉。
        session.endRequest(generation: old!)
        XCTAssertNil(session.beginRequest(), "旧代次收尾后，新请求仍应在途（不得并发取批）")

        session.endRequest(generation: new)
        XCTAssertNotNil(session.beginRequest(), "新代次收尾后才能再发一次")
    }

    /// 成功续批 **可以持续**：没有「听满 N 批就永久停掉」的上限。
    func testSuccessfulContinuationCanRequestAgain() {
        let session = PersonalFMSession()
        for _ in 0..<50 {
            let generation = session.beginRequest()
            XCTAssertNotNil(generation, "每次耗尽续批都要能发一次请求")
            session.endRequest(generation: generation!)
        }
        XCTAssertEqual(session.requestCount, 50)
    }
}

/// 曲目行的 **稳定标签**（逐行选中用）的回归。
final class TrackRowTagTests: XCTestCase {

    /// 本地曲目按 **绝对路径**：排序 / 重排都不影响选中。
    func testLocalTagUsesPath() {
        let path = "/Users/jee/Music/a.flac"
        XCTAssertEqual(TrackRowTag.local(path: path), .local(path: path))
        XCTAssertNotEqual(
            TrackRowTag.local(path: path),
            .local(path: "/Users/jee/Music/b.flac")
        )
    }

    /// 网络曲目按 **网易曲目 ID**。
    func testRemoteTagUsesSongID() {
        XCTAssertEqual(TrackRowTag.remote(id: 42), .remote(id: 42))
        XCTAssertNotEqual(TrackRowTag.remote(id: 42), .remote(id: 43))
    }

    /// 雷达推荐的标签 **不与来源歌单的原曲目冲突**。
    func testRadarTagDoesNotCollideWithSongTag() {
        XCTAssertNotEqual(TrackRowTag.radar(id: 42), TrackRowTag.remote(id: 42))
        XCTAssertNotEqual(TrackRowTag.radar(id: 42), TrackRowTag.local(path: "42"))
    }

    /// 队列条目按 **队列条目 ID**：同一首曲目的两次入队互不影响。
    func testQueueTagIsUniquePerEntry() {
        let first = UUID()
        let second = UUID()
        XCTAssertNotEqual(TrackRowTag.queue(entryID: first), TrackRowTag.queue(entryID: second))
    }
}

/// 播放上下文（**来源标题 / 只读来源**）的回归。
final class PlaybackContextTests: XCTestCase {

    /// 雷达来源的标题：「“XX”的推荐雷达」。
    func testRadarTitleUsesRealPlaylistName() {
        XCTAssertEqual(PlaybackContext.radar(title: "深夜通勤").title, "“深夜通勤”的推荐雷达")
        XCTAssertEqual(PlaybackContext.radar(title: "").title, "推荐雷达")
    }

    /// 私人 FM 的标题。
    func testPersonalFMTitle() {
        XCTAssertEqual(PlaybackContext.personalFM.title, "私人 FM")
    }

    /// 只读来源（网络歌单 / 雷达 / 私人 FM）不能作为添加目标。
    func testReadOnlySources() {
        XCTAssertFalse(PlaybackContext.none.isReadOnlySource)
        XCTAssertFalse(PlaybackContext.localPlaylist("x").isReadOnlySource)
        XCTAssertTrue(PlaybackContext.remotePlaylist(1).isReadOnlySource)
        XCTAssertTrue(PlaybackContext.radar(title: "x").isReadOnlySource)
        XCTAssertTrue(PlaybackContext.personalFM.isReadOnlySource)
    }
}
