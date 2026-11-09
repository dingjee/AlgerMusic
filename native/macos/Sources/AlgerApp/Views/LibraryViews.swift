import AlgerKit
import SwiftUI

// MARK: - 未知元信息的统一显示

/// 未知元信息的统一占位（**不显示一长串路径**）。
private let unknownMetadataLabel = "Unrecognized"

/// 元信息显示值：空值与「未知…」统一成 `Unrecognized`。
private func metadataLabel(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return unknownMetadataLabel }
    switch trimmed {
    case "未知艺人", "未知专辑", "未知歌曲":
        return unknownMetadataLabel
    default:
        return trimmed
    }
}

/// 本地曲目的显示标题（**兜底不显示路径**）。
private func trackTitle(_ track: TrackRecord) -> String {
    let title = metadataLabel(track.displayTitle)
    if title == track.path { return unknownMetadataLabel }
    return title
}

// MARK: - 排序（只影响显示）

/// 歌曲排序（**只影响显示**，不改数据、不改稳定 ID）。
enum SongSort: String, CaseIterable, Identifiable {
    case name
    case artist
    /// 按本地文件的最后修改时间（**文案是「最近修改」**）。
    case modified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .artist: return "艺人"
        case .modified: return "最近修改"
        }
    }
}

/// 专辑排序（只影响显示）。
enum AlbumSort: String, CaseIterable, Identifiable {
    case name
    case artist
    case trackCount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .artist: return "艺人"
        case .trackCount: return "曲目数"
        }
    }
}

/// 艺人排序（只影响显示；本地与关注 **分区各自排序**）。
enum ArtistSort: String, CaseIterable, Identifiable {
    case name
    case trackCount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .trackCount: return "曲目数"
        }
    }
}

// MARK: - 列视图（类似 Finder 列视图）

/// 列视图里的艺人选择（**本地与网络分开，不混 ID**）。
private enum ArtistColumnSelection: Hashable {
    /// 本地艺人（按艺人名）。
    case local(name: String)
    /// 关注的艺人（**只按网络艺人 ID**）。
    ///
    /// 不带名字：上游刷新后艺人名可能变，**按 ID 选中才不会丢高亮**。
    case followed(id: Int64)
}

/// 列视图里的专辑选择（**本地与网络分开，不混 ID**）。
private enum AlbumColumnSelection: Hashable {
    /// 本地专辑（`LocalAlbum.id` = `艺人|专辑`）。
    case local(id: String)
    /// 网络专辑（按网络专辑 ID）。
    case remote(id: Int64, name: String, artist: String)
}

/// 列视图里的一行（**点箭头向右打开下一列**）。
struct BrowserRow: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    var trailingText: String?
    var isSelected: Bool = false
    /// 辅助功能标识（供 AX 验证定位这一行）。
    var identifier: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let trailingText {
                    Text(trailingText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        }
        .buttonStyle(.plain)
        // **已选态给辅助功能一个明确标记**（AX selected trait）。
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .axIdentifier(identifier)
    }
}

/// 列视图的一列（**等宽**：可见列平分正文宽度，列内各自纵向滚动）。
///
/// - 宽度 **由布局决定**（`EqualColumnsLayout`）：根列占满正文，展开后各列等分；
/// - 不设固定像素、也不设最小宽度 → 窄窗口不会横向溢出；
/// - 每列 **各自纵向滚动**（互不影响）；
/// - **没有灰底**：与歌曲页共享同一块正文背景（窗口背景）。
/// - **根列不画标题**：页面顶部已经有统一标题，重复画一遍会多出计数。
///   子列保留 **具体艺人 / 专辑** 的标题与左侧竖线。
struct BrowserColumn<Content: View>: View {
    /// 列标题（`nil` = 不画标题区）。
    let title: String?
    var subtitle: String?
    /// 是否画标题区（根列 false，子列 true）。
    var showsHeader: Bool = true
    /// 左侧是否画分隔线（第一列不画）。
    var showsSeparator: Bool = false
    private let content: () -> Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        showsHeader: Bool = true,
        showsSeparator: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showsHeader = showsHeader
        self.showsSeparator = showsSeparator
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader, let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 分隔线画在列的左沿（不额外占位，列宽仍是平分出来的）。
        .overlay(alignment: .leading) {
            if showsSeparator {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1)
            }
        }
    }
}

/// 等宽列布局：**可见列平分正文宽度**（1/N）。
///
/// - 宽度按容器实时计算 → 没有固定像素宽度，也没有最小宽度
///   → 窄窗口不会横向溢出；
/// - 列数变化 → 每列宽度按比例重算（父列随之平滑收窄）；
/// - 子列从尾部推入（配合 `.transition(.move(edge: .trailing))`）。
///
/// 用法：`EqualColumnsLayout { 列1; 列2 }`（SwiftUI 的 `Layout.callAsFunction`）。
struct EqualColumnsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = resolvedWidth(proposal: proposal, subviews: subviews)
        let width = columnWidth(total: total, count: subviews.count)
        var height: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
            height = max(height, size.height)
        }
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = columnWidth(total: bounds.width, count: subviews.count)
        var x = bounds.minX
        for subview in subviews {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width
        }
    }

    /// 容器宽度：优先用父级给的 **有限** 宽度，否则退回子列的理想宽度。
    ///
    /// 绝不返回 `nil` / `infinity`（否则列宽会变成无限或 0）。
    private func resolvedWidth(proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        if let width = proposal.width, width.isFinite, width > 0 { return width }
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height))
            if size.width.isFinite { widest = max(widest, size.width) }
        }
        return widest
    }

    /// 每列宽度：**平分**容器宽度（至少一列）。
    private func columnWidth(total: CGFloat, count: Int) -> CGFloat {
        let columns = max(1, count)
        guard total.isFinite, total > 0 else { return 0 }
        return total / CGFloat(columns)
    }
}

/// 列视图里的占位提示（**不造假数据**）。
struct BrowserPlaceholder: View {
    let systemImage: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 28)
    }
}

/// 一列本地歌曲（**每行右端都有「+」**：加到临时播放 / 本地歌单）。
struct LocalSongList: View {
    @EnvironmentObject private var model: AppModel
    let tracks: [TrackRecord]
    /// 副标题显示艺人还是专辑。
    var subtitleStyle: SubtitleStyle = .artist

    enum SubtitleStyle {
        case artist
        case album
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if tracks.isEmpty {
                BrowserPlaceholder(systemImage: "music.note.list", text: "这里还没有本地歌曲")
            } else {
                ForEach(tracks, id: \.path) { track in
                    TrackRowView(
                        title: trackTitle(track),
                        subtitle: subtitleStyle == .artist
                            ? metadataLabel(track.displayArtist)
                            : metadataLabel(track.displayAlbum),
                        trailingText: formatDuration(Double(track.durationMs) / 1000),
                        isCurrent: model.player.current?.id == "path:\(track.path)",
                        onPlay: { model.playLocal(track) }
                    ) {
                        AddToPlaylistMenu(result: .local(track)) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("加入临时播放；右键或长按选择歌单")
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }
}

// MARK: - 本地歌曲

/// 本地歌曲（**与侧栏同名**：歌曲）。
///
/// - 顶部是 **共享标题组件**（与专辑 / 艺人 / 下载同一套布局）；
/// - 副标题统一「共N个」；
/// - 右侧操作：**排序** 与 **扫描**（图标 + 文字，与其它页一致）；
/// - 排序 **只影响显示**：不改数据、不改稳定 ID。
struct LocalSongsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deletingTrack: TrackRecord?
    @State private var sort: SongSort = .name

    /// 按当前排序显示的歌曲（**只改顺序**）。
    private var sortedSongs: [TrackRecord] {
        switch sort {
        case .name:
            return model.localSongs.sorted {
                let left = ($0.displayTitle, $0.displayArtist)
                let right = ($1.displayTitle, $1.displayArtist)
                if left.0 != right.0 { return left.0.localizedCaseInsensitiveCompare(right.0) == .orderedAscending }
                return left.1.localizedCaseInsensitiveCompare(right.1) == .orderedAscending
            }
        case .artist:
            return model.localSongs.sorted {
                let left = ($0.displayArtist, $0.displayTitle)
                let right = ($1.displayArtist, $1.displayTitle)
                if left.0 != right.0 { return left.0.localizedCaseInsensitiveCompare(right.0) == .orderedAscending }
                return left.1.localizedCaseInsensitiveCompare(right.1) == .orderedAscending
            }
        case .modified:
            // **最近修改**（按文件最后修改时间；新的在前）。
            return model.localSongs.sorted { $0.modifiedAt > $1.modifiedAt }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "歌曲", subtitle: "共\(model.localSongs.count)个") {
                HStack(spacing: 8) {
                    PageSortMenu(title: "排序") {
                        ForEach(SongSort.allCases) { option in
                            Button {
                                sort = option
                            } label: {
                                if sort == option {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    }
                    PageActionButton(
                        title: "扫描",
                        systemImage: "arrow.triangle.2.circlepath",
                        isEnabled: !model.isScanning,
                        help: "扫描音乐目录"
                    ) {
                        Task { await model.scanLibrary() }
                    }
                }
            }
            if model.localSongs.isEmpty {
                EmptyStateView(
                    systemImage: "music.note.list",
                    title: "本地还没有歌曲",
                    message: "在设置里选择音乐目录后扫描，或下载音乐后自动加入。",
                    actionTitle: "立即扫描"
                ) {
                    Task { await model.scanLibrary() }
                }
            } else {
                List {
                    ForEach(sortedSongs, id: \.path) { track in
                        TrackRowView(
                            title: trackTitle(track),
                            subtitle: metadataLabel(track.displayArtist),
                            trailingText: formatDuration(Double(track.durationMs) / 1000),
                            isCurrent: model.player.current?.id == "path:\(track.path)",
                            onPlay: { model.playLocal(track) }
                        ) {
                            HStack(spacing: 6) {
                                AddToPlaylistMenu(result: .local(track)) {
                                    Image(systemName: "plus")
                                }
                                .buttonStyle(.plain)
                                .help("加入临时播放；右键或长按选择歌单")
                            }
                        }
                        .contextMenu {
                            Button("编辑元信息…") {
                                model.openMetadataEditor(for: track)
                            }
                            Button("移到废纸篓…", role: .destructive) {
                                deletingTrack = track
                            }
                        }
                    }
                }
                .listStyle(.inset)
                // **与列视图共享正文背景**：去掉列表自己的背景材质。
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(item: $deletingTrack) { track in
            TrashDeleteSheet(track: track)
                .environmentObject(model)
        }
    }
}

/// 删除到废纸篓的确认（**显示受影响歌单数**）。
struct TrashDeleteSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let track: TrackRecord

    private var plan: TrashService.Plan { model.trashPlan(for: track) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("移到废纸篓").font(.headline)
            Text(trackTitle(track))
                .font(.callout)
            Text("文件会移到 macOS 废纸篓，可从废纸篓恢复。")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("受影响的本地歌单", value: "\(plan.affectedPlaylistCount) 个")
            if plan.hasUnknownScope {
                Label(
                    "另有 \(plan.unreadablePlaylistIds.count) 个歌单当前读不出来，删除后会继续尝试清理其引用。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            ForEach(plan.issues, id: \.self) { issue in
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("移到废纸篓", role: .destructive) {
                    Task {
                        await model.confirmTrashDelete(track)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - 本地专辑（列视图）

/// 本地专辑浏览器：**专辑 → 歌曲** 两级列视图。
///
/// 初次只渲染专辑列（**占满正文宽度**）；点专辑（整行）才在右侧追加并列的
/// 歌曲列，**两列平分正文宽度**（1/2），子列从尾部推入；
/// 左侧选择保留；未选中时不铺「请选择」占位列。
///
/// 顶部是 **共享标题组件**（与歌曲 / 艺人同一套）；根列 **不再重复画标题与计数**。
struct LocalAlbumsView: View {
    @EnvironmentObject private var model: AppModel
    /// 当前选中的本地专辑（`LocalAlbum.id`）。
    @State private var selectedAlbumID: String?
    @State private var sort: AlbumSort = .name

    private var selectedAlbum: LocalAlbum? {
        guard let selectedAlbumID else { return nil }
        return sortedAlbums.first { $0.id == selectedAlbumID }
    }

    /// 按当前排序显示的专辑（**只改顺序**，稳定 ID 不变 → 选择不丢）。
    private var sortedAlbums: [LocalAlbum] {
        switch sort {
        case .name:
            return model.localAlbums.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .artist:
            return model.localAlbums.sorted {
                let left = ($0.albumArtist, $0.name)
                let right = ($1.albumArtist, $1.name)
                if left.0 != right.0 { return left.0.localizedCaseInsensitiveCompare(right.0) == .orderedAscending }
                return left.1.localizedCaseInsensitiveCompare(right.1) == .orderedAscending
            }
        case .trackCount:
            return model.localAlbums.sorted {
                if $0.tracks.count != $1.tracks.count { return $0.tracks.count > $1.tracks.count }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "专辑", subtitle: "共\(model.localAlbums.count)个") {
                PageSortMenu(title: "排序") {
                    ForEach(AlbumSort.allCases) { option in
                        Button {
                            sort = option
                        } label: {
                            if sort == option {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
            }
            if model.localAlbums.isEmpty {
                EmptyStateView(
                    systemImage: "square.stack",
                    title: "还没有本地专辑",
                    message: "扫描音乐目录后，专辑会按文件标签自动归组。"
                )
            } else {
                // **等宽列**：根列占满正文；选中专辑后两列平分（不横向滚动）。
                EqualColumnsLayout {
                    albumsColumn
                    if let album = selectedAlbum {
                        albumSongsColumn(album)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
        }
    }

    /// 根列：**不画标题**（页面顶部已经有统一标题与计数）。
    private var albumsColumn: some View {
        BrowserColumn(showsHeader: false) {
            ForEach(sortedAlbums) { album in
                BrowserRow(
                    systemImage: "square.stack",
                    title: metadataLabel(album.name),
                    subtitle: "\(metadataLabel(album.albumArtist)) · \(album.tracks.count) 首",
                    isSelected: selectedAlbumID == album.id,
                    identifier: "album-row-\(album.id)"
                ) {
                    selectAlbum(album)
                }
            }
        }
    }

    private func albumSongsColumn(_ album: LocalAlbum) -> some View {
        BrowserColumn(
            title: metadataLabel(album.name),
            subtitle: metadataLabel(album.albumArtist),
            showsSeparator: true
        ) {
            LocalSongList(tracks: album.tracks, subtitleStyle: .artist)
        }
    }

    /// 选中专辑（**子列从尾部推入**，父列一起收窄）。
    private func selectAlbum(_ album: LocalAlbum) {
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedAlbumID = album.id
        }
    }
}

// MARK: - 艺人（列视图）

/// 艺人浏览器：**本地艺人 + 关注的艺人**。
///
/// 列视图（类似 Finder 列视图），**按需追加，初次只显示第一列**：
/// - 第一列：本地艺人、关注的艺人（**两段独立展示，ID 不混用**）；
/// - 点本地艺人 → 追加第二列本地专辑；点关注的艺人 → 追加第二列艺人详情（网络热门 / 网络专辑）；
/// - 点专辑 → 再追加第三列歌曲；换艺人清掉旧的歌曲列，前列选中保留。
///
/// 宽度：**可见列平分正文宽度**（1 → 1/2 → 1/3），不横向滚动。
struct LocalArtistsView: View {
    @EnvironmentObject private var model: AppModel
    /// 第一列选中的艺人（**本地与网络分开**）。
    @State private var selectedArtist: ArtistColumnSelection?
    /// 第二列选中的专辑（**本地与网络分开**）。
    @State private var selectedAlbum: AlbumColumnSelection?
    @State private var sort: ArtistSort = .name

    /// 艺人总数（**本地组 + 关注组**）。
    private var artistCount: Int {
        model.localArtists.count + model.followedArtists.count
    }

    /// 本地艺人（按当前排序；**只改顺序**，稳定 ID = 艺人名不变）。
    private var sortedLocalArtists: [LocalArtist] {
        switch sort {
        case .name:
            return model.localArtists.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .trackCount:
            return model.localArtists.sorted {
                if $0.tracks.count != $1.tracks.count { return $0.tracks.count > $1.tracks.count }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    /// 关注的艺人（按当前排序；**ID 不变 → 高亮不丢**）。
    private var sortedFollowedArtists: [RemoteArtist] {
        switch sort {
        case .name:
            return model.followedArtists.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .trackCount:
            return model.followedArtists.sorted {
                if $0.musicCount != $1.musicCount { return $0.musicCount > $1.musicCount }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    /// 选中的关注艺人（**按 ID 找**，名字刷新也不丢）。
    private var selectedFollowedArtist: RemoteArtist? {
        guard case .followed(let id) = selectedArtist else { return nil }
        return model.followedArtists.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "艺人", subtitle: "共\(artistCount)个") {
                PageSortMenu(title: "排序") {
                    ForEach(ArtistSort.allCases) { option in
                        Button {
                            sort = option
                        } label: {
                            if sort == option {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
            }
            // **永远显示列视图**：关注分区（加载 / 错误 / 刷新）不能被空态整页盖住。
            // **等宽列**：一列 → 两列 → 三列，各列平分正文宽度（不横向滚动）。
            EqualColumnsLayout {
                artistsColumn
                if let selectedArtist {
                    artistDetailColumn(selectedArtist)
                        .transition(.move(edge: .trailing))
                    if let selectedAlbum {
                        albumColumn(selectedAlbum)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
        }
        .task {
            // 关注的艺人：登录后才有内容（core 也会在登录后自动刷新）。
            guard model.isLoggedIn else { return }
            await model.refreshFollowedArtists()
        }
    }

    // MARK: 第一列：艺人

    private var artistsColumn: some View {
        // 根列 **不画标题**（页面顶部已经有统一标题与计数）。
        BrowserColumn(showsHeader: false) {
            sectionTitle("本地艺人")
            if model.localArtists.isEmpty {
                BrowserPlaceholder(systemImage: "music.mic", text: "还没有本地艺人")
            } else {
                ForEach(sortedLocalArtists) { artist in
                    BrowserRow(
                        systemImage: "music.mic",
                        title: metadataLabel(artist.name),
                        subtitle: "\(artist.tracks.count) 首",
                        isSelected: selectedArtist == .local(name: artist.name),
                        identifier: "artist-row-local-\(artist.name)"
                    ) {
                        selectArtist(.local(name: artist.name))
                    }
                }
            }
            sectionTitle("关注的艺人", action: { refreshFollowedArtists() })
            followedArtists
        }
    }

    @ViewBuilder
    private var followedArtists: some View {
        if model.isLoadingFollowedArtists {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在加载关注的艺人…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } else if let error = model.followedArtistsError {
            VStack(alignment: .leading, spacing: 6) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Button("重试") { refreshFollowedArtists() }
                    .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } else if model.followedArtists.isEmpty {
            Text(model.isLoggedIn ? "还没有关注的艺人" : "登录后可以查看关注的艺人")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        } else {
            ForEach(sortedFollowedArtists) { artist in
                BrowserRow(
                    systemImage: "person.2",
                    title: metadataLabel(artist.name),
                    subtitle: artist.musicCount > 0 ? "\(artist.musicCount) 首" : nil,
                    isSelected: selectedArtist == .followed(id: artist.id),
                    identifier: "artist-row-followed-\(artist.id)"
                ) {
                    selectArtist(.followed(id: artist.id))
                }
            }
        }
    }

    private func sectionTitle(_ title: String, action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let action {
                Button(action: action) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.isLoadingFollowedArtists)
                .help("刷新关注的艺人")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: 第二列：艺人 → 专辑 / 艺人详情

    @ViewBuilder
    private func artistDetailColumn(_ selection: ArtistColumnSelection) -> some View {
        switch selection {
        case .local(let name):
            BrowserColumn(title: metadataLabel(name), subtitle: "专辑", showsSeparator: true) {
                if localAlbums.isEmpty {
                    BrowserPlaceholder(systemImage: "square.stack", text: "这个艺人还没有本地专辑")
                } else {
                    ForEach(localAlbums) { album in
                        BrowserRow(
                            systemImage: "square.stack",
                            title: metadataLabel(album.name),
                            subtitle: "\(album.tracks.count) 首",
                            isSelected: selectedAlbum == .local(id: album.id)
                        ) {
                            selectAlbum(.local(id: album.id))
                        }
                    }
                }
            }
        case .followed(let id):
            // **按 ID 找艺人**（名称刷新也不丢高亮）。
            let artist = selectedFollowedArtist
            BrowserColumn(title: metadataLabel(artist?.name ?? ""), showsSeparator: true) {
                if let artist {
                    // 网络艺人：**复用艺人详情**（网络热门 / 网络专辑仍在右列）。
                    ArtistDetailView(
                        name: artist.name,
                        remoteID: id,
                        onSelectAlbum: { album in
                            selectAlbum(.remote(id: album.id, name: album.name, artist: artist.name))
                        },
                        isEmbedded: true
                    )
                } else {
                    BrowserPlaceholder(systemImage: "person.2", text: "找不到这个艺人")
                }
            }
        }
    }

    // MARK: 第三列：专辑 → 歌曲

    @ViewBuilder
    private func albumColumn(_ selection: AlbumColumnSelection) -> some View {
        switch selection {
        case .local:
            BrowserColumn(title: metadataLabel(selectedLocalAlbum?.name ?? ""), subtitle: "歌曲", showsSeparator: true) {
                if let album = selectedLocalAlbum {
                    LocalSongList(tracks: album.tracks, subtitleStyle: .artist)
                } else {
                    BrowserPlaceholder(systemImage: "music.note.list", text: "找不到这个专辑")
                }
            }
        case .remote(let id, let albumName, let artistName):
            BrowserColumn(title: metadataLabel(albumName), subtitle: metadataLabel(artistName), showsSeparator: true) {
                AlbumDetailView(
                    name: albumName,
                    artist: artistName,
                    remoteID: id,
                    isEmbedded: true
                )
            }
        }
    }

    // MARK: 选择与数据

    /// 选中的本地艺人。
    private var selectedLocalArtist: LocalArtist? {
        guard case .local(let name) = selectedArtist else { return nil }
        return model.localArtists.first { $0.name == name }
    }

    /// 选中本地艺人 → 本地专辑（**按 `displayAlbum` 分组**，与资料库的分组口径一致）。
    ///
    /// 排序 **跟顶部一致**（只影响显示）。
    private var localAlbums: [LocalAlbum] {
        guard let artist = selectedLocalArtist else { return [] }
        var order: [String] = []
        var groups: [String: [TrackRecord]] = [:]
        for track in artist.tracks {
            let key = track.displayAlbum
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(track)
        }
        let albums = order.map { key in
            LocalAlbum(name: key, albumArtist: artist.name, tracks: groups[key] ?? [])
        }
        switch sort {
        case .name:
            return albums.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .trackCount:
            return albums.sorted {
                if $0.tracks.count != $1.tracks.count { return $0.tracks.count > $1.tracks.count }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    /// 选中的本地专辑。
    private var selectedLocalAlbum: LocalAlbum? {
        guard case .local(let id) = selectedAlbum else { return nil }
        return localAlbums.first { $0.id == id }
    }

    /// 选择艺人（**换艺人就清掉右边的专辑选择**，左侧选择保留）。
    private func selectArtist(_ selection: ArtistColumnSelection) {
        // 子列从尾部推入，父列一起平滑收窄。
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedArtist = selection
            selectedAlbum = nil
        }
    }

    /// 选择专辑。
    private func selectAlbum(_ selection: AlbumColumnSelection) {
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedAlbum = selection
        }
    }

    /// 刷新关注的艺人。
    private func refreshFollowedArtists() {
        Task { await model.refreshFollowedArtists() }
    }
}

// MARK: - 艺人详情

/// 艺人详情：**本地上方，网络热门与新作下方**。
struct ArtistDetailView: View {
    @EnvironmentObject private var model: AppModel
    let name: String
    let remoteID: Int64?
    /// 选中网络专辑时的回调（不传就跳转到专辑详情页）。
    var onSelectAlbum: ((RemoteAlbum) -> Void)?
    /// 嵌在列视图里（**不再套一层滚动视图**，用列自己的滚动）。
    var isEmbedded: Bool = false

    private var data: ArtistDetailData {
        model.artistDetails[model.artistKey(name: name, remoteID: remoteID)] ?? ArtistDetailData()
    }

    var body: some View {
        Group {
            if isEmbedded {
                sections
            } else {
                ScrollView {
                    sections
                }
            }
        }
        .task(id: model.artistKey(name: name, remoteID: remoteID)) {
            await model.loadArtistDetail(name: name, remoteID: remoteID)
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(
                title: metadataLabel(name),
                subtitle: isEmbedded ? nil : "本地曲目在上，网络热门与新作在下"
            )

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "本地曲目")
                if data.localTracks.isEmpty {
                    Text("本地还没有这个艺人的曲目")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(data.localTracks, id: \.path) { track in
                        TrackRowView(
                            title: trackTitle(track),
                            subtitle: metadataLabel(track.displayAlbum),
                            trailingText: formatDuration(Double(track.durationMs) / 1000),
                            isCurrent: model.player.current?.id == "path:\(track.path)",
                            onPlay: { model.playLocal(track) }
                        ) {
                            AddToPlaylistMenu(result: .local(track)) {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.plain)
                            .help("加入临时播放；右键或长按选择歌单")
                        }
                    }
                }
            }

            if let error = data.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if remoteID != nil {
                hotSongsSection
                remoteAlbumsSection
            }
        }
        .padding(.horizontal, isEmbedded ? 14 : 20)
        .padding(.top, isEmbedded ? 12 : 16)
        .padding(.bottom, isEmbedded ? 12 : 20)
    }

    @ViewBuilder
    private var hotSongsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "网络热门歌曲")
            if data.hotSongs.isEmpty {
                Text("暂时没有内容")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(data.hotSongs) { song in
                    TrackRowView(
                        title: metadataLabel(song.name),
                        subtitle: metadataLabel(song.artistText),
                        trailingText: formatDuration(Double(song.durationMs) / 1000),
                        isCurrent: model.player.current?.id == "netease:\(song.id)",
                        onPlay: { model.playRemote(song) }
                    ) {
                        AddToPlaylistMenu(result: .remote(song)) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("加入临时播放；右键或长按选择歌单")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var remoteAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "网络专辑 / 新作")
            if data.albums.isEmpty {
                Text("暂时没有内容")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(data.albums) { album in
                    Button {
                        if let onSelectAlbum {
                            onSelectAlbum(album)
                        } else {
                            model.selection = .albumDetail(
                                name: album.name,
                                artist: name,
                                remoteID: album.id
                            )
                        }
                    } label: {
                        HStack {
                            Image(systemName: "square.stack")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(metadataLabel(album.name))
                                Text("网络专辑")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 专辑详情

/// 专辑详情（本地曲目 + 网络曲目）。
struct AlbumDetailView: View {
    @EnvironmentObject private var model: AppModel
    let name: String
    let artist: String
    let remoteID: Int64?
    /// 嵌在列视图里（**不再套一层滚动视图**，用列自己的滚动）。
    var isEmbedded: Bool = false

    private var data: AlbumDetailData {
        model.albumDetails[model.albumKey(name: name, artist: artist, remoteID: remoteID)] ?? AlbumDetailData()
    }

    var body: some View {
        Group {
            if isEmbedded {
                sections
            } else {
                ScrollView {
                    sections
                }
            }
        }
        .task(id: model.albumKey(name: name, artist: artist, remoteID: remoteID)) {
            await model.loadAlbumDetail(name: name, artist: artist, remoteID: remoteID)
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: metadataLabel(name), subtitle: artist.isEmpty ? nil : metadataLabel(artist))

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "本地曲目")
                if data.localTracks.isEmpty {
                    Text("本地还没有这个专辑的曲目")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(data.localTracks, id: \.path) { track in
                        TrackRowView(
                            title: trackTitle(track),
                            subtitle: metadataLabel(track.displayArtist),
                            trailingText: formatDuration(Double(track.durationMs) / 1000),
                            isCurrent: model.player.current?.id == "path:\(track.path)",
                            onPlay: { model.playLocal(track) }
                        ) {
                            AddToPlaylistMenu(result: .local(track)) {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.plain)
                            .help("加入临时播放；右键或长按选择歌单")
                        }
                    }
                }
            }

            if let error = data.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if remoteID != nil {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "网络曲目")
                    if data.songs.isEmpty {
                        Text("暂时没有内容")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(data.songs) { song in
                            TrackRowView(
                                title: metadataLabel(song.name),
                                subtitle: metadataLabel(song.artistText),
                                trailingText: formatDuration(Double(song.durationMs) / 1000),
                                isCurrent: model.player.current?.id == "netease:\(song.id)",
                                onPlay: { model.playRemote(song) }
                            ) {
                                AddToPlaylistMenu(result: .remote(song)) {
                                    Image(systemName: "plus")
                                }
                                .buttonStyle(.plain)
                                .help("加入临时播放；右键或长按选择歌单")
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, isEmbedded ? 14 : 20)
        .padding(.top, isEmbedded ? 12 : 16)
        .padding(.bottom, isEmbedded ? 12 : 20)
    }
}
