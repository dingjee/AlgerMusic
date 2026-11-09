import Foundation

/// 收齐真实扫描事件后一次提交索引；完成响应不能越过排队中的事件。
@MainActor
public final class LibraryScanner {
    private let client: BridgeClient
    private let index: LibraryIndex
    public init(client: BridgeClient, index: LibraryIndex) {
        self.client = client
        self.index = index
    }

    private final class Buffer {
        private let lock = NSLock()
        private var entries: [ScannedTrack] = []
        func append(_ entry: ScannedTrack) {
            lock.lock(); defer { lock.unlock() }
            entries.append(entry)
        }
        func snapshot() -> [ScannedTrack] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }

    public func scan(directories: [String]) async throws -> ScanSummary {
        guard !directories.isEmpty else {
            throw BridgeServiceError.invalidResponse("尚未选择音乐目录")
        }
        for directory in directories {
            // Rust 枚举无法读取的根目录会跳过，提前验证才能给出真实失败。
            _ = try FileManager.default.contentsOfDirectory(atPath: directory)
        }
        let buffer = Buffer()
        let observer = client.addEventObserver { name, payload in
            if name == "scan", let entry = ScannedTrack.parse(payload) { buffer.append(entry) }
        }
        defer { client.removeEventObserver(observer) }
        let known = Dictionary(index.tracks.map {
            ($0.path, (size: $0.size, mtime: Int64($0.modifiedAt)))
        }, uniquingKeysWith: { first, _ in first })
        let summary = try await BridgeService(client: client).scan(directories: directories, known: known)
        await client.drainEvents()
        let entries = buffer.snapshot()
        guard entries.count == summary.updated else {
            throw BridgeServiceError.invalidResponse("扫描结果不完整：发现 \(summary.updated) 首，收到 \(entries.count) 首，请重新扫描")
        }
        if !entries.isEmpty || Set(index.tracks.map(\.path)).count != index.tracks.count {
            let records = try entries.map { entry -> TrackRecord in
                let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                return TrackRecord(
                    path: entry.path,
                    neteaseId: entry.neteaseId > 0 ? entry.neteaseId : (index.track(path: entry.path)?.neteaseId ?? 0),
                    title: entry.title, artist: entry.artist, album: entry.album,
                    durationMs: UInt64(max(0, entry.durationMs)), format: entry.format,
                    size: entry.fileSize, modifiedAt: modified
                )
            }
            try index.mutate { tracks in
                var byPath = Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                for record in records { byPath[record.path] = record }
                tracks = byPath.values.sorted { $0.path < $1.path }
            }
        }
        return summary
    }
}
