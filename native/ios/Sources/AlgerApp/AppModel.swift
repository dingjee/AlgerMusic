import AlgerKit
import Foundation
import SwiftUI

/// 应用状态中枢（极简版）。
///
/// - **会话**：桥接 `session.snapshot` → 是否已登录；
/// - **下载目录**：启动时写回容器路径（Rust 侧的 `dirs` 在 iOS 不可靠）；
/// - **播放**：搜索结果点击 → 解析音源 → 播放。
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var client: FFIClient?
    @Published private(set) var service: BridgeService?
    @Published private(set) var session: SessionSnapshot?
    @Published private(set) var account: AccountInfo?
    @Published private(set) var isReady = false
    @Published private(set) var fatalError: String?

    let player = PlayerController()
    @Published private(set) var downloads: DownloadStore?

    private var downloadsDirectory: URL?

    /// 启动：建桥接 → 写设置 → 读会话 → 订阅下载事件。
    func bootstrap() async {
        do {
            let sessionPath = try ContainerPaths.sessionFile().path
            let downloadsDir = try ContainerPaths.downloadsDirectory()
            downloadsDirectory = downloadsDir

            let client = try FFIClient(sessionPath: sessionPath)
            let service = BridgeService(client: client)
            self.client = client
            self.service = service

            // 下载目录固定为容器目录（文件 App 可见）；音质用较高档。
            try? await service.updateSettings(quality: "higher", downloadDirectory: downloadsDir.path)

            let store = DownloadStore(service: service)
            store.startObserving(client: client)
            downloads = store
            await store.refresh()

            await refreshSession()
            isReady = true
        } catch {
            fatalError = DownloadStore.describe(error)
            isReady = true
        }
    }

    /// 刷新会话状态（登录 / 注销后调用）。
    func refreshSession() async {
        guard let service else { return }
        do {
            let snapshot = try await service.sessionSnapshot()
            session = snapshot
            account = snapshot.account
        } catch {
            fatalError = DownloadStore.describe(error)
        }
    }

    /// 登录成功：提交 Cookie（桥接校验后落盘）→ 刷新会话。
    func completeLogin(cookie: String) async -> Bool {
        guard let service else { return false }
        do {
            _ = try await service.verifyCookie(cookie)
            try await service.setCookie(cookie)
            await refreshSession()
            return true
        } catch {
            fatalError = DownloadStore.describe(error)
            return false
        }
    }

    func signOut() async {
        guard let service else { return }
        try? await service.logout()
        await refreshSession()
    }

    /// 解析音源并播放（搜索结果点击）。
    func play(song: RemoteSong) async {
        guard let service else { return }
        do {
            let audio = try await service.resolve(song: song)
            guard let url = URL(string: audio.url) else {
                player.reportError("音源地址无效")
                return
            }
            player.playResolved(url: url, song: song, sourceLabel: audio.sourceLabel)
        } catch {
            player.reportError(DownloadStore.describe(error))
        }
    }

    /// 下载一首歌。
    func download(song: RemoteSong) async -> Bool {
        guard let downloads else { return false }
        return await downloads.enqueue(song: song, directory: downloadsDirectory?.path)
    }

    /// 播放已下载文件。
    func playDownload(_ task: DownloadTask) {
        guard let downloads, let url = downloads.localURL(for: task) else { return }
        let song = RemoteSong(
            id: task.id,
            name: task.name,
            artists: [RemoteArtist(id: 0, name: task.artist)],
            album: RemoteAlbum(id: 0, name: "本地下载", picUrl: ""),
            durationMs: 0
        )
        player.playLocal(song: song, url: url)
    }
}
