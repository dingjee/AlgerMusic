//! 网络歌单 **完全只读** 回归：桥接 dispatch 不得再有任何写 handler。
//!
//! 网络歌单写能力已整体移除（创建 / 改名 / 描述 / 增删曲 / 删除 /
//! 歌单重排 / 曲目重排）。本测试对每个已删除的写方法发真实协议请求，
//! 断言：
//! 1. 每个请求恰好得到一个响应（协议完整性）；
//! 2. 响应都是 `Unsupported`（未知方法）——证明 handler 确实不在
//!    dispatch 里，而不是执行失败；
//! 3. 未登录的只读方法（net.account）仍被 dispatch 识别（返回
//!    NeedLogin 业务错误，而非 Unsupported）——读路径没有随写能力
//!    一起被删。
//!
//! 隔离方式与 exit.rs 一致：显式 `--session-path` 指向 `.artifacts`
//! 夹具（空会话 = 未登录），**绝不触碰真实账号**；未知方法在
//! dispatch 层就被拒绝，不会发出任何上游请求（无真实写操作）。

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

/// 已删除的网络歌单写方法（曾经存在，现在必须不存在）。
const REMOVED_WRITE_METHODS: &[&str] = &[
    "net.createPlaylist",
    "net.updatePlaylist",
    "net.addTracks",
    "net.removeTracks",
    "net.deletePlaylist",
    "net.reorderPlaylistTracks",
    "net.reorderPlaylists",
];

/// 夹具目录（.artifacts/fixtures/bridge-readonly-<pid>/）。
fn fixture_dir() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../.artifacts/fixtures")
        .join(format!("bridge-readonly-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// RAII 子进程守卫：即使断言失败也 kill + wait，不留探针进程。
struct ChildGuard {
    child: Option<Child>,
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// 启动桥接子进程：显式 --session-path 夹具隔离（空会话 = 未登录）。
fn spawn_bridge(label: &str) -> ChildGuard {
    let session = fixture_dir().join(label).join("session.json");
    std::fs::create_dir_all(session.parent().unwrap()).unwrap();
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_alger-bridge"));
    cmd.arg("--session-path").arg(&session);
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    ChildGuard {
        child: Some(cmd.spawn().expect("spawn alger-bridge")),
    }
}

fn send(stdin: &mut std::process::ChildStdin, id: u64, method: &str, params: &str) {
    writeln!(stdin, r#"{{"id":{},"m":"{}","p":{}}}"#, id, method, params).unwrap();
    stdin.flush().unwrap();
}

/// 读取桥接全部 stdout（shutdown 后流会关闭），解析为 JSON 行。
fn read_all(child: &mut Child) -> Vec<serde_json::Value> {
    let mut out = String::new();
    child
        .stdout
        .take()
        .expect("stdout")
        .take(1 << 20)
        .read_to_string(&mut out)
        .expect("read bridge stdout");
    out.lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

fn response_for<'a>(lines: &'a [serde_json::Value], id: u64, what: &str) -> &'a serde_json::Value {
    let mut hits = lines
        .iter()
        .filter(|v| v.get("id").and_then(|i| i.as_u64()) == Some(id));
    let v = hits
        .next()
        .unwrap_or_else(|| panic!("{}：缺少 id={} 的响应", what, id));
    assert!(
        hits.next().is_none(),
        "{}：id={} 必须恰好一个响应",
        what,
        id
    );
    v
}

/// 每个已删除的写方法都必须回「未知方法」错误，且恰好一个响应。
#[test]
fn write_methods_are_unknown_to_dispatch() {
    let mut guard = spawn_bridge("writes");
    let child = guard.child.as_mut().unwrap();
    let mut stdin = child.stdin.take().expect("stdin");

    // 一次性发出全部 7 个写方法请求（id 1..=7），再 shutdown 收尾
    for (i, m) in REMOVED_WRITE_METHODS.iter().enumerate() {
        let params = match *m {
            "net.addTracks" | "net.removeTracks" => {
                r#"{"playlistId":123,"songIds":[1,2]}"#.to_string()
            }
            "net.reorderPlaylistTracks" => r#"{"id":123,"ids":[1,2]}"#.to_string(),
            "net.reorderPlaylists" => r#"{"ids":[1,2]}"#.to_string(),
            "net.createPlaylist" => r#"{"name":"回归测试（绝不应创建）"}"#.to_string(),
            "net.updatePlaylist" => r#"{"id":123,"name":"x"}"#.to_string(),
            _ => r#"{"id":123}"#.to_string(),
        };
        send(&mut stdin, (i + 1) as u64, m, &params);
    }
    send(&mut stdin, 99, "app.shutdown", "{}");
    drop(stdin);

    let lines = read_all(child);
    assert!(
        lines
            .iter()
            .any(|v| v.get("id").and_then(|i| i.as_u64()) == Some(99)
                && v["r"]["bye"] == serde_json::json!(true)),
        "shutdown 响应不得丢失：{:?}",
        lines
    );

    for (i, m) in REMOVED_WRITE_METHODS.iter().enumerate() {
        let id = (i + 1) as u64;
        let v = response_for(&lines, id, m);
        assert_eq!(
            v["ok"].as_bool(),
            Some(false),
            "写方法 {} 必须失败（不得执行）",
            m
        );
        assert_eq!(
            v["e"]["code"].as_str(),
            Some("Unsupported"),
            "写方法 {} 必须是「未知方法」（handler 已删），实际：{}",
            m,
            v
        );
        let msg = v["e"]["message"].as_str().unwrap_or_default();
        assert!(
            !msg.contains("done") && !msg.contains("success"),
            "写方法 {} 的错误不得伪装执行成功：{}",
            m,
            msg
        );
    }
}

/// 只读方法仍然被 dispatch 识别：未登录的 net.account 返回 NeedLogin
/// （业务错误，而非 Unsupported）。
#[test]
fn read_methods_still_routed() {
    let mut guard = spawn_bridge("reads");
    let child = guard.child.as_mut().unwrap();
    let mut stdin = child.stdin.take().expect("stdin");
    send(&mut stdin, 1, "net.account", "{}");
    send(&mut stdin, 2, "app.shutdown", "{}");
    drop(stdin);

    let lines = read_all(child);
    let v = response_for(&lines, 1, "net.account");
    assert_eq!(
        v["ok"].as_bool(),
        Some(false),
        "空会话下 net.account 应失败（未登录）：{}",
        v
    );
    let code = v["e"]["code"].as_str().unwrap_or_default();
    assert_ne!(
        code, "Unsupported",
        "net.account 仍应被 dispatch 识别（不得随写能力一起被删）"
    );
}
