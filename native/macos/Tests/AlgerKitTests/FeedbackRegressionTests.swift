import Foundation
import XCTest

@testable import AlgerKit

/// 反馈回归测试（**纯逻辑 + 持久化**，不播放真实音频、不碰用户资料）。
///
/// 覆盖：
/// - **播放顺序**：默认顺序、随机模式跨重启恢复、随机整轮不漏播不重复；
/// - **展示名**：未知标签 → `Unrecognized`、旧标题里的绝对路径 → 只留文件名；
/// - **保守去重**：同名不同人 / 时长不符 / 专辑版本不符 / 两项都缺 → 都不合并；
/// - **音频质量**：真实编码（ALAC 不当成有损）、无损按 PCM 属性比、
///   有损按实测码率比、不可证实就不替换。
///
/// 全部临时文件都落在 `.artifacts/` 下（`TempWorkspace`），
/// 播放地址解析一律走 **失败夹具** → 不会产生任何真实音频。

// MARK: - 夹具

/// 夹具错误（**只用于测试**）。
struct FeedbackFixtureError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// **永远解析失败**的播放地址解析器。
///
/// 回归测试只关心 **队列 / 随机顺序** 这类纯逻辑，
/// 因此不解析任何地址 → **不会产生任何真实音频**。
final class FeedbackFailingResolver: PlaybackResolving, @unchecked Sendable {
    func resolve(_ item: PlaybackItem) async throws -> PlaybackSource {
        throw FeedbackFixtureError(message: "回归测试不需要真实音频")
    }
}

/// 标签读取夹具（**不读真实文件**，按路径返回配置好的标签）。
final class FeedbackTagReader: AudioTagReading, @unchecked Sendable {
    private let tags: [String: AudioTags]
    private let unreadable: Set<String>

    init(tags: [String: AudioTags] = [:], unreadable: Set<String> = []) {
        self.tags = tags
        self.unreadable = unreadable
    }

    func readAudioTags(path: String) async throws -> AudioTags {
        if unreadable.contains(path) {
            throw FeedbackFixtureError(message: "标签读不出来")
        }
        guard let tags = tags[path] else {
            throw FeedbackFixtureError(message: "没有为该路径配置标签")
        }
        return tags
    }
}

/// 播放地址解析夹具（**不联网**）。
final class FeedbackSourceResolver: AudioSourceResolving, @unchecked Sendable {
    private let audio: ResolvedAudio?
    private let failure: String?

    init(audio: ResolvedAudio? = nil, failure: String? = nil) {
        self.audio = audio
        self.failure = failure
    }

    func resolve(song: RemoteSong) async throws -> ResolvedAudio {
        if let failure { throw FeedbackFixtureError(message: failure) }
        guard let audio else {
            throw FeedbackFixtureError(message: "没有配置解析结果")
        }
        return audio
    }
}

/// 下载审核用的本地资料库夹具（**真实索引 + 真实文件**，都在 `.artifacts` 下）。
final class FeedbackLibraryFixture {
    let workspace: TempWorkspace
    let index: LibraryIndex
    let store: NativeStore
    let library: LocalLibrary
    let intake: DownloadIntakeService

    init(_ label: String) throws {
        workspace = try TempWorkspace(label)
        index = LibraryIndex(fileURL: workspace.url("library/index.json"))
        store = NativeStore(fileURL: workspace.url("native.json"))
        library = LocalLibrary(index: index, store: store)
        intake = DownloadIntakeService(store: store, library: library)
    }

    /// **隔离的废纸篓**：把文件移到 `.artifacts` 下的隔离目录。
    ///
    /// **绝不写真实用户废纸篓**（测试只碰 `.artifacts`）。
    func trashAction() -> DownloadReplacementService.TrashAction {
        let trashDirectory = workspace.url("Trash")
        try? FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        return { path in
            let source = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return }
            let target = trashDirectory.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: source, to: target)
        }
    }

    /// 写一个本地文件并登记到索引（**只落在测试目录**）。
    @discardableResult
    func addTrack(
        name: String,
        title: String,
        artist: String,
        album: String = "",
        durationMs: Int = 0,
        neteaseId: Int64 = 0
    ) throws -> TrackRecord {
        let url = workspace.url("Music/\(name)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
        let track = TrackRecord(
            path: url.path,
            neteaseId: neteaseId,
            title: title,
            artist: artist,
            album: album,
            durationMs: UInt64(max(0, durationMs))
        )
        try index.upsert(track)
        return track
    }

    /// 写一个 **未登记到索引** 的文件（下载完成的新文件用）。
    func writeDownloadedFile(name: String, contents: String) throws -> URL {
        let url = workspace.url("Downloads/\(name)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }
}

/// 网络曲目夹具。
func makeFeedbackSong(
    id: Int64 = 100,
    name: String = "晴天",
    artist: String = "周杰伦",
    album: String = "叶惠美",
    durationMs: Int = 269_000
) -> RemoteSong {
    RemoteSong(
        id: id,
        name: name,
        artists: [RemoteArtist(id: 9, name: artist)],
        album: RemoteAlbum(id: 3, name: album, picUrl: ""),
        durationMs: Int64(durationMs)
    )
}

/// 远端解析结果夹具（**不联网**）。
func makeResolvedAudio(url: String, bitrate: Int) -> ResolvedAudio {
    ResolvedAudio(
        url: url,
        bitrate: bitrate,
        size: 0,
        source: "test",
        sourceLabel: "",
        thirdParty: false,
        note: nil
    )
}

// MARK: - 播放顺序（顺序 / 随机 / 跨重启）

/// 播放顺序的回归：**默认顺序**、**随机整轮**、**顺序模式跨重启恢复**。
@MainActor
final class FeedbackPlaybackOrderTests: XCTestCase {

    private func makeItems(_ count: Int) -> [PlaybackItem] {
        (0..<count).map { index in
            PlaybackItem(
                title: "曲目 \(index)",
                artist: "艺人",
                album: "专辑",
                durationMs: 1_000,
                origin: .remote(neteaseId: Int64(index + 1))
            )
        }
    }

    /// 默认就是 **顺序播放**（随机必须显式打开）。
    func testDefaultOrderIsOrdered() {
        XCTAssertEqual(NativeSettings().playbackOrder, .ordered)
        XCTAssertEqual(PlaybackOrder.ordered.toggled, .shuffle)
        XCTAssertEqual(PlaybackOrder.shuffle.toggled, .ordered)

        let player = PlayerController(resolver: FeedbackFailingResolver())
        XCTAssertEqual(player.playbackOrder, .ordered, "播放器默认必须是顺序播放")
    }

    /// 随机模式 **跨重启** 保留（`native.json` → 重开 → 仍然是随机）。
    func testShuffleOrderSurvivesRestart() throws {
        let workspace = try TempWorkspace("feedback-order-restart")
        let file = workspace.url("native.json")

        let store = NativeStore(fileURL: file)
        try store.mutate { state in
            state.settings.playbackOrder = .shuffle
        }

        // 「重启」= 重新打开同一个文件。
        let reopened = NativeStore(fileURL: file)
        XCTAssertEqual(reopened.current.settings.playbackOrder, .shuffle, "随机模式必须跨重启保留")
    }

    /// 旧版本文件 **没有** 这个字段 → 默认顺序（不猜、不报错）。
    func testLegacyStateWithoutOrderFieldFallsBackToOrdered() throws {
        let workspace = try TempWorkspace("feedback-order-legacy")
        let legacy = try workspace.write(
            """
            {
              "version": 1,
              "settings": {
                "playlistsDirectory": "",
                "libraryFolders": [],
                "downloadDirectory": "",
                "autoSaveEnabled": true,
                "autoSaveThreshold": 3,
                "hideRemotePlaylists": false
              }
            }
            """,
            to: "native.json"
        )

        let store = NativeStore(fileURL: legacy)
        XCTAssertEqual(store.current.settings.playbackOrder, .ordered, "旧文件必须落到顺序播放")
    }

    /// 顺序模式：严格按队列顺序前进，末尾不再前进。
    func testOrderedPlaybackFollowsQueueOrder() async throws {
        let player = PlayerController(resolver: FeedbackFailingResolver())
        let items = makeItems(3)

        await player.replaceQueue(items)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.current?.id, items[0].id)

        player.next()
        _ = await waitUntil { player.currentIndex == 1 }
        XCTAssertEqual(player.current?.id, items[1].id, "顺序播放必须按队列顺序")

        player.next()
        _ = await waitUntil { player.currentIndex == 2 }
        XCTAssertEqual(player.current?.id, items[2].id)

        // 末尾：不再前进（停住，不越界）。
        player.next()
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(player.currentIndex, 2, "队列末尾不得越界")
    }

    /// 随机模式：**队列显示顺序不变**（随机只影响「下一首是谁」）。
    func testShuffleKeepsVisibleQueueOrder() async throws {
        let player = PlayerController(resolver: FeedbackFailingResolver())
        let items = makeItems(4)
        player.setPlaybackOrder(.shuffle, randomSeed: 0x5EED)

        await player.replaceQueue(items)
        XCTAssertEqual(player.queue.map(\.id), items.map(\.id), "随机不得打乱队列显示顺序")
    }

    /// 随机模式：**从任意一首开始，一整轮每首各播一次**（不漏播、不重复）。
    func testShuffleRoundVisitsEveryItemExactlyOnceFromAnyStart() async throws {
        let count = 5
        for start in 0..<count {
            let player = PlayerController(resolver: FeedbackFailingResolver())
            player.setPlaybackOrder(.shuffle, randomSeed: 0xC0FFEE)
            let items = makeItems(count)

            await player.replaceQueue(items, startAt: start)
            XCTAssertEqual(player.currentIndex, start, "起点必须落在被点中的那一首")

            var visited: [Int] = [start]
            for _ in 1..<count {
                let before = player.currentIndex
                player.next()
                let moved = await waitUntil(timeout: 2) { player.currentIndex != before }
                XCTAssertTrue(moved, "下一首必须真的切换（start=\(start)）")
                guard let index = player.currentIndex else { break }
                visited.append(index)
            }

            XCTAssertEqual(visited.count, count, "整轮必须正好 \(count) 首（start=\(start)）")
            XCTAssertEqual(Set(visited).count, count, "整轮不得重复播放同一首（start=\(start)）")
            XCTAssertEqual(Set(visited), Set(0..<count), "整轮不得漏播任何一首（start=\(start)）")
        }
    }
}

// MARK: - 展示名（未知标签 / 绝对路径标题）

/// 展示名的回归：**未知标签 → Unrecognized**，**旧标题里的绝对路径 → 只留文件名**。
final class FeedbackMetadataDisplayTests: XCTestCase {

    /// 没有标签 → 用 **文件名（去扩展名）**，不是一长串路径。
    func testDisplayTitleFallsBackToBasename() {
        let track = TrackRecord(path: "/Music/周杰伦 - 晴天.mp3", title: "", artist: "", album: "")
        XCTAssertEqual(track.displayTitle, "周杰伦 - 晴天")
        XCTAssertFalse(track.displayTitle.contains("/"), "不得显示路径")
    }

    /// 旧索引把 **绝对路径写成了标题** → 只显示文件名。
    func testDisplayTitleSanitizesLegacyAbsolutePathTitle() {
        let track = TrackRecord(path: "/Music/晴天.mp3", title: "/Users/me/Music/周杰伦 - 晴天.mp3")
        XCTAssertEqual(track.displayTitle, "周杰伦 - 晴天")
        XCTAssertFalse(track.displayTitle.contains("/"), "不得显示路径")
    }

    /// `file://` URL 形式的旧标题同样只留文件名。
    func testDisplayTitleSanitizesLegacyFileURLTitle() {
        let track = TrackRecord(path: "/Music/晴天.mp3", title: "file:///Users/me/Music/晴天.mp3")
        XCTAssertEqual(track.displayTitle, "晴天")
    }

    /// 正常标题只做去空白，不动内容。
    func testDisplayTitleKeepsRealTitle() {
        let track = TrackRecord(path: "/Music/a.mp3", title: "  晴天  ")
        XCTAssertEqual(track.displayTitle, "晴天")
    }

    /// 缺失的艺人 / 专辑 → 统一 `Unrecognized`。
    func testMissingArtistAndAlbumShowUnrecognized() {
        let track = TrackRecord(path: "/Music/a.mp3", title: "晴天", artist: "", album: "")
        XCTAssertEqual(track.displayArtist, "Unrecognized")
        XCTAssertEqual(track.displayAlbum, "Unrecognized")
        XCTAssertEqual(TrackRecord.unrecognizedPlaceholder, "Unrecognized")
    }

    /// 路径判定：绝对路径 / `file://` 算路径，普通标题不算。
    func testLooksLikePathDetection() {
        XCTAssertTrue(TrackRecord.looksLikePath("/Music/a.mp3"))
        XCTAssertTrue(TrackRecord.looksLikePath("file:///Music/a.mp3"))
        XCTAssertFalse(TrackRecord.looksLikePath("晴天"))
        XCTAssertFalse(TrackRecord.looksLikePath("Live at 晴天"))
    }

    /// 文件名提取：去扩展名、解码 `file://`、空路径不编造名字。
    func testBasenameWithoutExtension() {
        XCTAssertEqual(TrackRecord.basenameWithoutExtension(path: "/Music/周杰伦 - 晴天.mp3"), "周杰伦 - 晴天")
        XCTAssertEqual(TrackRecord.basenameWithoutExtension(path: "file:///Music/a%20b.flac"), "a b")
        XCTAssertEqual(TrackRecord.basenameWithoutExtension(path: "/"), "")
        XCTAssertEqual(TrackRecord.basenameWithoutExtension(path: ""), "")
    }

    /// 旧索引里的路径标题 **落盘重读后** 仍然是文件名（不是路径）。
    func testLegacyPathTitleStaysSanitizedAfterIndexReload() throws {
        let workspace = try TempWorkspace("feedback-display-index")
        let file = workspace.url("library/index.json")
        let index = LibraryIndex(fileURL: file)
        try index.upsert(TrackRecord(
            path: "/Music/晴天.mp3",
            title: "/Users/me/Music/晴天.mp3",
            artist: "",
            album: ""
        ))

        let reloaded = LibraryIndex(fileURL: file)
        let stored = reloaded.track(path: "/Music/晴天.mp3")
        XCTAssertEqual(stored?.displayTitle, "晴天")
        XCTAssertEqual(stored?.displayArtist, "Unrecognized")
    }
}

// MARK: - 保守去重（下载审核）

/// 下载前的 **保守去重** 回归：**同名不同人不合并**、**时长 / 专辑不符不合并**、
/// **两项都缺也不合并**。
final class FeedbackDownloadReviewTests: XCTestCase {

    private func localTrack(
        title: String = "晴天",
        artist: String = "周杰伦",
        album: String = "叶惠美",
        durationMs: Int = 269_000
    ) -> TrackRecord {
        TrackRecord(
            path: "/Music/local.mp3",
            title: title,
            artist: artist,
            album: album,
            durationMs: UInt64(max(0, durationMs))
        )
    }

    /// 标题 + 艺人 + 时长 + 专辑都一致 → 认定为同一首。
    func testConservativeMatchAcceptsIdenticalMetadata() {
        let song = makeFeedbackSong()
        XCTAssertTrue(DownloadReviewService.conservativelyMatches(localTrack(), song: song))
    }

    /// 同名 **不同艺人** → 不合并（可能是别人的同名歌 / 翻唱）。
    func testConservativeMatchRejectsDifferentArtist() {
        let song = makeFeedbackSong(artist: "其他歌手")
        XCTAssertFalse(
            DownloadReviewService.conservativelyMatches(localTrack(), song: song),
            "同名不同艺人不得自动合并"
        )
    }

    /// 时长明显不符（差 5 秒）→ 不合并（现场版 / 剪辑版）。
    func testConservativeMatchRejectsDurationMismatch() {
        let song = makeFeedbackSong(durationMs: 274_000)
        XCTAssertFalse(
            DownloadReviewService.conservativelyMatches(localTrack(), song: song),
            "时长不符不得自动合并"
        )
    }

    /// 时长差 2 秒以内 → 仍算同一首（允许一点点误差）。
    func testConservativeMatchAcceptsSmallDurationDifference() {
        let song = makeFeedbackSong(durationMs: 270_000)
        XCTAssertTrue(DownloadReviewService.conservativelyMatches(localTrack(), song: song))
    }

    /// 专辑不同（同名 **不同版本**）→ 不合并。
    func testConservativeMatchRejectsDifferentAlbumVersion() {
        let song = makeFeedbackSong(album: "叶惠美（再版）")
        XCTAssertFalse(
            DownloadReviewService.conservativelyMatches(localTrack(), song: song),
            "不同专辑版本不得自动合并"
        )
    }

    /// **时长与专辑都缺** → 不合并（不能只凭标题就自动合并）。
    func testConservativeMatchRejectsWhenDurationAndAlbumBothUnknown() {
        let track = TrackRecord(path: "/Music/local.mp3", title: "晴天", artist: "周杰伦", album: "", durationMs: 0)
        let song = makeFeedbackSong(album: "", durationMs: 0)
        XCTAssertFalse(
            DownloadReviewService.conservativelyMatches(track, song: song),
            "时长与专辑都不可判定时不得自动合并"
        )
    }

    /// 本地没有标题 / 艺人 → 不合并。
    func testConservativeMatchRejectsMissingIdentityFields() {
        let noTitle = TrackRecord(path: "/Music/local.mp3", title: "", artist: "周杰伦", album: "叶惠美", durationMs: 269_000)
        let noArtist = TrackRecord(path: "/Music/local.mp3", title: "晴天", artist: "", album: "叶惠美", durationMs: 269_000)
        let song = makeFeedbackSong()
        XCTAssertFalse(DownloadReviewService.conservativelyMatches(noTitle, song: song))
        XCTAssertFalse(DownloadReviewService.conservativelyMatches(noArtist, song: song))
    }

    /// **来源 ID 优先**：ID 命中时不再靠标题 / 艺人猜。
    func testLocalCandidatePrefersSourceID() throws {
        let fixture = try FeedbackLibraryFixture("feedback-review-sourceid")
        let track = try fixture.addTrack(
            name: "song.mp3",
            title: "完全不同的标题",
            artist: "完全不同的艺人",
            album: "完全不同的专辑",
            durationMs: 1_000,
            neteaseId: 555
        )
        let song = makeFeedbackSong(id: 555, name: "晴天", artist: "周杰伦")

        let service = DownloadReviewService(
            library: fixture.library,
            tagReader: FeedbackTagReader(),
            resolver: FeedbackSourceResolver()
        )
        let candidate = service.findLocalCandidate(song: song)
        XCTAssertEqual(candidate?.matchKind, .sourceID, "来源 ID 必须优先于标题匹配")
        XCTAssertEqual(candidate?.track.path, track.path)
    }

    /// 标题 / 艺人 / 时长 / 专辑一致 → 走 **保守匹配**。
    func testLocalCandidateUsesConservativeTitleMatch() throws {
        let fixture = try FeedbackLibraryFixture("feedback-review-title")
        try fixture.addTrack(
            name: "song.mp3",
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            durationMs: 269_000
        )

        let service = DownloadReviewService(
            library: fixture.library,
            tagReader: FeedbackTagReader(),
            resolver: FeedbackSourceResolver()
        )
        let candidate = service.findLocalCandidate(song: makeFeedbackSong())
        XCTAssertEqual(candidate?.matchKind, .titleArtist)
    }
}

// MARK: - 音频质量（真实编码 / ALAC / 无损比较）

/// 音频质量的回归：**真实编码**、**ALAC 不当成有损**、
/// **无损不按压缩码率比优劣**、**不可证实就不替换**。
final class FeedbackAudioQualityTests: XCTestCase {

    // MARK: 编码类别（与比较方向无关，纯事实）

    /// 真实编码优先：`alac` → 无损，`aac` → 有损。
    func testCodecClassUsesRealCodec() {
        let alac = AudioQuality.measured(tags: AudioTags(format: "m4a", bitrate: 705_600, codec: "alac"))
        let aac = AudioQuality.measured(tags: AudioTags(format: "m4a", bitrate: 256_000, codec: "aac"))
        XCTAssertEqual(alac.codecClass, .lossless, "ALAC 是无损，不得当成有损")
        XCTAssertEqual(aac.codecClass, .lossy)
    }

    /// 判不出编码的容器（`m4a` 没有真实编码）→ **unknown**，不是有损也不是无损。
    func testUnknownContainerIsNeitherLossyNorLossless() {
        let unknown = AudioQuality.measured(tags: AudioTags(format: "m4a", bitrate: 256_000))
        XCTAssertEqual(unknown.codecClass, .unknown)
    }

    /// 容器能判出来时按容器判（`flac` 无损 / `mp3` 有损）。
    func testCodecClassFallsBackToContainer() {
        XCTAssertEqual(AudioQuality.measured(tags: AudioTags(format: "flac", bitrate: 900_000)).codecClass, .lossless)
        XCTAssertEqual(AudioQuality.measured(tags: AudioTags(format: "mp3", bitrate: 320_000)).codecClass, .lossy)
    }

    /// 本地编码未知 → **禁止** 被有损版本替换（两个方向都不可证实）。
    func testUnknownQualityIsNeverProvablyHigherThanLossy() {
        let unknown = AudioQuality.measured(tags: AudioTags(format: "m4a", bitrate: 256_000))
        let lossy = AudioQuality.measured(tags: AudioTags(format: "mp3", bitrate: 320_000, codec: "mp3"))
        XCTAssertFalse(lossy.isProvablyHigher(than: unknown), "远端有损不得替换编码未知的本地文件")
        XCTAssertFalse(unknown.isProvablyHigher(than: lossy))
    }

    /// 两边都判不出编码 → **不比较**（不猜）。
    func testUnknownQualityIsNeverProvablyHigherThanUnknown() {
        let a = AudioQuality.measured(tags: AudioTags(format: "m4a", bitrate: 256_000))
        let b = AudioQuality.measured(tags: AudioTags(format: "m4a", bitrate: 128_000))
        XCTAssertFalse(a.isProvablyHigher(than: b))
        XCTAssertFalse(b.isProvablyHigher(than: a))
    }

    /// 没有实测码率 → **不可证实更高**（不猜）。
    func testUnknownBitrateIsNeverProvablyHigher() {
        let unknown = AudioQuality.measured(tags: AudioTags(format: "mp3", bitrate: 0, codec: "mp3"))
        let known = AudioQuality.measured(tags: AudioTags(format: "mp3", bitrate: 320_000, codec: "mp3"))
        XCTAssertFalse(known.isProvablyHigher(than: unknown))
        XCTAssertFalse(unknown.isProvablyHigher(than: known))
    }

    /// **比较方向必须正确**：有损 MP3 不高于无损 ALAC，无损 ALAC 高于有损 MP3。
    ///
    /// - `a.isProvablyHigher(than: b)` = 「**a** 可证实高于 **b**」；
    /// - 两个调用点（`review` 的「远端 vs 本地」、`commit` 的「新文件 vs 旧文件」）
    ///   都是这个方向，方向反了会把 **本地无损文件换成远端有损文件**。
    func testLosslessIsHigherThanLossyInBothDirections() {
        let alac = AudioQuality.measured(tags: AudioTags(
            format: "m4a", bitrate: 705_600, sampleRate: 44_100, bitDepth: 16, codec: "alac"
        ))
        let mp3 = AudioQuality.measured(tags: AudioTags(
            format: "mp3", bitrate: 320_000, sampleRate: 44_100, codec: "mp3"
        ))
        XCTAssertFalse(mp3.isProvablyHigher(than: alac), "有损 MP3 不得高于无损 ALAC")
        XCTAssertTrue(alac.isProvablyHigher(than: mp3), "无损 ALAC 必须高于有损 MP3")
    }

    /// 无损 vs 无损：**采样率高但位深更低** → 不得自动判高（各有优劣，不可证实）。
    func testLosslessWithHigherSampleRateButLowerBitDepthIsNotProvablyHigher() {
        let highRate = AudioQuality.measured(tags: AudioTags(
            format: "flac", bitrate: 900_000, sampleRate: 96_000, bitDepth: 16, codec: "flac"
        ))
        let deeper = AudioQuality.measured(tags: AudioTags(
            format: "flac", bitrate: 1_000_000, sampleRate: 44_100, bitDepth: 24, codec: "flac"
        ))
        XCTAssertFalse(
            highRate.isProvablyHigher(than: deeper),
            "采样率高但位深更低时不得自动判高"
        )
        XCTAssertFalse(
            deeper.isProvablyHigher(than: highRate),
            "各有优劣时两个方向都不可证实"
        )
    }

    /// 无损 vs 无损：**采样率与位深都不差** → 可以判高（正向路径不能被一起改坏）。
    func testLosslessWithBothPropertiesBetterIsProvablyHigher() {
        let better = AudioQuality.measured(tags: AudioTags(
            format: "flac", bitrate: 900_000, sampleRate: 96_000, bitDepth: 24, codec: "flac"
        ))
        let worse = AudioQuality.measured(tags: AudioTags(
            format: "flac", bitrate: 1_000_000, sampleRate: 44_100, bitDepth: 16, codec: "flac"
        ))
        XCTAssertTrue(better.isProvablyHigher(than: worse), "两项都不差时必须能判高")
        XCTAssertFalse(worse.isProvablyHigher(than: better))
    }

    /// 码率单位是 **bps**（不是 kbps）：192000 → 192 kbps。
    func testBitrateIsExpressedInBps() {
        let quality = AudioQuality.measured(tags: AudioTags(format: "mp3", bitrate: 192_000, codec: "mp3"))
        XCTAssertTrue(quality.description.contains("192 kbps"), quality.description)
        XCTAssertTrue(quality.description.contains("有损"), quality.description)
    }

    /// 没有码率时显示 **码率未知**（不显示 0 kbps）。
    func testUnknownBitrateIsDescribedAsUnknown() {
        let quality = AudioQuality.measured(tags: AudioTags(format: "mp3", bitrate: 0, codec: "mp3"))
        XCTAssertTrue(quality.description.contains("码率未知"), quality.description)
    }
}

/// 质量比较的 **端到端** 回归（走 `review()` / `commit()`，结论不依赖比较方向的内部约定）。
final class FeedbackQualityDecisionTests: XCTestCase {

    private func makeService(
        fixture: FeedbackLibraryFixture,
        localTags: AudioTags,
        remote: ResolvedAudio?
    ) -> DownloadReviewService {
        DownloadReviewService(
            library: fixture.library,
            tagReader: FeedbackTagReader(tags: [localTags.path: localTags]),
            resolver: FeedbackSourceResolver(audio: remote)
        )
    }

    /// 本地是 **无损** → 不得被 **有损** 远端替换。
    func testLosslessLocalIsNotReplacedByLossyRemote() async throws {
        let fixture = try FeedbackLibraryFixture("feedback-quality-lossless-local")
        let track = try fixture.addTrack(
            name: "song.flac",
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            durationMs: 269_000
        )
        let service = makeService(
            fixture: fixture,
            localTags: AudioTags(
                path: track.path,
                format: "flac",
                bitrate: 900_000,
                sampleRate: 44_100,
                bitDepth: 16,
                codec: "flac"
            ),
            remote: makeResolvedAudio(url: "https://example.invalid/song.mp3", bitrate: 320_000)
        )

        let decision = await service.review(song: makeFeedbackSong())
        guard case .reuseLocal = decision else {
            return XCTFail("本地无损版本不得被有损版本替换，实际：\(decision)")
        }
        XCTAssertFalse(decision.needsDownload, "复用本地时不应再下载")
    }

    /// 本地是 **有损**、远端是 **无损** → 远端确实更好，应当替换。
    func testLossyLocalIsReplacedByLosslessRemote() async throws {
        let fixture = try FeedbackLibraryFixture("feedback-quality-lossless-remote")
        let track = try fixture.addTrack(
            name: "song.mp3",
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            durationMs: 269_000
        )
        let service = makeService(
            fixture: fixture,
            localTags: AudioTags(
                path: track.path,
                format: "mp3",
                bitrate: 192_000,
                sampleRate: 44_100,
                codec: "mp3"
            ),
            remote: makeResolvedAudio(url: "https://example.invalid/song.flac", bitrate: 900_000)
        )

        let decision = await service.review(song: makeFeedbackSong())
        guard case .replaceLocal = decision else {
            return XCTFail("远端是无损版本时应替换本地有损版本，实际：\(decision)")
        }
        XCTAssertTrue(decision.needsDownload)
    }

    /// 有损 vs 有损：按 **实测码率** 比（远端更高 → 替换）。
    func testLossyRemoteWithHigherBitrateReplacesLocal() async throws {
        let fixture = try FeedbackLibraryFixture("feedback-quality-lossy-higher")
        let track = try fixture.addTrack(
            name: "song.mp3",
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            durationMs: 269_000
        )
        let service = makeService(
            fixture: fixture,
            localTags: AudioTags(
                path: track.path,
                format: "mp3",
                bitrate: 192_000,
                sampleRate: 44_100,
                codec: "mp3"
            ),
            remote: makeResolvedAudio(url: "https://example.invalid/song.mp3", bitrate: 320_000)
        )

        let decision = await service.review(song: makeFeedbackSong())
        guard case .replaceLocal = decision else {
            return XCTFail("远端实测码率更高时应替换，实际：\(decision)")
        }
    }

    /// 有损 vs 有损：远端码率更低 → **保留本地**。
    func testLossyRemoteWithLowerBitrateKeepsLocal() async throws {
        let fixture = try FeedbackLibraryFixture("feedback-quality-lossy-lower")
        let track = try fixture.addTrack(
            name: "song.mp3",
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            durationMs: 269_000
        )
        let service = makeService(
            fixture: fixture,
            localTags: AudioTags(
                path: track.path,
                format: "mp3",
                bitrate: 320_000,
                sampleRate: 44_100,
                codec: "mp3"
            ),
            remote: makeResolvedAudio(url: "https://example.invalid/song.mp3", bitrate: 192_000)
        )

        let decision = await service.review(song: makeFeedbackSong())
        guard case .reuseLocal = decision else {
            return XCTFail("远端码率更低时必须保留本地，实际：\(decision)")
        }
    }

    /// 本地编码未知（`m4a` 没暴露编码）→ **禁止** 被有损远端替换。
    func testUnknownLocalIsNotReplacedByLossyRemote() async throws {
        let fixture = try FeedbackLibraryFixture("feedback-quality-unknown-local")
        let track = try fixture.addTrack(
            name: "song.m4a",
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            durationMs: 269_000
        )
        let service = makeService(
            fixture: fixture,
            localTags: AudioTags(
                path: track.path,
                format: "m4a",
                bitrate: 256_000,
                sampleRate: 44_100
            ),
            remote: makeResolvedAudio(url: "https://example.invalid/song.mp3", bitrate: 320_000)
        )

        let decision = await service.review(song: makeFeedbackSong())
        guard case .reuseLocal = decision else {
            return XCTFail("本地编码未知时不得被有损版本替换，实际：\(decision)")
        }
    }

    /// 远端解析失败 → **保守复用本地**（不猜、不重复下载）。
    func testReviewKeepsLocalWhenRemoteResolutionFails() async throws {
        let fixture = try FeedbackLibraryFixture("feedback-quality-resolve-fail")
        let track = try fixture.addTrack(
            name: "song.mp3",
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            durationMs: 269_000
        )
        let service = DownloadReviewService(
            library: fixture.library,
            tagReader: FeedbackTagReader(tags: [track.path: AudioTags(
                path: track.path,
                format: "mp3",
                bitrate: 192_000,
                codec: "mp3"
            )]),
            resolver: FeedbackSourceResolver(failure: "解析失败")
        )

        let decision = await service.review(song: makeFeedbackSong())
        guard case .reuseLocal = decision else {
            return XCTFail("远端解析失败时必须复用本地，实际：\(decision)")
        }
    }

    /// 本地标签读不出来 → **保守复用本地**。
    func testReviewKeepsLocalWhenLocalTagsUnreadable() async throws {
        let fixture = try FeedbackLibraryFixture("feedback-quality-tags-unreadable")
        let track = try fixture.addTrack(
            name: "song.mp3",
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            durationMs: 269_000
        )
        let service = DownloadReviewService(
            library: fixture.library,
            tagReader: FeedbackTagReader(unreadable: [track.path]),
            resolver: FeedbackSourceResolver(audio: makeResolvedAudio(
                url: "https://example.invalid/song.flac",
                bitrate: 900_000
            ))
        )

        let decision = await service.review(song: makeFeedbackSong())
        guard case .reuseLocal = decision else {
            return XCTFail("读不出本地标签时必须复用本地，实际：\(decision)")
        }
    }

    /// 本地没有对应曲目 → 直接下载。
    func testReviewDownloadsWhenNoLocalCandidate() async throws {
        let fixture = try FeedbackLibraryFixture("feedback-quality-new")
        try fixture.addTrack(
            name: "other.mp3",
            title: "完全不同的歌",
            artist: "完全不同的艺人",
            album: "完全不同的专辑",
            durationMs: 1_000
        )
        let service = DownloadReviewService(
            library: fixture.library,
            tagReader: FeedbackTagReader(),
            resolver: FeedbackSourceResolver()
        )

        let decision = await service.review(song: makeFeedbackSong())
        guard case .downloadNew = decision else {
            return XCTFail("本地没有对应曲目时应直接下载，实际：\(decision)")
        }
        XCTAssertTrue(decision.needsDownload)
    }

    /// 优质替换：**无损按采样率 / 位深（PCM 属性）判高低**，不按压缩后码率。
    ///
    /// 新文件压缩码率更低（800 kbps < 1 000 kbps），但 PCM 属性更好
    /// （96 kHz / 24 bit > 44.1 kHz / 16 bit）→ 应当替换。
    ///
    /// 替换语义：**保留新文件路径**（扩展名正确），旧文件移入废纸篓，
    /// 索引 / 歌单 / 入单记录全部迁到新路径。
    func testLosslessReplacementUsesPCMPropertiesNotCompressedBitrate() async throws {
        let fixture = try FeedbackLibraryFixture("feedback-quality-replace-pcm")
        let oldTrack = try fixture.addTrack(
            name: "old.flac",
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            durationMs: 269_000
        )
        let newFile = try fixture.writeDownloadedFile(name: "new.flac", contents: "新版本内容")

        let review = DownloadReviewService(
            library: fixture.library,
            tagReader: FeedbackTagReader(tags: [
                oldTrack.path: AudioTags(
                    path: oldTrack.path,
                    format: "flac",
                    durationMs: 269_000,
                    bitrate: 1_000_000,
                    sampleRate: 44_100,
                    bitDepth: 16,
                    codec: "flac",
                    title: "晴天",
                    artist: "周杰伦"
                ),
                newFile.path: AudioTags(
                    path: newFile.path,
                    format: "flac",
                    durationMs: 269_000,
                    bitrate: 800_000,
                    sampleRate: 96_000,
                    bitDepth: 24,
                    codec: "flac",
                    title: "晴天",
                    artist: "周杰伦"
                )]),
            resolver: FeedbackSourceResolver()
        )
        let replacement = DownloadReplacementService(
            store: fixture.store,
            index: fixture.index,
            library: fixture.library,
            intake: fixture.intake,
            review: review,
            trash: fixture.trashAction()
        )
        try replacement.register(neteaseId: 4242, oldPath: oldTrack.path)

        let outcome = await replacement.commit(neteaseId: 4242, newPath: newFile.path)
        guard case .committed(let path) = outcome else {
            return XCTFail("PCM 属性更好的无损版本应当替换旧文件，实际：\(outcome)")
        }
        XCTAssertEqual(path, newFile.path, "存活文件必须是新下载的文件（扩展名正确）")
        let content = try Data(contentsOf: URL(fileURLWithPath: newFile.path))
        XCTAssertEqual(String(decoding: content, as: UTF8.self), "新版本内容", "新文件内容必须保持不变")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldTrack.path),
            "旧文件应当已移走（废纸篓隔离目录）"
        )
        XCTAssertNotNil(fixture.index.track(path: newFile.path), "索引必须指向新路径")
        XCTAssertNil(fixture.index.track(path: oldTrack.path), "索引不得还留着旧路径")
        let record = fixture.store.current.pendingReplacements.last { $0.neteaseId == 4242 }
        XCTAssertEqual(record?.state, .committed, "替换记录必须标记为已提交")
        XCTAssertTrue(replacement.pendingRecords.isEmpty, "提交后不得还留着待处理记录")
    }
}
