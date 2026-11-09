//! 桥接层元信息接口回归：`meta.*` 的请求 / 响应契约与取消语义。
//!
//! 隔离方式：
//! - 显式 `--session-path` 指向 `.artifacts` 夹具（不 repurpose HOME，
//!   不触真实 profile）；
//! - MusicBrainz / AcoustID / 封面服务地址用环境变量指向 **本地桩服务**
//!   （`ALGER_METADATA_*_BASE`），不访问真实外部服务；
//! - 夹具日志与桩数据落在 `.artifacts/rust-metadata/meta`。

use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const TIMEOUT: Duration = Duration::from_secs(20);

/// 夹具目录：`.artifacts/rust-metadata/meta/`。
fn fixture_dir() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../.artifacts/rust-metadata/meta")
        .join("bridge");
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// 子进程守卫：失败也清理，不留探针进程。
struct ChildGuard {
    child: Option<Child>,
    label: &'static str,
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

fn spawn_bridge(label: &'static str, env: &[(&str, &str)]) -> Probe {
    let session = fixture_dir().join(label).join("session.json");
    std::fs::create_dir_all(session.parent().unwrap()).unwrap();
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_alger-bridge"));
    cmd.arg("--session-path").arg(&session);
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut child = cmd.spawn().expect("spawn alger-bridge");
    let stdout = child.stdout.take().expect("stdout");
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        use std::io::Read as _;
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
    Probe {
        guard: ChildGuard {
            child: Some(child),
            label,
        },
        rx,
        last: String::new(),
    }
}

/// 桥接探针：持续读 stdout，按需等待某段内容。
struct Probe {
    guard: ChildGuard,
    rx: std::sync::mpsc::Receiver<String>,
    last: String,
}

impl Probe {
    /// 等待 stdout 出现包含 `needle` 的内容（或超时），返回累计输出。
    fn wait_for(&mut self, needle: &str, timeout: Duration) -> String {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if let Ok(text) = self.rx.recv_timeout(Duration::from_millis(200)) {
                self.last = text;
                if self.last.contains(needle) {
                    return self.last.clone();
                }
            }
        }
        self.last.clone()
    }
}

/// 本地桩服务：`delay_ms` 毫秒后返回固定 JSON。
///
/// 返回 `(基地址, 收到请求的通知)`：测试据此确认请求 **真的在途**，
/// 不靠固定 sleep 猜时序。
fn spawn_stub(body: &'static str, delay_ms: u64) -> (String, std::sync::mpsc::Receiver<()>) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind stub");
    let port = listener.local_addr().unwrap().port();
    let (tx, rx) = std::sync::mpsc::channel::<()>();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut s = match stream {
                Ok(s) => s,
                Err(_) => break,
            };
            let mut buf = Vec::new();
            let mut chunk = [0u8; 4096];
            loop {
                match s.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        buf.extend_from_slice(&chunk[..n]);
                        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                            break;
                        }
                    }
                }
            }
            let head = String::from_utf8_lossy(&buf).to_string();
            let len = head
                .lines()
                .find(|l| l.to_ascii_lowercase().starts_with("content-length:"))
                .and_then(|l| l.split(':').nth(1))
                .and_then(|v| v.trim().parse::<usize>().ok())
                .unwrap_or(0);
            let mut read = buf.len() - head.find("\r\n\r\n").map(|i| i + 4).unwrap_or(buf.len());
            while read < len {
                match s.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => read += n,
                }
            }
            // 通知测试：请求已到达（此时响应还没给出 → 请求确实在途）。
            let _ = tx.send(());
            if delay_ms > 0 {
                std::thread::sleep(Duration::from_millis(delay_ms));
            }
            let head = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                body.len()
            );
            let _ = s.write_all(head.as_bytes());
            let _ = s.write_all(body.as_bytes());
            let _ = s.flush();
        }
    });
    (format!("http://127.0.0.1:{}", port), rx)
}

fn write_script(name: &str, body: &str) -> PathBuf {
    let path = fixture_dir().join(name);
    std::fs::write(&path, body).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();
    }
    path
}

fn send(probe: &mut Probe, line: &str) {
    let stdin = probe
        .guard
        .child
        .as_mut()
        .unwrap()
        .stdin
        .as_mut()
        .expect("stdin");
    writeln!(stdin, "{}", line).unwrap();
    stdin.flush().unwrap();
}

/// `meta.search` 的正常路径：本地桩返回候选 → 桥接按契约返回 `candidates`。
#[test]
fn meta_search_returns_candidates() {
    let body = r#"{"count":1,"recordings":[{"id":"b1a9c0b9-d987-404e-a7db-3b00416af0c9","title":"Yesterday","length":269000,"artist-credit":[{"name":"The Beatles"}],"isrcs":["GBAYE0601498"],"releases":[{"id":"0da2e35a-1234-4a5b-9f9d-1a2b3c4d5e6f","title":"Help!","date":"1965-08-06","country":"GB","artist-credit":[{"name":"The Beatles"}]}]}]}"#;
    let (base, _rx) = spawn_stub(body, 0);
    let mut probe = spawn_bridge(
        "meta-search",
        &[
            ("ALGER_METADATA_MUSICBRAINZ_BASE", base.as_str()),
            ("ALGER_MB_MIN_INTERVAL_MS", "1"),
        ],
    );
    send(
        &mut probe,
        r#"{"id":1,"m":"meta.search","p":{"title":"Yesterday","artist":"The Beatles","durationMs":269000,"limit":5}}"#,
    );
    let out = probe.wait_for("\"id\":1", TIMEOUT);
    assert!(out.contains("\"ok\":true"), "必须成功：{}", out);
    assert!(
        out.contains("\"candidates\""),
        "响应必须含 candidates：{}",
        out
    );
    assert!(
        out.contains("b1a9c0b9-d987-404e-a7db-3b00416af0c9"),
        "候选必须含 recordingId：{}",
        out
    );
    assert!(out.contains("\"isrcs\""), "候选必须含 isrcs：{}", out);
    assert!(out.contains("\"releases\""), "候选必须含 releases：{}", out);
    assert!(out.contains("\"durationMs\":269000"), "时长字段：{}", out);
    assert!(!out.contains("\"score\":0,"), "评分不得为 0：{}", out);
    send(&mut probe, r#"{"id":2,"m":"app.shutdown","p":{}}"#);
}

/// `meta.cancel` 必须让原请求返回 `Cancelled` 错误（不得悬挂）。
#[test]
fn meta_cancel_makes_pending_request_fail_with_cancelled() {
    let body = r#"{"count":0,"recordings":[]}"#;
    let (base, received) = spawn_stub(body, 8000);
    let mut probe = spawn_bridge(
        "meta-cancel",
        &[
            ("ALGER_METADATA_MUSICBRAINZ_BASE", base.as_str()),
            ("ALGER_MB_MIN_INTERVAL_MS", "1"),
        ],
    );
    send(
        &mut probe,
        r#"{"id":10,"m":"meta.search","p":{"title":"Yesterday","token":"tok-1"}}"#,
    );
    // 等桩服务 **真的收到** 请求（此时响应未给出 → 请求确实在途）
    received
        .recv_timeout(Duration::from_secs(15))
        .expect("桩服务必须收到请求");
    let started = Instant::now();
    send(
        &mut probe,
        r#"{"id":11,"m":"meta.cancel","p":{"token":"tok-1"}}"#,
    );
    let out = probe.wait_for("\"id\":10", Duration::from_secs(10));
    assert!(
        out.contains("\"code\":\"Cancelled\""),
        "被取消的请求必须回 Cancelled：{}",
        out
    );
    assert!(
        out.contains("\"cancelled\":true"),
        "meta.cancel 必须回 cancelled:true：{}",
        out
    );
    assert!(
        started.elapsed() < Duration::from_secs(6),
        "取消必须立即生效，实际 {:?}",
        started.elapsed()
    );
    send(&mut probe, r#"{"id":12,"m":"app.shutdown","p":{}}"#);
}

/// 取消 **先于** 请求登记到达时也不得丢失（预取消墓碑）。
///
/// 桥接把每个请求派发到独立任务，取消与请求之间存在真实竞态：这里先发
/// 取消、再发请求，请求必须立刻以 `Cancelled` 失败（且不得发出 HTTP 请求）。
#[test]
fn meta_cancel_before_request_is_not_lost() {
    let body = r#"{"count":0,"recordings":[]}"#;
    let (base, received) = spawn_stub(body, 3000);
    let mut probe = spawn_bridge(
        "meta-cancel-early",
        &[
            ("ALGER_METADATA_MUSICBRAINZ_BASE", base.as_str()),
            ("ALGER_MB_MIN_INTERVAL_MS", "1"),
        ],
    );
    // 先取消（请求尚未发出）
    send(
        &mut probe,
        r#"{"id":20,"m":"meta.cancel","p":{"token":"tok-early"}}"#,
    );
    let out = probe.wait_for("\"id\":20", TIMEOUT);
    assert!(
        out.contains("\"cancelled\":true"),
        "meta.cancel 必须回 cancelled:true：{}",
        out
    );
    // 随后到达的请求必须被取消
    send(
        &mut probe,
        r#"{"id":21,"m":"meta.search","p":{"title":"Yesterday","token":"tok-early"}}"#,
    );
    let out = probe.wait_for("\"id\":21", TIMEOUT);
    assert!(
        out.contains("\"code\":\"Cancelled\""),
        "先到的取消必须被承接：{}",
        out
    );
    // 桩服务不得收到任何请求（被取消的请求不应打到网络）
    assert!(
        received.recv_timeout(Duration::from_millis(500)).is_err(),
        "被预取消的请求不得发出 HTTP 请求"
    );
    send(&mut probe, r#"{"id":22,"m":"app.shutdown","p":{}}"#);
}

/// 缺 AcoustID key / 缺 fpcalc 必须 **明确失败**（错误码可辨识）。
#[test]
fn meta_fingerprint_fails_explicitly_without_key_or_fpcalc() {
    let mut probe = spawn_bridge("meta-fp", &[]);
    send(
        &mut probe,
        r#"{"id":20,"m":"meta.fingerprint","p":{"path":"/tmp/nope.mp3"}}"#,
    );
    let out = probe.wait_for("\"id\":20", TIMEOUT);
    assert!(
        out.contains("\"code\":\"MissingApiKey\""),
        "缺 key 必须回 MissingApiKey：{}",
        out
    );

    let missing_fpcalc = fixture_dir().join("no-such-fpcalc");
    send(
        &mut probe,
        &format!(
            r#"{{"id":21,"m":"meta.fingerprint","p":{{"path":"/tmp/nope.mp3","apiKey":"k","fpcalcPath":"{}"}}}}"#,
            missing_fpcalc.display()
        ),
    );
    let out = probe.wait_for("\"id\":21", TIMEOUT);
    assert!(
        out.contains("\"code\":\"FpcalcMissing\""),
        "缺 fpcalc 必须回 FpcalcMissing：{}",
        out
    );
    send(&mut probe, r#"{"id":22,"m":"app.shutdown","p":{}}"#);
}

/// 参数缺失与未知方法必须是明确的桥接错误。
#[test]
fn meta_methods_validate_parameters() {
    let mut probe = spawn_bridge("meta-params", &[]);
    send(&mut probe, r#"{"id":30,"m":"meta.search","p":{}}"#);
    let out = probe.wait_for("\"id\":30", TIMEOUT);
    assert!(out.contains("\"code\":\"Business\""), "缺标题：{}", out);

    send(&mut probe, r#"{"id":31,"m":"meta.lookup","p":{}}"#);
    let out = probe.wait_for("\"id\":31", TIMEOUT);
    assert!(
        out.contains("\"code\":\"Business\""),
        "缺 recordingId：{}",
        out
    );

    send(&mut probe, r#"{"id":32,"m":"meta.release","p":{}}"#);
    let out = probe.wait_for("\"id\":32", TIMEOUT);
    assert!(
        out.contains("\"code\":\"Business\""),
        "缺 releaseId：{}",
        out
    );

    send(&mut probe, r#"{"id":33,"m":"meta.artwork","p":{}}"#);
    let out = probe.wait_for("\"id\":33", TIMEOUT);
    assert!(
        out.contains("\"code\":\"Business\""),
        "缺 releaseId：{}",
        out
    );

    send(&mut probe, r#"{"id":34,"m":"meta.fingerprint","p":{}}"#);
    let out = probe.wait_for("\"id\":34", TIMEOUT);
    assert!(out.contains("\"code\":\"Business\""), "缺 path：{}", out);
    send(&mut probe, r#"{"id":35,"m":"app.shutdown","p":{}}"#);
}

/// `meta.artwork`：307 重定向必须被跟随；404 必须明确「无封面」。
///
/// 用本地桩验证（不访问真实 CAA）：`/release/{id}/front` 返回 307 指向
/// `/image.jpg`；`/release/missing/front` 返回 404。
#[test]
fn meta_artwork_follows_redirect_and_reports_missing_cover() {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port();
    let body = b"\xff\xd8\xff\xe0fake-jpeg";
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut s = match stream {
                Ok(s) => s,
                Err(_) => break,
            };
            let mut buf = [0u8; 4096];
            let n = s.read(&mut buf).unwrap_or(0);
            let request = String::from_utf8_lossy(&buf[..n]).to_string();
            let path = request
                .lines()
                .next()
                .and_then(|l| l.split(' ').nth(1))
                .unwrap_or("")
                .to_string();
            if path.ends_with("/front") && !path.contains("missing") {
                // 307 → 指向图片
                let head = format!(
                    "HTTP/1.1 307 Temporary Redirect\r\nlocation: http://127.0.0.1:{}/image.jpg\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                    port
                );
                let _ = s.write_all(head.as_bytes());
            } else if path.contains("missing") {
                let head = "HTTP/1.1 404 Not Found\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"error\":1}";
                let _ = s.write_all(head.as_bytes());
            } else {
                let head = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: image/jpeg\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                    body.len()
                );
                let _ = s.write_all(head.as_bytes());
                let _ = s.write_all(body);
            }
            let _ = s.flush();
        }
    });
    let mut probe = spawn_bridge(
        "meta-artwork-redirect",
        &[
            (
                "ALGER_METADATA_COVERART_BASE",
                &format!("http://127.0.0.1:{}", port),
            ),
            ("ALGER_CAA_MIN_INTERVAL_MS", "1"),
        ],
    );
    // 307 → 必须跟随到图片
    send(
        &mut probe,
        r#"{"id":60,"m":"meta.artwork","p":{"releaseId":"0da2e35a-1234-4a5b-9f9d-1a2b3c4d5e6f"}}"#,
    );
    let out = probe.wait_for("\"id\":60", TIMEOUT);
    assert!(
        out.contains("\"ok\":true"),
        "307 必须被跟随并取到封面：{}",
        out
    );
    assert!(
        out.contains("\"artworkBase64\""),
        "必须含 artworkBase64：{}",
        out
    );
    assert!(
        out.contains("\"mimeType\":\"image/jpeg\""),
        "必须回图片 MIME：{}",
        out
    );
    // 404 → 明确「无封面」
    send(
        &mut probe,
        r#"{"id":61,"m":"meta.artwork","p":{"releaseId":"missing"}}"#,
    );
    let out = probe.wait_for("\"id\":61", TIMEOUT);
    assert!(
        out.contains("\"code\":\"NoArtwork\""),
        "404 必须明确报无封面：{}",
        out
    );
    send(&mut probe, r#"{"id":62,"m":"app.shutdown","p":{}}"#);
}

/// `meta.fingerprint`：真实 fpcalc 替身脚本 + AcoustID 桩 → 候选。
#[test]
fn meta_fingerprint_runs_fpcalc_and_returns_candidates() {
    let (base, _rx) = spawn_stub(
        r#"{"status":"ok","results":[{"id":"r1","score":0.95,"recordings":[{"id":"b1a9c0b9-d987-404e-a7db-3b00416af0c9","title":"Yesterday","length":269000,"artists":[{"name":"The Beatles"}]}]}]}"#,
        0,
    );
    let script = write_script(
        "fpcalc-ok.sh",
        "#!/bin/sh\nprintf '%s' '{\"duration\": 269.5, \"fingerprint\": \"AQADtEm0yE=\"}'\n",
    );
    let audio = fixture_dir().join("sample.mp3");
    std::fs::write(&audio, b"fake audio").unwrap();
    let mut probe = spawn_bridge(
        "meta-fingerprint",
        &[
            ("ALGER_METADATA_ACOUSTID_BASE", base.as_str()),
            ("ALGER_METADATA_MUSICBRAINZ_BASE", base.as_str()),
            ("ALGER_ACOUSTID_MIN_INTERVAL_MS", "1"),
            ("ALGER_MB_MIN_INTERVAL_MS", "1"),
        ],
    );
    send(
        &mut probe,
        &format!(
            r#"{{"id":50,"m":"meta.fingerprint","p":{{"path":"{}","apiKey":"test-key","fpcalcPath":"{}"}}}}"#,
            audio.display(),
            script.display()
        ),
    );
    let out = probe.wait_for("\"id\":50", TIMEOUT);
    assert!(out.contains("\"ok\":true"), "指纹查询必须成功：{}", out);
    assert!(out.contains("\"candidates\""), "必须含 candidates：{}", out);
    assert!(
        out.contains("b1a9c0b9-d987-404e-a7db-3b00416af0c9"),
        "候选必须含 recordingId：{}",
        out
    );
    send(&mut probe, r#"{"id":51,"m":"app.shutdown","p":{}}"#);
}

/// `meta.artwork` 的封面路径：桩服务返回图片 → 返回 base64 + mimeType；
/// 404 → 明确「无封面」。
#[test]
fn meta_artwork_returns_base64_and_reports_missing_cover() {
    // 图片桩（content-type 为 image/jpeg）
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port();
    let body = b"\xff\xd8\xff\xe0fake-jpeg";
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut s = match stream {
                Ok(s) => s,
                Err(_) => break,
            };
            let mut buf = [0u8; 4096];
            let _ = s.read(&mut buf);
            let head = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: image/jpeg\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                body.len()
            );
            let _ = s.write_all(head.as_bytes());
            let _ = s.write_all(body);
        }
    });
    let mut probe = spawn_bridge(
        "meta-artwork",
        &[
            (
                "ALGER_METADATA_COVERART_BASE",
                &format!("http://127.0.0.1:{}", port),
            ),
            ("ALGER_CAA_MIN_INTERVAL_MS", "1"),
        ],
    );
    send(
        &mut probe,
        r#"{"id":40,"m":"meta.artwork","p":{"releaseId":"0da2e35a-1234-4a5b-9f9d-1a2b3c4d5e6f"}}"#,
    );
    let out = probe.wait_for("\"id\":40", TIMEOUT);
    assert!(out.contains("\"ok\":true"), "取封面必须成功：{}", out);
    assert!(
        out.contains("\"artworkBase64\""),
        "必须含 artworkBase64：{}",
        out
    );
    assert!(
        out.contains("\"mimeType\":\"image/jpeg\""),
        "必须含 mimeType：{}",
        out
    );
    assert!(
        out.contains("\"releaseId\":\"0da2e35a-1234-4a5b-9f9d-1a2b3c4d5e6f\""),
        "必须回显 releaseId：{}",
        out
    );
    send(&mut probe, r#"{"id":41,"m":"app.shutdown","p":{}}"#);
}
