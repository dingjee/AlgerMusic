import AlgerKit
import SwiftUI

/// iOS 极简版入口（妈妈版）：三个页签 —— 找歌 / 正在播放 / 已下载。
@main
struct AlgerIOSApp: App {
    @StateObject private var model = AppModel()
    @State private var showingLogin = false

    var body: some Scene {
        WindowGroup {
            Group {
                if let error = model.fatalError, model.service == nil {
                    StartupFailureView(message: error)
                } else if model.session?.loggedIn == true {
                    mainTabs
                } else {
                    loginGate
                }
            }
            .environmentObject(model)
            .task { await model.bootstrap() }
        }
    }

    private var mainTabs: some View {
        TabView {
            SearchView()
                .tabItem { Label("找歌", systemImage: "magnifyingglass") }

            PlayerView(player: model.player)
                .tabItem { Label("播放", systemImage: "play.circle") }

            if let downloads = model.downloads {
                DownloadsView(store: downloads)
                    .tabItem { Label("已下载", systemImage: "arrow.down.circle") }
            }
        }
    }

    private var loginGate: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "music.note")
                .font(.system(size: 72))
                .foregroundStyle(Color.accentColor)
            Text("网易音乐")
                .font(.system(size: 34, weight: .bold))
            Text("登录后就能找歌、听歌和下载")
                .font(.system(size: 19))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                showingLogin = true
            } label: {
                ElderUI.bigButton(title: "登录", systemImage: "person.circle")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showingLogin) {
            LoginView().environmentObject(model)
        }
    }
}

/// 启动失败（桥接起不来等）：给出明确原因与重试。
struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Text("启动失败").font(.system(size: 26, weight: .bold))
            Text(message)
                .font(ElderUI.captionFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding()
    }
}
