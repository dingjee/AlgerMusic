import Foundation

// MARK: - JSON 取值助手

/// 桥接 JSON 取值助手（桥接返回的是 Foundation 的 `Any` 树）。
enum JSONValue {
    static func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = int64(value) else { return nil }
        return Int(number)
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return (text as NSString).boolValue }
        return nil
    }

    static func stringArray(_ value: Any?) -> [String] {
        array(value).compactMap { string($0) }
    }
}

// MARK: - 模型

/// 网易云账号信息。
public struct AccountInfo: Equatable {
    public var userId: Int64
    public var nickname: String
    public var avatarUrl: String
    public var vipType: Int

    public init(userId: Int64, nickname: String, avatarUrl: String, vipType: Int) {
        self.userId = userId
        self.nickname = nickname
        self.avatarUrl = avatarUrl
        self.vipType = vipType
    }

    public static func parse(_ value: Any?) -> AccountInfo? {
        let dict = JSONValue.dictionary(value)
        guard let userId = JSONValue.int64(dict["userId"]), userId > 0 else { return nil }
        let nickname = JSONValue.string(dict["nickname"]) ?? "未知用户"
        return AccountInfo(
            userId: userId,
            nickname: nickname,
            avatarUrl: JSONValue.string(dict["avatarUrl"]) ?? "",
            vipType: JSONValue.int(dict["vipType"]) ?? 0
        )
    }
}

/// 远程艺人。
public struct RemoteArtist: Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var picUrl: String
    /// 网易侧的作品数（0 = 上游没给 / 未知）。
    ///
    /// **仅用于排序与展示**，不代表本机已收录的数量。
    public var musicCount: Int

    public init(id: Int64, name: String, picUrl: String = "", musicCount: Int = 0) {
        self.id = id
        self.name = name
        self.picUrl = picUrl
        self.musicCount = musicCount
    }

    public static func parse(_ value: Any?) -> RemoteArtist? {
        let dict = JSONValue.dictionary(value)
        guard let name = JSONValue.string(dict["name"]), !name.isEmpty else { return nil }
        return RemoteArtist(
            id: JSONValue.int64(dict["id"]) ?? 0,
            name: name,
            picUrl: JSONValue.string(dict["picUrl"]) ?? JSONValue.string(dict["avatar"]) ?? "",
            musicCount: JSONValue.int(dict["musicCount"]) ?? 0
        )
    }
}

/// 远程专辑。
public struct RemoteAlbum: Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var picUrl: String

    public init(id: Int64, name: String, picUrl: String) {
        self.id = id
        self.name = name
        self.picUrl = picUrl
    }

    public static func parse(_ value: Any?) -> RemoteAlbum? {
        let dict = JSONValue.dictionary(value)
        let name = JSONValue.string(dict["name"]) ?? ""
        guard !name.isEmpty else { return nil }
        return RemoteAlbum(
            id: JSONValue.int64(dict["id"]) ?? 0,
            name: name,
            picUrl: JSONValue.string(dict["picUrl"]) ?? ""
        )
    }
}

/// 远程专辑详情（`net.albumDetail`）。
public struct RemoteAlbumDetail: Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var picUrl: String
    public var artists: [RemoteArtist]

    public init(id: Int64, name: String, picUrl: String, artists: [RemoteArtist]) {
        self.id = id
        self.name = name
        self.picUrl = picUrl
        self.artists = artists
    }

    /// 艺人名拼接。
    public var artistText: String { artists.map(\.name).joined(separator: " / ") }

    public static func parse(_ value: Any?) -> RemoteAlbumDetail? {
        let dict = JSONValue.dictionary(value)
        guard let id = JSONValue.int64(dict["id"]), id > 0 else { return nil }
        let name = JSONValue.string(dict["name"]) ?? ""
        guard !name.isEmpty else { return nil }
        return RemoteAlbumDetail(
            id: id,
            name: name,
            picUrl: JSONValue.string(dict["picUrl"]) ?? "",
            artists: JSONValue.array(dict["artists"]).compactMap { RemoteArtist.parse($0) }
        )
    }
}

/// 远程艺人详情（`net.artistDetail`）。
public struct RemoteArtistDetail: Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var picUrl: String
    public var albumSize: Int
    public var musicSize: Int
    public var followed: Bool

    public init(
        id: Int64,
        name: String,
        picUrl: String,
        albumSize: Int,
        musicSize: Int,
        followed: Bool
    ) {
        self.id = id
        self.name = name
        self.picUrl = picUrl
        self.albumSize = albumSize
        self.musicSize = musicSize
        self.followed = followed
    }

    public static func parse(_ value: Any?) -> RemoteArtistDetail? {
        let dict = JSONValue.dictionary(value)
        guard let id = JSONValue.int64(dict["id"]), id > 0 else { return nil }
        let name = JSONValue.string(dict["name"]) ?? ""
        guard !name.isEmpty else { return nil }
        return RemoteArtistDetail(
            id: id,
            name: name,
            picUrl: JSONValue.string(dict["picUrl"]) ?? "",
            albumSize: JSONValue.int(dict["albumSize"]) ?? 0,
            musicSize: JSONValue.int(dict["musicSize"]) ?? 0,
            followed: JSONValue.bool(dict["followed"]) ?? false
        )
    }
}

/// 远程歌曲。
public struct RemoteSong: Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var artists: [RemoteArtist]
    public var album: RemoteAlbum
    public var durationMs: Int64
    public var fee: Int
    public var copyright: Int

    public init(
        id: Int64,
        name: String,
        artists: [RemoteArtist],
        album: RemoteAlbum,
        durationMs: Int64,
        fee: Int = 0,
        copyright: Int = 0
    ) {
        self.id = id
        self.name = name
        self.artists = artists
        self.album = album
        self.durationMs = durationMs
        self.fee = fee
        self.copyright = copyright
    }

    /// 艺人名拼接。
    public var artistText: String {
        artists.map(\.name).joined(separator: " / ")
    }

    /// 时长（秒）。
    public var durationSeconds: Double { Double(durationMs) / 1000 }

    public static func parse(_ value: Any?) -> RemoteSong? {
        let dict = JSONValue.dictionary(value)
        guard let id = JSONValue.int64(dict["id"]), id > 0 else { return nil }
        let artists = JSONValue.array(dict["artists"]).compactMap { RemoteArtist.parse($0) }
        let album = RemoteAlbum.parse(dict["album"]) ?? RemoteAlbum(id: 0, name: "未知专辑", picUrl: "")
        return RemoteSong(
            id: id,
            name: JSONValue.string(dict["name"]) ?? "未知歌曲",
            artists: artists,
            album: album,
            durationMs: JSONValue.int64(dict["durationMs"]) ?? 0,
            fee: JSONValue.int(dict["fee"]) ?? 0,
            copyright: JSONValue.int(dict["copyright"]) ?? 0
        )
    }

    /// 转成桥接 `src.resolve` / `dl.enqueue` 需要的形状。
    public var bridgePayload: [String: Any] {
        [
            "id": id,
            "name": name,
            "artists": artists.map { ["id": $0.id, "name": $0.name] },
            "album": ["id": album.id, "name": album.name, "picUrl": album.picUrl],
            "durationMs": durationMs,
            "fee": fee,
            "copyright": copyright,
        ]
    }
}

/// 远程歌单概要。
public struct RemotePlaylist: Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var details: String
    public var coverImgUrl: String
    public var trackCount: Int
    public var creatorId: Int64
    public var creatorName: String
    public var subscribed: Bool
    /// 歌单里 **全部** 的网易曲目 ID（来自上游 `trackIds`）。
    ///
    /// 推荐雷达用它 **排除来源歌单自身的曲目**；上游没给时为空数组
    /// （此时只按已取回的曲目排除，不会假装拿到了完整列表）。
    public var trackIds: [Int64]

    public init(
        id: Int64,
        name: String,
        details: String,
        coverImgUrl: String,
        trackCount: Int,
        creatorId: Int64,
        creatorName: String,
        subscribed: Bool,
        trackIds: [Int64] = []
    ) {
        self.id = id
        self.name = name
        self.details = details
        self.coverImgUrl = coverImgUrl
        self.trackCount = trackCount
        self.creatorId = creatorId
        self.creatorName = creatorName
        self.subscribed = subscribed
        self.trackIds = trackIds
    }

    /// 是否是当前账号自己创建的歌单（**权限判定**：只有自己的歌单能改）。
    public func isEditable(by account: AccountInfo?) -> Bool {
        guard let account else { return false }
        return creatorId == account.userId
    }

    public static func parse(_ value: Any?) -> RemotePlaylist? {
        let dict = JSONValue.dictionary(value)
        guard let id = JSONValue.int64(dict["id"]), id > 0 else { return nil }
        let creator = JSONValue.dictionary(dict["creator"])
        return RemotePlaylist(
            id: id,
            name: JSONValue.string(dict["name"]) ?? "未命名歌单",
            details: JSONValue.string(dict["description"]) ?? "",
            coverImgUrl: JSONValue.string(dict["coverImgUrl"]) ?? "",
            trackCount: JSONValue.int(dict["trackCount"]) ?? 0,
            creatorId: JSONValue.int64(creator["userId"]) ?? 0,
            creatorName: JSONValue.string(creator["nickname"]) ?? "",
            subscribed: JSONValue.bool(dict["subscribed"]) ?? false,
            trackIds: JSONValue.array(dict["trackIds"]).compactMap { JSONValue.int64($0) }
        )
    }
}

/// 会话快照。
public struct SessionSnapshot: Equatable {
    public var loggedIn: Bool
    public var hasCookie: Bool
    public var account: AccountInfo?
    public var quality: String
    public var sources: [String]
    public var downloadDirectory: String
    public var sessionPath: String
    /// 会话载入问题（损坏 / 读失败）。
    public var loadIssue: String?
    /// 下载队列载入问题。
    public var downloadLoadIssue: String?
    /// 下载队列最近一次落盘错误。
    public var downloadLastError: String?

    public init(
        loggedIn: Bool,
        hasCookie: Bool,
        account: AccountInfo?,
        quality: String,
        sources: [String],
        downloadDirectory: String,
        sessionPath: String,
        loadIssue: String?,
        downloadLoadIssue: String?,
        downloadLastError: String?
    ) {
        self.loggedIn = loggedIn
        self.hasCookie = hasCookie
        self.account = account
        self.quality = quality
        self.sources = sources
        self.downloadDirectory = downloadDirectory
        self.sessionPath = sessionPath
        self.loadIssue = loadIssue
        self.downloadLoadIssue = downloadLoadIssue
        self.downloadLastError = downloadLastError
    }

    public static func parse(_ value: Any?) -> SessionSnapshot {
        let dict = JSONValue.dictionary(value)
        let dlq = JSONValue.dictionary(dict["dlq"])
        return SessionSnapshot(
            loggedIn: JSONValue.bool(dict["loggedIn"]) ?? false,
            hasCookie: JSONValue.bool(dict["hasCookie"]) ?? false,
            account: AccountInfo.parse(dict["account"]),
            quality: JSONValue.string(dict["quality"]) ?? "higher",
            sources: JSONValue.stringArray(dict["sources"]),
            downloadDirectory: JSONValue.string(dict["downloadDir"]) ?? "",
            sessionPath: JSONValue.string(dict["sessionPath"]) ?? "",
            loadIssue: JSONValue.string(dict["loadIssue"]),
            downloadLoadIssue: JSONValue.string(dlq["loadIssue"]),
            downloadLastError: JSONValue.string(dlq["lastError"])
        )
    }
}

/// 下载任务。
public struct DownloadTask: Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var artist: String
    public var album: String
    public var durationMs: Int64
    public var path: String
    public var downloaded: UInt64
    public var total: UInt64
    public var percent: Int
    public var status: String
    public var error: String?
    public var source: String?
    /// 目标本地歌单 ID（下载成功后才入单）。
    public var targets: [String]
    /// 创建时间（Unix 秒；0 = 未知）。
    public var createdAt: Double
    /// 最近更新时间（Unix 秒；0 = 未知）。
    public var updatedAt: Double

    public init(
        id: Int64,
        name: String,
        artist: String,
        album: String,
        durationMs: Int64,
        path: String,
        downloaded: UInt64,
        total: UInt64,
        percent: Int,
        status: String,
        error: String?,
        source: String?,
        targets: [String],
        createdAt: Double = 0,
        updatedAt: Double = 0
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.path = path
        self.downloaded = downloaded
        self.total = total
        self.percent = percent
        self.status = status
        self.error = error
        self.source = source
        self.targets = targets
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 是否已完成。
    public var isDone: Bool { status == "done" }
    /// 是否失败（需要重试）。
    public var isFailed: Bool { status == "failed" }
    /// 是否仍在进行。
    public var isActive: Bool { status == "queued" || status == "running" }

    /// 时间戳归一化到 **Unix 秒**。
    ///
    /// Rust 侧 `DlTask.created_at` / `updated_at` 是 **毫秒**（`now_millis()`），
    /// 桥接原样发出；旧数据可能已经是秒。
    ///
    /// - Important: 不归一化会让「本次会话 vs 上次会话遗留」的判断 **完全失效**
    ///   （毫秒值远大于秒级时间戳 → 所有旧任务都被当成本次会话 → 跨重启恢复被跳过）。
    /// - 判据：毫秒级时间戳一定 **大于 1e11**（1e11 秒 = 公元 5138 年，
    ///   而 1e11 毫秒 = 1973 年）；秒级时间戳现在是 ~1.8e9。
    public static func normalizedTimestamp(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return value > 100_000_000_000 ? value / 1000 : value
    }

    public static func parse(_ value: Any?) -> DownloadTask? {
        let dict = JSONValue.dictionary(value)
        guard let id = JSONValue.int64(dict["id"]) else { return nil }
        return DownloadTask(
            id: id,
            name: JSONValue.string(dict["name"]) ?? "未知曲目",
            artist: JSONValue.string(dict["artist"]) ?? "",
            album: JSONValue.string(dict["album"]) ?? "",
            durationMs: JSONValue.int64(dict["durationMs"]) ?? 0,
            path: JSONValue.string(dict["path"]) ?? "",
            downloaded: UInt64(max(0, JSONValue.int64(dict["downloaded"]) ?? 0)),
            total: UInt64(max(0, JSONValue.int64(dict["total"]) ?? 0)),
            percent: JSONValue.int(dict["percent"]) ?? 0,
            status: JSONValue.string(dict["status"]) ?? "queued",
            error: JSONValue.string(dict["error"]),
            source: JSONValue.string(dict["source"]),
            targets: JSONValue.stringArray(dict["targets"]),
            // **一律归一化到秒**（Rust 发的是毫秒，旧数据是秒）。
            createdAt: normalizedTimestamp(JSONValue.double(dict["createdAt"]) ?? 0),
            updatedAt: normalizedTimestamp(JSONValue.double(dict["updatedAt"]) ?? 0)
        )
    }
}

/// 扫描统计。
public struct ScanSummary: Equatable {
    public var scanned: Int
    public var updated: Int
    public var skipped: Int
    public var errors: Int
    public var durationMs: Int
    public var errorSamples: [String]

    public init(scanned: Int, updated: Int, skipped: Int, errors: Int, durationMs: Int, errorSamples: [String]) {
        self.scanned = scanned
        self.updated = updated
        self.skipped = skipped
        self.errors = errors
        self.durationMs = durationMs
        self.errorSamples = errorSamples
    }

    public static func parse(_ value: Any?) -> ScanSummary {
        let dict = JSONValue.dictionary(value)
        return ScanSummary(
            scanned: JSONValue.int(dict["scanned"]) ?? 0,
            updated: JSONValue.int(dict["updated"]) ?? 0,
            skipped: JSONValue.int(dict["skipped"]) ?? 0,
            errors: JSONValue.int(dict["errors"]) ?? 0,
            durationMs: JSONValue.int(dict["durationMs"]) ?? 0,
            errorSamples: JSONValue.stringArray(dict["errorSamples"])
        )
    }
}

/// 扫描到的单条曲目元信息（桥接 `ev:"scan"` 事件）。
public struct ScannedTrack: Equatable {
    public var path: String
    public var format: String
    public var durationMs: Int
    public var title: String
    public var artist: String
    public var album: String
    public var fileSize: UInt64
    public var neteaseId: Int64

    public init(
        path: String,
        format: String,
        durationMs: Int,
        title: String,
        artist: String,
        album: String,
        fileSize: UInt64,
        neteaseId: Int64
    ) {
        self.path = path
        self.format = format
        self.durationMs = durationMs
        self.title = title
        self.artist = artist
        self.album = album
        self.fileSize = fileSize
        self.neteaseId = neteaseId
    }

    public static func parse(_ value: Any?) -> ScannedTrack? {
        let dict = JSONValue.dictionary(value)
        let entry = dict["entry"] == nil ? dict : JSONValue.dictionary(dict["entry"])
        guard let path = JSONValue.string(entry["path"]), !path.isEmpty else { return nil }
        return ScannedTrack(
            path: path,
            format: JSONValue.string(entry["format"]) ?? "",
            durationMs: JSONValue.int(entry["durationMs"]) ?? 0,
            title: JSONValue.string(entry["title"]) ?? "",
            artist: JSONValue.string(entry["artist"]) ?? "",
            album: JSONValue.string(entry["album"]) ?? "",
            fileSize: UInt64(max(0, JSONValue.int64(entry["fileSize"]) ?? 0)),
            neteaseId: JSONValue.int64(entry["neteaseId"]) ?? 0
        )
    }
}

/// 解析出来的播放地址。
public struct ResolvedAudio: Equatable {
    public var url: String
    public var bitrate: Int
    public var size: Int
    public var source: String
    public var sourceLabel: String
    public var thirdParty: Bool
    public var note: String?
    /// 实际编码（`alac` / `aac` / `flac` / `mp3` …；空串 = **没有探测到**）。
    ///
    /// 桥接 **真的探测到** 时才有值；空串表示「只知道容器与码率」，
    /// 此时 **不能** 把远端当成某种真实音质（见 `AudioQuality`）。
    public var codec: String
    /// 采样率（Hz；0 = 未知）。
    public var sampleRate: Int
    /// 位深（bit；0 = 未知）。
    public var bitDepth: Int

    public init(
        url: String,
        bitrate: Int,
        size: Int,
        source: String,
        sourceLabel: String,
        thirdParty: Bool,
        note: String?,
        codec: String = "",
        sampleRate: Int = 0,
        bitDepth: Int = 0
    ) {
        self.url = url
        self.bitrate = bitrate
        self.size = size
        self.source = source
        self.sourceLabel = sourceLabel
        self.thirdParty = thirdParty
        self.note = note
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }

    public static func parse(_ value: Any?) -> ResolvedAudio? {
        let dict = JSONValue.dictionary(value)
        guard let url = JSONValue.string(dict["url"]), !url.isEmpty else { return nil }
        return ResolvedAudio(
            url: url,
            bitrate: JSONValue.int(dict["br"]) ?? 0,
            size: JSONValue.int(dict["size"]) ?? 0,
            source: JSONValue.string(dict["source"]) ?? "",
            sourceLabel: JSONValue.string(dict["sourceLabel"]) ?? "",
            thirdParty: JSONValue.bool(dict["thirdParty"]) ?? false,
            note: JSONValue.string(dict["note"]),
            // **可选字段**：桥接没提供时是空串 / 0 → 上游按「未知」保守处理。
            codec: JSONValue.string(dict["codec"]) ?? "",
            sampleRate: JSONValue.int(dict["sampleRate"]) ?? 0,
            bitDepth: JSONValue.int(dict["bitDepth"]) ?? 0
        )
    }
}

// MARK: - 桥接服务

/// 桥接服务的类型化封装。
///
/// 字段一律 **从桥接真实返回里读取**（`crates/alger-bridge`），
/// 这里只做形状转换，不造数据、不填默认值冒充成功。
public final class BridgeService {
    public let client: BridgeClient

    public init(client: BridgeClient) {
        self.client = client
    }

    // MARK: 应用 / 会话

    public func hello() async throws -> [String: Any] {
        try await client.callDictionary("app.hello")
    }

    public func sessionSnapshot() async throws -> SessionSnapshot {
        let response = try await client.callDictionary("session.snapshot")
        return SessionSnapshot.parse(response)
    }

    /// 校验 Cookie（**不落盘**；校验成功后再调 `setCookie`）。
    public func verifyCookie(_ cookie: String) async throws -> AccountInfo {
        let response = try await client.call("session.verifyCookie", params: ["cookie": cookie])
        guard let account = AccountInfo.parse(response) else {
            throw BridgeServiceError.invalidResponse("账号信息无效")
        }
        return account
    }

    /// 提交 Cookie（桥接会先校验，落盘成功后才会替换会话）。
    public func setCookie(_ cookie: String) async throws {
        _ = try await client.call("session.setCookie", params: ["cookie": cookie])
    }

    /// 注销（返回 false 表示期间身份已变化，保留了新登录）。
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

    // MARK: 网易云只读接口

    public func account() async throws -> AccountInfo? {
        let response = try await client.call("net.account")
        return AccountInfo.parse(response)
    }

    /// 统一搜索（**网络部分**；本地部分由 `LocalLibrary` 提供）。
    public func searchSongs(
        keywords: String,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> (songs: [RemoteSong], total: Int) {
        let response = try await client.callDictionary(
            "net.search",
            params: ["keywords": keywords, "limit": limit, "offset": offset]
        )
        let songs = JSONValue.array(response["songs"]).compactMap { RemoteSong.parse($0) }
        return (songs, JSONValue.int(response["total"]) ?? songs.count)
    }

    public func userPlaylists(uid: Int64? = nil) async throws -> [RemotePlaylist] {
        var params: [String: Any] = [:]
        if let uid { params["uid"] = uid }
        let response = try await client.callDictionary("net.userPlaylists", params: params)
        return JSONValue.array(response["playlists"]).compactMap { RemotePlaylist.parse($0) }
    }

    public func playlistDetail(id: Int64) async throws -> (playlist: RemotePlaylist?, songs: [RemoteSong], missing: Int) {
        let response = try await client.callDictionary("net.playlistDetail", params: ["id": id])
        let playlist = RemotePlaylist.parse(response["playlist"])
        let songs = JSONValue.array(response["songs"]).compactMap { RemoteSong.parse($0) }
        return (playlist, songs, JSONValue.int(response["missing"]) ?? 0)
    }

    public func songDetails(ids: [Int64]) async throws -> [RemoteSong] {
        guard !ids.isEmpty else { return [] }
        let response = try await client.callDictionary("net.songDetails", params: ["ids": ids])
        return JSONValue.array(response["songs"]).compactMap { RemoteSong.parse($0) }
    }

    public func personalFM() async throws -> [RemoteSong] {
        let response = try await client.callDictionary("net.personalFm")
        return JSONValue.array(response["songs"]).compactMap { RemoteSong.parse($0) }
    }

    public func intelligenceList(playlistId: Int64, songId: Int64 = 0) async throws -> [RemoteSong] {
        let response = try await client.callDictionary(
            "net.intelligenceList",
            params: ["playlistId": playlistId, "songId": songId]
        )
        return JSONValue.array(response["songs"]).compactMap { RemoteSong.parse($0) }
    }

    /// 相似歌曲（`net.similarSongs` → `/api/v1/discovery/simiSong`）。
    ///
    /// **只读、可匿名**：推荐雷达的共同来源，绕开「歌单类型限制」。
    ///
    /// - 结构错误（上游缺 `songs` / 类型不对）→ 桥接返回 `Decode` 错误，
    ///   这里原样上抛（**绝不**变成「没有相似歌曲」）；
    /// - 合法空数组 → 返回空列表（上游真的没有相似歌曲）。
    public func similarSongs(
        songId: Int64,
        limit: Int = 20,
        offset: Int = 0
    ) async throws -> [RemoteSong] {
        let response = try await client.callDictionary(
            "net.similarSongs",
            params: ["songId": songId, "limit": limit, "offset": offset]
        )
        return JSONValue.array(response["songs"]).compactMap { RemoteSong.parse($0) }
    }

    public func artistSublist() async throws -> [RemoteArtist] {
        let response = try await client.callDictionary("net.artistSublist")
        return JSONValue.array(response["artists"]).compactMap { RemoteArtist.parse($0) }
    }

    public func artistNewWorks() async throws -> [RemoteSong] {
        let response = try await client.callDictionary("net.artistNewWorks")
        return JSONValue.array(response["works"]).compactMap { RemoteSong.parse($0) }
    }

    public func artistTopSongs(id: Int64) async throws -> [RemoteSong] {
        let response = try await client.callDictionary("net.artistTopSongs", params: ["id": id])
        return JSONValue.array(response["songs"]).compactMap { RemoteSong.parse($0) }
    }

    public func artistAlbums(id: Int64) async throws -> [RemoteAlbum] {
        let response = try await client.callDictionary("net.artistAlbums", params: ["id": id])
        return JSONValue.array(response["albums"]).compactMap { RemoteAlbum.parse($0) }
    }

    // MARK: 网络歌单（**只读**）
    //
    // 网络歌单 **没有写接口**：不新建、不改名、不删除、不增删曲目、不排序。
    // 需要整理曲目时只能加入 **本地歌单**（下载后入库）或临时播放。

    /// 远程专辑详情（`net.albumDetail`）。
    public func albumDetail(id: Int64) async throws -> (album: RemoteAlbumDetail?, songs: [RemoteSong]) {
        let response = try await client.callDictionary("net.albumDetail", params: ["id": id])
        let album = RemoteAlbumDetail.parse(response["album"])
        let songs = JSONValue.array(response["songs"]).compactMap { RemoteSong.parse($0) }
        return (album, songs)
    }

    /// 远程艺人详情（`net.artistDetail`）。
    public func artistDetail(id: Int64) async throws -> RemoteArtistDetail {
        let response = try await client.call("net.artistDetail", params: ["id": id])
        guard let detail = RemoteArtistDetail.parse(response) else {
            throw BridgeServiceError.invalidResponse("艺人详情无效")
        }
        return detail
    }

    // MARK: 播放地址

    /// 解析播放地址（官方优先，回退第三方音源）。
    public func resolve(song: RemoteSong) async throws -> ResolvedAudio {
        let response = try await client.call("src.resolve", params: ["song": song.bridgePayload])
        guard let audio = ResolvedAudio.parse(response) else {
            throw BridgeServiceError.invalidResponse("未能解析到可播放地址")
        }
        return audio
    }

    // MARK: 下载

    /// 入队下载（**成功落盘后** 才会按 `targets` 入本地歌单）。
    @discardableResult
    public func enqueueDownload(
        song: RemoteSong,
        directory: String?,
        targets: [String]
    ) async throws -> String? {
        var params: [String: Any] = ["song": song.bridgePayload, "targets": targets]
        if let directory { params["dir"] = directory }
        let response = try await client.callDictionary("dl.enqueue", params: params)
        return JSONValue.string(response["note"])
    }

    public func downloadTasks() async throws -> [DownloadTask] {
        let response = try await client.callDictionary("dl.list")
        return JSONValue.array(response["tasks"]).compactMap { DownloadTask.parse($0) }
    }

    /// 重试下载（先本地恢复，再重新解析地址）。
    public func retryDownload(id: Int64) async throws -> (queued: Bool, recovered: Bool) {
        let response = try await client.callDictionary("dl.retry", params: ["id": id])
        return (
            JSONValue.bool(response["queued"]) ?? false,
            JSONValue.bool(response["recovered"]) ?? false
        )
    }

    public func clearDownloads(onlyDone: Bool = true) async throws {
        _ = try await client.call("dl.clear", params: ["onlyDone": onlyDone])
    }

    public func downloadStatus() async throws -> (available: Bool, loadIssue: String?, lastError: String?) {
        let response = try await client.callDictionary("dl.status")
        return (
            JSONValue.bool(response["available"]) ?? false,
            JSONValue.string(response["loadIssue"]),
            JSONValue.string(response["lastError"])
        )
    }

    // MARK: 扫描 / 标签

    /// 扫描目录（`known` 为已知文件的「大小 + 修改时间」戳，避免重复读标签）。
    public func scan(directories: [String], known: [String: (size: UInt64, mtime: Int64)]) async throws -> ScanSummary {
        let knownPayload: [String: [String: Int64]] = known.reduce(into: [:]) { result, item in
            result[item.key] = ["size": Int64(item.value.size), "mtime": item.value.mtime]
        }
        let response = try await client.callDictionary(
            "lib.scan",
            params: ["dirs": directories, "known": knownPayload],
            timeout: 600
        )
        return ScanSummary.parse(response)
    }

    public func cancelScan() async throws {
        _ = try await client.call("lib.cancel")
    }

    /// 读取音频标签。
    public func readTags(path: String) async throws -> [String: Any] {
        try await client.callDictionary("tags.read", params: ["path": path])
    }

    /// 读取音频标签（**类型化**：带实测码率，用于质量审核）。
    public func readAudioTags(path: String) async throws -> AudioTags {
        let response = try await client.callDictionary("tags.read", params: ["path": path])
        guard let tags = AudioTags.parse(response) else {
            throw BridgeServiceError.invalidResponse("tags.read 未返回有效标签")
        }
        return tags
    }
}

/// 桥接服务可以实测本地音频质量，也可以解析远端播放地址。
extension BridgeService: AudioTagReading, AudioSourceResolving {}

/// 桥接服务的附加错误。
public enum BridgeServiceError: Error, CustomStringConvertible {
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .invalidResponse(let message): return "桥接返回无效：\(message)"
        }
    }
}
