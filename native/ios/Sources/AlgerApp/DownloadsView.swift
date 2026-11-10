import AlgerKit
import SwiftUI

/// 下载页：任务列表（进度 / 状态）+ 播放已下载文件。
struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store: DownloadStore

    init(store: DownloadStore) {
        self.store = store
    }

    var body: some View {
        NavigationStack {
            List {
                if store.tasks.isEmpty {
                    Text("还没有下载")
                        .font(ElderUI.rowTitleFont)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.tasks) { task in
                        DownloadRow(
                            task: task,
                            onPlay: { model.playDownload(task) },
                            onRetry: { Task { await store.retry(id: task.id) } }
                        )
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("已下载")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { Task { await store.clearAll() } }
                        .font(ElderUI.captionFont)
                }
            }
            .overlay {
                if let error = store.lastError {
                    VStack {
                        Spacer()
                        Text(error)
                            .font(ElderUI.captionFont)
                            .foregroundStyle(.red)
                            .padding()
                    }
                }
            }
            .refreshable { await store.refresh() }
        }
    }
}

/// 下载任务行。
struct DownloadRow: View {
    let task: DownloadTask
    let onPlay: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.name)
                    .font(ElderUI.rowTitleFont)
                    .lineLimit(2)
                Text(task.artist)
                    .font(ElderUI.captionFont)
                    .foregroundStyle(.secondary)
                if task.isActive {
                    ProgressView(value: Double(task.percent) / 100)
                        .frame(height: 6)
                }
                if let error = task.error, !error.isEmpty {
                    Text(error)
                        .font(ElderUI.captionFont)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if task.isDone {
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill").font(.system(size: 32))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("播放 \(task.name)")
            } else if task.isFailed {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise.circle").font(.system(size: 32))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重试 \(task.name)")
            } else {
                ProgressView().frame(width: 32, height: 32)
            }
        }
        .padding(.vertical, 8)
    }
}
