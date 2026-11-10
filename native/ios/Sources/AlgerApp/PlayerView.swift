import AlgerKit
import SwiftUI

/// 播放页：当前曲目 + 大按钮控制。
struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var player: PlayerController

    init(player: PlayerController) {
        self.player = player
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 12)

                VStack(spacing: 10) {
                    Text(player.nowPlaying?.title ?? "还没有在播放")
                        .font(.system(size: 30, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 20)
                    Text(player.nowPlaying?.artist ?? "")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    if let label = player.nowPlaying?.sourceLabel, !label.isEmpty {
                        Text(label)
                            .font(ElderUI.captionFont)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = player.lastError {
                    Text(error)
                        .font(ElderUI.captionFont)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                }

                VStack(spacing: 12) {
                    ProgressView(value: progress)
                        .frame(height: 8)
                    HStack {
                        Text(format(player.elapsed))
                        Spacer()
                        Text(format(player.duration))
                    }
                    .font(ElderUI.captionFont)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)

                HStack(spacing: 28) {
                    Button { player.playPrevious() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 36))
                    }
                    .accessibilityLabel("上一首")

                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 76))
                    }
                    .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

                    Button { player.playNext() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 36))
                    }
                    .accessibilityLabel("下一首")
                }
                .buttonStyle(.plain)

                Spacer(minLength: 24)
            }
            .navigationTitle("正在播放")
        }
    }

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.elapsed / player.duration))
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
