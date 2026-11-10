import AlgerKit
import SwiftUI

/// 搜索页：输入歌名 → 列表 → 点按播放 / 下载。
struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var keyword = ""
    @State private var results: [RemoteSong] = []
    @State private var isSearching = false
    @State private var message: String?
    @State private var busySongID: Int64?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    TextField("歌名或歌手", text: $keyword)
                        .font(ElderUI.rowTitleFont)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Button {
                        Task { await search() }
                    } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .semibold))
                    }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("搜索")
                }
                .padding(.horizontal, 16)

                if let message {
                    Text(message)
                        .font(ElderUI.captionFont)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }

                List(results) { song in
                    SongRow(
                        song: song,
                        isBusy: busySongID == song.id,
                        onPlay: { Task { await play(song) } },
                        onDownload: { Task { await download(song) } }
                    )
                }
                .listStyle(.plain)
                .overlay {
                    if isSearching && results.isEmpty {
                        ProgressView("搜索中…").font(ElderUI.rowTitleFont)
                    } else if !isSearching && results.isEmpty {
                        Text("搜一首歌，点一下就能听")
                            .font(ElderUI.rowTitleFont)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("找歌")
        }
    }

    private func search() async {
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let service = model.service else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let (songs, total) = try await service.searchSongs(keywords: text, limit: 50)
            results = songs
            message = total > songs.count ? "共 \(total) 首，显示前 \(songs.count) 首" : nil
        } catch {
            message = DownloadStore.describe(error)
        }
    }

    private func play(_ song: RemoteSong) async {
        busySongID = song.id
        defer { busySongID = nil }
        await model.play(song: song)
    }

    private func download(_ song: RemoteSong) async {
        busySongID = song.id
        defer { busySongID = nil }
        let ok = await model.download(song: song)
        message = ok ? "已加入下载队列" : "下载失败"
    }
}

/// 搜索结果行（大字、大按钮）。
struct SongRow: View {
    let song: RemoteSong
    let isBusy: Bool
    let onPlay: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.name)
                        .font(ElderUI.rowTitleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(song.artistText)
                        .font(ElderUI.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if isBusy {
                ProgressView().frame(width: 40, height: 40)
            } else {
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("下载 \(song.name)")
            }
        }
        .padding(.vertical, 8)
    }
}
