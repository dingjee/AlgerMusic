import Foundation
import XCTest

@testable import AlgerKit

#if canImport(Darwin)
import Darwin
#endif

/// 桥接客户端测试。
///
/// 夹具分两类：
/// - **真实子进程夹具**（`/bin/sh` 脚本）：EOF、异常退出、事件、写入失败等边界；
/// - **真实桥接二进制**（`crates/alger-bridge`）：通过 `--session-path` 注入隔离会话，
///   **不改 HOME、不读真实凭证**。
final class BridgeClientTests: XCTestCase {

    /// 工作目录必须活到测试结束（夹具脚本被删掉的话，子进程会立刻退出）。
    private var keepAlive: [TempWorkspace] = []

    // MARK: - 辅助

    private func makeClient(
        script: String,
        configuration: BridgeClient.Configuration = BridgeClient.Configuration(),
        environment: [String: String]? = nil
    ) throws -> (BridgeClient, TempWorkspace) {
        let workspace = try TempWorkspace("bridge")
        keepAlive.append(workspace)
        let scriptURL = try workspace.writeScript(script, named: "fixture.sh")
        let client = try BridgeClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [scriptURL.path],
            environment: environment,
            configuration: configuration
        )
        return (client, workspace)
    }

    private func makeRealBridge(
        configuration: BridgeClient.Configuration = BridgeClient.Configuration(),
        environment: [String: String] = [:],
        sessionName: String = "session.json"
    ) throws -> (BridgeClient, TempWorkspace, URL) {
        let workspace = try TempWorkspace("bridge-real")
        keepAlive.append(workspace)
        let sessionURL = workspace.url(sessionName)
        let binary = TestPaths.bridgeBinary
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("""
                找不到真实桥接二进制：\(binary.path)
                请先执行 sh scripts/test-swift.sh（会自动构建 crates/alger-bridge）
                """)
            throw BridgeClient.ClientError.launchFailed(binary.path)
        }
        var env = environment
        env["ALGER_BRIDGE_TEST_HOOKS"] = "1"
        // 测试里不需要桥接等满默认的 10s：把在途请求的退出等待压到 1s。
        env["ALGER_BRIDGE_EXIT_WAIT_MS"] = "1000"
        let client = try BridgeClient(
            executableURL: binary,
            arguments: ["--session-path", sessionURL.path],
            environment: env,
            configuration: configuration
        )
        return (client, workspace, sessionURL)
    }

    // MARK: - 真实桥接

    func testRealBridgeAnswersAndPairsByID() async throws {
        let (client, workspace, _) = try makeRealBridge()
        defer { client.shutdown() }

        let hello = try await client.callDictionary("app.hello")
        XCTAssertEqual(hello["protocol"] as? Int, 1)

        // 并发两个请求：响应必须按 id 正确配对（谁先回谁先结算）。
        async let slow = client.callDictionary("test.slow", params: ["ms": 600])
        async let fast = client.callDictionary("test.slow", params: ["ms": 10])
        let fastResult = try await fast
        let slowResult = try await slow
        XCTAssertEqual(fastResult["slept"] as? Int, 10)
        XCTAssertEqual(slowResult["slept"] as? Int, 600)
        _ = workspace
    }

    func testRealBridgeUsesInjectedSessionPathAndNoRealCredentials() async throws {
        let (client, _, sessionURL) = try makeRealBridge()
        defer { client.shutdown() }

        let snapshot = try await client.callDictionary("session.snapshot")
        XCTAssertEqual(snapshot["sessionPath"] as? String, sessionURL.path)
        // 隔离会话文件落在测试目录里（不在用户 Application Support）。
        XCTAssertTrue(sessionURL.path.contains(".artifacts"), sessionURL.path)
        XCTAssertEqual(snapshot["hasCookie"] as? Bool, false)

        // 环境只是「追加」：HOME 没被改，其它变量仍在。
        let environment = try XCTUnwrap(client.launchedEnvironment)
        XCTAssertEqual(environment["HOME"], ProcessInfo.processInfo.environment["HOME"], "不得改 HOME")
        XCTAssertEqual(environment["ALGER_BRIDGE_TEST_HOOKS"], "1")
        XCTAssertEqual(environment["PATH"], ProcessInfo.processInfo.environment["PATH"])
    }

    func testRealBridgeReportsBusinessError() async throws {
        let (client, _, _) = try makeRealBridge()
        defer { client.shutdown() }

        do {
            _ = try await client.callDictionary("no.such.method")
            XCTFail("未知方法应当失败")
        } catch let error as BridgeClient.BridgeError {
            XCTAssertEqual(error.code, "Unsupported")
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    func testRealBridgeTimeoutSettlesOnceAndClientStaysUsable() async throws {
        let (client, _, _) = try makeRealBridge()
        defer { client.shutdown() }

        let started = Date()
        do {
            _ = try await client.callDictionary("test.slow", params: ["ms": 5000], timeout: 0.4)
            XCTFail("应当超时")
        } catch let error as BridgeClient.ClientError {
            guard case .timeout = error else {
                return XCTFail("期望超时错误，实际 \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)

        // 超时之后客户端仍然可用（被放弃的请求 id 之后到达的响应被忽略）。
        let hello = try await client.callDictionary("app.hello")
        XCTAssertEqual(hello["protocol"] as? Int, 1)
    }

    func testCancellationSettlesRequestExactlyOnce() async throws {
        let (client, _, _) = try makeRealBridge()
        defer { client.shutdown() }

        let task = Task { () -> Any in
            try await client.callDictionary("test.slow", params: ["ms": 5000])
        }
        // 给请求一点时间真正发出去
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("应当取消")
        } catch let error as BridgeClient.ClientError {
            guard case .cancelled = error else {
                return XCTFail("期望取消错误，实际 \(error)")
            }
        } catch is CancellationError {
            // 也接受任务级取消错误
        }
    }

    // MARK: - 子进程夹具

    func testEOFWhenChildExitsWithoutAnswering() async throws {
        let (client, _) = try makeClient(script: Fixtures.eofServer)
        defer { client.shutdown() }

        do {
            _ = try await client.callDictionary("test.echo")
            XCTFail("应当失败")
        } catch let error as BridgeClient.ClientError {
            guard case .closed = error else {
                return XCTFail("期望终态错误，实际 \(error)")
            }
        }
    }

    func testAbnormalExitSettlesPendingRequest() async throws {
        let (client, _) = try makeClient(script: Fixtures.crashServer)
        defer { client.shutdown() }

        do {
            _ = try await client.callDictionary("test.echo")
            XCTFail("应当失败")
        } catch let error as BridgeClient.ClientError {
            guard case .closed = error else {
                return XCTFail("期望终态错误，实际 \(error)")
            }
        }
    }

    func testTimeoutSettlesRequest() async throws {
        var configuration = BridgeClient.Configuration()
        configuration.requestTimeout = 0.4
        let (client, _) = try makeClient(script: Fixtures.silentServer, configuration: configuration)
        defer { client.shutdown() }

        let started = Date()
        do {
            _ = try await client.callDictionary("test.echo")
            XCTFail("应当超时")
        } catch let error as BridgeClient.ClientError {
            guard case .timeout = error else {
                return XCTFail("期望超时错误，实际 \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testTerminalStateRejectsNewCalls() async throws {
        let (client, _) = try makeClient(script: Fixtures.eofServer)
        // 等子进程退出
        _ = try? await client.callDictionary("test.echo")
        let deadline = Date().addingTimeInterval(3)
        while !client.isTerminated && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(client.isTerminated)

        do {
            _ = try await client.callDictionary("app.hello")
            XCTFail("终态后应当拒绝新调用")
        } catch let error as BridgeClient.ClientError {
            guard case .closed = error else {
                return XCTFail("期望终态错误，实际 \(error)")
            }
        }
    }

    func testEventCallbackRunsOutsideStateQueueAndCanCallBack() async throws {
        let (client, _) = try makeClient(script: Fixtures.echoServer)
        defer { client.shutdown() }

        let received = expectation(description: "事件回调")
        var onStateQueueDuringCallback: Bool?
        var nestedCallSucceeded = false

        client.onEvent { name, payload in
            onStateQueueDuringCallback = client.isOnStateQueue
            if name == "test", payload["n"] != nil {
                Task {
                    // 回调里再次调用客户端：不能死锁
                    if let result = try? await client.callDictionary("test.echo") {
                        nestedCallSucceeded = (result["echo"] as? Int) != nil
                    }
                    received.fulfill()
                }
            }
        }

        _ = try await client.callDictionary("test.event")
        await fulfillment(of: [received], timeout: 5)

        XCTAssertEqual(onStateQueueDuringCallback, false, "事件回调必须在状态队列之外")
        XCTAssertTrue(nestedCallSucceeded, "事件回调里应当可以再次调用客户端")
    }

    func testConcurrentRequestsAreSerializedOnTheWireAndPaired() async throws {
        let (client, _) = try makeClient(script: Fixtures.echoServer)
        defer { client.shutdown() }

        let count = 24
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<count {
                group.addTask {
                    let response = try await client.callDictionary("test.echo")
                    return response["echo"] as? Int ?? -1
                }
            }
            var collected: [Int] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        XCTAssertEqual(results.count, count)
        XCTAssertEqual(Set(results).count, count, "每个请求都必须拿到自己的 id")
        XCTAssertTrue(results.allSatisfy { $0 > 0 })
        XCTAssertEqual(client.pendingRequestCount, 0)
        // 每个请求 **只结算一次**。
        XCTAssertEqual(client.settledRequestCount, count)
    }

    func testWriteFailureOnBrokenPipeSettlesRequestOnce() async throws {
        // 夹具不读 stdin 并很快退出：写请求时管道会断（EPIPE）。
        let script = """
        #!/bin/sh
        sleep 0.4
        exit 0
        """
        let (client, _) = try makeClient(script: script)
        defer { client.shutdown() }

        // 大载荷撑满管道缓冲，子进程退出后写入失败。
        let payload = String(repeating: "x", count: 400_000)
        do {
            _ = try await client.callDictionary("test.echo", params: ["blob": payload], timeout: 10)
            XCTFail("写入失败时请求必须失败")
        } catch let error as BridgeClient.ClientError {
            switch error {
            case .writeFailed, .closed:
                break
            default:
                XCTFail("期望写入失败或终态错误，实际 \(error)")
            }
        }
        XCTAssertEqual(client.settledRequestCount, 1, "请求只结算一次")
        XCTAssertEqual(client.pendingRequestCount, 0)
    }

    func testBrokenPipeIsReportedAsWriteFailureAndSettlesOnce() async throws {
        // 子进程 **关闭 stdin 但继续运行**（stdout 不结束 → 不会先走 EOF 分支），
        // 并用一条 ready 事件确认 stdin 确实已关闭（不靠 sleep 撞竞态）。
        let script = """
        #!/bin/sh
        exec 0<&-
        printf '{"ev":"stdin-closed","p":{}}\\n'
        sleep 5
        """
        let (client, _) = try makeClient(script: script)
        defer { client.shutdown() }

        let ready = expectation(description: "夹具已关闭 stdin")
        client.onEvent { name, _ in
            if name == "stdin-closed" { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 10)

        do {
            _ = try await client.callDictionary("test.echo", timeout: 10)
            XCTFail("断管道时请求必须失败")
        } catch let error as BridgeClient.ClientError {
            guard case .writeFailed = error else {
                return XCTFail("期望写入失败，实际 \(error)")
            }
        }
        XCTAssertEqual(client.settledRequestCount, 1, "请求只结算一次")
    }

    func testCallsAfterShutdownAreRejected() async throws {
        let (client, _) = try makeClient(script: Fixtures.echoServer)
        client.shutdown()
        XCTAssertTrue(client.isTerminated)

        do {
            _ = try await client.callDictionary("app.hello")
            XCTFail("关闭后必须拒绝新调用")
        } catch let error as BridgeClient.ClientError {
            guard case .closed = error else {
                return XCTFail("期望终态错误，实际 \(error)")
            }
        }
    }

    func testShutdownSettlesInFlightRequestInsteadOfHanging() async throws {
        // 夹具不回答：请求会一直挂着。
        let (client, _) = try makeClient(script: Fixtures.silentServer)
        let pending = Task { () -> Any in
            try await client.callDictionary("test.echo", timeout: 30)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let started = Date()
        client.shutdown()
        let duration = Date().timeIntervalSince(started)

        do {
            _ = try await pending.value
            XCTFail("关闭时在途请求必须被结算")
        } catch let error as BridgeClient.ClientError {
            guard case .closed = error else {
                return XCTFail("期望终态错误，实际 \(error)")
            }
        }
        XCTAssertLessThan(duration, 8, "关闭必须有界")
        XCTAssertEqual(client.settledRequestCount, 1, "在途请求只结算一次")
    }

    func testWriteFailureAfterChildExitSettlesRequest() async throws {
        let (client, _) = try makeClient(script: Fixtures.exitAfterFirstLine)
        defer { client.shutdown() }

        // 第一次请求被子进程消费（可能成功，也可能撞上退出），随后子进程退出。
        _ = try? await client.callDictionary("test.echo")
        let deadline = Date().addingTimeInterval(3)
        while !client.isTerminated && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(client.isTerminated, "子进程退出后客户端必须进入终态")
    }

    // MARK: - 关闭

    func testShutdownIsIdempotentBoundedAndReapsExactChild() async throws {
        let (client, _) = try makeClient(script: Fixtures.echoServer)
        let pid = client.childProcessIdentifier
        XCTAssertNotNil(pid)

        let started = Date()
        client.shutdown()
        let firstDuration = Date().timeIntervalSince(started)

        let secondStarted = Date()
        client.shutdown()
        let secondDuration = Date().timeIntervalSince(secondStarted)

        XCTAssertLessThan(firstDuration, 8, "关闭必须有界")
        XCTAssertLessThan(secondDuration, 2, "重复关闭必须立即返回")
        XCTAssertFalse(client.isRunning)
        XCTAssertTrue(client.isTerminated)

        // 精确回收：只针对自己启动的 pid，且子进程已被 wait 掉（不是僵尸）。
        if let pid {
            XCTAssertEqual(kill(pid, 0), -1, "子进程应已退出")
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testShutdownTerminatesUnresponsiveChild() async throws {
        let (client, _) = try makeClient(script: Fixtures.silentServer)
        let pid = client.childProcessIdentifier

        let started = Date()
        client.shutdown()
        let duration = Date().timeIntervalSince(started)

        XCTAssertLessThan(duration, 8, "关闭必须有界")
        XCTAssertFalse(client.isRunning)
        if let pid {
            XCTAssertEqual(kill(pid, 0), -1)
        }
    }

    func testTerminationHandlerFiresOutsideStateQueue() async throws {
        let (client, _) = try makeClient(script: Fixtures.eofServer)
        let terminated = expectation(description: "终止通知")
        var onStateQueue: Bool?
        client.onTermination { _ in
            onStateQueue = client.isOnStateQueue
            terminated.fulfill()
        }
        _ = try? await client.callDictionary("test.echo")
        await fulfillment(of: [terminated], timeout: 5)
        XCTAssertEqual(onStateQueue, false)
    }

    // MARK: - stdin 写 / 关闭的并发边界（E1 必修 2）

    /// 关闭与在途写入并发：所有请求都必须 **结算且只结算一次**，
    /// 关闭必须有界，不得有请求悬着。
    func testConcurrentShutdownAndWritesSettleEveryRequestExactlyOnce() async throws {
        var configuration = BridgeClient.Configuration()
        configuration.shutdownTimeout = 1
        configuration.terminateGrace = 1
        // 夹具从不读 stdin → 写端很快写满（真实背压）。
        let (client, _) = try makeClient(script: Fixtures.nonReadingServer, configuration: configuration)

        let count = 16
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<count {
            tasks.append(Task {
                _ = try? await client.callDictionary(
                    "test.echo",
                    params: ["blob": String(repeating: "x", count: 32 * 1024)],
                    timeout: 30
                )
            })
        }
        // 给请求一点时间真正登记并开始写
        try await Task.sleep(nanoseconds: 300_000_000)

        let started = Date()
        client.shutdown()
        let duration = Date().timeIntervalSince(started)
        XCTAssertLessThan(duration, 10, "关闭必须有界")

        for task in tasks { await task.value }
        XCTAssertEqual(client.pendingRequestCount, 0, "不得有请求悬着")
        XCTAssertEqual(client.settledRequestCount, count, "每个请求都必须结算且只结算一次")
        XCTAssertTrue(client.isTerminated)
    }

    /// 管道背压时写入必须有界失败（不得挂死 writer）。
    func testBackpressuredWriteFailsBoundedInsteadOfHanging() async throws {
        var configuration = BridgeClient.Configuration()
        configuration.writeTimeout = 1
        configuration.shutdownTimeout = 1
        configuration.terminateGrace = 1
        let (client, _) = try makeClient(script: Fixtures.nonReadingServer, configuration: configuration)
        defer { client.shutdown() }

        let payload = String(repeating: "x", count: 2 * 1024 * 1024)
        let started = Date()
        do {
            _ = try await client.callDictionary("test.echo", params: ["blob": payload], timeout: 30)
            XCTFail("背压写入必须有界失败")
        } catch let error as BridgeClient.ClientError {
            switch error {
            case .writeFailed, .closed:
                break
            default:
                XCTFail("期望写入失败或终态错误，实际 \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "背压写入必须有界")
    }

    /// 关闭后写端 fd 必须真的被关闭；之后 **不得** 有迟到写入落进被复用的 fd 号。
    func testShutdownClosesStdinWriteEndAndNoLateWriteLeaksIntoReusedDescriptor() async throws {
        var configuration = BridgeClient.Configuration()
        configuration.shutdownTimeout = 1
        configuration.terminateGrace = 1
        let (client, workspace) = try makeClient(
            script: Fixtures.nonReadingServer,
            configuration: configuration
        )
        let descriptor = client.stdinWriteDescriptor

        // 让 writer 卡在写满的管道上（真实背压）
        let payload = String(repeating: "x", count: 4 * 1024 * 1024)
        let pending = Task {
            _ = try? await client.callDictionary("test.echo", params: ["blob": payload], timeout: 30)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        client.shutdown()
        _ = await pending.value

        // 写端必须已经关闭：这个 fd 号不会再被写。
        XCTAssertTrue(client.stdinWriteEndClosed, "stdin 写端必须被关闭")
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1, "stdin 写端 fd 应当已关闭")
        XCTAssertEqual(errno, EBADF)

        // 复用该 fd 号打开哨兵文件：任何迟到写入都会污染它。
        let canary = workspace.url("canary.bin")
        let canaryFD = open(canary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(canaryFD, 0)
        // 等一会儿，让可能迟到的写入有机会发生
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(try Data(contentsOf: canary), Data(), "关闭后的迟到写入不得污染复用该 fd 号的文件")
        close(canaryFD)
    }

    /// 客户端释放后，**无关的 fd** 必须仍然有效（不得有「陈旧所有者」二次 close）。
    func testClientDeallocationDoesNotCloseUnrelatedDescriptors() async throws {
        let workspace = try TempWorkspace("bridge-fd-keepalive")
        keepAlive.append(workspace)
        let canary = workspace.url("keepalive.txt")
        let canaryFD = open(canary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(canaryFD, 0)

        do {
            let (client, _) = try makeClient(script: Fixtures.echoServer)
            _ = try? await client.callDictionary("test.echo")
            client.shutdown()
        }   // 客户端在此释放（deinit → shutdown）

        XCTAssertNotEqual(fcntl(canaryFD, F_GETFD), -1, "无关 fd 不得被误关")
        var byte: UInt8 = 88
        let written = write(canaryFD, &byte, 1)
        XCTAssertEqual(written, 1, "无关 fd 必须仍然可写")
        close(canaryFD)
        XCTAssertEqual(try Data(contentsOf: canary), Data([88]))
    }

    /// 客户端 **不得** 改动全局信号处置（SIGPIPE 仍是默认动作）。
    func testGlobalSigpipeDispositionIsUnchanged() async throws {
        let (client, _) = try makeClient(script: Fixtures.echoServer)
        _ = try? await client.callDictionary("test.echo")
        client.shutdown()

        // 真实子进程往断管道写：默认处置下应当死于 SIGPIPE。
        // 如果客户端把 SIGPIPE 改成忽略，子进程就会正常退出 —— 断言会失败。
        let helper = try LockHelper.executable()
        let process = Process()
        process.executableURL = helper
        process.arguments = ["sigpipe"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(process.isRunning, "探针子进程应当已经退出")
        XCTAssertEqual(process.terminationReason, .uncaughtSignal, "子进程应当死于信号")
        XCTAssertEqual(process.terminationStatus, SIGPIPE, "全局 SIGPIPE 处置不得被客户端改动")
    }

    // MARK: - 启动失败路径不得泄漏 fd / 线程（E1 必修 2 补充）

    /// 反复启动失败（可执行文件不存在）不得泄漏 fd，也不得留下等待中的读线程。
    ///
    /// 这条检查同时在 **隔离的子进程** 里跑一遍（`ALGER_LEAK_ISOLATED=1`）：
    /// 主进程派生一个只跑这条检查的 xctest 子进程，泄漏不会污染主测试进程。
    func testFailedLaunchDoesNotLeakDescriptorsOrThreads() throws {
        if ProcessInfo.processInfo.environment["ALGER_LEAK_ISOLATED"] == "1" {
            try measureFailedLaunchLeak()
            return
        }
        // 隔离运行：让子进程执行同样的检查。
        let bundle = Bundle(for: BridgeClientTests.self).bundleURL
        let runner = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
        guard bundle.pathExtension == "xctest",
              FileManager.default.isExecutableFile(atPath: runner.path) else {
            try measureFailedLaunchLeak()
            return
        }
        let process = Process()
        process.executableURL = runner
        process.arguments = [
            "-XCTest", "AlgerKitTests.BridgeClientTests/testFailedLaunchDoesNotLeakDescriptorsOrThreads",
            bundle.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["ALGER_LEAK_ISOLATED"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(
            process.terminationStatus, 0,
            "隔离子进程中的泄漏检查必须通过：\n\(text)"
        )
        XCTAssertTrue(
            text.contains("testFailedLaunchDoesNotLeakDescriptorsOrThreads"),
            "隔离子进程必须真的执行了这条检查：\n\(text)"
        )
    }

    /// 在当前进程里测量「反复启动失败」前后的 fd / 线程数量。
    private func measureFailedLaunchLeak() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/alger-bridge-does-not-exist")
        // 预热（第一次可能加载动态库、起 libdispatch 线程池）。
        for _ in 0..<4 {
            XCTAssertThrowsError(try BridgeClient(executableURL: missing))
        }

        let descriptorsBefore = ProcessResources.openDescriptorCount()
        let threadsBefore = ProcessResources.threadCount()
        for _ in 0..<25 {
            XCTAssertThrowsError(try BridgeClient(executableURL: missing)) { error in
                guard case BridgeClient.ClientError.launchFailed = error else {
                    return XCTFail("期望启动失败，实际 \(error)")
                }
            }
        }
        // 给读线程一点时间收尾（它们应当在 EOF 后退出）。
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let descriptors = ProcessResources.openDescriptorCount()
            if descriptors <= descriptorsBefore + 1 && BridgeClient.activeReaderThreadCount == 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let descriptorsAfter = ProcessResources.openDescriptorCount()
        let threadsAfter = ProcessResources.threadCount()
        XCTAssertLessThanOrEqual(
            descriptorsAfter, descriptorsBefore + 1,
            "反复启动失败不得泄漏 fd（之前 \(descriptorsBefore)，之后 \(descriptorsAfter)）"
        )
        XCTAssertEqual(
            BridgeClient.activeReaderThreadCount, 0,
            "反复启动失败不得留下等待中的读线程"
        )
        // 线程总数只作参考：libdispatch 的工作线程池会按需增长，不是泄漏。
        XCTAssertLessThanOrEqual(
            threadsAfter, threadsBefore + 4,
            "反复启动失败不得大量增加线程（之前 \(threadsBefore)，之后 \(threadsAfter)）"
        )
    }

    /// 正常启动 + 关闭反复进行，也不得泄漏 fd / 线程。
    func testRepeatedLaunchAndShutdownDoesNotLeakDescriptorsOrThreads() async throws {
        // 只造夹具脚本，**不**通过 makeClient 顺带起一个没人关闭的客户端。
        let workspace = try TempWorkspace("bridge-leak")
        keepAlive.append(workspace)
        let scriptURL = try workspace.writeScript(Fixtures.echoServer, named: "fixture.sh")
        let before = ProcessResources.openDescriptorCount()
        let threadsBefore = ProcessResources.threadCount()
        for _ in 0..<10 {
            let client = try BridgeClient(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [scriptURL.path]
            )
            _ = try? await client.callDictionary("test.echo")
            client.shutdown()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let descriptors = ProcessResources.openDescriptorCount()
            if descriptors <= before + 1 && BridgeClient.activeReaderThreadCount == 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let after = ProcessResources.openDescriptorCount()
        let threadsAfter = ProcessResources.threadCount()
        XCTAssertLessThanOrEqual(after, before + 1, "反复启动/关闭不得泄漏 fd")
        XCTAssertEqual(BridgeClient.activeReaderThreadCount, 0, "反复启动/关闭不得留下读线程")
        XCTAssertLessThanOrEqual(
            threadsAfter, threadsBefore + 4,
            "反复启动/关闭不得大量增加线程（之前 \(threadsBefore)，之后 \(threadsAfter)）"
        )
    }
}
