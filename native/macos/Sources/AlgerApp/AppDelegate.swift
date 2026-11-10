import AppKit
import SwiftUI

/// 应用代理：窗口生命周期、Dock 恢复、异步退出。
///
/// 约定：
/// - **关窗隐藏**：关掉窗口不退出应用（音频与下载继续，Dock 图标保留）；
/// - **Dock 恢复**：点击 Dock 图标重新显示窗口；
/// - **⌘Q 异步退出**：退出前在 **后台线程** 做桥接收束（主线程不做可能阻塞的等待），
///   收束完成后再真正退出。
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var model: AppModel?
    private var isTerminating = false
    private var didShutDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        do {
            let model = try AppModel()
            self.model = model
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Alger Music"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            // 保留系统窗口框架与四角裁切，内容延伸至透明标题栏。
            window.backgroundColor = .windowBackgroundColor
            window.minSize = NSSize(width: 940, height: 580)
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView().environmentObject(model))
            window.center()
            window.makeKeyAndOrderFront(nil)
            mainWindow = window
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                await model.bootstrap()
            }
        } catch {
            // 启动失败（例如数据目录覆盖不合法）：明确报错，不静默回落真实 profile。
            presentFatalError(error)
        }
    }

    /// 关窗 → **隐藏**（应用继续运行）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// Dock 点击 / `open -a` → 恢复窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// 关闭所有窗口后 **不退出**（窗口只是被隐藏）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// ⌘Q：**异步退出**（不在主线程做可能阻塞的收束）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateNow }
        isTerminating = true
        let model = self.model
        Task {
            await model?.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// ⌘, → 打开设置（设置是内容区的一个导航目标）。
    @objc func showSettings(_ sender: Any?) {
        Task { @MainActor [weak self] in
            self?.model?.selection = .settings
            self?.mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// ⌘F → 聚焦 **侧栏第一行的搜索框**（**唯一搜索入口**）。
    @objc func focusSearch(_ sender: Any?) {
        Task { @MainActor [weak self] in
            self?.model?.focusSearchField()
            self?.mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 兜底收束：**幂等且有界**（前台的异步收束已经做过时这里立即返回）。
        model?.shutdownNow()
    }

    private func presentFatalError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Alger Music 无法启动"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .critical
        alert.addButton(withTitle: "退出")
        alert.runModal()
        // **必须真正退出**：启动失败时没有 `terminateLater` 挂在身下，
        // 只 `reply(toApplicationShouldTerminate:)` 会留下一个没有窗口的进程。
        NSApp.terminate(nil)
    }
}

/// 应用菜单（AppKit 原生菜单；⌘Q / 复制粘贴等系统快捷键需要它）。
enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        // 应用菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "关于 Alger Music",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "设置…",
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "隐藏 Alger Music",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "隐藏其他",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(
            withTitle: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 Alger Music",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 文件菜单（关窗 = 隐藏，不是退出）
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(
            withTitle: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // 编辑菜单（文本框的复制 / 粘贴 / 全选）
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // **⌘F**：聚焦侧栏第一行的搜索框（唯一搜索入口，没有第二个入口）。
        editMenu.addItem(
            withTitle: "搜索",
            action: #selector(AppDelegate.focusSearch(_:)),
            keyEquivalent: "f"
        )
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 窗口菜单
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "缩放",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}
