import Foundation
import XCTest

@testable import AlgerKit

#if canImport(Darwin)
import Darwin
#endif

/// 进程环境变量的临时覆盖（测试用；结束后恢复原值）。
enum TestEnvironment {
    /// 设置环境变量，返回 **恢复函数**（调用后还原原值）。
    ///
    /// 用「设置 + 恢复函数」而不是闭包，避免 Swift 对多语句闭包
    /// 是否抛错的类型推断歧义（会同时产生「多余的 try」与「缺少 try」两类告警）。
    @discardableResult
    static func set(_ key: String, _ value: String?) -> () -> Void {
        let previous = getenv(key).map { String(cString: $0) }
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        return {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
    }
}

/// 生成真实可播放的 WAV 文件（16-bit PCM 单声道正弦波）。
enum TestAudio {
    /// 造一个 WAV 文件，返回其数据。
    static func wavData(seconds: Double = 1.0, sampleRate: Int = 8000, frequency: Double = 440) -> Data {
        let sampleCount = max(1, Int(Double(sampleRate) * seconds))
        var data = Data()
        let dataSize = sampleCount * 2

        func append32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)                      // fmt chunk 大小
        append16(1)                       // PCM
        append16(1)                       // 单声道
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2)) // 字节率
        append16(2)                       // 块对齐
        append16(16)                      // 位深
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))
        for index in 0..<sampleCount {
            let phase = 2 * Double.pi * frequency * Double(index) / Double(sampleRate)
            let sample = Int16(sin(phase) * 8000)
            append16(UInt16(bitPattern: sample))
        }
        return data
    }

    /// 写一个 WAV 文件到工作目录。
    @discardableResult
    static func writeWAV(to url: URL, seconds: Double = 1.0) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try wavData(seconds: seconds).write(to: url)
        return url
    }
}

/// 轮询等待条件成立（真实异步状态用）。
func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
