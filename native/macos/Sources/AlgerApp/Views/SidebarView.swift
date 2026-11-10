import AlgerKit
import SwiftUI

/// 原生侧栏。
///
/// 规则（产品规格）：
/// - 使用 **系统原生 sidebar 材质**（随系统外观 / 强调色 / 窗口激活变化）；
/// - **第一行是搜索框**（原生 `TextField` 胶囊）：与「探索」行左右边缘对齐，
///   两者之间留出清晰的垂直间距；**输入框不是导航项**（没有 tag）；
/// - **只有下载条目显示数字**，其余条目与分组不显示数字；
/// - **没有下载任务时隐藏下载入口**；有任务时按状态显示「正在下载 / 待处理 / 已下载」；
///   下载入口固定放在 **资料库分组最后**（歌曲 / 专辑 / 艺人之后）；
/// - 本地歌单组在前，网络歌单组在后，两组可独立折叠，远程组可在设置里隐藏；
///   macOS 14 起由系统分组管理折叠；macOS 13 用普通列表行控制折叠；
/// - **网络歌单只读**：侧栏不提供新建 / 删除入口，歌单详情页也只有播放与“加入”；
/// - **队列入口是条件入口**：队列为空时隐藏；播放本地 / 网络歌单时也隐藏
///   （队列就是那张歌单），播放器条上的队列图标仍可显式访问当前实际队列；
/// - 左下角显示账号（头像 + 昵称），点击进入账号操作与设置。
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingNewPlaylist = false
    /// 搜索框焦点（**⌘F** 也会聚焦它）。
    @FocusState private var searchFocused: Bool

    var body: some View {
        List(selection: $model.selection) {
            // **第一行：搜索框**（不是导航项：没有 tag，点它只是聚焦）。
            searchFieldRow

            Label("探索", systemImage: "safari")
                .tag(NavigationTarget.home)
                .accessibilityIdentifier("sidebar-explore")

            Section("资料库") {
                Label("歌曲", systemImage: "music.note")
                    .tag(NavigationTarget.localSongs)
                    .accessibilityIdentifier("sidebar-songs")
                Label("专辑", systemImage: "square.stack")
                    .tag(NavigationTarget.localAlbums)
                    .accessibilityIdentifier("sidebar-albums")
                Label("艺人", systemImage: "music.mic")
                    .tag(NavigationTarget.localArtists)
                    .accessibilityIdentifier("sidebar-artists")
                // 下载入口：资料库最后一项；**按本次任务出现**，没有任务就隐藏。
                if let entry = model.downloadEntry {
                    Label(entry.title, systemImage: "arrow.down.circle")
                        .badge(entry.badge)
                        .tag(NavigationTarget.downloads)
                        // 标题会随任务状态变，**NavigationTarget 保持稳定**。
                        .accessibilityIdentifier("sidebar-downloads")
                }
            }

            playlistSection(
                "本地歌单",
                expanded: $model.localSectionExpanded,
                showsNewPlaylistButton: true
            ) {
                ForEach(model.localPlaylists) { playlist in
                    Label(playlist.title, systemImage: "music.note.list")
                        .tag(NavigationTarget.localPlaylist(playlist.id))
                        .contextMenu {
                            Button("编辑歌单…") { model.selection = .localPlaylist(playlist.id) }
                            Button("删除歌单", role: .destructive) { model.deleteLocalPlaylist(id: playlist.id) }
                        }
                }
            }

            // 网络歌单组 **只读**：只列出、可折叠，无新建 / 删除入口。
            // 隐藏偏好下 **只**显示当前来源行（设置值不变）；没有来源行就整组隐藏。
            if showsRemoteSection {
                playlistSection("网络歌单", expanded: $model.remoteSectionExpanded) {
                    ForEach(model.sidebarRemotePlaylists) { playlist in
                        Label(playlist.name, systemImage: "music.note.list")
                            .tag(NavigationTarget.remotePlaylist(playlist.id))
                    }
                }
            }

            // **条件入口**：队列为空时没有这一行；雷达 / 私人 FM 显示真实来源。
            if let entry = model.queueEntry {
                Section {
                    Label(entry, systemImage: "text.line.first.and.arrowtriangle.forward")
                        .tag(NavigationTarget.queue)
                        .accessibilityIdentifier("sidebar-queue")
                }
            }

        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            accountRow
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .sheet(isPresented: $showingNewPlaylist) {
            NewPlaylistSheet()
                .environmentObject(model)
        }
        // **⌘F** → 聚焦搜索框（唯一搜索入口）。
        .onChange(of: model.searchFocusToken) { _ in
            searchFocused = true
        }
        // 侧栏换页 → **清掉搜索**：搜索不能遮住目的页。
        .onChange(of: model.selection) { target in
            guard target != nil else { return }
            model.clearSearch()
        }
    }

    /// 网络歌单组是否显示。
    ///
    /// - 正常（不隐藏）：显示；
    /// - 隐藏偏好：**只在有当前来源行时显示**（那一行是临时的，设置值不变）。
    private var showsRemoteSection: Bool {
        !model.environment.store.current.settings.hideRemotePlaylists
            || !model.sidebarRemotePlaylists.isEmpty
    }

    /// 搜索框（**侧栏第一行**：原生 `TextField` 胶囊）。    ///
    /// - **胶囊**：圆角 = 高度的一半；
    /// - **左右边缘**与「探索」行一致（同一套行内边距）；
    /// - 与「探索」之间留出清晰的垂直间距；
    /// - **不是导航项**（没有 tag）：点它只会聚焦输入框。
    private var searchFieldRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索本地与网络", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityIdentifier("sidebar-search")
            if !model.searchText.isEmpty {
                Button {
                    model.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.secondary.opacity(0.14), in: Capsule())
        .listRowSeparator(.hidden)
        // 与「探索」行之间留出清晰的垂直间距。
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func playlistSection(
        _ title: String,
        expanded: Binding<Bool>,
        showsNewPlaylistButton: Bool = false,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if !showsNewPlaylistButton, #available(macOS 14, *) {
            Section(title, isExpanded: expanded) {
                content()
            }
        } else {
            // 普通列表行让加号和折叠箭头各自保留按钮语义。
            Section {
                playlistHeader(
                    title,
                    expanded: expanded,
                    showsNewPlaylistButton: showsNewPlaylistButton
                )
                if expanded.wrappedValue {
                    content()
                }
            }
            .collapsible(false)
        }
    }

    /// 组标题行：**组标签 · 新建按钮 · 折叠箭头**。
    ///
    /// - 「新建歌单」是 **独立** 的 plus 图标按钮（组标签右边、箭头左边）；
    /// - plus 在标题行里 → **折叠后也可用**；
    /// - 点 plus **只开新建表单**，不改折叠状态、不改导航。
    private func playlistHeader(
        _ title: String,
        expanded: Binding<Bool>,
        showsNewPlaylistButton: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Button {
                toggle(expanded)
            } label: {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded.wrappedValue ? "已展开" : "已折叠")
            .accessibilityHint(expanded.wrappedValue ? "双击收起" : "双击展开")

            if showsNewPlaylistButton {
                Button {
                    showingNewPlaylist = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("新建歌单")
                .accessibilityLabel("新建歌单")
                .accessibilityIdentifier("sidebar-new-playlist")
            }

            Button {
                toggle(expanded)
            } label: {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(expanded.wrappedValue ? "收起" : "展开")\(title)")
            .accessibilityValue(expanded.wrappedValue ? "已展开" : "已折叠")
        }
    }

    /// 切换展开状态（组标签与箭头共用）。
    private func toggle(_ expanded: Binding<Bool>) {
        withAnimation(.easeInOut(duration: 0.18)) { expanded.wrappedValue.toggle() }
    }

    private var accountRow: some View {
        Button {
            model.selection = .settings
        } label: {
            HStack(spacing: 8) {
                AsyncImage(url: URL(string: model.account?.avatarUrl ?? "")) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.account?.nickname ?? "未登录")
                        .font(.callout)
                    Text(model.isLoggedIn ? "网易云账号" : "点击登录网易云")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 新建歌单表单（仅本地歌单）。
struct NewPlaylistSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建歌单").font(.headline)
            TextField("名称", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("描述（可选）", text: $details)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") {
                    model.createLocalPlaylist(title: title, details: details)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
