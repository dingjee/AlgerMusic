import AlgerKit
import SwiftUI

/// 底部播放条：暂停 / 跳过 / seek。
struct PlayerBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        HStack(spacing: 16) {
            // 当前曲目
            HStack(spacing: 8) {
                // **真实封面**：复用首页的封面组件 —— 本地读内嵌封面，
                // 网络走 https 的真实专辑图（`AsyncImage` 会被 ATS 拦掉）。
                HomeArtwork(
                    source: artworkSource,
                    size: 40,
                    cornerRadius: 9,
                    client: model.environment.client
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.player.current?.title ?? "未在播放")
                        .font(.callout)
                        .lineLimit(1)
                    if let current = model.player.current {
                        Text("\(current.artist)\(model.player.sourceDescription.isEmpty ? "" : " · \(model.player.sourceDescription)")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 传输控制
            HStack(spacing: 14) {
                Button {
                    model.player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.plain)
                .disabled(model.player.queue.isEmpty)
                .help("上一首")

                Button {
                    model.player.togglePlayPause()
                } label: {
                    Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(model.player.current == nil)
                .help(model.player.isPlaying ? "暂停" : "播放")

                Button {
                    model.player.next()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.plain)
                .disabled(model.player.queue.isEmpty)
                .help("下一首")
            }

            // 进度
            HStack(spacing: 8) {
                Text(formatDuration(isScrubbing ? scrubValue : model.player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : model.player.currentTime },
                        set: { newValue in
                            if !isScrubbing {
                                isScrubbing = true
                                scrubValue = newValue
                            } else {
                                scrubValue = newValue
                            }
                        }
                    ),
                    in: 0...max(model.player.duration, 0.01),
                    onEditingChanged: { editing in
                        if !editing {
                            model.player.seek(to: scrubValue)
                            isScrubbing = false
                        }
                    }
                )
                .frame(maxWidth: 320)
                .disabled(model.player.duration <= 0)
                Text(formatDuration(model.player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)
            }
            .frame(maxWidth: .infinity)

            // 队列入口（**显式访问当前实际队列**：侧栏入口是条件入口）。
            Button {
                model.selection = .queue
            } label: {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
            }
            .buttonStyle(.plain)
            .help(model.queueDisplayTitle)

            // 播放顺序（顺序 ↔ 随机）：与歌单头部是同一个控件，**这里只显示图标**。
            PlaybackOrderButton(iconOnly: true)
        }
        .padding(.horizontal, 22)
        .frame(height: 68)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    // MARK: - 封面来源

    /// 当前曲目的封面来源：**按播放来源选**。
    ///
    /// - 本地文件 → 读内嵌封面（真实文件里那张图）；
    /// - 网络曲目 → 专辑真实封面（http 会被规范化成 https，见 `HomeArtwork`）；
    /// - 没有曲目 → 占位图（不拿别的图冒充）。
    private var artworkSource: HomeArtwork.Source {
        guard let current = model.player.current else { return .none }
        switch current.origin {
        case .local(let path):
            return .local(path: path)
        case .remote:
            let raw = current.remoteSong?.album.picUrl ?? ""
            guard !raw.isEmpty, let url = URL(string: raw) else { return .none }
            return .remote(url)
        }
    }
}
