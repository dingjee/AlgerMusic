import AlgerKit
import SwiftUI

/// 本地歌单详情（标题 / 描述 / 曲目 / 移除 / 重排）。
struct LocalPlaylistDetailView: View {
    @EnvironmentObject private var model: AppModel
    let playlistID: String
    @State private var editingMetadata = false
    @State private var editTitle = ""
    @State private var editDetails = ""

    private var playlist: LocalPlaylist? {
        model.localPlaylists.first { $0.id == playlistID }
    }

    var body: some View {
        Group {
            if let playlist {
                VStack(alignment: .leading, spacing: 0) {
                    // **共享标题布局**：标题 / 副标题 / 右侧操作（图标 + 文字）。
                    PageHeader(
                        title: playlist.title,
                        subtitle: "共\(playlist.trackCount)首 · 本地歌单"
                    ) {
                        HStack(spacing: 8) {
                            PlaybackOrderButton()
                            PageActionButton(
                                title: "编辑",
                                systemImage: "pencil",
                                help: "重命名歌单或修改描述"
                            ) {
                                editTitle = playlist.title
                                editDetails = playlist.details
                                editingMetadata = true
                            }
                        }
                    }
                    if !playlist.details.isEmpty {
                        Text(playlist.details)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                    }

                    if playlist.entries.isEmpty {
                        // **空歌单是独立空态**（不放雷达：没有种子就没有推荐）。
                        EmptyStateView(
                            systemImage: "music.note.list",
                            title: "歌单是空的",
                            message: "从资料库或搜索结果点「+」加入曲目。"
                        )
                    } else {
                        let rows = Array(playlist.entries.enumerated())
                        List {
                            ForEach(rows, id: \.element.path) { row in
                                playlistRow(row: row, playlist: playlist)
                            }
                            .onMove { offsets, destination in
                                // 重排后立即落盘（写失败会明确报错）。
                                model.moveLocalPlaylistTracks(
                                    playlistId: playlist.id,
                                    fromOffsets: offsets,
                                    toOffset: destination
                                )
                            }

                            // **推荐雷达：原歌单 List 的最后一组 Section**
                            // （长歌单时随曲目一起滚动，不另开滚动区）。
                            Section {
                                PlaylistRadarContent(request: localRadarRequest(playlist))
                            } header: {
                                SectionHeader(title: "推荐雷达")
                                    .textCase(nil)
                            }
                        }
                        .listStyle(.inset)
                    }
                }

            } else {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "歌单不存在",
                    message: "它可能已被删除。刷新侧栏看看。"
                )
            }
        }
        .sheet(isPresented: $editingMetadata) {
            VStack(alignment: .leading, spacing: 12) {
                Text("编辑歌单信息").font(.headline)
                TextField("名称", text: $editTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("描述", text: $editDetails)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("取消") { editingMetadata = false }
                        .keyboardShortcut(.cancelAction)
                    Button("保存") {
                        model.renameLocalPlaylist(id: playlistID, title: editTitle, details: editDetails)
                        editingMetadata = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    /// 本地歌单的雷达请求（**种子 = 歌单自己的曲目**）。
    ///
    /// - 有来源 ID 的曲目直接做种子；
    /// - 没有来源 ID 的曲目走 **小规模精确搜索**（不写库、不改标签）。
    private func localRadarRequest(_ playlist: LocalPlaylist) -> RadarRequest {
        let tracks = playlist.entries.map { entry -> TrackRecord in
            model.environment.index.track(path: entry.path) ?? TrackRecord(path: entry.path)
        }
        let known = tracks.compactMap { $0.neteaseId > 0 ? $0.neteaseId : nil }
        let unknown = tracks.filter { $0.neteaseId <= 0 }
        // **内容身份包含全部曲目**（不只是前几条）：增删 / 换文件都会换身份。
        let signature = model.radarContentSignature(
            scope: "local:\(playlist.id)",
            id: playlist.id,
            ids: known,
            extra: playlist.entries.map(\.path).joined(separator: ",")
        )
        return RadarRequest(
            scope: "local:\(playlist.id)",
            contentSignature: signature,
            seedSongIDs: known,
            seedLocalTracks: unknown,
            sourceSongIDs: Set(known)
        )
    }

    @ViewBuilder
    private func playlistRow(
        row: (offset: Int, element: PlaylistEntry),
        playlist: LocalPlaylist
    ) -> some View {
        let entry = row.element
        // 索引里有就用索引的展示名；没有就按文件名兜底（**不显示父目录路径**）。
        let indexed = model.environment.index.track(path: entry.path)
        let fallback = TrackRecord(path: entry.path)
        let title = displayTitle(for: entry, indexed: indexed, fallback: fallback)
        let subtitle = displaySubtitle(for: entry, indexed: indexed, fallback: fallback)
        let durationText: String? = entry.duration > 0 ? formatDuration(entry.duration) : nil
        let isCurrent: Bool = model.player.current?.id == "path:\(entry.path)"
        TrackRowView(
            title: title,
            subtitle: subtitle,
            trailingText: durationText,
            isCurrent: isCurrent,
            onPlay: {
                model.playLocalPlaylist(playlist, index: row.offset)
            }
        ) {
            // **未入索引的文件也能加到别的本地歌单**（不因为缺索引就禁用）。
            AddToPlaylistMenu(result: .local(indexed ?? fallback)) { Image(systemName: "plus") }
            Button {
                model.removeTrackFromPlaylist(playlistId: playlist.id, path: entry.path)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("从歌单移除（文件保留）")
        }
        .contextMenu {
            Button("编辑元信息…") {
                model.openMetadataEditor(for: indexed ?? fallback)
            }
        }
    }

    // MARK: - 展示名（不露长路径）

    /// 行标题：**索引里的标题优先**，没有索引就用文件名兜底。
    ///
    /// 任何情况下都 **不显示父目录绝对路径**（旧歌单里存过整条路径时只取文件名）。
    private func displayTitle(
        for entry: PlaylistEntry,
        indexed: TrackRecord?,
        fallback: TrackRecord
    ) -> String {
        let raw: String
        if let indexed {
            raw = indexed.displayTitle
        } else {
            let stored = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            raw = stored.isEmpty ? fallback.displayTitle : stored
        }
        return shortName(raw)
    }

    /// 行副标题：**索引里的艺人 + 专辑**；没有索引就显示统一的未知占位。
    private func displaySubtitle(
        for entry: PlaylistEntry,
        indexed: TrackRecord?,
        fallback: TrackRecord
    ) -> String {
        guard let indexed else {
            return fallback.displayArtist
        }
        return "\(indexed.displayArtist) · \(indexed.displayAlbum)"
    }

    /// 只要文件名（去掉扩展名）。
    ///
    /// **只认真正的路径**：用 `TrackRecord.looksLikePath`（绝对路径 / `file://`）判断，
    /// 真实歌名里的 `/`（例如 `AC/DC`）**原样保留**，不被当成路径截断。
    private func shortName(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unrecognized" }
        if TrackRecord.looksLikePath(trimmed) {
            let name = TrackRecord.basenameWithoutExtension(path: trimmed)
            return name.isEmpty ? "Unrecognized" : name
        }
        return trimmed
    }
}

/// 网络歌单详情（**只读**）。
///
/// 可以播放、可以加入 **临时播放** 与 **本地歌单**；
/// 云端内容 **不提供任何写入入口**（改名 / 删除 / 增删曲目 / 排序都没有）。
struct RemotePlaylistDetailView: View {
    @EnvironmentObject private var model: AppModel
    let playlistID: Int64
    @State private var songs: [RemoteSong] = []
    @State private var detail: RemotePlaylist?
    @State private var loading = false
    @State private var loadError: String?

    private var playlist: RemotePlaylist? {
        model.remotePlaylists.first { $0.id == playlistID }
    }

    var body: some View {
        Group {
            if let playlist {
                VStack(alignment: .leading, spacing: 0) {
                    // **共享标题布局**：标题 / 副标题 / 右侧操作（图标 + 文字）。
                    PageHeader(
                        title: playlist.name,
                        subtitle: "创建者：\(playlist.creatorName.isEmpty ? "未知" : playlist.creatorName) · 共\(playlist.trackCount)首"
                    ) {
                        HStack(spacing: 8) {
                            PlaybackOrderButton()
                            Label("只读", systemImage: "lock")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.secondary.opacity(0.10))
                                )
                                .accessibilityLabel("只读")
                        }
                    }
                    if !playlist.details.isEmpty {
                        Text(playlist.details)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                    }

                    if loading {
                        ProgressView("加载中…").padding(20)
                    } else if let loadError {
                        EmptyStateView(
                            systemImage: "exclamationmark.triangle",
                            title: "无法加载歌单",
                            message: loadError,
                            actionTitle: "重试"
                        ) {
                            Task { await load() }
                        }
                    } else if songs.isEmpty {
                        // **空歌单是独立空态**（不放雷达：没有种子就没有推荐）。
                        EmptyStateView(
                            systemImage: "music.note.house",
                            title: "歌单里没有曲目",
                            message: "上游返回的是空歌单。"
                        )
                    } else {
                        let rows = Array(songs.enumerated())
                        List {
                            ForEach(rows, id: \.element.id) { row in
                                rowView(row: row, playlist: playlist)
                            }

                            // **推荐雷达：原歌单 List 的最后一组 Section**
                            // （长歌单时随曲目一起滚动，不另开滚动区）。
                            Section {
                                PlaylistRadarContent(request: remoteRadarRequest(playlist))
                            } header: {
                                SectionHeader(title: "推荐雷达")
                                    .textCase(nil)
                            }
                        }
                        .listStyle(.inset)
                    }
                }
            } else {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "歌单不存在",
                    message: "可能已登录到别的账号，或上游已删除。"
                )
            }
        }
        .task(id: playlistID) {
            await load()
        }
    }

    /// 网络歌单的雷达请求（**种子 = 歌单自己的曲目**）。
    private func remoteRadarRequest(_ playlist: RemotePlaylist) -> RadarRequest {
        // 优先用上游给的完整 `trackIds`；没有就用已取回的曲目 ID。
        let ids = detail?.trackIds.isEmpty == false ? (detail?.trackIds ?? []) : songs.map { $0.id }
        // **内容身份包含全部曲目**（不只是前几条）。
        let signature = model.radarContentSignature(
            scope: "remote:\(playlist.id)",
            id: playlist.id,
            ids: ids
        )
        return RadarRequest(
            scope: "remote:\(playlist.id)",
            contentSignature: signature,
            seedSongIDs: Array(ids.prefix(RadarService.Limits.maxSeeds)),
            seedLocalTracks: [],
            sourceSongIDs: Set(ids)
        )
    }

    @ViewBuilder
    private func rowView(
        row: (offset: Int, element: RemoteSong),
        playlist: RemotePlaylist
    ) -> some View {
        let song = row.element
        TrackRowView(
            title: song.name,
            subtitle: song.artistText,
            trailingText: formatDuration(Double(song.durationMs) / 1000),
            isCurrent: model.player.current?.id == "netease:\(song.id)",
            onPlay: { model.playRemotePlaylist(playlist, song: song) }
        ) {
            // 网络曲目也能加入 **临时播放** 与 **本地歌单**（先下载由 core 处理）。
            AddToPlaylistMenu(result: .remote(song)) { Image(systemName: "plus") }
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        do {
            let loaded = try await model.environment.bridge.playlistDetail(id: playlistID)
            guard !Task.isCancelled else { return }
            songs = loaded.songs
            detail = loaded.playlist
            if loaded.missing > 0 {
                model.banner = .warning("有 \(loaded.missing) 首曲目无法读取")
            }
        } catch {
            guard !Task.isCancelled else { return }
            loadError = AppModel.describe(error)
        }
        loading = false
    }
}

/// 歌单里的 **推荐雷达内容**（本地 / 网络歌单共用同一套）。
///
/// - **只读**：只给播放队列供曲，**不下载、不改歌单**；
/// - 播放走 **统一入口**：保留全部已展示的雷达项，从被点击的那一首开始；
/// - 失败与空结果 **如实显示**，都可重试；**不影响歌单自身的曲目**。
struct PlaylistRadarContent: View {
    @EnvironmentObject private var model: AppModel
    let request: RadarRequest

    var body: some View {
        let state = model.radarState(for: request.scope)
        VStack(alignment: .leading, spacing: 8) {
            Text("只推荐不在这个歌单、你的资料库或本应用播放记录里的相似歌曲。")
                .font(.caption)
                .foregroundStyle(.secondary)
            RadarStatusView(state: state) {
                Task { await model.loadRadar(request, force: true) }
            }
            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, song in
                TrackRowView(
                    title: song.name,
                    subtitle: song.artistText,
                    trailingText: formatDuration(Double(song.durationMs) / 1000),
                    isCurrent: model.player.current?.id == "netease:\(song.id)",
                    onPlay: { model.playRadar(state.items, startAt: index) }
                ) {
                    // 「+」仍是原来的规则（加入临时播放 / 本地歌单）。
                    AddToPlaylistMenu(result: .remote(song)) { Image(systemName: "plus") }
                }
            }
        }
        .task(id: request.contentSignature) {
            await model.loadRadar(request)
        }
    }
}

/// 把 **当前临时播放** 另存为 **本地歌单**。
struct SaveQueueAsPlaylistSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("把临时播放另存为歌单").font(.headline)
            TextField("名称", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("描述（可选）", text: $details)
                .textFieldStyle(.roundedBorder)
            Text("保存为本地歌单；其中的网络曲目会先下载，成功后再入单。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    let name = title
                    let description = details
                    dismiss()
                    Task {
                        await model.saveQueueAsLocalPlaylist(title: name, details: description)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
