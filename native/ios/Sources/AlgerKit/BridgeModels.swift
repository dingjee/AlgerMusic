import Foundation

// MARK: - JSON 取值助手（与 macOS AlgerKit 同一套语义）

enum JSONValue {
    static func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }

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

// MARK: - 模型（极简版：只带妈妈版需要的字段）

public struct AccountInfo: Equatable {
    public var userId: Int64
    public var nickname: String
    public var avatarUrl: String

    public static func parse(_ value: Any?) -> AccountInfo? {
        let dict = JSONValue.dictionary(value)
        guard let userId = JSONValue.int64(dict["userId"]) ?? JSONValue.int64(dict["uid"]) else { return nil }
        return AccountInfo(
            userId: userId,
            nickname: JSONValue.string(dict["nickname"]) ?? "网易云用户",
            avatarUrl: JSONValue.string(dict["avatarUrl"]) ?? ""
        )
    }
}

public struct SessionSnapshot: Equatable {
    public var loggedIn: Bool
    public var hasCookie: Bool
    public var account: AccountInfo?
    public var quality: String
    public var downloadDirectory: String
    public var loadIssue: String?

    public static func parse(_ value: Any?) -> SessionSnapshot {
        let dict = JSONValue.dictionary(value)
        return SessionSnapshot(
            loggedIn: JSONValue.bool(dict["loggedIn"]) ?? false,
            hasCookie: JSONValue.bool(dict["hasCookie"]) ?? false,
            account: AccountInfo.parse(dict["account"]),
            quality: JSONValue.string(dict["quality"]) ?? "",
            downloadDirectory: JSONValue.string(dict["downloadDirectory"]) ?? "",
            loadIssue: JSONValue.string(dict["loadIssue"])
        )
    }
}

public struct RemoteArtist: Identifiable, Equatable {
    public var id: Int64
    public var name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }

    public static func parse(_ value: Any?) -> RemoteArtist? {
        let dict = JSONValue.dictionary(value)
        guard let id = JSONValue.int64(dict["id"]) else { return nil }
        return RemoteArtist(id: id, name: JSONValue.string(dict["name"]) ?? "未知艺人")
    }
}

public struct RemoteAlbum: Equatable {
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
        guard let id = JSONValue.int64(dict["id"]) else { return nil }
        return RemoteAlbum(
            id: id,
            name: JSONValue.string(dict["name"]) ?? "未知专辑",
            picUrl: JSONValue.string(dict["picUrl"]) ?? ""
        )
    }
}

public struct RemoteSong: Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var artists: [RemoteArtist]
    public var album: RemoteAlbum
    public var durationMs: Int64

    public init(
        id: Int64,
        name: String,
        artists: [RemoteArtist],
        album: RemoteAlbum,
        durationMs: Int64
    ) {
        self.id = id
        self.name = name
        self.artists = artists
        self.album = album
        self.durationMs = durationMs
    }

    public var artistText: String { artists.map(\.name).joined(separator: " / ") }
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
            durationMs: JSONValue.int64(dict["durationMs"]) ?? 0
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
        ]
    }
}

/// 解析出的可播放音频。
public struct ResolvedAudio: Equatable {
    public var url: String
    public var source: String
    public var sourceLabel: String
    public var note: String?

    public static func parse(_ value: Any?) -> ResolvedAudio? {
        let dict = JSONValue.dictionary(value)
        guard let url = JSONValue.string(dict["url"]), !url.isEmpty else { return nil }
        return ResolvedAudio(
            url: url,
            source: JSONValue.string(dict["source"]) ?? "",
            sourceLabel: JSONValue.string(dict["sourceLabel"]) ?? "",
            note: JSONValue.string(dict["note"])
        )
    }
}

/// 下载任务（字段语义同 macOS；时间戳一律归一化到 Unix 秒）。
public struct DownloadTask: Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var artist: String
    public var path: String
    public var percent: Int
    public var status: String
    public var error: String?

    public var isDone: Bool { status == "done" }
    public var isFailed: Bool { status == "failed" }
    public var isActive: Bool { status == "queued" || status == "running" }

    /// Rust 侧createdAt/updatedAt 是毫秒，旧数据可能是秒。
    static func normalizedTimestamp(_ value: Double) -> Double {
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
            path: JSONValue.string(dict["path"]) ?? "",
            percent: JSONValue.int(dict["percent"]) ?? 0,
            status: JSONValue.string(dict["status"]) ?? "queued",
            error: JSONValue.string(dict["error"])
        )
    }
}
