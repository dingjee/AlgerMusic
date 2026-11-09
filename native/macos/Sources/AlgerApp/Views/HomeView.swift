import AlgerKit
import SwiftUI

/// 探索页（原「主页」）：私人 FM / 关注艺人新作 / 推荐雷达 / 最近存入本地。
///
/// 布局（参考 Spotify 的卡片式首页）：
/// - **分区卡片区**：横排卡片，**不做长列表**；
/// - **所有曲目一律同一套卡片**（统一方形封面 + 独立播放按钮），
///   私人 FM 不再有任何特殊尺寸 / 特殊状态的首项大卡；
/// - **卡片交互**：单击卡片 = 高亮选中；双击卡片 = 播放；卡片右下角有独立的播放按钮；
/// - **每个分区短预览**：先给一小撮卡片，点「显示更多」再展开全部；
/// - **每个分区只渲染一次**（`ForEach(model.homeSections)` 一遍，不重复）；
/// - **不伪造数据**：只展示 `AppModel.homeSections` 里真实存在的内容，
///   取不到内容时显示真实错误。
///
/// **顶部是共享标题组件**：标题「探索」，右侧是 **图标 + 文字** 的「刷新」
/// （取代旧的悬浮 icon；空态里不再重复放一个刷新入口）。
///
/// **「最近存入本地」即时更新**：`AppModel.refreshLibrary()` 在扫描后直接
/// 更新 `homeSections` 里的 `recent` 分区，**不等待网络刷新**。
///
/// **未登录时不做假数据**：网络分区需要登录，但
/// 「最近存入本地」与本地播放 **不依赖登录**。
struct ExploreView: View {
    /// 推荐雷达在 `AppModel` 里的分区键。
    static let radarScope = "explore"

    @EnvironmentObject private var model: AppModel
    /// 已展开全部分区的 ID（短预览 → 展开）。
    @State private var expandedSections: Set<String> = []
    /// 当前高亮选中的卡片（单击选中；双击 / 播放按钮直接播放）。
    @State private var selectedItemID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "探索", subtitle: "私人 FM · 关注艺人新作 · 推荐雷达") {
                PageActionButton(
                    title: "刷新",
                    systemImage: "arrow.clockwise",
                    isEnabled: model.isLoggedIn,
                    help: "刷新推荐内容"
                ) {
                    Task {
                        await model.refreshHome()
                        // 顶部刷新 **确实强制重刷** 推荐雷达。
                        await model.loadExploreRadar(force: true)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if !model.isLoggedIn {
                        loginNotice
                    }
                    if model.isLoadingHome && model.homeSections.isEmpty {
                        ProgressView("正在加载推荐…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                    }
                    // **每个分区只渲染一次**，全部走统一的卡片行。
                    ForEach(model.homeSections) { section in
                        sectionView(section)
                    }
                    radarSection
                    if model.homeSections.isEmpty && !model.isLoadingHome {
                        EmptyStateView(
                            systemImage: "antenna.radiowaves.left.and.right",
                            title: "还没有推荐内容",
                            message: "登录网易云账号后可以刷新推荐；本机资料库与本地播放不依赖登录。"
                        )
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .padding(.bottom, 8)
            }
        }
        .task(id: model.radarSeedPlaylist?.id) {
            // 推荐雷达 **独立加载**：不阻塞上面的分区，也不影响它们的成败。
            await model.loadExploreRadar()
        }
    }

    // MARK: - 登录提示

    private var loginNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Label(
                "登录网易云账号后可用私人 FM、关注艺人的新歌与推荐雷达；本地资料库与本地播放不依赖登录。",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("打开登录窗口") {
                model.openLoginWindow()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 分区

    @ViewBuilder
    private func sectionView(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionHeader(title: section.title)
                if section.id == "radio" {
                    radioPicker
                }
            }
            if let error = section.error {
                // **显示具体错误**，不用空列表假装「没有内容」。
                SectionErrorView(message: error)
            } else if section.items.isEmpty {
                Text("暂时没有内容")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let visible = visibleItems(section, items: section.items)
                cardRow(visible)
                if visible.count < section.items.count || isExpanded(section.id) {
                    Button {
                        toggleExpanded(section.id)
                    } label: {
                        Label(
                            isExpanded(section.id) ? "收起" : "显示更多（\(section.items.count)）",
                            systemImage: isExpanded(section.id) ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 短预览数量（未展开时只显示一小撮）。
    private func visibleItems(_ section: HomeSection, items: [HomeSection.Item]) -> [HomeSection.Item] {
        guard !isExpanded(section.id) else { return items }
        return Array(items.prefix(Self.previewLimit(for: section)))
    }

    /// 每个分区的短预览数量（**不铺满整屏**，避免长列表）。
    private static func previewLimit(for section: HomeSection) -> Int {
        switch section.id {
        case "recent": return 8
        default: return 6
        }
    }

    private func isExpanded(_ id: String) -> Bool {
        expandedSections.contains(id)
    }

    private func toggleExpanded(_ id: String) {
        if expandedSections.contains(id) {
            expandedSections.remove(id)
        } else {
            expandedSections.insert(id)
        }
    }

    // MARK: - 推荐雷达

    /// 推荐雷达分区（**取代旧的「歌单电台」**）。
    ///
    /// - 种子来自 **所选网络歌单** 的曲目（仍可自选歌单）；
    /// - 播放走 **统一入口**：从被点击的那张卡片开始，队列只含本次展示的结果。
    @ViewBuilder
    private var radarSection: some View {
        let state = model.radarState(for: ExploreView.radarScope)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionHeader(title: "推荐雷达")
                radioPicker
            }
            Text("只推荐不在这个歌单、你的资料库或本应用播放记录里的相似歌曲。")
                .font(.caption)
                .foregroundStyle(.secondary)
            RadarStatusView(state: state) {
                Task { await model.loadExploreRadar(force: true) }
            }
            if !state.items.isEmpty {
                cardRow(state.items.map { .remote($0) }) { index in
                    model.playRadar(state.items, startAt: index)
                }
            }
        }
    }

    // MARK: - 卡片行

    private func cardRow(
        _ items: [HomeSection.Item],
        onPlayAt: ((Int) -> Void)? = nil
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HomeTrackCard(
                        item: item,
                        isSelected: selectedItemID == item.id,
                        isCurrent: isCurrent(item),
                        client: model.environment.client,
                        onSelect: { selectedItemID = item.id },
                        onPlay: {
                            selectedItemID = item.id
                            if let onPlayAt {
                                onPlayAt(index)
                            } else {
                                model.playResult(result(for: item))
                            }
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 数据辅助

    private func result(for item: HomeSection.Item) -> SearchResult {
        switch item {
        case .remote(let song): return .remote(song)
        case .local(let track): return .local(track)
        }
    }

    private func isCurrent(_ item: HomeSection.Item) -> Bool {
        switch item {
        case .remote(let song):
            return model.player.current?.id == "netease:\(song.id)"
        case .local(let track):
            return model.player.current?.id == "path:\(track.path)"
        }
    }

    /// 推荐雷达 **可以自选收藏的歌单**（切换歌单 **只更新雷达**，不重刷其它分区）。
    private var radioPicker: some View {
        Menu {
            ForEach(model.remotePlaylists) { playlist in
                Button {
                    model.radioPlaylistID = playlist.id
                } label: {
                    if model.radioPlaylistID == playlist.id {
                        Label(playlist.name, systemImage: "checkmark")
                    } else {
                        Text(playlist.name)
                    }
                }
            }
        } label: {
            Label("选择歌单", systemImage: "music.note.house")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择用于推荐的歌单")
        .accessibilityLabel("选择推荐歌单")
    }
}

// MARK: - 卡片

/// 首页卡片（一首曲目，**所有分区统一这套卡片**）。
///
/// **交互**：
/// - 单击卡片 → 高亮选中；
/// - 双击卡片 → 播放；
/// - 右下角独立播放按钮 → 播放（当前播放时显示喇叭）。
///
/// **每首只有一个「+」**（共享组件 `AddToPlaylistMenu`）：
/// 单击加入 **临时播放**，右键 / 长按弹出菜单选择具体歌单。
private struct HomeTrackCard: View {
    @EnvironmentObject private var model: AppModel
    let item: HomeSection.Item
    let isSelected: Bool
    let isCurrent: Bool
    let client: BridgeClient?
    let onSelect: () -> Void
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                HomeArtwork(
                    source: source(for: item),
                    size: 132,
                    cornerRadius: 10,
                    client: client
                )
                Button(action: onPlay) {
                    Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .help(isCurrent ? "正在播放" : "播放")
                .padding(8)
            }

            Text(titleText)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .lineLimit(1)
            Text(subtitleText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack {
                Spacer(minLength: 0)
                // 共享组件：单击加入临时播放，右键 / 长按选择歌单。
                AddToPlaylistMenu(result: result) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .help("加入临时播放；右键或长按选择歌单")
            }
        }
        .frame(width: 132, alignment: .leading)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        // 单击选中、双击播放：**先声明双击**，单击识别器会等双击判定，
        // 不会出现双击时先触发两次单击。
        .onTapGesture(count: 2) { onPlay() }
        .onTapGesture { onSelect() }
    }

    private var subtitleText: String {
        switch item {
        case .remote(let song):
            return "\(song.artistText) · \(formatDuration(Double(song.durationMs) / 1000))"
        case .local(let track):
            return "\(track.displayArtist) · \(formatDuration(Double(track.durationMs) / 1000))"
        }
    }

    /// 卡片标题：**不显示父目录绝对路径**（本地曲目取索引展示名 / 文件名）。
    private var titleText: String {
        switch item {
        case .remote(let song):
            return song.name
        case .local(let track):
            return track.displayTitle
        }
    }

    private var result: SearchResult {
        switch item {
        case .remote(let song): return .remote(song)
        case .local(let track): return .local(track)
        }
    }

    private func source(for item: HomeSection.Item) -> HomeArtwork.Source {
        switch item {
        case .remote(let song):
            let url = song.album.picUrl.isEmpty ? nil : URL(string: song.album.picUrl)
            return .remote(url)
        case .local(let track):
            return .local(path: track.path)
        }
    }
}

// MARK: - 分区错误

/// 分区错误（**显示具体原因**，不静默吞掉）。
struct SectionErrorView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 统一搜索结果（本地 + 网络）。
struct SearchResultView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isSearching {
                ProgressView("搜索中…")
                    .padding(20)
            }
            if model.searchResults.isEmpty && !model.isSearching {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "没有匹配的结果",
                    message: "换个关键词试试；本地与网络会一起搜索。"
                )
            } else {
                List {
                    Section {
                        ForEach(model.searchResults) { result in
                            row(for: result)
                        }
                        if model.canLoadMoreSearchResults {
                            HStack {
                                Spacer()
                                if model.isLoadingMoreResults {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("载入更多") {
                                        Task { await model.loadMoreSearchResults() }
                                    }
                                    .buttonStyle(.borderless)
                                }
                                Spacer()
                            }
                        }
                    } header: {
                        Text("结果（本地 \(model.searchResults.filter(\.isLocal).count) / 网络 \(model.searchResults.count - model.searchResults.filter(\.isLocal).count)）")
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func row(for result: SearchResult) -> some View {
        TrackRowView(
            title: displayTitle(for: result),
            subtitle: displaySubtitle(for: result),
            trailingText: result.isLocal ? "本地" : "网络",
            isCurrent: model.player.current?.id == result.id,
            onPlay: { model.playResult(result) }
        ) {
            // **只有一个 +**：单击加入临时播放，右键 / 长按选择歌单。
            AddToPlaylistMenu(result: result) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("加入临时播放；右键或长按选择歌单")
        }
    }

    /// 搜索结果标题：**本地曲目不显示父目录绝对路径**。
    private func displayTitle(for result: SearchResult) -> String {
        switch result {
        case .local(let track): return track.displayTitle
        case .remote(let song): return song.name
        }
    }

    /// 搜索结果副标题（艺人；缺失时用统一的未知占位）。
    private func displaySubtitle(for result: SearchResult) -> String {
        switch result {
        case .local(let track): return track.displayArtist
        case .remote(let song): return song.artistText
        }
    }
}
