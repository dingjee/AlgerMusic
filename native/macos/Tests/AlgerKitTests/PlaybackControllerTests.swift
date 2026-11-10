import Foundation
import XCTest
import AVFoundation

@testable import AlgerKit

#if canImport(Darwin)
import Darwin
#endif

/// 可控的播放地址解析器（夹具）。
///
/// 测试里只在主线程设置与调用，因此不加锁（避免异步上下文里的 NSLock 告警）。
final class FakePlaybackResolver: PlaybackResolving, @unchecked Sendable {
    private var handler: (@Sendable (PlaybackItem) async throws -> PlaybackSource)?

    func setHandler(_ handler: @escaping @Sendable (PlaybackItem) async throws -> PlaybackSource) {
        self.handler = handler
    }

    func resolve(_ item: PlaybackItem) async throws -> PlaybackSource {
        guard let handler else {
            throw PlaybackError.invalidSource("夹具没有配置解析器")
        }
        return try await handler(item)
    }
}

/// 播放器状态机（代次 / 计数 / seek）的回归。
@MainActor
final class PlaybackControllerTests: XCTestCase {

    private func makeRemoteItem(id: Int64 = 4242) -> PlaybackItem {
        PlaybackItem(
            title: "网络曲目",
            artist: "艺人",
            album: "专辑",
            durationMs: 5000,
            origin: .remote(neteaseId: id),
            remoteSong: RemoteSong(
                id: id,
                name: "网络曲目",
                artists: [RemoteArtist(id: 1, name: "艺人")],
                album: RemoteAlbum(id: 2, name: "专辑", picUrl: ""),
                durationMs: 5000
            )
        )
    }

    private func makeLocalItem(path: String) -> PlaybackItem {
        PlaybackItem(
            title: "本地曲目",
            artist: "",
            durationMs: 1000,
            origin: .local(path: path)
        )
    }

    /// 快速切歌：旧解析结果 **不得** 覆盖新曲目。
    func testStaleResolutionDoesNotOverrideNewTrack() async throws {
        let workspace = try TempWorkspace("player-stale")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.5)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { item in
            if item.title == "慢的" {
                try? await Task.sleep(nanoseconds: 400_000_000)
                return PlaybackSource(url: audio, isLocal: false, note: "慢的")
            }
            return PlaybackSource(url: audio, isLocal: false, note: "新的")
        }

        let player = PlayerController(resolver: resolver)
        let slow = PlaybackItem(
            title: "慢的",
            artist: "",
            durationMs: 1000,
            origin: .remote(neteaseId: 1),
            remoteSong: RemoteSong(id: 1, name: "慢的", artists: [], album: RemoteAlbum(id: 0, name: "", picUrl: ""), durationMs: 1000)
        )
        let fast = makeRemoteItem(id: 2)

        // 慢的那条先开始（解析要 400ms），中途切到新的那条。
        let slowTask = Task { await player.replaceQueue([slow]) }
        try? await Task.sleep(nanoseconds: 80_000_000)
        let fastTask = Task { await player.replaceQueue([fast]) }

        let settled = await waitUntil(timeout: 3) { player.sourceDescription == "新的" }
        _ = await slowTask.value
        _ = await fastTask.value
        XCTAssertTrue(settled, "旧解析结果不得覆盖新曲目（当前：\(player.sourceDescription)）")
        XCTAssertEqual(player.current?.id, "netease:2")
    }

    /// 停止播放 → 在途解析作废，不得再把播放器拉起来。
    func testStopCancelsPendingResolution() async throws {
        let workspace = try TempWorkspace("player-stop")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.5)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return PlaybackSource(url: audio, isLocal: false, note: "迟到的结果")
        }
        let player = PlayerController(resolver: resolver)
        await player.replaceQueue([makeRemoteItem()])
        player.stopPlayback()

        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(player.isPlaying, "停止后不得被迟到的解析结果拉起来")
        XCTAssertEqual(player.sourceDescription, "")
    }

    /// 自然播完（网络曲目）→ 计数一次。
    func testNaturalCompletionCountsOnce() async throws {
        let workspace = try TempWorkspace("player-count")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.5)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in
            PlaybackSource(url: audio, isLocal: false, note: "网络")
        }
        let player = PlayerController(resolver: resolver)
        var counted = 0
        player.onCompletedRemotePlay = { _ in counted += 1 }

        await player.replaceQueue([makeRemoteItem()])
        let playing = await waitUntil { player.isPlaying }
        XCTAssertTrue(playing, "应当开始播放")

        postEnd(of: player)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counted, 1, "完整播完的网络曲目应当计一次")

        // 再播一次同一条目：这一次 **先 seek** → 不得计数。
        await player.play(at: 0)
        _ = await waitUntil { player.isPlaying }
        player.seek(to: 1)
        postEnd(of: player)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counted, 1, "拖过进度后的这次播放不得计数")
    }

    /// 停止播放后即使收到结束通知也不计数。
    func testStopCancelsCompletionCount() async throws {
        let workspace = try TempWorkspace("player-stop-count")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.5)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: audio, isLocal: false, note: "网络") }
        let player = PlayerController(resolver: resolver)
        var counted = 0
        player.onCompletedRemotePlay = { _ in counted += 1 }

        await player.replaceQueue([makeRemoteItem()])
        _ = await waitUntil { player.isPlaying }
        player.stopPlayback()
        postEnd(of: player)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counted, 0, "停止后的结束通知不得计数")
    }

    /// 本地曲目播放不计数（只有网络曲目计数）。
    func testLocalPlaybackIsNotCounted() async throws {
        let workspace = try TempWorkspace("player-local-count")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.5)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: audio, isLocal: true, note: nil) }
        let player = PlayerController(resolver: resolver)
        var counted = 0
        player.onCompletedRemotePlay = { _ in counted += 1 }

        await player.replaceQueue([makeLocalItem(path: audio.path)])
        _ = await waitUntil { player.isPlaying }
        postEnd(of: player)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counted, 0, "本地播放不计数")
    }

    /// 队列操作：跳过 / 上一首 / 移除。
    func testQueueNavigationAndRemoval() async throws {
        let workspace = try TempWorkspace("player-queue")
        let a = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.3)
        let b = try TestAudio.writeWAV(to: workspace.url("b.wav"), seconds: 0.3)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { item in
            PlaybackSource(url: item.title == "A" ? a : b, isLocal: false, note: item.title)
        }
        let player = PlayerController(resolver: resolver)
        let first = PlaybackItem(title: "A", artist: "", durationMs: 500, origin: .remote(neteaseId: 1),
                                remoteSong: RemoteSong(id: 1, name: "A", artists: [], album: RemoteAlbum(id: 0, name: "", picUrl: ""), durationMs: 500))
        let second = PlaybackItem(title: "B", artist: "", durationMs: 500, origin: .remote(neteaseId: 2),
                                  remoteSong: RemoteSong(id: 2, name: "B", artists: [], album: RemoteAlbum(id: 0, name: "", picUrl: ""), durationMs: 500))
        await player.replaceQueue([first, second])
        XCTAssertEqual(player.queue.count, 2)
        XCTAssertEqual(player.current?.title, "A")

        player.next()
        _ = await waitUntil { player.current?.title == "B" }
        XCTAssertEqual(player.current?.title, "B", "跳过应当前进到下一首")

        player.previous()
        _ = await waitUntil { player.current?.title == "A" }
        XCTAssertEqual(player.current?.title, "A", "上一首应当回到前一首")

        // 移除当前项 → 停止播放。
        player.removeFromQueue(at: 0)
        XCTAssertEqual(player.queue.count, 1)
        XCTAssertNil(player.current)
        XCTAssertFalse(player.isPlaying)
    }

    /// 暂停 / 继续。
    func testPauseAndResume() async throws {
        let workspace = try TempWorkspace("player-pause")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.5)
        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: audio, isLocal: false, note: "网络") }
        let player = PlayerController(resolver: resolver)
        await player.replaceQueue([makeRemoteItem()])
        _ = await waitUntil { player.isPlaying }

        player.pause()
        XCTAssertFalse(player.isPlaying)
        player.resume()
        XCTAssertTrue(player.isPlaying)
        player.togglePlayPause()
        XCTAssertFalse(player.isPlaying)
    }

    /// 本地文件缺失 → 明确报错（不静默跳过）。
    func testMissingLocalFileReportsError() async throws {
        let resolver = FakePlaybackResolver()
        resolver.setHandler { item in
            switch item.origin {
            case .local(let path):
                guard FileManager.default.fileExists(atPath: path) else {
                    throw PlaybackError.localFileMissing(path)
                }
                return PlaybackSource(url: URL(fileURLWithPath: path), isLocal: true)
            case .remote:
                throw PlaybackError.invalidSource("不该走到这里")
            }
        }
        let player = PlayerController(resolver: resolver)
        await player.replaceQueue([makeLocalItem(path: "/definitely/missing/file.wav")])
        _ = await waitUntil { player.errorMessage != nil }
        XCTAssertNotNil(player.errorMessage)
        XCTAssertTrue(player.errorMessage?.contains("无法播放") ?? false, player.errorMessage ?? "")
        XCTAssertFalse(player.isPlaying)
    }

    func testUndoQueueAdditionPreservesEarlierOccurrenceOfSameSong() {
        let player = PlayerController(resolver: FakePlaybackResolver())
        let old = makeLocalItem(path: "/fixture/song.wav")
        let added = makeLocalItem(path: "/fixture/song.wav")
        player.enqueue([old, added])
        XCTAssertTrue(player.removeQueueEntry(id: added.queueEntryId))
        XCTAssertEqual(player.queue.map(\.queueEntryId), [old.queueEntryId])
        XCTAssertFalse(player.removeQueueEntry(id: added.queueEntryId))
    }

    /// 触发「播放到结尾」通知（真实通知对象 = 当前播放项）。
    private func postEnd(of player: PlayerController) {
        guard let item = player.currentPlayerItem else { return }
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
    }

    // MARK: - 队列耗尽（私人 FM 续批的接入点）

    /// 自然播完（队列末尾）→ 触发 **队列耗尽** 回调。
    func testQueueExhaustionFiresWhenQueueEnds() async throws {
        let workspace = try TempWorkspace("player-exhaust-natural")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.5)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: audio, isLocal: false, note: "网络") }
        let player = PlayerController(resolver: resolver)
        var exhausted = 0
        player.onQueueExhausted = { exhausted += 1 }

        await player.replaceQueue([makeRemoteItem()])
        _ = await waitUntil { player.isPlaying }
        postEnd(of: player)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(exhausted, 1, "队列末尾自然播完必须报一次耗尽")
    }

    /// 队列 **中间** 播完 → 不得报耗尽（下一首照旧接着播）。
    func testQueueExhaustionNotFiredMidQueue() async throws {
        let workspace = try TempWorkspace("player-exhaust-mid")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.5)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: audio, isLocal: false, note: "网络") }
        let player = PlayerController(resolver: resolver)
        var exhausted = 0
        player.onQueueExhausted = { exhausted += 1 }

        await player.replaceQueue([makeRemoteItem(id: 1), makeRemoteItem(id: 2)])
        _ = await waitUntil { player.isPlaying }
        postEnd(of: player)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(exhausted, 0, "队列还有下一首时不得报耗尽")
        XCTAssertEqual(player.current?.id, "netease:2", "应当自动接着播下一首")
    }

    /// 手动「下一首」走到队列末尾 → 报耗尽（私人 FM 用它取下一批）。
    func testManualNextAtEndReportsExhaustion() async throws {
        let workspace = try TempWorkspace("player-exhaust-next")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.5)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: audio, isLocal: false, note: "网络") }
        let player = PlayerController(resolver: resolver)
        var exhausted = 0
        player.onQueueExhausted = { exhausted += 1 }

        await player.replaceQueue([makeRemoteItem()])
        _ = await waitUntil { player.isPlaying }
        player.next()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(exhausted, 1, "手动下一首到末尾必须报耗尽")
    }

    /// 私人 FM 模式：随机轮播完时 **先报耗尽**（不重开一轮普通随机播放）。
    func testExternalContinuationReportsExhaustionBeforeRestartingShuffleRound() async throws {
        let workspace = try TempWorkspace("player-exhaust-shuffle")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.5)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: audio, isLocal: false, note: "网络") }
        let player = PlayerController(resolver: resolver)
        player.setPlaybackOrder(.shuffle, randomSeed: 42)
        var exhausted = 0
        player.onQueueExhausted = { exhausted += 1 }
        player.continuesOnExhaustion = true

        await player.replaceQueue([makeRemoteItem(id: 1), makeRemoteItem(id: 2)])
        _ = await waitUntil { player.isPlaying }
        // 走完这一轮（两首各播一次）。
        player.next()
        _ = await waitUntil { player.current?.id == "netease:2" }
        player.next()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(exhausted, 1, "随机轮播完必须报耗尽（由私人 FM 续批）")
        XCTAssertEqual(player.current?.id, "netease:2", "不得重开一轮普通随机播放")
    }

    /// 普通播放（不接管续播）：随机轮播完 **重开一轮**，不报耗尽。
    func testNormalPlaybackRestartsShuffleRoundWithoutExhaustion() async throws {
        let workspace = try TempWorkspace("player-exhaust-shuffle-normal")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.5)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: audio, isLocal: false, note: "网络") }
        let player = PlayerController(resolver: resolver)
        player.setPlaybackOrder(.shuffle, randomSeed: 42)
        var exhausted = 0
        player.onQueueExhausted = { exhausted += 1 }

        await player.replaceQueue([makeRemoteItem(id: 1), makeRemoteItem(id: 2)])
        _ = await waitUntil { player.isPlaying }
        player.next()
        _ = await waitUntil { player.current?.id == "netease:2" }
        player.next()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(exhausted, 0, "普通播放不报耗尽（行为不变）")
        XCTAssertNotNil(player.current, "普通随机轮播完会重开一轮")
    }
}
