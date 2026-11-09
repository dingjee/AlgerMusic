import Foundation
import AppKit

// 定向退出：**只**向指定 PID 发送 `kAEQuitApplication`。
//
// 为什么不用 `tell application id "com.alger.music.trial" to quit`：
// 那会按 **bundle 标识** 匹配目标，可能把用户正在运行的同标识旧版本一起关掉，
// 属于误伤既有会话。交付流程里只允许关闭**本次隔离试跑自己启动的那个进程**，
// 因此必须用进程号精确定位。
//
// 用法：
//   swift scripts/quit-native.swift <pid>
//
// 退出码：
//   0 事件已发出；1 发送失败（目标不存在 / 无权投递）；2 参数错误（**不发事件**）。

let arguments = CommandLine.arguments
guard arguments.count == 2, let pid = Int32(arguments[1]), pid > 0 else {
    fputs("用法：swift scripts/quit-native.swift <pid>\n", stderr)
    exit(2)
}

// 目标描述符：SDK 的 processIdentifier 工厂（不手工拼大端字节）。
let target = NSAppleEventDescriptor(processIdentifier: pid)

// kAEQuitApplication 与 kAEQuit 同值（'quit'）；这里显式用 kAEQuitApplication
// 以表达语义：请求目标进程按其正常流程退出，而不是强杀。
let event = NSAppleEventDescriptor.appleEvent(
    withEventClass: AEEventClass(kCoreEventClass),
    eventID: AEEventID(kAEQuitApplication),
    targetDescriptor: target,
    returnID: AEReturnID(kAutoGenerateReturnID),
    transactionID: AETransactionID(kAnyTransactionID)
)

do {
    // sendEvent(options:timeout:) 在 Swift 里是 throws，并返回事件描述符。
    let reply = try event.sendEvent(options: [.noReply], timeout: 30)
    _ = reply
    print("已向 pid \(pid) 发送 kAEQuitApplication")
    exit(0)
} catch {
    fputs("向 pid \(pid) 发送 kAEQuitApplication 失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}
