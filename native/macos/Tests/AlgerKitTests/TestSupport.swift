import Foundation
import XCTest

@testable import AlgerKit

#if canImport(Darwin)
import Darwin
#endif

/// 测试用路径工具。
///
/// 规则：
/// - 所有临时文件、夹具、日志都落在仓库 `.artifacts/` 下（gitignored，`clean.sh` 会清）；
/// - **不触碰用户数据**：不使用 `~/Library`，不读真实会话文件，不改 `HOME`；
/// - 真实桥接二进制通过 `ALGER_BRIDGE_BIN` 注入，默认取仓库内构建产物。
enum TestPaths {
    static var repoRoot: URL {
        if let override = ProcessInfo.processInfo.environment["ALGER_TEST_REPO_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // #filePath = <root>/native/macos/Tests/AlgerKitTests/TestSupport.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        return url
    }

    static var artifactsRoot: URL {
        if let override = ProcessInfo.processInfo.environment["ALGER_TEST_ARTIFACTS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return repoRoot.appendingPathComponent(".artifacts/swift-tests", isDirectory: true)
    }

    /// 真实桥接二进制路径。
    static var bridgeBinary: URL {
        if let override = ProcessInfo.processInfo.environment["ALGER_BRIDGE_BIN"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return repoRoot
            .appendingPathComponent("crates/alger-bridge/target/debug", isDirectory: true)
            .appendingPathComponent("alger-bridge")
    }
}

/// 一次性测试工作目录（位于 `.artifacts/` 下）。
final class TempWorkspace {
    let root: URL

    init(_ label: String = "case") throws {
        let base = TestPaths.artifactsRoot
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative, isDirectory: false)
    }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> URL {
        let directory = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func write(_ text: String, to relative: String) throws -> URL {
        let target = url(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: target)
        return target
    }

    @discardableResult
    func write(_ data: Data, to relative: String) throws -> URL {
        let target = url(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: target)
        return target
    }

    /// 写一个可执行脚本夹具（真实子进程）。
    @discardableResult
    func writeScript(_ script: String, named relative: String) throws -> URL {
        let target = try write(script, to: relative)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

/// 子进程脚本夹具。
enum Fixtures {
    /// 回声服务器：每收到一行就按 id 回一行；另支持事件、慢响应、退出等模式。
    static let echoServer = """
    #!/bin/sh
    # 真实子进程夹具：JSON 行协议回声服务器。
    while IFS= read -r line; do
      case "$line" in
        *app.shutdown*)
          printf '{"id":0,"ok":true,"r":{"bye":true}}\\n'
          exit 0
          ;;
      esac
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      if [ -z "$id" ]; then
        echo "garbled line: $line" >&2
        exit 3
      fi
      case "$line" in
        *test.event*)
          printf '{"ev":"test","p":{"n":%s}}\\n' "$id"
          ;;
      esac
      case "$line" in
        *test.slow*)
          sleep 5
          ;;
      esac
      printf '{"id":%s,"ok":true,"r":{"echo":%s}}\\n' "$id" "$id"
    done
    """

    /// 哑服务器：只读不答（验证超时结算）。
    static let silentServer = """
    #!/bin/sh
    while IFS= read -r line; do
      :
    done
    """

    /// 立刻退出（验证 EOF 结算）。
    static let eofServer = """
    #!/bin/sh
    exit 0
    """

    /// 读一行后被信号杀掉（验证异常退出结算）。
    static let crashServer = """
    #!/bin/sh
    IFS= read -r line
    kill -9 $$
    """

    /// 读一行后退出（验证写入失败 / 断管道）。
    static let exitAfterFirstLine = """
    #!/bin/sh
    IFS= read -r line
    exit 0
    """

    /// **从不读 stdin** 的夹具：用于制造真实的管道背压（写端写满）。
    static let nonReadingServer = """
    #!/bin/sh
    sleep 30
    """
}

/// 跨进程夹具助手：一个极小的 C 程序（测试时用 clang 现场编译到 `.artifacts`）。
///
/// 用途：提供 **真实子进程** 的协作式 `flock` 持有者 / 竞争写者，
/// 以及一个用来探测「全局 SIGPIPE 处置」的探针。
///
/// 模式：
/// - `hold <lock>`：取排他锁 → 打印 `LOCKED` → 等 stdin 一行 → 放锁退出；
/// - `rename <lock> <src> <dst>`：取排他锁 → 原子替换 → 放锁 → 打印 `LOCKED` → 退出；
/// - `sigpipe`：往断管道写（默认处置下应当死于 SIGPIPE）。
enum LockHelper {
    static let source = """
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/file.h>
    #include <unistd.h>

    static int lock_file(const char *path) {
        int fd = open(path, O_RDWR | O_CREAT, 0600);
        if (fd < 0) return -1;
        if (flock(fd, LOCK_EX) != 0) { close(fd); return -1; }
        return fd;
    }

    int main(int argc, char **argv) {
        if (argc < 2) return 2;
        if (strcmp(argv[1], "sigpipe") == 0) {
            int fds[2];
            if (pipe(fds) != 0) return 3;
            close(fds[0]);
            const char *payload = "x";
            ssize_t ignored = write(fds[1], payload, 1);
            (void)ignored;
            /* 默认处置下走不到这里：写端会收到 SIGPIPE。 */
            return 0;
        }
        if (argc < 3) return 2;
        int fd = lock_file(argv[2]);
        if (fd < 0) return 3;
        if (strcmp(argv[1], "rename") == 0) {
            if (argc < 5) return 2;
            if (rename(argv[3], argv[4]) != 0) return 4;
            flock(fd, LOCK_UN);
            close(fd);
            printf("LOCKED\\n");
            fflush(stdout);
            return 0;
        }
        printf("LOCKED\\n");
        fflush(stdout);
        {
            char line[64];
            if (fgets(line, sizeof(line), stdin) == NULL) { /* EOF 即放行 */ }
        }
        flock(fd, LOCK_UN);
        close(fd);
        return 0;
    }
    """

    /// 编译并返回可执行文件路径（缓存于 `.artifacts`，源文件没变就不重编）。
    static func executable() throws -> URL {
        let directory = TestPaths.artifactsRoot.appendingPathComponent("lock-helper", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("lock_helper.c")
        let binaryURL = directory.appendingPathComponent("lock_helper")

        var needsBuild = !FileManager.default.fileExists(atPath: binaryURL.path)
        if !needsBuild {
            let sourceDate = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.modificationDate]) as? Date
            let binaryDate = (try? FileManager.default.attributesOfItem(atPath: binaryURL.path)[.modificationDate]) as? Date
            needsBuild = (sourceDate ?? Date.distantPast) > (binaryDate ?? Date.distantPast)
        }
        if needsBuild {
            try source.write(to: sourceURL, atomically: true, encoding: .utf8)
            let compiler = URL(fileURLWithPath: "/usr/bin/clang")
            guard FileManager.default.isExecutableFile(atPath: compiler.path) else {
                throw NSError(domain: "LockHelper", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "找不到 C 编译器（/usr/bin/clang），无法构建跨进程夹具"
                ])
            }
            let process = Process()
            process.executableURL = compiler
            process.arguments = ["-O0", "-o", binaryURL.path, sourceURL.path]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()
            try process.run()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "LockHelper", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "编译锁夹具失败：\(String(data: errorData, encoding: .utf8) ?? "")"
                ])
            }
        }
        return binaryURL
    }
}

/// 真实跨进程夹具：另一个 **进程** 持有协作式 `flock`（由 `LockHelper` 提供）。
///
/// - 父进程拿到句柄后可 **放行**（子进程释放锁并退出）；
/// - 子进程持锁期间，本进程的写入必须 **有界失败**（而不是互相穿插丢更新）；
/// - 竞争写者模式：子进程持锁期间把另一个文件原子替换到目标路径。
final class LockHolderProcess {
    private let process: Process
    private let stdinPipe: Pipe
    private var released = false

    private init(process: Process, stdinPipe: Pipe) {
        self.process = process
        self.stdinPipe = stdinPipe
    }

    /// 启动持锁子进程（持锁直到 `release()`）。
    static func start(lockPath: String, readyTimeout: TimeInterval = 5) throws -> LockHolderProcess {
        try start(arguments: ["hold", lockPath], readyTimeout: readyTimeout)
    }

    /// 启动「协作写者」子进程：持锁 → 原子替换目标文件 → 放锁 → 退出。
    static func startCompetingWriter(
        lockPath: String,
        sourcePath: String,
        targetPath: String,
        readyTimeout: TimeInterval = 5
    ) throws -> LockHolderProcess {
        try start(
            arguments: ["rename", lockPath, sourcePath, targetPath],
            readyTimeout: readyTimeout
        )
    }

    private static func start(arguments: [String], readyTimeout: TimeInterval) throws -> LockHolderProcess {
        let helper = try LockHelper.executable()
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe
        process.standardError = Pipe()
        try process.run()

        // 有界等待子进程确认（"LOCKED"）。
        let deadline = Date().addingTimeInterval(readyTimeout)
        var buffer = Data()
        let descriptor = stdoutPipe.fileHandleForReading.fileDescriptor
        var confirmed = false
        while Date() < deadline {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(0.01, deadline.timeIntervalSinceNow)
            let ready = poll(&pollDescriptor, 1, Int32(remaining * 1000))
            guard ready > 0 else { break }
            var chunk = [UInt8](repeating: 0, count: 256)
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])
            if let text = String(data: buffer, encoding: .utf8), text.contains("LOCKED") {
                confirmed = true
                break
            }
        }
        guard confirmed else {
            process.terminate()
            _ = LockHolderProcess.waitForExit(process: process, timeout: 2)
            throw NSError(domain: "LockHolderProcess", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "子进程未能在超时内持锁"
            ])
        }
        return LockHolderProcess(process: process, stdinPipe: stdinPipe)
    }

    /// 子进程 pid（测试用：确认是我们自己的那个子进程）。
    var processIdentifier: Int32 { process.processIdentifier }

    /// 放行：子进程释放锁并退出。
    func release() {
        guard !released else { return }
        released = true
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// 等待子进程退出（返回退出状态；超时返回 nil）。
    @discardableResult
    func waitForExit(timeout: TimeInterval = 5) -> Int32? {
        LockHolderProcess.waitForExit(process: process, timeout: timeout)
    }

    private static func waitForExit(process: Process, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                return process.terminationStatus
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }
}

/// 进程资源观测（fd / 线程计数）。
enum ProcessResources {
    /// 当前进程打开的 fd 数量（`/dev/fd`）。
    static func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// 当前进程的线程数（`proc_pidinfo`）。
    static func threadCount() -> Int {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let written = proc_pidinfo(getpid(), PROC_PIDTASKALLINFO, 0, &info, size)
        guard written == size else { return -1 }
        return Int(info.ptinfo.pti_threadnum)
    }
}

/// 测试辅助断言。
enum TestAssert {    static func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTFail(message, file: file, line: line)
    }

    /// 断言某个错误属于期望的类型。
    static func expectError<T: Error>(
        _ type: T.Type,
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("期望抛出 \(type) 但没有错误", file: file, line: line)
        } catch let error as T {
            _ = error
        } catch {
            XCTFail("期望 \(type) 实际是 \(error)", file: file, line: line)
        }
    }
}

/// 等待条件成立（**真实播放**用例专用）。
///
/// - **必须让出主 actor**（`await Task.sleep`），不能阻塞主线程去跑
///   `RunLoop.main.run(until:)`：那会让 **主队列** 停摆，而
///   AVFoundation 的「周期时间观察」与「播放到结尾」通知都投递在主队列上
///   → 收不到回调，播放器看起来「完全不动」，
///   `AVPlayerItem.status` 也停在 `.unknown`。
/// - 条件在 **主 actor** 上求值（播放器状态是主 actor 隔离的）。
@MainActor
func waitForPlayback(
    timeout: TimeInterval = 10,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
