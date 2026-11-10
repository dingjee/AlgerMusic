import AlgerKit
import SwiftUI

/// 主界面骨架：原生侧栏 + 内容区 + 底部播放条。
///
/// **搜索在侧栏第一行**（`SidebarView` 里的原生 `TextField` 胶囊）：
/// 这里 **不再挂 `.searchable`** —— 搜索入口只有那一个，
/// 侧栏换页时搜索会被清掉（**搜索不能遮住目的页**）。
struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 320)
        } detail: {
            DetailContainer()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: 96)
                }
                // **提示浮在内容之上**：不占布局空间，出现 / 消失都不会让内容跳高度。
                .overlay(alignment: .top) {
                    ToastView()
                        .padding(.top, 12)
                }
                .overlay(alignment: .bottom) {
                    PlayerBar()
                        .frame(maxWidth: 1000)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 18)
                }
        }
        .onChange(of: model.searchText) { newValue in
            // **唯一搜索入口**：输入内容即进入搜索结果。
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if model.selection == nil { model.selection = .home }
            }
        }
        .sheet(isPresented: $model.showingAdditionTargetPicker) {
            AdditionTargetPickerSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: Binding(
            get: { model.metadataEditorTrack != nil },
            set: { if !$0 { model.metadataEditorTrack = nil } }
        )) {
            if let track = model.metadataEditorTrack {
                // **只有保存成功才回调** → 回调里写索引 + 刷新资料库。
                MetadataEditorView(
                    track: track,
                    client: model.environment.client,
                    settingsURL: model.metadataSettingsURL,
                    onSaved: { updated in
                        model.applyMetadataUpdate(updated)
                    }
                )
            }
        }
    }
}

/// 内容区（按导航目标切换）。
struct DetailContainer: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchResultView()
            } else {
                switch model.selection ?? .home {
                case .home:
                    ExploreView()
                case .localSongs:
                    LocalSongsView()
                case .localAlbums:
                    LocalAlbumsView()
                case .localArtists:
                    LocalArtistsView()
                case .localPlaylist(let id):
                    LocalPlaylistDetailView(playlistID: id)
                case .remotePlaylist(let id):
                    RemotePlaylistDetailView(playlistID: id)
                        .id(id)
                case .artistDetail(let name, let remoteID):
                    ArtistDetailView(name: name, remoteID: remoteID)
                case .albumDetail(let name, let artist, let remoteID):
                    AlbumDetailView(name: name, artist: artist, remoteID: remoteID)
                case .downloads:
                    DownloadsView()
                case .queue:
                    QueueView()
                case .settings:
                    SettingsView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
