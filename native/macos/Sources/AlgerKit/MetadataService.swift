import Foundation

// MARK: - 元信息服务

/// `meta.*` 方法与 `tags.*` 的类型化封装（E5）。
///
/// 契约固定的方法与参数（与 `crates/alger-bridge` 一致）：
/// - `meta.search {title, artist, durationMs?, limit?, token?} -> {candidates: [Candidate]}`
/// - `meta.lookup {recordingId, token?} -> {candidate: Candidate}`
/// - `meta.release {releaseId, recordingId?, token?} -> {release: Release, tracks: [Track]}`
/// - `meta.artwork {releaseId, token?} -> {artworkBase64, mimeType, releaseId}`
/// - `meta.fingerprint {path, apiKey, fpcalcPath?, token?} -> {candidates: [Candidate]}`
/// - `meta.cancel {token} -> {cancelled: true}`
/// - `tags.read {path}` / `tags.write {path, patch}` / `tags.artwork {path}`
///
/// 约定：
/// - **直接用 `BridgeClient.callDictionary`**（不经过 `BridgeService`）：
///   元信息是独立能力，不污染既有桥接服务；
/// - **令牌取消**：每个在途操作带 token；本地 Task 取消时后台补发一次
///   `meta.cancel`，服务端（MusicBrainz 限速队列）尽早停止；
/// - **封面上限**：解码后超过 `MetadataTagPatch.maxArtworkBytes`（4 MiB）报错，
///   保证配合桥接 `maxLineBytes`（base64 后约 5.6 MiB < 8 MiB）；
/// - **不打日志**：API key、封面 base64 不会出现在任何日志或错误文本里；
/// - **离线明确失败**：桥接不可达 / EOF 直接抛错，绝不假成功，也不阻塞播放
///   （调用方是编辑器 sheet，与播放互不影响；本类不做主线程整文件哈希）。
public final class MetadataService {
    /// 桥接客户端（**唯一**依赖；不持有也不改动 `BridgeService`）。
    public let client: BridgeClient

    public init(client: BridgeClient) {
        self.client = client
    }

    // MARK: 在线匹配

    /// 按标题 / 艺人搜索录音候选（MusicBrainz）。
    public func search(
        title: String,
        artist: String,
        durationMs: Int? = nil,
        limit: Int? = nil,
        token: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> [MetadataCandidate] {
        var params: [String: Any] = ["title": title, "artist": artist]
        if let durationMs { params["durationMs"] = durationMs }
        if let limit { params["limit"] = limit }
        if let token { params["token"] = token }
        let response = try await withCancellation(token: token, timeout: timeout) {
            try await self.client.callDictionary("meta.search", params: params, timeout: timeout)
        }
        return try parseCandidates(JSONValue.array(response["candidates"]), context: "meta.search")
    }

    /// 按 MusicBrainz 录音 ID 精确取候选（确认录音时用）。
    public func lookup(
        recordingId: String,
        token: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> MetadataCandidate {
        var params: [String: Any] = ["recordingId": recordingId]
        if let token { params["token"] = token }
        let response = try await withCancellation(token: token, timeout: timeout) {
            try await self.client.callDictionary("meta.lookup", params: params, timeout: timeout)
        }
        guard let candidate = MetadataCandidate.parse(response["candidate"]) else {
            throw MetadataError.invalidResponse("meta.lookup 未返回有效候选")
        }
        return candidate
    }

    /// 取发行详情（发行 + 曲目列表）。
    @discardableResult
    public func release(
        releaseId: String,
        recordingId: String? = nil,
        token: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> (release: MetadataRelease, tracks: [MetadataTrack]) {
        var params: [String: Any] = ["releaseId": releaseId]
        if let recordingId { params["recordingId"] = recordingId }
        if let token { params["token"] = token }
        let response = try await withCancellation(token: token, timeout: timeout) {
            try await self.client.callDictionary("meta.release", params: params, timeout: timeout)
        }
        guard let release = MetadataRelease.parse(response["release"]) else {
            throw MetadataError.invalidResponse("meta.release 未返回有效发行")
        }
        let tracks = JSONValue.array(response["tracks"]).compactMap { MetadataTrack.parse($0) }
        return (release, tracks)
    }

    /// 取确认发行版本的 CAA 封面（**按发行版本**，不按录音）。
    public func artwork(
        releaseId: String,
        token: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> MetadataArtwork {
        var params: [String: Any] = ["releaseId": releaseId]
        if let token { params["token"] = token }
        let response = try await withCancellation(token: token, timeout: timeout) {
            try await self.client.callDictionary("meta.artwork", params: params, timeout: timeout)
        }
        guard let base64 = JSONValue.string(response["artworkBase64"]), !base64.isEmpty,
              let data = Data(base64Encoded: base64), !data.isEmpty
        else {
            throw MetadataError.invalidResponse("meta.artwork 未返回有效封面数据")
        }
        if data.count > MetadataTagPatch.maxArtworkBytes {
            throw MetadataError.artworkTooLarge(
                bytes: data.count,
                limit: MetadataTagPatch.maxArtworkBytes
            )
        }
        return MetadataArtwork(
            data: data,
            mimeType: JSONValue.string(response["mimeType"]) ?? "",
            releaseId: JSONValue.string(response["releaseId"]) ?? releaseId
        )
    }

    /// AcoustID 音频指纹匹配（指纹由 Rust 侧调用 fpcalc 计算）。
    ///
    /// 缺 key / 缺 fpcalc 工具时桥接会明确报错，这里原样上抛，不假成功。
    public func fingerprint(
        path: String,
        apiKey: String,
        fpcalcPath: String? = nil,
        token: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> [MetadataCandidate] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MetadataError.missingConfiguration("未配置 AcoustID API key")
        }
        var params: [String: Any] = ["path": path, "apiKey": apiKey]
        let trimmedTool = fpcalcPath.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if !trimmedTool.isEmpty { params["fpcalcPath"] = trimmedTool }
        if let token { params["token"] = token }
        let response = try await withCancellation(token: token, timeout: timeout) {
            try await self.client.callDictionary("meta.fingerprint", params: params, timeout: timeout)
        }
        return try parseCandidates(JSONValue.array(response["candidates"]), context: "meta.fingerprint")
    }

    /// 通知服务端取消某个在途操作。
    @discardableResult
    public func cancel(token: String) async throws -> Bool {
        let response = try await client.callDictionary("meta.cancel", params: ["token": token])
        return JSONValue.bool(response["cancelled"]) ?? false
    }

    // MARK: 标签读写（桥接现有 tags.*）

    /// 读取音频标签（写前基线 / 写后核验都用它）。
    public func readTags(path: String, timeout: TimeInterval? = nil) async throws -> AudioTags {
        let response = try await client.callDictionary("tags.read", params: ["path": path], timeout: timeout)
        guard let tags = AudioTags.parse(response) else {
            throw MetadataError.invalidResponse("tags.read 未返回有效标签")
        }
        return tags
    }

    /// 读取音频内嵌封面（`tags.artwork` 返回 `{base64}`）。
    public func embeddedArtwork(path: String, timeout: TimeInterval? = nil) async throws -> Data? {
        switch try await embeddedArtworkState(path: path, timeout: timeout) {
        case .present(let data): return data
        case .none: return nil
        case .unreadable: return nil
        }
    }

    /// 读取音频内嵌封面（**区分「没有封面」与「读不出来」**）。
    ///
    /// `hasArtwork` 来自 `tags.read`；只有确实有封面时才再取 `tags.artwork` 的字节。
    public func embeddedArtworkState(
        path: String,
        tags: AudioTags? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> MetadataEmbeddedArtwork {
        let current: AudioTags
        if let tags {
            current = tags
        } else {
            current = try await readTags(path: path, timeout: timeout)
        }
        guard current.hasArtwork else { return .none }
        let response = try await client.callDictionary(
            "tags.artwork",
            params: ["path": path],
            timeout: timeout
        )
        guard let base64 = JSONValue.string(response["base64"]), !base64.isEmpty else {
            return .unreadable("tags.artwork 未返回封面数据")
        }
        guard let data = Data(base64Encoded: base64) else {
            return .unreadable("tags.artwork 返回的封面 base64 无法解码")
        }
        return .present(data)
    }

    /// 写入音频标签（**只在用户确认后调用**；桥接侧做原子替换 + 读回验证）。
    @discardableResult
    public func writeTags(
        path: String,
        patch: MetadataTagPatch,
        timeout: TimeInterval? = nil
    ) async throws -> AudioTags {
        let response = try await client.callDictionary(
            "tags.write",
            params: ["path": path, "patch": patch.payload()],
            timeout: timeout ?? 120
        )
        guard let tags = AudioTags.parse(response) else {
            throw MetadataError.invalidResponse("tags.write 未返回有效标签")
        }
        return tags
    }

    // MARK: 内部

    private func parseCandidates(_ array: [Any], context: String) throws -> [MetadataCandidate] {
        var candidates: [MetadataCandidate] = []
        for item in array {
            guard let candidate = MetadataCandidate.parse(item) else {
                throw MetadataError.invalidResponse("\(context) 存在无法解析的候选")
            }
            candidates.append(candidate)
        }
        return candidates
    }

    /// 本地 Task 被取消时，后台补发一次 `meta.cancel`（服务端尽早停止）。
    ///
    /// 取消回调里不能 await，这里用独立 Task 发送；失败静默（取消通知是尽力而为，
    /// 本地请求本身的结算由 `BridgeClient` 的恰好一次语义保证）。
    private func withCancellation<T>(
        token: String?,
        timeout: TimeInterval?,
        _ body: @escaping () async throws -> T
    ) async throws -> T {
        guard let token else { return try await body() }
        return try await withTaskCancellationHandler {
            try await body()
        } onCancel: {
            let client = self.client
            Task.detached(priority: .utility) {
                _ = try? await client.callDictionary(
                    "meta.cancel",
                    params: ["token": token],
                    timeout: timeout
                )
            }
        }
    }
}
