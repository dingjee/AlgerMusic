import Foundation

/// 下载中心：桥接 `dl.*` + `ev:"dl"` 事件。
///
/// - 事件驱动刷新（进度 / 状态变化）；
/// - 任务列表供「下载」页展示；完成后可直接播放本地文件。
public final class DownloadStore: ObservableObject {
    @Published public private(set) var tasks: [DownloadTask] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    private let service: BridgeService
    private var observer: ((String, [String: Any]) -> Void)?

    public init(service: BridgeService) {
        self.service = service
    }

    /// 订阅桥接下载事件（应用启动时调用一次）。
    public func startObserving(client: FFIClient) {
        guard observer == nil else { return }
        let handler: (String, [String: Any]) -> Void = { [weak self] name, _ in
            guard name == "dl" else { return }
            Task { await self?.refresh() }
        }
        observer = handler
        client.onEvent(handler)
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            tasks = try await service.downloadTasks()
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// 入队下载（成功后刷新列表）。
    public func enqueue(song: RemoteSong, directory: String?) async -> Bool {
        do {
            try await service.enqueueDownload(song: song, directory: directory)
            lastError = nil
            await refresh()
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    public func retry(id: Int64) async {
        do {
            try await service.retryDownload(id: id)
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
        await refresh()
    }

    public func clearAll() async {
        do {
            try await service.clearDownloads()
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
        await refresh()
    }

    /// 已完成任务的本地文件 URL（存在才返回）。
    public func localURL(for task: DownloadTask) -> URL? {
        guard task.isDone, !task.path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: task.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 错误转可读文案（界面直接显示）。
    public static func describe(_ error: Error) -> String {
        if let e = error as? FFIClientError { return e.errorDescription ?? String(describing: error) }
        return error.localizedDescription
    }
}
