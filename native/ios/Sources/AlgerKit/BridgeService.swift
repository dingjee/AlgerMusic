import Foundation

/// 桥接服务（FFI 传输）：把协议方法包成类型化调用。
///
/// 方法名 / 参数 / 响应结构与 macOS stdio 版 **完全一致**（同一个 Rust
/// dispatch），差别只在传输层。
public final class BridgeService {
    private let client: FFIClient

    public init(client: FFIClient) {
        self.client = client
    }

    /// 调用并要求响应是字典。
    public func callDictionary(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let response = try await client.call(method, params: params)
        return JSONValue.dictionary(response)
    }

    // MARK: - 会话 / 账号

    public func sessionSnapshot() async throws -> SessionSnapshot {
        SessionSnapshot.parse(try await callDictionary("session.snapshot"))
    }

    /// 校验 Cookie（**不落盘**；校验成功后再调 `setCookie`）。
    public func verifyCookie(_ cookie: String) async throws -> AccountInfo {
        let response = try await client.call("session.verifyCookie", params: ["cookie": cookie])
        guard let account = AccountInfo.parse(response) else {
            throw FFIClientError.bridge(code: "Decode", message: "账号信息无效")
        }
        return account
    }

    /// 提交 Cookie（桥接先校验，落盘成功后才替换会话）。
    public func setCookie(_ cookie: String) async throws {
        _ = try await client.call("session.setCookie", params: ["cookie": cookie])
    }

    /// 注销。
    @discardableResult
    public func logout() async throws -> Bool {
        let response = try await client.call("session.logout")
        return (response as? NSNumber)?.boolValue ?? false
    }

    /// 更新设置（音质 / 音源 / 下载目录）。
    public func updateSettings(
        quality: String? = nil,
        sources: [String]? = nil,
        downloadDirectory: String? = nil
    ) async throws {
        var params: [String: Any] = [:]
        if let quality { params["quality"] = quality }
        if let sources { params["sources"] = sources }
        if let downloadDirectory { params["downloadDir"] = downloadDirectory }
        guard !params.isEmpty else { return }
        _ = try await client.call("session.updateSettings", params: params)
    }

    public func account() async throws -> AccountInfo? {
        AccountInfo.parse(try await client.call("net.account"))
    }

    // MARK: - 搜索 / 播放

    /// 统一搜索（网络部分）。
    public func searchSongs(
        keywords: String,
        limit: Int = 30,
        offset: Int = 0
    ) async throws -> (songs: [RemoteSong], total: Int) {
        let response = try await callDictionary(
            "net.search",
            params: ["keywords": keywords, "limit": limit, "offset": offset]
        )
        let songs = JSONValue.array(response["songs"]).compactMap { RemoteSong.parse($0) }
        return (songs, JSONValue.int(response["total"]) ?? songs.count)
    }

    /// 解析可播放地址（优先网易源，失败回退第三方源）。
    public func resolve(song: RemoteSong) async throws -> ResolvedAudio {
        let response = try await client.call("src.resolve", params: ["song": song.bridgePayload])
        guard let audio = ResolvedAudio.parse(response) else {
            throw FFIClientError.bridge(code: "Business", message: "没有找到可播放的音源")
        }
        return audio
    }

    // MARK: - 下载

    /// 入队下载（`dir` 省略时用会话里的下载目录）。
    public func enqueueDownload(song: RemoteSong, directory: String? = nil) async throws {
        var params: [String: Any] = ["song": song.bridgePayload]
        if let directory { params["dir"] = directory }
        _ = try await client.call("dl.enqueue", params: params)
    }

    public func downloadTasks() async throws -> [DownloadTask] {
        let response = try await callDictionary("dl.list")
        return JSONValue.array(response["tasks"]).compactMap { DownloadTask.parse($0) }
    }

    public func retryDownload(id: Int64) async throws {
        _ = try await client.call("dl.retry", params: ["id": id])
    }

    public func clearDownloads() async throws {
        _ = try await client.call("dl.clear")
    }
}
