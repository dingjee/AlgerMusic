//! 桥接子进程生命周期测试：EOF 与 app.shutdown 都必须在短超时内退出，
//! 已接受的每个请求恰好一个结果（正常响应或 ShuttingDown 错误）。
//!
//! 隔离方式：显式 `--session-path` 指向 `.artifacts` 夹具（不 repurpose
//! HOME，不触真实 profile）；子进程由 RAII guard 保证失败也清理。

use std::io::Write;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const TIMEOUT: Duration = Duration::from_secs(15);

/// 夹具目录（.artifacts/fixtures/bridge-exit-<pid>/）。
fn fixture_dir() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../.artifacts/fixtures")
        .join(format!("bridge-exit-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// RAII 子进程守卫：即使断言失败也 kill + wait，不留探针进程。
struct ChildGuard {
    child: Option<Child>,
    label: &'static str,
}

/// 等待子进程退出：超时则 kill + wait（不留探针进程），返回退出状态。
fn wait_status(child: &mut Child, timeout: Duration, what: &str) -> std::process::ExitStatus {
    let start = Instant::now();
    loop {
        match child.try_wait().expect("try_wait") {
            Some(status) => return status,
            None => {
                if start.elapsed() >= timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    panic!("{}：子进程未在 {:?} 内退出", what, timeout);
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        }
    }
}

impl ChildGuard {
    fn wait_exit(&mut self, what: &str) -> std::process::ExitStatus {
        let child = self.child.as_mut().expect("child");
        let status = wait_status(child, TIMEOUT, what);
        assert!(status.success(), "{}：桥接应正常退出（0）", what);
        status
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            eprintln!("测试失败，清理桥接探针（{}）", self.label);
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// 启动桥接子进程：显式 --session-path 夹具隔离 + 可注入环境变量。
fn spawn_bridge(label: &'static str, extra_env: &[(&str, &str)]) -> ChildGuard {
    let dir = fixture_dir();
    let session = dir.join(label).join("session.json");
    std::fs::create_dir_all(session.parent().unwrap()).unwrap();
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_alger-bridge"));
    cmd.arg("--session-path").arg(&session);
    for (k, v) in extra_env {
        cmd.env(k, v);
    }
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    ChildGuard {
        child: Some(cmd.spawn().expect("spawn alger-bridge")),
        label,
    }
}

fn read_stdout_to_string(child: &mut Child) -> String {
    use std::io::Read;
    let mut out = String::new();
    child
        .stdout
        .take()
        .expect("stdout")
        .take(1 << 20)
        .read_to_string(&mut out)
        .unwrap();
    out
}

/// 统计某 id 在输出中出现的响应行数（每行一个 JSON）。
fn count_responses(out: &str, id: u64) -> usize {
    out.lines()
        .filter(|l| {
            serde_json::from_str::<serde_json::Value>(l)
                .map(|v| v.get("id").and_then(|i| i.as_u64()) == Some(id))
                .unwrap_or(false)
        })
        .count()
}

#[test]
fn exits_on_stdin_eof() {
    let mut guard = spawn_bridge("eof", &[]);
    // 立即关闭 stdin（EOF）
    drop(guard.child.as_mut().unwrap().stdin.take());
    guard.wait_exit("stdin EOF");
}

#[test]
fn exits_on_app_shutdown_without_losing_responses() {
    let mut guard = spawn_bridge("shutdown", &[]);
    // stdin 保持打开：shutdown 必须主动退出，而不是等 EOF。
    // 注意：此处 **不可** drop stdin——那会让本测试失去覆盖力。
    let stdin = guard.child.as_mut().unwrap().stdin.as_mut().expect("stdin");
    writeln!(stdin, r#"{{"id":1,"m":"app.hello","p":{{}}}}"#).unwrap();
    writeln!(stdin, r#"{{"id":2,"m":"app.shutdown","p":{{}}}}"#).unwrap();
    stdin.flush().unwrap();
    guard.wait_exit("app.shutdown（stdin 仍打开）");
    let out = read_stdout_to_string(guard.child.as_mut().unwrap());
    // 已接受请求的响应必须在退出前写出
    assert!(out.contains(r#""id":1"#), "app.hello 响应不得丢失：{}", out);
    assert!(
        out.contains(r#""bye":true"#),
        "shutdown 响应不得丢失：{}",
        out
    );
}

/// 慢请求在退出等待内完成：拿到正常响应，恰好一个结果。
#[test]
fn slow_request_completes_within_bounded_wait() {
    let mut guard = spawn_bridge(
        "slow-ok",
        &[
            ("ALGER_BRIDGE_TEST_HOOKS", "1"),
            ("ALGER_BRIDGE_EXIT_WAIT_MS", "8000"),
        ],
    );
    let stdin = guard.child.as_mut().unwrap().stdin.as_mut().expect("stdin");
    writeln!(stdin, r#"{{"id":10,"m":"test.slow","p":{{"ms":1500}}}}"#).unwrap();
    writeln!(stdin, r#"{{"id":11,"m":"app.shutdown","p":{{}}}}"#).unwrap();
    stdin.flush().unwrap();
    guard.wait_exit("慢请求在界内完成");
    let out = read_stdout_to_string(guard.child.as_mut().unwrap());
    assert_eq!(
        count_responses(&out, 10),
        1,
        "慢请求必须恰好一个结果：{}",
        out
    );
    assert!(
        out.contains(r#""slept":1500"#),
        "慢请求应拿到正常响应：{}",
        out
    );
    assert_eq!(
        count_responses(&out, 11),
        1,
        "shutdown 必须恰好一个结果：{}",
        out
    );
}

/// 慢请求超过退出上限：仍必须回一个 ShuttingDown 错误响应
/// （每个已接受 id 恰好一个结果，不允许丢响应）。
#[test]
fn slow_request_past_deadline_gets_shutting_down_response() {
    let mut guard = spawn_bridge(
        "slow-timeout",
        &[
            ("ALGER_BRIDGE_TEST_HOOKS", "1"),
            ("ALGER_BRIDGE_EXIT_WAIT_MS", "500"),
        ],
    );
    let stdin = guard.child.as_mut().unwrap().stdin.as_mut().expect("stdin");
    writeln!(stdin, r#"{{"id":20,"m":"test.slow","p":{{"ms":30000}}}}"#).unwrap();
    writeln!(stdin, r#"{{"id":21,"m":"app.shutdown","p":{{}}}}"#).unwrap();
    stdin.flush().unwrap();
    guard.wait_exit("慢请求超时取消");
    let out = read_stdout_to_string(guard.child.as_mut().unwrap());
    assert_eq!(
        count_responses(&out, 20),
        1,
        "超时取消也必须恰好一个结果：{}",
        out
    );
    assert!(
        out.contains(r#""code":"ShuttingDown""#),
        "超时未完成必须回 ShuttingDown：{}",
        out
    );
    assert_eq!(
        count_responses(&out, 21),
        1,
        "shutdown 必须恰好一个结果：{}",
        out
    );
}

/// shutdown 后仍排队未分发的请求：每个一个 ShuttingDown 结果。
#[test]
fn queued_requests_after_shutdown_get_shutting_down() {
    let mut guard = spawn_bridge(
        "queued-drain",
        &[
            ("ALGER_BRIDGE_TEST_HOOKS", "1"),
            ("ALGER_BRIDGE_EXIT_WAIT_MS", "8000"),
        ],
    );
    let stdin = guard.child.as_mut().unwrap().stdin.as_mut().expect("stdin");
    // 慢请求占住分发，后面紧跟 shutdown；再之后的请求可能已排队未分发
    writeln!(stdin, r#"{{"id":30,"m":"test.slow","p":{{"ms":800}}}}"#).unwrap();
    writeln!(stdin, r#"{{"id":31,"m":"app.shutdown","p":{{}}}}"#).unwrap();
    for id in 32..36 {
        writeln!(stdin, r#"{{"id":{},"m":"app.hello","p":{{}}}}"#, id).unwrap();
    }
    stdin.flush().unwrap();
    guard.wait_exit("shutdown 后排队请求");
    let out = read_stdout_to_string(guard.child.as_mut().unwrap());
    for id in 30..36 {
        assert_eq!(
            count_responses(&out, id),
            1,
            "id={} 必须恰好一个结果：{}",
            id,
            out
        );
    }
}

/// 夹具隔离验证：进程只在 .artifacts 夹具下落会话文件，不触 HOME。
#[test]
fn session_fixture_is_used() {
    let mut guard = spawn_bridge("fixture-check", &[]);
    // 无请求：直接 EOF 触发退出
    drop(guard.child.as_mut().unwrap().stdin.take());
    guard.wait_exit("夹具会话");
    let session = fixture_dir().join("fixture-check").join("session.json");
    assert!(
        session.exists(),
        "会话文件必须落在 --session-path 夹具：{}",
        session.display()
    );
}

/// E0-3：`--session-path` 缺参必须 **明确失败**（非 0 退出 + stderr 说明），
/// 绝不回落默认会话文件（那会读写用户真实 profile）。
#[test]
fn missing_session_path_argument_fails_closed() {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_alger-bridge"));
    cmd.arg("--session-path"); // 故意不给值
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().expect("spawn alger-bridge");
    let status = wait_status(&mut child, TIMEOUT, "--session-path 缺参");
    assert!(!status.success(), "缺参必须以非 0 退出，实际 {:?}", status);
    let mut err = String::new();
    {
        use std::io::Read;
        let _ = child.stderr.take().unwrap().read_to_string(&mut err);
    }
    assert!(
        err.contains("--session-path"),
        "stderr 必须说明失败原因：{}",
        err
    );
}

/// E0-3：`--session-path=`（空值）、相对路径与未知参数同样必须失败
/// （参数名写错若被静默忽略，就会悄悄回落到默认会话文件）。
#[test]
fn malformed_session_path_argument_fails_closed() {
    for arg in ["--session-path=", "--session-path", "relative/session.json"] {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_alger-bridge"));
        cmd.arg(arg);
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = cmd.spawn().expect("spawn alger-bridge");
        let status = wait_status(&mut child, TIMEOUT, arg);
        assert!(
            !status.success(),
            "{} 必须以非 0 退出，实际 {:?}",
            arg,
            status
        );
        let _ = child.wait();
    }
}

/// E1-3：**真实在途 HTTP 下载** + app.shutdown —— 桥接必须限时退出，
/// 且下载被收束为可恢复状态（queued + targets 保留 + 无 .part 残留）。
///
/// 慢分发器只测分发，不能替代真实下载：这里真的起一个只发响应头、
/// 永不发送 body 的本地 HTTP 服务器。
#[test]
fn in_flight_download_is_paused_and_bridge_exits() {
    // 服务器：发头（声明 4 字节）后永不发送 body
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        use std::io::{Read, Write};
        for stream in listener.incoming() {
            let mut s = stream.unwrap();
            let mut buf = [0u8; 1024];
            let _ = s.read(&mut buf);
            let head = "HTTP/1.1 200 OK\r\ncontent-type: audio/mpeg\r\ncontent-length: 4\r\nconnection: close\r\n\r\n";
            let _ = s.write_all(head.as_bytes());
            std::thread::sleep(Duration::from_secs(30));
        }
    });

    let mut guard = spawn_bridge(
        "dl-shutdown",
        &[
            ("ALGER_BRIDGE_TEST_HOOKS", "1"),
            ("ALGER_BRIDGE_EXIT_WAIT_MS", "3000"),
        ],
    );
    let dl_dir = fixture_dir().join("dl-shutdown-dl");
    std::fs::create_dir_all(&dl_dir).unwrap();
    let queue_file = fixture_dir()
        .join("dl-shutdown")
        .join("bridge")
        .join("downloads.json");

    let stdin = guard.child.as_mut().unwrap().stdin.as_mut().expect("stdin");
    writeln!(
        stdin,
        r#"{{"id":1,"m":"test.dlEnqueue","p":{{"id":77,"url":"http://127.0.0.1:{}/a.mp3","dir":"{}","targets":["pl-x"]}}}}"#,
        port,
        dl_dir.display()
    )
    .unwrap();
    stdin.flush().unwrap();

    // 等到下载真的在途（队列记录为 running）
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut running = false;
    while Instant::now() < deadline {
        if let Ok(raw) = std::fs::read(&queue_file) {
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&raw) {
                if v["tasks"]
                    .as_array()
                    .map(|t| {
                        t.iter()
                            .any(|task| task["status"].as_str() == Some("running"))
                    })
                    .unwrap_or(false)
                {
                    running = true;
                    break;
                }
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(running, "下载必须真的进入 running（在途）");

    let stdin = guard.child.as_mut().unwrap().stdin.as_mut().expect("stdin");
    writeln!(stdin, r#"{{"id":2,"m":"app.shutdown","p":{{}}}}"#).unwrap();
    stdin.flush().unwrap();
    guard.wait_exit("在途下载时 shutdown");

    // 下载必须被收束为可恢复状态：queued + targets 保留
    let raw = std::fs::read(&queue_file).expect("队列文件必须存在");
    let v: serde_json::Value = serde_json::from_slice(&raw).unwrap();
    let task = &v["tasks"][0];
    assert_eq!(
        task["status"].as_str(),
        Some("queued"),
        "在途下载必须被暂停为 queued：{}",
        raw.len()
    );
    assert_eq!(
        task["targets"][0].as_str(),
        Some("pl-x"),
        "targets 必须保留：{}",
        String::from_utf8_lossy(&raw)
    );
    // 临时文件必须清理
    let parts: Vec<_> = std::fs::read_dir(&dl_dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().ends_with(".part"))
        .collect();
    assert!(parts.is_empty(), "退出后不得残留 .part：{:?}", parts);
}

/// E0-8（桥接层验收）：真实 `dl.retry` 路由必须 **先做本地 intent 恢复** ——
/// 文件已落位且内容摘要一致时，即使离线 / 音源解析不可用也能就地完成，
/// 不得先去解析新地址（解析失败就永远恢复不了）。
///
/// 夹具流程：
/// 1. 桥接 A：用本地 HTTP 服务器真实下载完成（拿到 path + 大小 + 摘要）；
/// 2. 退出桥接 A，把 downloads.json 里的状态改回 `running`
///    （模拟「done 落盘失败」的持久状态）；
/// 3. 桥接 B（同 --session-path）：调用 **真实 dl.retry** → 必须本地恢复；
/// 4. 断言：状态回到 done、path 不变、本地服务器 **零新增请求**、响应很快。
#[test]
fn dl_retry_recovers_locally_without_resolving_a_new_url() {
    // 本地服务器：返回固定内容并统计命中次数
    let body: &'static [u8] = b"local-retry-audio-bytes";
    let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    {
        let hits = std::sync::Arc::clone(&hits);
        std::thread::spawn(move || {
            use std::io::{Read, Write};
            for stream in listener.incoming() {
                let mut s = stream.unwrap();
                let mut buf = [0u8; 1024];
                let _ = s.read(&mut buf);
                hits.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let head = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: audio/mpeg\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                    body.len()
                );
                let _ = s.write_all(head.as_bytes());
                let _ = s.write_all(body);
            }
        });
    }

    let label = "dl-retry-local";
    let session_dir = fixture_dir().join(label);
    let queue_file = session_dir.join("bridge").join("downloads.json");
    let dl_dir = fixture_dir().join("dl-retry-local-dl");
    std::fs::create_dir_all(&dl_dir).unwrap();
    let session = session_dir.join("session.json");
    std::fs::create_dir_all(session.parent().unwrap()).unwrap();

    // ---- 1) 桥接 A：真实下载完成 ----
    {
        let mut guard = spawn_bridge(label, &[("ALGER_BRIDGE_TEST_HOOKS", "1")]);
        let stdin = guard.child.as_mut().unwrap().stdin.as_mut().expect("stdin");
        writeln!(
            stdin,
            r#"{{"id":1,"m":"test.dlEnqueue","p":{{"id":91,"url":"http://127.0.0.1:{}/a.mp3","dir":"{}","targets":["pl-x"]}}}}"#,
            port,
            dl_dir.display()
        )
        .unwrap();
        stdin.flush().unwrap();

        // 等到任务真的完成
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut done_path = String::new();
        while Instant::now() < deadline {
            if let Ok(raw) = std::fs::read(&queue_file) {
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&raw) {
                    if let Some(task) = v["tasks"].as_array().and_then(|t| t.first()) {
                        if task["status"].as_str() == Some("done") {
                            done_path = task["path"].as_str().unwrap_or_default().to_string();
                            break;
                        }
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(!done_path.is_empty(), "第一次下载必须完成");
        assert_eq!(
            hits.load(std::sync::atomic::Ordering::SeqCst),
            1,
            "第一次下载只应命中一次"
        );

        // 退出桥接 A
        let stdin = guard.child.as_mut().unwrap().stdin.as_mut().expect("stdin");
        writeln!(stdin, r#"{{"id":2,"m":"app.shutdown","p":{{}}}}"#).unwrap();
        stdin.flush().unwrap();
        guard.wait_exit("桥接 A 退出");
    }

    // ---- 2) 模拟「done 落盘失败」：状态改回 running（path / 大小 / 摘要保留）----
    let raw = std::fs::read(&queue_file).expect("队列文件必须存在");
    let mut v: serde_json::Value = serde_json::from_slice(&raw).unwrap();
    v["tasks"][0]["status"] = serde_json::json!("running");
    v["tasks"][0]["error"] = serde_json::json!("应用退出，下载已暂停，可重试");
    std::fs::write(&queue_file, serde_json::to_string_pretty(&v).unwrap()).unwrap();
    let path_before = v["tasks"][0]["path"].as_str().unwrap().to_string();
    let digest_before = v["tasks"][0]["digest"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(!digest_before.is_empty(), "完成记录必须带内容摘要");

    // ---- 3) 桥接 B：真实 dl.retry → 必须本地恢复（不解析新地址）----
    let mut guard = spawn_bridge(label, &[("ALGER_BRIDGE_TEST_HOOKS", "1")]);
    let stdin = guard.child.as_mut().unwrap().stdin.as_mut().expect("stdin");
    let started = Instant::now();
    writeln!(stdin, r#"{{"id":3,"m":"dl.retry","p":{{"id":91}}}}"#).unwrap();
    stdin.flush().unwrap();

    let out = read_stdout_until(&mut guard, "recovered", Duration::from_secs(15));
    let elapsed = started.elapsed();
    assert!(
        elapsed < Duration::from_secs(8),
        "本地恢复必须很快（不得先去解析新地址）：{:?}\n输出：{}",
        elapsed,
        out
    );
    assert!(
        out.contains(r#""recovered":true"#),
        "dl.retry 必须走本地恢复：{}",
        out
    );
    assert!(
        !out.contains(r#""recovered":false"#),
        "本地恢复不得回落到解析路径：{}",
        out
    );

    // ---- 4) 断言：状态回到 done、path 不变、无新增请求 ----
    let raw = std::fs::read(&queue_file).unwrap();
    let v: serde_json::Value = serde_json::from_slice(&raw).unwrap();
    assert_eq!(
        v["tasks"][0]["status"].as_str(),
        Some("done"),
        "本地恢复后状态必须是 done：{}",
        String::from_utf8_lossy(&raw)
    );
    assert_eq!(
        v["tasks"][0]["path"].as_str(),
        Some(path_before.as_str()),
        "path 必须原样保留"
    );
    assert_eq!(
        v["tasks"][0]["targets"][0].as_str(),
        Some("pl-x"),
        "targets 必须保留"
    );
    assert_eq!(
        hits.load(std::sync::atomic::Ordering::SeqCst),
        1,
        "本地恢复不得重新下载（零新增 HTTP 请求）"
    );

    let stdin = guard.child.as_mut().unwrap().stdin.as_mut().expect("stdin");
    writeln!(stdin, r#"{{"id":4,"m":"app.shutdown","p":{{}}}}"#).unwrap();
    stdin.flush().unwrap();
    guard.wait_exit("桥接 B 退出");
}

/// 读取 stdout 直到出现包含 `needle` 的行（或超时）。
fn read_stdout_until(guard: &mut ChildGuard, needle: &str, timeout: Duration) -> String {
    use std::io::Read;
    let stdout = guard.child.as_mut().unwrap().stdout.take().expect("stdout");
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        let mut buf = String::new();
        let mut stdout = stdout;
        let mut chunk = [0u8; 4096];
        loop {
            match stdout.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    buf.push_str(&String::from_utf8_lossy(&chunk[..n]));
                    let _ = tx.send(buf.clone());
                }
            }
        }
    });
    let deadline = Instant::now() + timeout;
    let mut last = String::new();
    while Instant::now() < deadline {
        if let Ok(text) = rx.recv_timeout(Duration::from_millis(200)) {
            last = text;
            if last.contains(needle) {
                return last;
            }
        }
    }
    last
}
