import Foundation
import XCTest
import AVFoundation

@testable import AlgerKit

/// **真实音频**播放回归：AVPlayer 真的加载文件、真的推进时间、
/// 真的自然结束（不是手动伪造结束通知）。
///
/// 规格（计数口径）：
/// - **只计完整在线播放**：队列来源是网络曲目、**实际播的也是网络流**、
///   自然播完、期间没有 seek / 停止 → 计一次；
/// - 本地文件播放（无论队列来源是本地还是「网络曲目本地优先命中本地文件」）
///   → **不计数**；
/// - 拖过进度 / 停止过 → **不计数**。
///
/// 等待方式：见 `waitForPlayback`（必须让出主 actor，否则 AVFoundation 的
/// 主队列回调收不到，播放看起来「完全不动」）。
@MainActor
final class PlaybackRealAudioTests: XCTestCase {

    private func remoteItem(id: Int64, title: String = "网络曲目", durationMs: Int64 = 2000) -> PlaybackItem {
        PlaybackItem(
            title: title,
            artist: "艺人",
            album: "专辑",
            durationMs: durationMs,
            origin: .remote(neteaseId: id),
            remoteSong: RemoteSong(
                id: id,
                name: title,
                artists: [RemoteArtist(id: 1, name: "艺人")],
                album: RemoteAlbum(id: 2, name: "专辑", picUrl: ""),
                durationMs: durationMs
            )
        )
    }

    /// 真实 **HTTP 流**播放：时间真的在推进，播完自然结束 → 只计一次。
    func testRealHTTPStreamReachesNaturalEndAndCountsOnce() async throws {
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 1.0))
        defer { server.stop() }
        let streamURL = server.baseURL.appendingPathComponent("song.wav")

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: streamURL, isLocal: false, note: "网络") }
        let player = PlayerController(resolver: resolver)
        var counted = 0
        player.onCompletedRemotePlay = { _ in counted += 1 }

        await player.replaceQueue([remoteItem(id: 1, durationMs: 1000)])
        let advanced = await waitForPlayback(timeout: 15) { player.currentTime > 0.05 }
        XCTAssertTrue(
            advanced,
            "真实 HTTP 音频应当推进播放时间（当前 \(player.currentTime)，item 状态 \(player.currentPlayerItem?.status.rawValue ?? -1)，错误 \(player.currentPlayerItem?.error as Any)）"
        )
        XCTAssertTrue(player.isPlaying)

        let finished = await waitForPlayback(timeout: 25) { counted == 1 }
        XCTAssertTrue(finished, "真实音频自然结束后应当计数一次（计数 \(counted)）")
        XCTAssertEqual(counted, 1, "一次播放最多计一次")

        // 再播一次同一条目 → 又是一次新的完整播放。
        await player.play(at: 0)
        _ = await waitForPlayback(timeout: 15) { player.currentTime > 0.05 }
        let finishedAgain = await waitForPlayback(timeout: 25) { counted == 2 }
        XCTAssertTrue(finishedAgain, "第二次完整播放应当再计一次")
        XCTAssertEqual(counted, 2)
    }

    /// 真实本地文件播放：时间推进 + 自然结束 → **不计数**（不是在线播放）。
    func testRealLocalFileReachesNaturalEndAndIsNotCounted() async throws {
        let workspace = try TempWorkspace("player-real-file")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 1.0)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: audio, isLocal: true, note: "本地文件") }
        let player = PlayerController(resolver: resolver)
        var counted = 0
        player.onCompletedRemotePlay = { _ in counted += 1 }

        await player.replaceQueue([remoteItem(id: 31, durationMs: 1000)])
        let advanced = await waitForPlayback(timeout: 15) { player.currentTime > 0.05 }
        XCTAssertTrue(
            advanced,
            "真实本地文件应当推进播放时间（当前 \(player.currentTime)，item 状态 \(player.currentPlayerItem?.status.rawValue ?? -1)，错误 \(String(describing: player.currentPlayerItem?.error))，loadedURL \(String(describing: player.currentLoadedURL))）"
        )
        let ended = await waitForPlayback(timeout: 25) { !player.isPlaying }
        XCTAssertTrue(ended, "真实本地文件应当播放到自然结束")
        XCTAssertEqual(counted, 0, "本地文件播放不是在线播放，不计数")
    }

    /// 网络曲目 **本地优先** 命中本地文件 → 播的是本地文件 → **不计数**。
    ///
    /// 规格：只计完整 **在线** 播放；本地优先命中本地文件时播的是本地文件。
    func testRemoteSongResolvedToLocalFileIsNotCounted() async throws {
        let workspace = try TempWorkspace("player-local-first-count")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 1.0)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: audio, isLocal: true, note: "本地文件") }
        let player = PlayerController(resolver: resolver)
        var counted = 0
        player.onCompletedRemotePlay = { _ in counted += 1 }

        await player.replaceQueue([remoteItem(id: 32, durationMs: 1000)])
        let advanced = await waitForPlayback(timeout: 15) { player.currentTime > 0.05 }
        XCTAssertTrue(advanced, "本地优先命中时也应当真的开始播放")
        XCTAssertEqual(
            player.currentLocalPath,
            audio.path,
            "网络曲目本地优先命中时也必须报告实际播放的本地路径"
        )
        let ended = await waitForPlayback(timeout: 25) { !player.isPlaying }
        XCTAssertTrue(ended, "本地优先命中时应当播放到自然结束")
        XCTAssertEqual(counted, 0, "播的是本地文件，不算完整在线播放")
    }

    /// 暂停 → 继续 → 自然结束：**只计一次**（在线播放，暂停续播不重复计数）。
    func testRealHTTPStreamPauseResumeCountsOnce() async throws {
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 1.5))
        defer { server.stop() }
        let streamURL = server.baseURL.appendingPathComponent("song.wav")

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: streamURL, isLocal: false, note: "网络") }
        let player = PlayerController(resolver: resolver)
        var counted = 0
        player.onCompletedRemotePlay = { _ in counted += 1 }

        await player.replaceQueue([remoteItem(id: 7, durationMs: 1500)])
        let advanced = await waitForPlayback(timeout: 15) { player.currentTime > 0.05 }
        XCTAssertTrue(advanced, "真实 HTTP 音频应当推进播放时间")

        player.pause()
        XCTAssertFalse(player.isPlaying)
        let pausedTime = player.currentTime
        // 暂停期间时间不应继续推进。
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(player.currentTime, pausedTime, accuracy: 0.05, "暂停时时间不应继续推进")

        player.resume()
        XCTAssertTrue(player.isPlaying)
        let finished = await waitForPlayback(timeout: 25) { counted == 1 }
        XCTAssertTrue(finished, "暂停续播后自然结束应当计数一次（计数 \(counted)）")
        XCTAssertEqual(counted, 1, "暂停续播不得重复计数")
    }

    /// 拖动进度 → 自然结束：**不计数**（拖过进度不算完整听完）。
    func testRealHTTPStreamSeekCancelsCount() async throws {
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 1.5))
        defer { server.stop() }
        let streamURL = server.baseURL.appendingPathComponent("song.wav")

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: streamURL, isLocal: false, note: "网络") }
        let player = PlayerController(resolver: resolver)
        var counted = 0
        player.onCompletedRemotePlay = { _ in counted += 1 }

        await player.replaceQueue([remoteItem(id: 9, durationMs: 1500)])
        let advanced = await waitForPlayback(timeout: 15) { player.currentTime > 0.05 }
        XCTAssertTrue(advanced, "真实 HTTP 音频应当推进播放时间")

        player.seek(to: max(player.duration - 0.05, 0.1))
        let finished = await waitForPlayback(timeout: 25) { !player.isPlaying }
        XCTAssertTrue(finished, "seek 之后应当播到结尾")
        XCTAssertEqual(counted, 0, "拖过进度不得计入完整播放")
    }

    /// 切歌：**旧声音必须立刻停止**（旧声 / 新 UI 不一致），新曲真的开始播。
    func testSwitchingTracksStopsOldSound() async throws {
        let workspace = try TempWorkspace("player-real-switch")
        let first = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 3.0)
        let second = try TestAudio.writeWAV(to: workspace.url("b.wav"), seconds: 3.0)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { item in
            if item.title == "第二首" {
                // 解析要一会儿：这段时间里旧声音 **不能** 继续播。
                try? await Task.sleep(nanoseconds: 400_000_000)
                return PlaybackSource(url: second, isLocal: true, note: "第二首")
            }
            return PlaybackSource(url: first, isLocal: true, note: "第一首")
        }
        let player = PlayerController(resolver: resolver)

        await player.replaceQueue([
            remoteItem(id: 1, title: "第一首", durationMs: 3000),
            remoteItem(id: 2, title: "第二首", durationMs: 3000),
        ])
        let firstAdvanced = await waitForPlayback(timeout: 15) { player.currentTime > 0.05 }
        XCTAssertTrue(firstAdvanced, "第一首应当真的开始播放")
        let oldItem = player.currentPlayerItem
        XCTAssertNotNil(oldItem, "第一首应当有真实播放项")

        // 切到第二首（解析要 400ms）。
        let switchTask = Task { await player.play(at: 1) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        // 解析期间：旧声音 **不能** 继续播，界面也不能显示旧曲目的状态。
        XCTAssertFalse(player.isPlaying, "切歌解析期间不得继续播放旧声音")
        XCTAssertFalse(oldItem === player.currentPlayerItem, "切歌后旧播放项必须脱离播放器")
        XCTAssertEqual(player.current?.title, "第二首", "界面应当立刻切到新曲目")
        _ = await switchTask.value

        let settled = await waitForPlayback(timeout: 15) { player.current?.title == "第二首" && player.isPlaying }
        XCTAssertTrue(settled, "应当切到第二首并开始播放")
        XCTAssertEqual(player.current?.title, "第二首")
        let secondAdvanced = await waitForPlayback(timeout: 15) { player.currentTime > 0.05 }
        XCTAssertTrue(secondAdvanced, "第二首应当真的推进播放时间")
    }

    /// 网络曲目 **本地优先** 命中同一个本地文件 →
    /// 删除该文件前必须能认出「正在播的就是这个文件」并停掉播放。
    func testRemoteSongResolvedToLocalFileIsDetectedAndStopped() async throws {
        let workspace = try TempWorkspace("player-local-first")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 2.0)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in PlaybackSource(url: audio, isLocal: true, note: "本地文件") }
        let player = PlayerController(resolver: resolver)

        await player.replaceQueue([remoteItem(id: 21, durationMs: 2000)])
        let advanced = await waitForPlayback(timeout: 15) { player.currentTime > 0.02 }
        XCTAssertTrue(advanced, "本地优先命中时应当真的开始播放")
        XCTAssertEqual(
            player.currentLocalPath,
            audio.path,
            "网络曲目本地优先命中时也必须报告实际播放的本地路径"
        )
        XCTAssertTrue(
            player.stopIfPlayingLocalFile(path: audio.path),
            "必须能停掉正在播的本地文件"
        )
        XCTAssertFalse(player.isPlaying, "停止后不得继续播放")
        XCTAssertNil(player.currentLocalPath, "停止后不得再报告本地路径")
    }

    /// 本地文件播放（真实音频，队列项本身就是本地来源）→ **不计数**。
    func testRealLocalAudioIsNotCounted() async throws {
        let workspace = try TempWorkspace("player-real-local")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 0.8)

        let resolver = FakePlaybackResolver()
        resolver.setHandler { item in
            switch item.origin {
            case .local(let path):
                return PlaybackSource(url: URL(fileURLWithPath: path), isLocal: true)
            case .remote:
                throw PlaybackError.invalidSource("不该走到这里")
            }
        }
        let player = PlayerController(resolver: resolver)
        var counted = 0
        player.onCompletedRemotePlay = { _ in counted += 1 }

        await player.replaceQueue([PlaybackItem(
            title: "本地曲目",
            artist: "",
            durationMs: 800,
            origin: .local(path: audio.path)
        )])
        let advanced = await waitForPlayback(timeout: 15) { player.currentTime > 0.02 }
        XCTAssertTrue(advanced, "本地音频应当真的开始播放")
        let ended = await waitForPlayback(timeout: 20) { !player.isPlaying }
        XCTAssertTrue(ended, "本地音频应当播放到结束")
        XCTAssertEqual(counted, 0, "本地播放不计数")
    }
}
