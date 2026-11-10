import AlgerKit
import SwiftUI

/// 下载任务。
struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    /// 当前选中的任务（**按任务 ID**：任务名会变，选中不该跟着丢）。
    @State private var selectedTaskID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **共享标题布局**：标题用侧栏那条 **动态下载入口标题**，
            // 副标题是 **当前可见任务数**（会话范围过滤后的真实数量）。
            PageHeader(
                title: model.downloadEntry?.title ?? "下载",
                subtitle: "共\(model.visibleDownloadTasks.count)个"
            ) {
                PageActionButton(
                    title: "清除已完成",
                    systemImage: "trash",
                    isEnabled: model.visibleCompletedDownloadCount > 0,
                    help: "清除已完成的下载任务"
                ) {
                    Task { await model.clearFinishedDownloads() }
                }
            }

            if !model.pendingIntakes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "待处理的入单操作")
                    Text("这些曲目已经下载到本地，但加入歌单没有全部成功；重试会补上缺失的目标（不会重复加入）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(model.pendingIntakes) { intake in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(intake.displayName.isEmpty ? intake.path : intake.displayName)
                                .font(.callout)
                            Text(playlistTitle(intake.playlistId))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let error = intake.lastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    Button("重试全部待处理入单") {
                        model.retryPendingIntakes()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            if !model.autoSavePending.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "自动保存待重试")
                    ForEach(model.autoSavePending) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title.isEmpty ? "曲目 \(record.neteaseId)" : record.title)
                                .font(.callout)
                            if let error = record.lastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            Button("重置状态（下次完整播放重新触发）") {
                                Task { await model.retryAutoSave(neteaseId: record.neteaseId) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            if model.visibleDownloadTasks.isEmpty {
                EmptyStateView(
                    systemImage: "arrow.down.circle",
                    title: "没有下载任务",
                    message: "把网络曲目加入本地歌单时会先下载，落盘成功后才入单。"
                )
            } else {
                // **原生选中语义**（与歌曲 / 专辑一致）：单击行即选中（按任务 ID）。
                List(selection: $selectedTaskID) {
                    ForEach(model.visibleDownloadTasks) { task in
                        let isCurrentSession = model.isCurrentSessionTask(task)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(task.name)
                                    Text("\(task.artist) · \(statusText(task, isCurrentSession: isCurrentSession))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                // 进度只显示 **本次会话** 的在途任务。
                                if task.isActive, isCurrentSession {
                                    Text("\(task.percent)%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                // 失败任务 + 旧会话遗留、还没恢复的在途任务都能重试。
                                if task.isFailed || (task.isActive && !isCurrentSession) {
                                    Button("重试") {
                                        Task { await model.retryDownload(id: task.id) }
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            if task.isActive, isCurrentSession {
                                ProgressView(value: Double(task.percent), total: 100)
                            }
                            if let error = task.error, !error.isEmpty {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            if !task.targets.isEmpty {
                                Text("目标歌单：\(task.targets.count) 个（下载成功后自动入单）")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(task.id)
                        .accessibilityIdentifier("download-task-\(task.id)")
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func playlistTitle(_ id: String) -> String {
        model.localPlaylists.first { $0.id == id }?.title ?? id
    }

    private func statusText(_ task: DownloadTask, isCurrentSession: Bool) -> String {
        switch task.status {
        case "done": return "已完成"
        case "failed": return "失败"
        case "running": return "下载中"
        case "queued":
            // 旧会话遗留、还没被本次接手的排队任务：**不是**本次的进度。
            return isCurrentSession ? "排队中" : "排队中（上次未完成，可重试）"
        default: return "排队中"
        }
    }
}

/// 临时播放。
struct QueueView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSaveSheet = false
    /// 当前选中的队列项（**稳定 ID = queueEntryId**）。
    @State private var selectedEntryID: UUID?

    private func additionResult(for item: PlaybackItem) -> SearchResult? {
        switch item.origin {
        case .remote(let id):
            let song = item.remoteSong ?? RemoteSong(
                id: id, name: item.title,
                artists: item.artist.components(separatedBy: " / ").filter { !$0.isEmpty }
                    .map { RemoteArtist(id: 0, name: $0) },
                album: RemoteAlbum(id: 0, name: item.album, picUrl: ""),
                durationMs: item.durationMs
            )
            return .remote(song)
        case .local(let path):
            let track = model.environment.index.track(path: path) ?? TrackRecord(
                path: path, title: item.title, artist: item.artist, album: item.album,
                durationMs: UInt64(max(0, item.durationMs))
            )
            return .local(track)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // **共享标题布局**：标题按 **队列来源** 显示
            // （临时播放 / “XX”的推荐雷达 / 私人 FM）。
            PageHeader(title: model.queueDisplayTitle, subtitle: "共\(model.player.queue.count)项") {
                HStack(spacing: 8) {
                    PageActionButton(
                        title: "另存为歌单",
                        systemImage: "square.and.arrow.down",
                        isEnabled: !model.player.queue.isEmpty,
                        help: "把临时播放另存为本地歌单"
                    ) {
                        showingSaveSheet = true
                    }
                    PageActionButton(
                        title: "清空队列",
                        systemImage: "trash",
                        isEnabled: !model.player.queue.isEmpty,
                        help: "清空临时播放"
                    ) {
                        model.player.clearQueue()
                    }
                }
            }
            if model.playbackContext == .personalFM, let error = model.fmError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            if model.player.queue.isEmpty {
                EmptyStateView(
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    title: "队列是空的",
                    message: "播放或加入队列后会显示在这里。"
                )
            } else {
                // **原生选中语义**：单击正文即选中（**按 queueEntryId**：不误选同曲目的其它条目）。
                List(selection: $selectedEntryID) {
                    ForEach(Array(model.player.queue.enumerated()), id: \.element.queueEntryId) { index, item in
                        TrackRowView(
                            title: item.title,
                            subtitle: item.artist,
                            trailingText: item.isRemote ? "网络" : "本地",
                            isCurrent: model.player.current?.id == item.id,
                            onPlay: {
                                Task { await model.player.play(at: index) }
                            }
                        ) {
                            if let result = additionResult(for: item) {
                                AddToPlaylistMenu(result: result) { Image(systemName: "plus") }
                            }
                            Button {
                                model.player.removeFromQueue(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("从队列移除")
                        }
                        .tag(item.queueEntryId)
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showingSaveSheet) {
            SaveQueueAsPlaylistSheet()
                .environmentObject(model)
        }
    }
}
