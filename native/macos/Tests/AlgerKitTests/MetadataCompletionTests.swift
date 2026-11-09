import Foundation
import XCTest

@testable import AlgerKit

/// 元信息 **自动补全** 回归。
///
/// 覆盖（全部用 **假桥接**，不碰公网、不碰真实音乐库）：
/// - 可信下载来源补齐空字段；
/// - 已有非空标签 **一个都不覆盖**；
/// - 来源 ID 冲突 → **整体拒绝**；
/// - 多个同样精确的候选 → **拒绝自动选择**（歧义）；
/// - 低置信 / 不同版本（live、时长不一致）→ 拒绝自动填写；
/// - 标签够用 → **不请求** MusicBrainz；
/// - 写后核验不过 → **不假成功**；
/// - 网络失败 → **明确抛出**；
/// - 封面 **永远不动**；占位 / 路径 **绝不写进标签**。
final class MetadataCompletionTests: XCTestCase {

    // MARK: - 夹具

    private func tagsJSON(
        title: String = "",
        artist: String = "",
        album: String = "",
        albumArtist: String = "",
        year: Int = 0,
        date: String? = "",
        isrc: String? = "",
        neteaseId: Int = 0,
        musicBrainzRecordingId: String? = "",
        musicBrainzReleaseId: String? = "",
        durationMs: Int = 200_000,
        hasArtwork: Bool = false
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "path": "/tmp/a.mp3",
            "format": "mp3",
            "durationMs": durationMs,
            "title": title,
            "artist": artist,
            "album": album,
            "albumArtist": albumArtist,
            "genre": "",
            "track": 0,
            "disc": 0,
            "year": year,
            "hasArtwork": hasArtwork,
            "fileSize": 10,
            "neteaseId": neteaseId,
        ]
        if let date { payload["date"] = date }
        if let isrc { payload["isrc"] = isrc }
        if let musicBrainzRecordingId { payload["musicBrainzRecordingId"] = musicBrainzRecordingId }
        if let musicBrainzReleaseId { payload["musicBrainzReleaseId"] = musicBrainzReleaseId }
        return payload
    }

    private func candidateJSON(
        recordingId: String = "rec-1",
        title: String = "Imagine",
        artist: String = "John Lennon",
        durationMs: Int = 200_000,
        score: Int = 100,
        isrcs: [String] = [],
        releases: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "recordingId": recordingId,
            "title": title,
            "artist": artist,
            "durationMs": durationMs,
            "score": score,
            "isrcs": isrcs,
            "releases": releases,
        ]
    }

    private func makeService(
        _ bridge: FakeMetadataBridge
    ) throws -> (MetadataCompletionService, BridgeClient) {
        let client = try bridge.makeClient()
        return (MetadataCompletionService(client: client), client)
    }

    private func makeSong(
        id: Int64 = 123,
        name: String = "Imagine",
        artist: String = "John Lennon",
        album: String = "Imagine",
        durationMs: Int64 = 200_000
    ) -> RemoteSong {
        RemoteSong(
            id: id,
            name: name,
            artists: [RemoteArtist(id: 0, name: artist)],
            album: RemoteAlbum(id: 1, name: album, picUrl: ""),
            durationMs: durationMs
        )
    }

    /// 写入补丁（`tags.write` 的 `patch`）。
    private func writePatch(_ bridge: FakeMetadataBridge) -> [String: Any]? {
        for request in bridge.requests() where (request["m"] as? String) == "tags.write" {
            return (request["p"] as? [String: Any])?["patch"] as? [String: Any]
        }
        return nil
    }

    // MARK: - 可信来源补空

    func testTrustedSourceFillsEmptyFieldsOnly() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON())                                   // 写前基线
        try bridge.enqueueSuccess(tagsJSON())                                   // 保存前重读
        try bridge.enqueueSuccess(tagsJSON(                                    // 写入返回
            title: "Imagine",
            artist: "John Lennon",
            album: "Imagine",
            neteaseId: 123
        ))
        try bridge.enqueueSuccess(tagsJSON(                                    // 写后重读
            title: "Imagine",
            artist: "John Lennon",
            album: "Imagine",
            neteaseId: 123
        ))
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(path: "/tmp/a.mp3", source: makeSong())

        XCTAssertEqual(tags.title, "Imagine")
        XCTAssertEqual(tags.artist, "John Lennon")
        XCTAssertEqual(tags.album, "Imagine")
        XCTAssertEqual(tags.neteaseId, 123)
        // 读 → 写前重读 → 写 → 写后重读。
        XCTAssertEqual(bridge.methods(), ["tags.read", "tags.read", "tags.write", "tags.read"])

        let patch = writePatch(bridge)
        XCTAssertEqual(patch?["title"] as? String, "Imagine")
        XCTAssertEqual(patch?["artist"] as? String, "John Lennon")
        XCTAssertEqual(patch?["album"] as? String, "Imagine")
        XCTAssertEqual(patch?["neteaseId"] as? Int, 123)
        // 封面：**永远不动**（不嵌入、不移除）。
        XCTAssertNil(patch?["artworkBase64"])
        XCTAssertEqual(patch?["removeArtwork"] as? Bool, false)
    }

    func testExistingNonEmptyValuesAreNeverOverwritten() async throws {
        let bridge = try FakeMetadataBridge()
        // 已有非空标题 / 艺人 / 专辑（手工改过的值）。
        try bridge.enqueueSuccess(tagsJSON(
            title: "已有标题",
            artist: "已有艺人",
            album: "已有专辑",
            neteaseId: 123
        ))
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(
            path: "/tmp/a.mp3",
            source: makeSong(name: "新标题", artist: "新艺人", album: "新专辑")
        )

        XCTAssertEqual(tags.title, "已有标题")
        XCTAssertEqual(tags.artist, "已有艺人")
        XCTAssertEqual(tags.album, "已有专辑")
        // **一个字段都没写**（核心信息齐了 → 连 MusicBrainz 都不问）。
        XCTAssertEqual(bridge.methods(), ["tags.read"])
        XCTAssertFalse(bridge.methods().contains("meta.search"))
    }

    func testOnlyMissingFieldIsFilledAndExistingOneIsKept() async throws {
        let bridge = try FakeMetadataBridge()
        // 标题已有，专辑缺失。
        try bridge.enqueueSuccess(tagsJSON(title: "已有标题", artist: "已有艺人"))
        try bridge.enqueueSuccess(tagsJSON(title: "已有标题", artist: "已有艺人"))
        try bridge.enqueueSuccess(tagsJSON(
            title: "已有标题",
            artist: "已有艺人",
            album: "Imagine",
            neteaseId: 123
        ))
        try bridge.enqueueSuccess(tagsJSON(
            title: "已有标题",
            artist: "已有艺人",
            album: "Imagine",
            neteaseId: 123
        ))
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        _ = try await service.completeDownloaded(path: "/tmp/a.mp3", source: makeSong())

        let patch = writePatch(bridge)
        XCTAssertEqual(patch?["album"] as? String, "Imagine")
        XCTAssertEqual(patch?["neteaseId"] as? Int, 123)
        // 已有非空字段 **不进补丁**。
        XCTAssertNil(patch?["title"])
        XCTAssertNil(patch?["artist"])
    }

    func testSourceIDConflictRefusesEverything() async throws {
        let bridge = try FakeMetadataBridge()
        // 文件里的来源 ID 与可信来源不一致。
        try bridge.enqueueSuccess(tagsJSON(neteaseId: 111))
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(path: "/tmp/a.mp3", source: makeSong(id: 222))

        // 原样返回，**没有写任何东西**。
        XCTAssertEqual(tags.neteaseId, 111)
        XCTAssertEqual(tags.title, "")
        XCTAssertEqual(bridge.methods(), ["tags.read"])
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    func testPlaceholderValuesAreNeverWritten() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try enqueueStrictSearch(bridge, candidates: [candidateJSON(recordingId: "rec-1")])
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon", neteaseId: 123))
        try bridge.enqueueSuccess(tagsJSON(
            title: "Imagine",
            artist: "John Lennon",
            neteaseId: 123,
            musicBrainzRecordingId: "rec-1"
        ))
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        _ = try await service.completeDownloaded(
            path: "/tmp/a.mp3",
            // 占位专辑名 → **不写进标签**（只能靠严格匹配确认的发行版本）。
            source: makeSong(album: "未知专辑")
        )

        let patch = writePatch(bridge)
        XCTAssertNil(patch?["album"])
        XCTAssertEqual(patch?["neteaseId"] as? Int, 123)
        XCTAssertEqual(patch?["musicBrainzRecordingId"] as? String, "rec-1")
    }

    func testPlaceholderDetection() {
        XCTAssertTrue(MetadataCompletionService.isPlaceholder(""))
        XCTAssertTrue(MetadataCompletionService.isPlaceholder("   "))
        XCTAssertTrue(MetadataCompletionService.isPlaceholder("Unrecognized"))
        XCTAssertTrue(MetadataCompletionService.isPlaceholder("/Users/jee/Music/a.mp3"))
        XCTAssertTrue(MetadataCompletionService.isPlaceholder("file:///Users/jee/Music/a.mp3"))
        XCTAssertTrue(MetadataCompletionService.isPlaceholder("未知歌曲"))
        XCTAssertTrue(MetadataCompletionService.isPlaceholder("未知专辑"))
        XCTAssertFalse(MetadataCompletionService.isPlaceholder("Imagine"))
        XCTAssertFalse(MetadataCompletionService.isPlaceholder("John Lennon"))
    }

    // MARK: - 严格匹配（MusicBrainz）

    /// 触发 MusicBrainz 查询的基线：标题 / 艺人已有，**专辑缺失**。
    private func enqueueStrictSearch(
        _ bridge: FakeMetadataBridge,
        candidates: [[String: Any]]
    ) throws {
        try bridge.enqueueSuccess(["candidates": candidates])
    }

    func testStrictMatchFillsMissingFields() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(
                recordingId: "rec-1",
                isrcs: ["USRC17607839"],
                releases: [[
                    "id": "rel-1",
                    "title": "Imagine",
                    "date": "1971-11-08",
                    "country": "GB",
                    "albumArtist": "John Lennon",
                ]]
            ),
        ])
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try bridge.enqueueSuccess(tagsJSON(
            title: "Imagine",
            artist: "John Lennon",
            album: "Imagine",
            albumArtist: "John Lennon",
            year: 1971,
            date: "1971-11-08",
            isrc: "USRC17607839",
            musicBrainzRecordingId: "rec-1",
            musicBrainzReleaseId: "rel-1"
        ))
        try bridge.enqueueSuccess(tagsJSON(
            title: "Imagine",
            artist: "John Lennon",
            album: "Imagine",
            albumArtist: "John Lennon",
            year: 1971,
            date: "1971-11-08",
            isrc: "USRC17607839",
            musicBrainzRecordingId: "rec-1",
            musicBrainzReleaseId: "rel-1"
        ))
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(path: "/tmp/a.mp3", source: nil)

        XCTAssertEqual(tags.album, "Imagine")
        XCTAssertEqual(tags.albumArtist, "John Lennon")
        XCTAssertEqual(tags.year, 1971)
        XCTAssertEqual(tags.date, "1971-11-08")
        XCTAssertEqual(tags.isrc, "USRC17607839")
        XCTAssertEqual(tags.musicBrainzRecordingId, "rec-1")
        XCTAssertEqual(tags.musicBrainzReleaseId, "rel-1")
        // 标题 / 艺人 **没有** 被覆盖（本来就有值）。
        let patch = writePatch(bridge)
        XCTAssertNil(patch?["title"])
        XCTAssertNil(patch?["artist"])
        XCTAssertEqual(patch?["album"] as? String, "Imagine")
    }

    func testAmbiguousCandidatesAreRefused() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        // 实网探测到的形态：同名候选不止一个。
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(recordingId: "rec-1"),
            candidateJSON(recordingId: "rec-2"),
            candidateJSON(recordingId: "rec-3"),
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(path: "/tmp/a.mp3", source: nil)

        XCTAssertEqual(tags.album, "")
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    func testLowConfidenceCandidateIsRefused() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(recordingId: "rec-1", score: 30),
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(path: "/tmp/a.mp3", source: nil)

        XCTAssertEqual(tags.album, "")
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    // MARK: - 自动写入的置信度门槛（与人工候选的 0.5 分开）

    func testAutoWriteRejectsManualLevelConfidence() async throws {
        // 0.5：人工候选的门槛（「值得让人看一眼」），**自动写回不够**。
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(recordingId: "rec-1", score: 50),
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(path: "/tmp/a.mp3", source: nil)

        XCTAssertEqual(tags.album, "")
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    func testAutoWriteRejectsJustBelowThreshold() async throws {
        // 0.89：低于自动写入门槛（0.90）→ 拒绝。
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(recordingId: "rec-1", score: 89),
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(path: "/tmp/a.mp3", source: nil)

        XCTAssertEqual(tags.album, "")
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    func testAutoWriteAcceptsHighConfidence() async throws {
        // 0.95：达到自动写入门槛（0.90）→ 采纳。
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(recordingId: "rec-1", score: 95),
        ])
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon", musicBrainzRecordingId: "rec-1"))
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon", musicBrainzRecordingId: "rec-1"))
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(path: "/tmp/a.mp3", source: nil)

        XCTAssertEqual(tags.musicBrainzRecordingId, "rec-1")
        XCTAssertTrue(bridge.methods().contains("tags.write"))
    }

    func testAutoWriteThresholdIsIndependentFromManualThreshold() {
        XCTAssertEqual(MetadataCompletionService.autoWriteConfidenceThreshold, 0.90, accuracy: 0.000_001)
        // 人工候选阈值仍然是 0.5（**不能**被自动写入的门槛覆盖）。
        XCTAssertEqual(MetadataCandidate.lowConfidenceThreshold, 0.5, accuracy: 0.000_001)
        XCTAssertGreaterThan(
            MetadataCompletionService.autoWriteConfidenceThreshold,
            MetadataCandidate.lowConfidenceThreshold
        )
    }

    func testDurationMismatchIsRefusedAsDifferentVersion() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon", durationMs: 200_000))
        // 时长差 50 秒 → 不是同一段录音。
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(recordingId: "rec-1", durationMs: 250_000),
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(path: "/tmp/a.mp3", source: nil)

        XCTAssertEqual(tags.album, "")
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    func testLiveVersionIsNeverAutoSelected() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        // 不同版本（现场版）标题不同 → 严格标题相等不成立。
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(recordingId: "rec-live", title: "Imagine (Live)"),
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(path: "/tmp/a.mp3", source: nil)

        XCTAssertEqual(tags.album, "")
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    func testCompleteTagsNeverRequestMusicBrainz() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(
            title: "Imagine",
            artist: "John Lennon",
            album: "Imagine",
            neteaseId: 123
        ))
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(path: "/tmp/a.mp3", source: makeSong())

        XCTAssertEqual(tags.title, "Imagine")
        XCTAssertFalse(bridge.methods().contains("meta.search"))
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    // MARK: - 发行版本一致性

    func testUniqueReleaseRequiresConsistencyWithExistingAlbum() {
        let candidate = MetadataCandidate(
            recordingId: "rec-1",
            title: "Imagine",
            artist: "John Lennon",
            durationMs: 200_000,
            score: 1,
            releases: [
                MetadataRelease(id: "rel-2", title: "Let It Be", date: "1970-01-01", albumArtist: "Beatles"),
            ]
        )
        // 文件里的专辑与候选发行版本 **对不上** → 不确定，不填。
        XCTAssertNil(MetadataCompletionService.uniqueRelease(
            in: candidate,
            tags: AudioTags(path: "/tmp/a.mp3", album: "Abbey Road")
        ))
        // 专辑对得上 → 用那个发行版本。
        XCTAssertEqual(MetadataCompletionService.uniqueRelease(
            in: candidate,
            tags: AudioTags(path: "/tmp/a.mp3", album: "Let It Be")
        )?.id, "rel-2")
        // 已有发行 ID 与候选不一致 → 不确定，不填。
        XCTAssertNil(MetadataCompletionService.uniqueRelease(
            in: candidate,
            tags: AudioTags(path: "/tmp/a.mp3", album: "Let It Be", musicBrainzReleaseId: "rel-old")
        ))
        // 没有任何线索 + **唯一** 发行版本 → 可以确定。
        XCTAssertEqual(MetadataCompletionService.uniqueRelease(
            in: candidate,
            tags: AudioTags(path: "/tmp/a.mp3")
        )?.id, "rel-2")
        // 多个发行版本 + 没有线索 → 不确定。
        let multiple = MetadataCandidate(
            recordingId: "rec-1",
            title: "Imagine",
            artist: "John Lennon",
            durationMs: 200_000,
            score: 1,
            releases: [
                MetadataRelease(id: "rel-2", title: "Let It Be"),
                MetadataRelease(id: "rel-3", title: "Imagine"),
            ]
        )
        XCTAssertNil(MetadataCompletionService.uniqueRelease(in: multiple, tags: AudioTags(path: "/tmp/a.mp3")))
    }

    func testReleaseFieldsAreNotFilledWhenAlbumDoesNotMatch() async throws {
        let bridge = try FakeMetadataBridge()
        // 文件里有专辑（Abbey Road），但标题 / 艺人缺失 → 需要外部匹配。
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(
                recordingId: "rec-1",
                releases: [[
                    "id": "rel-2",
                    "title": "Let It Be",
                    "date": "1970-01-01",
                    "country": "GB",
                    "albumArtist": "Beatles",
                ]]
            ),
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let suggestion = try await service.proposal(
            for: AudioTags(
                path: "/tmp/a.mp3",
                durationMs: 200_000,
                album: "Abbey Road",
                // 桥接读得到（空）→ 才可能被补上。
                musicBrainzRecordingId: ""
            ),
            query: MetadataCompletionQuery(title: "Imagine", artist: "John Lennon")
        )

        // 录音级别的字段可以补；**发行版本级别的一律不补**（专辑对不上）。
        XCTAssertEqual(suggestion.values[.musicBrainzRecordingId], "rec-1")
        XCTAssertNil(suggestion.values[.album])
        XCTAssertNil(suggestion.values[.musicBrainzReleaseId])
        XCTAssertNil(suggestion.values[.date])
        XCTAssertNil(suggestion.values[.year])
        XCTAssertNil(suggestion.values[.albumArtist])
        // **没有写文件**。
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    func testMultipleISRCsAreNotAutoFilled() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(recordingId: "rec-1", isrcs: ["USRC17607839", "GBRC17607839"]),
        ])
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try bridge.enqueueSuccess(tagsJSON(
            title: "Imagine",
            artist: "John Lennon",
            musicBrainzRecordingId: "rec-1"
        ))
        try bridge.enqueueSuccess(tagsJSON(
            title: "Imagine",
            artist: "John Lennon",
            musicBrainzRecordingId: "rec-1"
        ))
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(path: "/tmp/a.mp3", source: nil)

        // 多个 ISRC → 有歧义 → **不自动填**。
        XCTAssertEqual(tags.isrc, "")
        let patch = writePatch(bridge)
        XCTAssertNil(patch?["isrc"])
    }

    // MARK: - 外部匹配被拒绝时，可信来源那部分仍然算数

    func testTrustedValuesAreStillFilledWhenMatchingIsAmbiguous() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON())
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(recordingId: "rec-1"),
            candidateJSON(recordingId: "rec-2"),
        ])
        try bridge.enqueueSuccess(tagsJSON())
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon", neteaseId: 123))
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon", neteaseId: 123))
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.completeDownloaded(
            path: "/tmp/a.mp3",
            // 来源里没有专辑名 → 专辑仍然缺失 → 需要外部匹配（结果有歧义）。
            source: makeSong(album: "")
        )

        // 可信来源那部分 **照样写进去**（标题 / 艺人 / 来源 ID）。
        XCTAssertEqual(tags.title, "Imagine")
        XCTAssertEqual(tags.artist, "John Lennon")
        XCTAssertEqual(tags.neteaseId, 123)
        // 歧义的部分（专辑等）没有写。
        XCTAssertEqual(tags.album, "")
        XCTAssertEqual(tags.musicBrainzRecordingId, "")
        let patch = writePatch(bridge)
        XCTAssertEqual(patch?["title"] as? String, "Imagine")
        XCTAssertNil(patch?["album"])
    }

    func testProposalStatusMatchesActuallyFilledFields() async throws {
        let bridge = try FakeMetadataBridge()
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(recordingId: "rec-1"),
            candidateJSON(recordingId: "rec-2"),
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        // 有可信来源补上的字段 + 外部匹配有歧义 → 状态必须说清楚「补了什么」。
        let suggestion = try await service.proposal(
            for: AudioTags(path: "/tmp/a.mp3", durationMs: 200_000),
            source: makeSong(album: "")
        )

        XCTAssertTrue(suggestion.hasValues)
        XCTAssertTrue(suggestion.hasWarning)
        XCTAssertTrue(suggestion.isCompleted)
        guard case .completedWithWarning = suggestion.status else {
            return XCTFail("应为 completedWithWarning，实际：\(suggestion.status)")
        }
        // 说明与 **实际填入的字段数** 一致。
        XCTAssertTrue(suggestion.note.contains("\(suggestion.values.count)"))
        XCTAssertFalse(suggestion.detail.isEmpty)
    }

    // MARK: - 失败路径

    func testVerificationMismatchFailsWithoutSuccess() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try enqueueStrictSearch(bridge, candidates: [candidateJSON(recordingId: "rec-1")])
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))  // 保存前重读
        try bridge.enqueueSuccess(tagsJSON(album: "Imagine"))                        // 写入返回
        try bridge.enqueueSuccess(tagsJSON())                                       // 写后重读：没写进去
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        do {
            _ = try await service.completeDownloaded(path: "/tmp/a.mp3", source: nil)
            XCTFail("写后核验不过必须报错（不能假成功）")
        } catch let error as MetadataError {
            guard case .verificationFailed = error else {
                return XCTFail("应为 verificationFailed，实际：\(error)")
            }
            XCTAssertTrue(error.description.contains("未能确认保存成功"))
        }
    }

    func testNetworkFailureIsSurfacedExplicitly() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "Imagine", artist: "John Lennon"))
        try bridge.enqueueError(code: "Network", message: "MusicBrainz 不可达")
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        do {
            _ = try await service.completeDownloaded(path: "/tmp/a.mp3", source: nil)
            XCTFail("网络失败必须抛出来")
        } catch let error as BridgeClient.BridgeError {
            XCTAssertEqual(error.code, "Network")
            XCTAssertTrue(error.message.contains("不可达"))
        }
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    func testReadFailureIsSurfacedExplicitly() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueError(code: "Io", message: "文件不存在")
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        do {
            _ = try await service.completeDownloaded(path: "/tmp/a.mp3", source: makeSong())
            XCTFail("读标签失败必须抛出来")
        } catch let error as BridgeClient.BridgeError {
            XCTAssertEqual(error.code, "Io")
        }
    }

    // MARK: - 编辑器用的统一建议

    func testProposalNeverWritesToFile() async throws {
        let bridge = try FakeMetadataBridge()
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(
                recordingId: "rec-1",
                releases: [[
                    "id": "rel-1",
                    "title": "Imagine",
                    "date": "1971-11-08",
                    "country": "GB",
                    "albumArtist": "John Lennon",
                ]]
            ),
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let suggestion = try await service.proposal(
            for: AudioTags(
                path: "/tmp/a.mp3",
                durationMs: 200_000,
                title: "Imagine",
                artist: "John Lennon",
                // 桥接 **读得到** 这个字段（空）→ 才可能被补上；读不到就不写。
                musicBrainzRecordingId: ""
            )
        )

        XCTAssertTrue(suggestion.isCompleted)
        XCTAssertEqual(suggestion.values[.album], "Imagine")
        XCTAssertEqual(suggestion.values[.musicBrainzRecordingId], "rec-1")
        // **只给建议，不写文件**。
        XCTAssertFalse(bridge.methods().contains("tags.write"))
        XCTAssertEqual(bridge.methods(), ["meta.search"])
    }

    func testProposalReportsAmbiguityWithoutValues() async throws {
        let bridge = try FakeMetadataBridge()
        try enqueueStrictSearch(bridge, candidates: [
            candidateJSON(recordingId: "rec-1"),
            candidateJSON(recordingId: "rec-2"),
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let suggestion = try await service.proposal(
            for: AudioTags(path: "/tmp/a.mp3", durationMs: 200_000, title: "Imagine", artist: "John Lennon")
        )

        XCTAssertFalse(suggestion.isCompleted)
        XCTAssertTrue(suggestion.values.isEmpty)
        guard case .ambiguous = suggestion.status else {
            return XCTFail("应为 ambiguous，实际：\(suggestion.status)")
        }
        XCTAssertFalse(suggestion.note.isEmpty)
    }

    func testProposalReportsSourceIDConflict() async throws {
        let bridge = try FakeMetadataBridge()
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let suggestion = try await service.proposal(
            for: AudioTags(path: "/tmp/a.mp3", neteaseId: 111),
            source: makeSong(id: 222)
        )

        XCTAssertFalse(suggestion.isCompleted)
        XCTAssertTrue(suggestion.values.isEmpty)
        guard case .sourceIDConflict = suggestion.status else {
            return XCTFail("应为 sourceIDConflict，实际：\(suggestion.status)")
        }
        // 冲突时 **一个请求都不该发**。
        XCTAssertTrue(bridge.methods().isEmpty)
    }

    func testProposalWithoutAnyCandidateIsNoMatch() async throws {
        let bridge = try FakeMetadataBridge()
        try enqueueStrictSearch(bridge, candidates: [])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let suggestion = try await service.proposal(
            for: AudioTags(path: "/tmp/a.mp3", durationMs: 200_000, title: "Imagine", artist: "John Lennon")
        )

        guard case .noMatch = suggestion.status else {
            return XCTFail("应为 noMatch，实际：\(suggestion.status)")
        }
        XCTAssertTrue(suggestion.values.isEmpty)
    }

    // MARK: - 文件名提示

    func testFilenameQueryRequiresStrictArtistTitlePattern() {
        let query = MetadataCompletionService.filenameQuery(path: "/Music/John Lennon - Imagine.mp3")
        XCTAssertEqual(query?.artist, "John Lennon")
        XCTAssertEqual(query?.title, "Imagine")

        // 没有分隔符 → 没有艺人 → 不猜。
        XCTAssertNil(MetadataCompletionService.filenameQuery(path: "/Music/Imagine.mp3"))
        // 多个分隔符 → 分不清 → 不猜。
        XCTAssertNil(MetadataCompletionService.filenameQuery(path: "/Music/A - B - C.mp3"))
        // 空路径 → 不猜。
        XCTAssertNil(MetadataCompletionService.filenameQuery(path: ""))
    }

    func testFilenameQueryIsOnlyUsedAsSearchHint() async throws {
        let bridge = try FakeMetadataBridge()
        try enqueueStrictSearch(bridge, candidates: [candidateJSON(recordingId: "rec-1")])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        // 文件里没有标签 → 只能用文件名当 **搜索提示**。
        let suggestion = try await service.proposal(
            for: AudioTags(path: "/Music/John Lennon - Imagine.mp3", durationMs: 200_000),
            query: MetadataCompletionService.filenameQuery(path: "/Music/John Lennon - Imagine.mp3")
        )

        XCTAssertTrue(suggestion.isCompleted)
        XCTAssertEqual(suggestion.values[.title], "Imagine")
        XCTAssertEqual(suggestion.values[.artist], "John Lennon")
        // 确实按文件名推断的标题 / 艺人去搜了。
        let params = (bridge.requests().first?["p"] as? [String: Any])
        XCTAssertEqual(params?["title"] as? String, "Imagine")
        XCTAssertEqual(params?["artist"] as? String, "John Lennon")
    }

    // MARK: - 归一化与匹配规则

    func testNormalisationAndArtistMatchingRules() {
        // 与 Rust 侧同一套归一化（只保留字母数字 + 小写）。
        XCTAssertEqual(MetadataCompletionService.normalize("Don't Stop Me Now"), "dontstopmenow")
        XCTAssertEqual(MetadataCompletionService.normalize("Imagine (Live)"), "imaginelive")
        // 多人合作逐个对上才算同一组。
        XCTAssertTrue(MetadataCompletionService.artistsMatch("A / B", "A & B"))
        XCTAssertFalse(MetadataCompletionService.artistsMatch("A", "A & B"))
        XCTAssertTrue(MetadataCompletionService.artistsMatch("John Lennon", "john lennon"))
    }
}
