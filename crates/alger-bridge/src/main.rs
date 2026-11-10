//! Alger 原生桥接进程。
//!
//! 协议（逐行 JSON，UTF-8）：
//! - 请求：`{"id":1,"m":"net.search","p":{...}}`
//! - 响应：`{"id":1,"ok":true,"r":...}` / `{"id":1,"ok":false,"e":{"code":"...","message":"..."}}`
//! - 事件：`{"ev":"dl","p":{...}}` / `{"ev":"scan","p":{...}}`
//!
//! 安全约定：
//! - Cookie 只存在于 session.json 与内存；任何响应、事件、日志都不回传 Cookie；
//! - stdout 只输出协议行（单写者、逐行 flush）；诊断日志走 stderr。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use alger_core::dlq::{DlQueue, DlTask};
use alger_core::metadata::{
    ArtworkRequest, FingerprintRequest, LookupRequest, MetadataError, MetadataService,
    ReleaseRequest, SearchRequest,
};
use alger_core::netease::client::ApiError;
use alger_core::netease::{NeteaseClient, Song};
use alger_core::scan::{scan as core_scan, ScanOptions};
use alger_core::session::SessionStore;
use alger_core::sources::{Resolver, SourceContext, SourceKind};
use alger_core::tags::{self, TagPatch};
use serde_json::{json, Value};
use tokio::sync::mpsc;

/// 错误码（Swift 侧按码分流处理）。
#[derive(Debug, Clone)]
struct BridgeError {
    code: &'static str,
    message: String,
}

impl BridgeError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        BridgeError {
            code,
            message: message.into(),
        }
    }
    fn into_value(self) -> Value {
        json!({ "code": self.code, "message": self.message })
    }
}

impl From<ApiError> for BridgeError {
    fn from(e: ApiError) -> Self {
        match e {
            ApiError::NeedLogin | ApiError::NotLoggedIn => {
                BridgeError::new("NeedLogin", e.to_string())
            }
            ApiError::Business(_) => BridgeError::new("Business", e.to_string()),
            ApiError::Network(_) => BridgeError::new("Network", e.to_string()),
            ApiError::Decode(_) => BridgeError::new("Decode", e.to_string()),
        }
    }
}

type Res = Result<Value, BridgeError>;

struct Bridge {
    session: SessionStore,
    client: NeteaseClient,
    resolver: Arc<Resolver>,
    dlq: Option<Arc<DlQueue>>,
    /// 在线匹配元信息（MusicBrainz / Cover Art Archive / AcoustID）。
    meta: Arc<MetadataService>,
    outbound: mpsc::UnboundedSender<Value>,
    /// 身份锁：会话持久化提交与客户端 Cookie 切换在同一临界区
    /// （与 Tauri 侧 AppState::commit_identity 同语义，E0 audit）。
    identity: parking_lot::Mutex<()>,
    /// 会话代号：登录 / 退出自增。注销等待期间若代号变化，说明用户已
    /// 重新登录 → 本次注销结论作废，不得清掉新登录（审查 E0-5）。
    session_generation: std::sync::atomic::AtomicU64,
    /// 扫描取消标志。
    cancel: Arc<std::sync::atomic::AtomicBool>,
}

/// 每个已接受请求 **恰好一个结果** 的去重器：先发为准（正常响应或
/// ShuttingDown 错误 whichever first），迟到的一律丢弃。
struct Responder {
    tx: mpsc::UnboundedSender<Value>,
    answered: Arc<parking_lot::Mutex<std::collections::HashSet<u64>>>,
}

impl Responder {
    fn respond(&self, seq: u64, value: Value) {
        if self.answered.lock().insert(seq) {
            let _ = self.tx.send(value);
        }
    }
}

/// 分发任务完成时：减计数、移出在途表、唤醒退出等待。
struct DecOnDrop {
    count: Arc<std::sync::atomic::AtomicUsize>,
    notify: Arc<tokio::sync::Notify>,
    seq: u64,
    in_flight: Arc<parking_lot::Mutex<std::collections::HashMap<u64, u64>>>,
    handles: Arc<parking_lot::Mutex<std::collections::HashMap<u64, tokio::task::JoinHandle<()>>>>,
}

impl Drop for DecOnDrop {
    fn drop(&mut self) {
        self.count.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
        self.in_flight.lock().remove(&self.seq);
        self.handles.lock().remove(&self.seq);
        self.notify.notify_waiters();
    }
}

/// 退出时在途请求的明确结果（每个 id 恰好一个，由 Responder 按 seq 去重）。
fn shutting_down_response(id: u64) -> Value {
    json!({
        "id": id,
        "ok": false,
        "e": { "code": "ShuttingDown", "message": "应用正在关闭，请求未完成" },
    })
}

/// 有界等待时长（测试可用 ALGER_BRIDGE_EXIT_WAIT_MS 覆盖）。
fn exit_wait() -> std::time::Duration {
    let ms = std::env::var("ALGER_BRIDGE_EXIT_WAIT_MS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(10_000)
        .min(120_000);
    std::time::Duration::from_millis(ms)
}

async fn run() {
    let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
    let (req_tx, mut req_rx) = mpsc::unbounded_channel::<(u64, u64, String, Value)>();
    // 进行中的分发任务数与在途请求表：EOF / shutdown 后有界等待，
    // 超时未完成的请求回 ShuttingDown（每个已接受 id 恰好一个结果）。
    let outstanding = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let in_flight: Arc<parking_lot::Mutex<std::collections::HashMap<u64, u64>>> =
        Arc::new(parking_lot::Mutex::new(std::collections::HashMap::new()));
    let handles: Arc<
        parking_lot::Mutex<std::collections::HashMap<u64, tokio::task::JoinHandle<()>>>,
    > = Arc::new(parking_lot::Mutex::new(std::collections::HashMap::new()));
    let notify = Arc::new(tokio::sync::Notify::new());
    let responder = Responder {
        tx: tx.clone(),
        answered: Arc::new(parking_lot::Mutex::new(std::collections::HashSet::new())),
    };
    // 接受闸：关闭后置位；reader 在闸锁内「检查 + 转发」，退出路径在同一把
    // 锁内「置位 + 排空」——转发要么发生在排空之前（得到响应），要么
    // 看见关闭位并由 reader 自己回 ShuttingDown，已接受的请求不丢响应。
    let accepting = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let accept_lock = Arc::new(parking_lot::Mutex::new(()));
    let seq_gen = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let reader_done = Arc::new(std::sync::atomic::AtomicBool::new(false));

    // 输出线程：单写者，逐行 flush。收到 Null 哨兵 = 请求侧已全部结束，
    // drain 残余响应后退出。
    let writer = tokio::task::spawn_blocking(move || {
        use std::io::Write;
        let stdout = std::io::stdout();
        let mut lock = stdout.lock();
        let mut write_line = |value: &Value| -> bool {
            let mut line = match serde_json::to_string(value) {
                Ok(l) => l,
                Err(_) => return true, // 单条序列化失败不拖垮 writer
            };
            line.push('\n');
            lock.write_all(line.as_bytes()).is_ok() && lock.flush().is_ok()
        };
        while let Some(value) = rx.blocking_recv() {
            if value.is_null() {
                // 哨兵：把队列里剩余的响应全部写完再退出
                while let Ok(v) = rx.try_recv() {
                    if !write_line(&v) {
                        return;
                    }
                }
                return;
            }
            if !write_line(&value) {
                return;
            }
        }
    });

    // stdin 读取线程：逐行解析请求。EOF 或接受关闭后结束；
    // 「检查接受位 + 转发」持 accept_lock，与退出路径的「置位 + 排空」互斥。
    let tx_reader = tx.clone();
    let req_tx_reader = req_tx.clone();
    let accepting_r = Arc::clone(&accepting);
    let accept_lock_r = Arc::clone(&accept_lock);
    let seq_gen_r = Arc::clone(&seq_gen);
    let reader_done_r = Arc::clone(&reader_done);
    tokio::task::spawn_blocking(move || {
        use std::io::BufRead;
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            let Ok(line) = line else { break };
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let Ok(v) = serde_json::from_str::<Value>(line) else {
                let _ = tx_reader.send(
                    json!({"ok": false, "e": {"code": "Decode", "message": "无法解析请求行"}}),
                );
                continue;
            };
            let id = v.get("id").and_then(|i| i.as_u64()).unwrap_or(0);
            let method = v
                .get("m")
                .and_then(|m| m.as_str())
                .unwrap_or("")
                .to_string();
            let params = v.get("p").cloned().unwrap_or(Value::Null);
            {
                let _g = accept_lock_r.lock();
                if !accepting_r.load(std::sync::atomic::Ordering::Acquire) {
                    // 接受已关闭：该行从未被接受执行，回 ShuttingDown 结果
                    let _ = tx_reader.send(shutting_down_response(id));
                    continue;
                }
                let s = seq_gen_r.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                if req_tx_reader.send((s, id, method, params)).is_err() {
                    break;
                }
            }
        }
        reader_done_r.store(true, std::sync::atomic::Ordering::Release);
    });
    // 关键：主作用域不再保留 req_tx，stdin EOF 后 req_rx 才能收到 None
    drop(req_tx);

    // 会话与客户端（--session-path 显式指定时用它，供测试隔离；
    // 不 repurpose HOME，避免触到真实 profile）
    let session = match session_path_arg() {
        Ok(Some(p)) => {
            if let Some(parent) = p.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            SessionStore::open_at(p)
        }
        Ok(None) => SessionStore::open(),
        Err(e) => {
            // fail closed：参数不合法绝不回落默认会话文件（审查 E0-3）
            eprintln!("alger-bridge: {}", e);
            std::process::exit(2);
        }
    };
    let client = NeteaseClient::new();
    let cookie = session.get().cookie;
    if !cookie.trim().is_empty() {
        client.set_cookie(&cookie);
    }
    let resolver = Arc::new(Resolver::new());

    // 下载队列（目录：会话目录/bridge）
    let session_dir = session.path();
    let session_dir = Path::new(&session_dir)
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."));
    let dl_dir = session_dir.join("bridge");
    let tx_sink = tx.clone();
    let sink: alger_core::dlq::EventSink = Arc::new(move |value| {
        let _ = tx_sink.send(value);
    });
    let dlq = match DlQueue::open(&dl_dir, sink) {
        Ok(q) => Some(Arc::new(q)),
        Err(e) => {
            eprintln!("alger-bridge: download queue unavailable: {}", e);
            None
        }
    };

    let bridge = Arc::new(Bridge {
        session,
        client,
        resolver,
        dlq,
        meta: Arc::new(MetadataService::new()),
        outbound: tx.clone(),
        identity: parking_lot::Mutex::new(()),
        session_generation: std::sync::atomic::AtomicU64::new(0),
        cancel: Arc::new(std::sync::atomic::AtomicBool::new(false)),
    });

    // 处理请求（分发到独立任务；阻塞扫描走 spawn_blocking）。
    // 每个已接受请求最终恰好一个结果：正常响应，或退出时的 ShuttingDown。
    while let Some((seq, id, method, params)) = req_rx.recv().await {
        if method == "app.shutdown" {
            responder.respond(seq, json!({"id": id, "ok": true, "r": {"bye": true}}));
            break;
        }
        let b = Arc::clone(&bridge);
        let responder = Responder {
            tx: tx.clone(),
            answered: Arc::clone(&responder.answered),
        };
        outstanding.fetch_add(1, std::sync::atomic::Ordering::AcqRel);
        in_flight.lock().insert(seq, id);
        let guard_count = Arc::clone(&outstanding);
        let guard_notify = Arc::clone(&notify);
        let guard_in_flight = Arc::clone(&in_flight);
        let guard_handles = Arc::clone(&handles);
        let task_seq = seq;
        let handle = tokio::spawn(async move {
            let _guard = DecOnDrop {
                count: guard_count,
                notify: guard_notify,
                seq: task_seq,
                in_flight: guard_in_flight,
                handles: guard_handles,
            };
            let result = dispatch(&b, &method, &params).await;
            let response = match result {
                Ok(r) => json!({"id": id, "ok": true, "r": r}),
                Err(e) => json!({"id": id, "ok": false, "e": e.into_value()}),
            };
            responder.respond(task_seq, response);
        });
        handles.lock().insert(seq, handle);
    }

    // 退出路径：
    // 1. 关闭接受并在同一把闸锁内排空 **已接受** 队列（reader 无法再把
    //    请求插到排空之后）；未接受的后续行由 reader 回 ShuttingDown；
    // 2. 有界等待 reader 处理完已缓冲的行（其 ShuttingDown 结果先于
    //    哨兵发出，不会丢）；stdin 仍开且无数据时按上限放弃——那些行
    //    从未被接受；
    // 3. 在途请求有界等待（通知驱动，无自旋）；超时未完成的回 ShuttingDown
    //    并 abort 对应任务（恰好一个结果，任务被真正取消）；
    // 4. 下载队列收束：在途下载在块边界暂停并持久化可恢复状态与
    //    targets（事件先于 writer 关闭发出）；
    // 5. 发 Null 哨兵 → writer drain 完毕返回 → run() 正常返回。
    {
        let _g = accept_lock.lock();
        accepting.store(false, std::sync::atomic::Ordering::Release);
        while let Ok((seq, id, _, _)) = req_rx.try_recv() {
            responder.respond(seq, shutting_down_response(id));
        }
    }
    let drain_deadline = std::time::Instant::now() + std::time::Duration::from_secs(1);
    while !reader_done.load(std::sync::atomic::Ordering::Acquire) {
        if std::time::Instant::now() >= drain_deadline {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    let wait = exit_wait();
    let deadline = std::time::Instant::now() + wait;
    loop {
        if in_flight.lock().is_empty() {
            break;
        }
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            let pending: Vec<(u64, u64)> = in_flight.lock().iter().map(|(s, i)| (*s, *i)).collect();
            eprintln!(
                "alger-bridge: {} in-flight request(s) not finished within {:?}, responding ShuttingDown and aborting",
                pending.len(),
                wait
            );
            for (s, i) in &pending {
                responder.respond(*s, shutting_down_response(*i));
            }
            // 真正取消超时任务：扫描置取消位 + abort 分发任务
            bridge
                .cancel
                .store(true, std::sync::atomic::Ordering::Relaxed);
            for (s, h) in handles.lock().iter() {
                if pending.iter().any(|(ps, _)| ps == s) {
                    h.abort();
                }
            }
            break;
        }
        let notified = notify.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        if in_flight.lock().is_empty() {
            break;
        }
        let _ = tokio::time::timeout(remaining, notified).await;
    }
    // 下载收束：在途下载暂停、持久化可恢复状态（含 targets），事件经
    // sink → writer（此时 writer 仍在运行）。
    if let Some(dlq) = &bridge.dlq {
        let remaining = dlq.begin_shutdown(std::time::Duration::from_secs(5));
        if remaining > 0 {
            eprintln!(
                "alger-bridge: {} download(s) still active after shutdown wait",
                remaining
            );
        }
    }
    let _ = tx.send(Value::Null); // 哨兵：关闭 writer
    drop(tx);
    // **有界**等待 writer（审查 E1-1）：stdout peer 停止读取时管道会写满，
    // writer 永久阻塞在 write 上 —— 退出不能被它拖死。
    match tokio::time::timeout(std::time::Duration::from_secs(2), writer).await {
        Ok(_) => {}
        Err(_) => {
            eprintln!("alger-bridge: stdout writer 未在 2s 内结束（peer 可能卡住），强制结束");
        }
    }
    eprintln!("alger-bridge: stopped");
}

/// 解析 `--session-path <path>`（显式会话文件路径，测试隔离用）。
///
/// **fail closed**（审查 E0-3）：缺参 / 空值 / 相对路径都必须 **明确失败**，
/// 绝不回落到默认会话文件——回落意味着读写用户真实 profile（含凭证）。
fn session_path_arg() -> Result<Option<PathBuf>, String> {
    let mut args = std::env::args().skip(1);
    // 只认第一个参数：它要么是 `--session-path <path>`，要么是
    // `--session-path=<path>`，要么是 **未知参数**（必须明确失败）。
    let Some(a) = args.next() else {
        return Ok(None);
    };
    if a == "--session-path" {
        return match args.next() {
            Some(v) if !v.trim().is_empty() => check_session_path(PathBuf::from(v)),
            _ => Err("--session-path 缺少路径参数（拒绝回落到默认会话文件）".into()),
        };
    }
    if let Some(v) = a.strip_prefix("--session-path=") {
        if v.trim().is_empty() {
            return Err("--session-path 参数为空（拒绝回落到默认会话文件）".into());
        }
        return check_session_path(PathBuf::from(v));
    }
    // 未知参数 **同样 fail closed**：参数名写错（如 --session-pth）若被
    // 静默忽略，就会悄悄回落到默认会话文件（审查 E0-3）。
    Err(format!("未知参数 {}（拒绝回落到默认会话文件）", a))
}

/// 校验显式会话路径：必须是绝对路径（相对路径会随 cwd 漂移，可能误指
/// 真实 profile）。
fn check_session_path(path: PathBuf) -> Result<Option<PathBuf>, String> {
    if !path.is_absolute() {
        return Err(format!(
            "--session-path 必须是绝对路径（收到 {}），拒绝回落到默认会话文件",
            path.display()
        ));
    }
    Ok(Some(path))
}

fn main() {
    // stderr 诊断：只输出进程级信息，不输出任何凭证
    eprintln!("alger-bridge: starting");
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("build tokio runtime");
    runtime.block_on(run());
    // reader 可能仍阻塞在 stdin；不等待阻塞线程，直接结束运行时与进程
    runtime.shutdown_background();
    std::process::exit(0);
}

fn parse_song(v: &Value) -> Result<Song, BridgeError> {
    alger_core::netease::models::Song::from_value(v)
        .ok_or_else(|| BridgeError::new("Decode", "歌曲对象无效（缺少 id / name）"))
}

fn parse_ctx(song: &Song) -> SourceContext {
    SourceContext::new(
        song.id,
        &song.name,
        &song
            .artists
            .iter()
            .map(|a| a.name.clone())
            .collect::<Vec<_>>(),
        &song.album.name,
        song.duration_ms,
    )
}

async fn dispatch(b: &Bridge, method: &str, p: &Value) -> Res {
    match method {
        // ---------- 测试钩子（仅 ALGER_BRIDGE_TEST_HOOKS=1 时启用） ----------
        "test.slow" if std::env::var_os("ALGER_BRIDGE_TEST_HOOKS").is_some() => {
            let ms = p
                .get("ms")
                .and_then(|v| v.as_u64())
                .unwrap_or(0)
                .min(60_000);
            tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
            Ok(json!({ "slept": ms }))
        }
        // 直接用给定 URL 入队（不解析音源）：用于验证 **真实在途 HTTP 下载**
        // 在退出时的收束语义（审查 E1-3）。
        "test.dlEnqueue" if std::env::var_os("ALGER_BRIDGE_TEST_HOOKS").is_some() => {
            let dlq = b
                .dlq
                .as_ref()
                .ok_or_else(|| BridgeError::new("IO", "下载队列不可用"))?;
            let id = p.get("id").and_then(|v| v.as_i64()).unwrap_or(1);
            let url = p
                .get("url")
                .and_then(|v| v.as_str())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 url"))?;
            let dir = p
                .get("dir")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let targets: Vec<String> = p
                .get("targets")
                .and_then(|t| t.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str())
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();
            dlq.enqueue(
                id,
                "测试",
                "测试",
                "",
                0,
                url,
                Path::new(&dir),
                None,
                targets,
            )
            .map_err(|e| BridgeError::new("IO", e))?;
            Ok(json!({ "queued": true }))
        }

        // ---------- 应用与会话 ----------
        "app.hello" => Ok(json!({
            "protocol": 1,
            "core": env!("CARGO_PKG_VERSION"),
            "platform": "macos",
        })),
        "session.snapshot" => {
            let data = b.session.get();
            Ok(json!({
                "loggedIn": b.client.is_logged_in(),
                "hasCookie": b.client.has_cookie(),
                "account": data.account,
                "quality": data.quality,
                "sources": data.sources,
                "downloadDir": b.session.download_dir(),
                "sessionPath": b.session.path(),
                "loadIssue": b.session.load_issue(),
                "dlq": match b.dlq.as_ref() {
                    Some(q) => json!({
                        "available": true,
                        "loadIssue": q.load_issue(),
                        "lastError": q.last_error(),
                    }),
                    None => json!({ "available": false, "loadIssue": Value::Null, "lastError": Value::Null }),
                },
            }))
        }
        "session.verifyCookie" => {
            let cookie = p
                .get("cookie")
                .and_then(|c| c.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            if cookie.is_empty() {
                return Err(BridgeError::new("Business", "请填写 Cookie"));
            }
            if !cookie.contains("MUSIC_U") {
                return Err(BridgeError::new(
                    "Business",
                    "Cookie 中未找到 MUSIC_U，请确认已登录网易云音乐后重新复制",
                ));
            }
            let account = NeteaseClient::verify_account_with(&cookie)
                .await
                .map_err(BridgeError::from)?;
            // 返回账号信息但不落盘；Swift 确认后再调 session.setCookie
            Ok(serde_json::to_value(account).unwrap_or(Value::Null))
        }
        "session.setCookie" => {
            let cookie = p
                .get("cookie")
                .and_then(|c| c.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            if cookie.is_empty() {
                return Err(BridgeError::new("Business", "Cookie 为空"));
            }
            // 再次校验（与登录窗口流程一致：校验成功才替换会话）
            let account = NeteaseClient::verify_account_with(&cookie)
                .await
                .map_err(BridgeError::from)?;
            // 共享身份事务（E0 audit）：事务闭包写会话（先落盘后提交），
            // 同一临界区内切客户端 Cookie；落盘失败时客户端保持旧身份。
            let _g = b.identity.lock();
            b.session
                .update(|data| {
                    data.cookie = cookie.clone();
                    data.account = Some(account);
                })
                .map_err(|e| BridgeError::new("IO", e))?;
            b.client.set_cookie(&cookie);
            b.session_generation
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(Value::Bool(true))
        }
        "session.logout" => {
            // E0 audit：捕获发起时的 cookie / 代号；网络注销等待期间用户
            // 可能已重新登录，清理必须按「仍是旧身份」条件执行——stale 时
            // 保留新登录，不得清掉（审查 E0-5）。
            let cookie = b.session.get().cookie;
            let generation = b
                .session_generation
                .load(std::sync::atomic::Ordering::SeqCst);
            // 用 **捕获的旧 cookie** 注销（审查 E0-6）：用可变 client 会在
            // 等待期间切到新登录时把 **新会话** 在服务端注销掉。
            let _ = NeteaseClient::logout_with(&cookie).await;
            let _g = b.identity.lock();
            if b.session_generation
                .load(std::sync::atomic::Ordering::SeqCst)
                != generation
                || b.session.get().cookie != cookie
            {
                // stale：期间身份已变化 → 静默保留新登录
                return Ok(Value::Bool(false));
            }
            // 先落盘清除，成功后才清内存客户端（失败时用户仍保持登录态，
            // 界面显示具体原因而不是假退出）
            b.session
                .clear_login()
                .map_err(|e| BridgeError::new("IO", e))?;
            b.client.clear_cookie();
            b.session_generation
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(Value::Bool(true))
        }
        "session.updateSettings" => {
            // R1：读改写整体走事务（串行锁 + 先落盘后提交），不用旧快照
            b.session
                .update(|data| {
                    if let Some(q) = p.get("quality").and_then(|q| q.as_str()) {
                        if !q.trim().is_empty() {
                            data.quality = q.trim().to_string();
                        }
                    }
                    if let Some(s) = p.get("sources").and_then(|s| s.as_array()) {
                        let filtered: Vec<String> = s
                            .iter()
                            .filter_map(|x| x.as_str())
                            .filter(|x| SourceKind::parse(x).is_some())
                            .map(|x| x.trim().to_lowercase())
                            .collect();
                        if !filtered.is_empty() {
                            data.sources = filtered;
                        }
                    }
                    if let Some(d) = p.get("downloadDir").and_then(|d| d.as_str()) {
                        if !d.trim().is_empty() {
                            data.download_dir = d.trim().to_string();
                        }
                    }
                })
                .map_err(|e| BridgeError::new("IO", e))?;
            Ok(Value::Bool(true))
        }

        // ---------- 网易云只读接口 ----------
        "net.account" => {
            let account = b.client.account().await.map_err(BridgeError::from)?;
            Ok(serde_json::to_value(account).unwrap_or(Value::Null))
        }
        "net.userPlaylists" => {
            let uid = match p.get("uid").and_then(|u| u.as_i64()) {
                Some(u) => u,
                None => b.client.account().await.map_err(BridgeError::from)?.user_id,
            };
            let mut out = Vec::new();
            let mut offset = 0u32;
            loop {
                let page = b
                    .client
                    .user_playlists(uid, 50, offset)
                    .await
                    .map_err(BridgeError::from)?;
                let count = page.len();
                for pl in page {
                    out.push(serde_json::to_value(pl).unwrap_or(Value::Null));
                }
                if count == 0 {
                    break;
                }
                offset += count as u32;
                if count < 50 || offset > 1000 {
                    break;
                }
            }
            Ok(json!({ "playlists": out }))
        }
        "net.playlistDetail" => {
            let id = p
                .get("id")
                .and_then(|i| i.as_i64())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 id"))?;
            let playlist = b
                .client
                .playlist_detail(id)
                .await
                .map_err(BridgeError::from)?;
            let ids = playlist.track_ids.clone();
            let mut songs: Vec<Song> = Vec::with_capacity(ids.len());
            for chunk in ids.chunks(500) {
                let batch = b
                    .client
                    .song_details(chunk)
                    .await
                    .map_err(BridgeError::from)?;
                songs.extend(batch);
            }
            let missing = ids.len().saturating_sub(songs.len());
            let mut map = HashMap::new();
            for s in songs {
                map.insert(s.id, s);
            }
            let mut ordered: Vec<Value> = Vec::with_capacity(map.len());
            for id in &ids {
                if let Some(song) = map.remove(id) {
                    ordered.push(serde_json::to_value(song).unwrap_or(Value::Null));
                }
            }
            Ok(json!({
                "playlist": serde_json::to_value(playlist).unwrap_or(Value::Null),
                "songs": ordered,
                "missing": missing,
            }))
        }
        "net.songDetails" => {
            let ids: Vec<i64> = p
                .get("ids")
                .and_then(|i| i.as_array())
                .map(|a| a.iter().filter_map(|x| x.as_i64()).collect())
                .unwrap_or_default();
            let songs = b
                .client
                .song_details(&ids)
                .await
                .map_err(BridgeError::from)?;
            Ok(
                json!({ "songs": songs.iter().map(|s| serde_json::to_value(s).unwrap_or(Value::Null)).collect::<Vec<_>>() }),
            )
        }
        "net.search" => {
            let keywords = p
                .get("keywords")
                .and_then(|k| k.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            if keywords.is_empty() {
                return Err(BridgeError::new("Business", "请输入搜索关键词"));
            }
            let limit = p.get("limit").and_then(|l| l.as_u64()).unwrap_or(50) as u32;
            let offset = p.get("offset").and_then(|l| l.as_u64()).unwrap_or(0) as u32;
            let (songs, total) = b
                .client
                .search_songs(&keywords, limit, offset)
                .await
                .map_err(BridgeError::from)?;
            Ok(json!({
                "songs": songs.iter().map(|s| serde_json::to_value(s).unwrap_or(Value::Null)).collect::<Vec<_>>(),
                "total": total,
            }))
        }
        "net.songUrl" => {
            let id = p
                .get("id")
                .and_then(|i| i.as_i64())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 id"))?;
            let level = p.get("level").and_then(|l| l.as_str()).unwrap_or("higher");
            let url = b
                .client
                .song_url(id, level)
                .await
                .map_err(BridgeError::from)?;
            Ok(serde_json::to_value(url).unwrap_or(Value::Null))
        }
        "net.lyric" => {
            let id = p
                .get("id")
                .and_then(|i| i.as_i64())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 id"))?;
            let lyric = b.client.lyric(id).await.map_err(BridgeError::from)?;
            Ok(serde_json::to_value(lyric).unwrap_or(Value::Null))
        }
        "net.personalFm" => {
            let songs = b.client.personal_fm().await.map_err(BridgeError::from)?;
            Ok(
                json!({ "songs": songs.iter().map(|s| serde_json::to_value(s).unwrap_or(Value::Null)).collect::<Vec<_>>() }),
            )
        }
        "net.intelligenceList" => {
            let pid = p
                .get("playlistId")
                .and_then(|i| i.as_i64())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 playlistId"))?;
            let sid = p.get("songId").and_then(|i| i.as_i64()).unwrap_or(0);
            let start = p
                .get("startMusicId")
                .and_then(|i| i.as_i64())
                .unwrap_or(sid);
            let songs = b
                .client
                .playmode_intelligence(pid, sid, start)
                .await
                .map_err(BridgeError::from)?;
            Ok(
                json!({ "songs": songs.iter().map(|s| serde_json::to_value(s).unwrap_or(Value::Null)).collect::<Vec<_>>() }),
            )
        }
        "net.similarSongs" => {
            // 相似歌曲（`/api/v1/discovery/simiSong`）：只读、可匿名。
            // **结构错误 ≠ 空结果**：上游缺 `songs` / 类型不对时明确报错
            // （`Decode`），合法空数组才返回空列表。
            let song_id = p
                .get("songId")
                .and_then(|i| i.as_i64())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 songId"))?;
            let limit = p.get("limit").and_then(|l| l.as_u64()).unwrap_or(20).min(100) as u32;
            let offset = p.get("offset").and_then(|l| l.as_u64()).unwrap_or(0) as u32;
            let songs = b
                .client
                .similar_songs(song_id, limit, offset)
                .await
                .map_err(BridgeError::from)?;
            Ok(
                json!({ "songs": songs.iter().map(|s| serde_json::to_value(s).unwrap_or(Value::Null)).collect::<Vec<_>>() }),
            )
        }
        "net.topPlaylists" => {
            // 公开热门歌单（`/api/playlist/list`）：**只读、匿名可用**。
            // 上游参数：`{cat, order, limit, offset, total}`。
            let limit = p
                .get("limit")
                .and_then(|l| l.as_u64())
                .unwrap_or(12)
                .min(50) as u32;
            let offset = p.get("offset").and_then(|l| l.as_u64()).unwrap_or(0) as u32;
            let category = p.get("cat").and_then(|c| c.as_str()).unwrap_or("全部");
            let order = p.get("order").and_then(|o| o.as_str()).unwrap_or("hot");
            let playlists = b
                .client
                .top_playlists(category, order, limit, offset)
                .await
                .map_err(BridgeError::from)?;
            Ok(json!({
                "playlists": playlists.iter().map(|pl| serde_json::to_value(pl).unwrap_or(Value::Null)).collect::<Vec<_>>(),
            }))
        }
        "net.artistSublist" => {
            // 分页取全（去重 / 终止保护 / 错误上抛），不再固定 100,0 一页
            let list = b
                .client
                .artist_sublist_all()
                .await
                .map_err(BridgeError::from)?;
            Ok(json!({ "artists": list }))
        }
        "net.artistNewWorks" => {
            // 上游 `artist_new_song.js` 用的是 `{limit, startTimestamp}`
            // （`before` 缺省即当前时间），旧参数（offset / total）取不到数据。
            let limit = p
                .get("limit")
                .and_then(|v| v.as_u64())
                .unwrap_or(20)
                .min(100) as u32;
            let before = p.get("before").and_then(|v| v.as_i64());
            let list = b
                .client
                .artist_new_works(limit, before)
                .await
                .map_err(BridgeError::from)?;
            Ok(json!({ "works": list }))
        }
        "net.artistTopSongs" => {
            let id = p
                .get("id")
                .and_then(|i| i.as_i64())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 id"))?;
            let songs = b
                .client
                .artist_top_songs(id, 50)
                .await
                .map_err(BridgeError::from)?;
            Ok(
                json!({ "songs": songs.iter().map(|s| serde_json::to_value(s).unwrap_or(Value::Null)).collect::<Vec<_>>() }),
            )
        }
        "net.artistAlbums" => {
            let id = p
                .get("id")
                .and_then(|i| i.as_i64())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 id"))?;
            let albums = b
                .client
                .artist_albums(id, 100, 0)
                .await
                .map_err(BridgeError::from)?;
            Ok(json!({ "albums": albums }))
        }
        "net.artistDetail" => {
            let id = p
                .get("id")
                .and_then(|i| i.as_i64())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 id"))?;
            let detail = b
                .client
                .artist_detail(id)
                .await
                .map_err(BridgeError::from)?;
            Ok(serde_json::to_value(detail).unwrap_or(Value::Null))
        }

        // ---------- 歌单只读 ----------
        // 网络歌单为 **完全只读**：创建 / 改名 / 描述 / 增删曲 / 删除 / 重排
        // 等写 handler 已彻底移除（连同底层 API），任何写方法都会落到
        // 「未知方法」错误（回归见 tests/readonly.rs）。
        "net.albumDetail" => {
            let id = p
                .get("id")
                .and_then(|i| i.as_i64())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 id"))?;
            let detail = b.client.album_detail(id).await.map_err(BridgeError::from)?;
            Ok(json!({
                "album": serde_json::to_value(detail.album).unwrap_or(Value::Null),
                "songs": detail.songs.iter().map(|s| serde_json::to_value(s).unwrap_or(Value::Null)).collect::<Vec<_>>(),
            }))
        }

        // ---------- 音源与播放地址 ----------
        "src.resolve" => {
            let song = parse_song(p.get("song").unwrap_or(p))?;
            resolve_for(b, &song).await
        }
        "src.probeSource" => {
            let kind = p.get("kind").and_then(|k| k.as_str()).unwrap_or("");
            let source =
                SourceKind::parse(kind).ok_or_else(|| BridgeError::new("Decode", "未知音源"))?;
            let song = parse_song(p.get("song").unwrap_or(p))?;
            let ctx = parse_ctx(&song);
            let audio = b
                .resolver
                .resolve_one(source, &ctx)
                .await
                .map_err(|e| BridgeError::new("Business", e.to_string()))?;
            Ok(serde_json::to_value(audio).unwrap_or(Value::Null))
        }

        // ---------- 下载 ----------
        "dl.enqueue" => {
            let dlq = b
                .dlq
                .as_ref()
                .ok_or_else(|| BridgeError::new("IO", "下载队列不可用"))?;
            let song = parse_song(p.get("song").unwrap_or(p))?;
            let dir = p
                .get("dir")
                .and_then(|d| d.as_str())
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(b.session.download_dir()))
                .to_string_lossy()
                .to_string();
            let resolved = resolve_for(b, &song).await?;
            let url = resolved
                .get("url")
                .and_then(|u| u.as_str())
                .ok_or_else(|| BridgeError::new("Business", "未能解析到可下载地址"))?
                .to_string();
            let source = resolved
                .get("source")
                .and_then(|s| s.as_str())
                .map(|s| s.to_string());
            let note = resolved
                .get("note")
                .and_then(|n| n.as_str())
                .unwrap_or("")
                .to_string();
            let dir_override = p.get("dir").and_then(|d| d.as_str()).map(|s| s.to_string());
            // 目标歌单（Swift 侧稳定 ID 列表），随任务持久化
            let targets: Vec<String> = p
                .get("targets")
                .and_then(|t| t.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str())
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();
            dlq.enqueue(
                song.id,
                &song.name,
                &song.artist_text(),
                &song.album.name,
                song.duration_ms,
                &url,
                Path::new(dir_override.as_deref().unwrap_or(&dir)),
                source,
                targets,
            )
            .map_err(|e| BridgeError::new("IO", e))?;
            Ok(json!({ "queued": true, "note": note }))
        }
        "dl.list" => {
            let dlq = b
                .dlq
                .as_ref()
                .ok_or_else(|| BridgeError::new("IO", "下载队列不可用"))?;
            let mut out = Vec::new();
            for t in dlq.list() {
                out.push(task_value(&t));
            }
            Ok(json!({ "tasks": out }))
        }
        "dl.retry" => {
            let dlq = b
                .dlq
                .as_ref()
                .ok_or_else(|| BridgeError::new("IO", "下载队列不可用"))?;
            let id = p
                .get("id")
                .and_then(|i| i.as_i64())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 id"))?;
            let task = dlq
                .task(id)
                .ok_or_else(|| BridgeError::new("NotFound", "任务不存在"))?;
            // 用 **在途集合** 判断「真的在下载」，而不是持久状态（审查 E0-8）：
            // 完成后的落盘失败会让持久状态停在 running，但下载其实已结束
            // —— 这种情况必须允许重试走 intent 恢复（不重下、不产生副本）。
            if dlq.is_active(id) {
                return Err(BridgeError::new("Business", "任务正在下载中"));
            }
            // **先本地恢复**：文件已落位且内容摘要一致 → 直接完成，
            // 不解析新地址（离线 / 音源解析服务失败时也能恢复，审查 E0-8）。
            if dlq.try_complete_from_intent(id).unwrap_or(false) {
                return Ok(json!({ "queued": false, "recovered": true }));
            }
            // 本地无法确认 → 才解析新地址并重新下载
            // 重建 Song 以重新解析地址
            let song = Song {
                id: task.id,
                name: task.name.clone(),
                artists: task
                    .artist
                    .split(" / ")
                    .map(|s| alger_core::netease::models::Artist {
                        id: 0,
                        name: s.to_string(),
                    })
                    .collect(),
                album: alger_core::netease::models::Album {
                    id: 0,
                    name: task.album.clone(),
                    pic_url: String::new(),
                },
                duration_ms: task.duration_ms,
                fee: 0,
                copyright: 0,
            };
            let resolved = resolve_for(b, &song).await?;
            let url = resolved
                .get("url")
                .and_then(|u| u.as_str())
                .ok_or_else(|| BridgeError::new("Business", "未能解析到可下载地址"))?
                .to_string();
            let source = resolved
                .get("source")
                .and_then(|s| s.as_str())
                .map(|s| s.to_string());
            // 重试必须带上原任务的目标歌单（审查 P0-4）
            dlq.enqueue(
                song.id,
                &song.name,
                &song.artist_text(),
                &song.album.name,
                song.duration_ms,
                &url,
                Path::new(&b.session.download_dir()),
                source,
                task.targets.clone(),
            )
            .map_err(|e| BridgeError::new("IO", e))?;
            Ok(json!({ "queued": true, "recovered": false }))
        }
        "dl.clear" => {
            let dlq = b
                .dlq
                .as_ref()
                .ok_or_else(|| BridgeError::new("IO", "下载队列不可用"))?;
            let only_done = p.get("onlyDone").and_then(|v| v.as_bool()).unwrap_or(true);
            dlq.clear(only_done)
                .map_err(|e| BridgeError::new("IO", e))?;
            Ok(Value::Bool(true))
        }
        "dl.status" => {
            // 队列健康状态：载入问题与最近落盘错误必须对界面可见（审查 P0-3）
            match b.dlq.as_ref() {
                Some(dlq) => Ok(json!({
                    "available": true,
                    "loadIssue": dlq.load_issue(),
                    "lastError": dlq.last_error(),
                })),
                None => Ok(json!({
                    "available": false,
                    "loadIssue": Some("下载队列不可用".to_string()),
                    "lastError": Value::Null,
                })),
            }
        }

        // ---------- 标签 ----------
        "tags.read" => {
            let path = p
                .get("path")
                .and_then(|x| x.as_str())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 path"))?;
            let meta = tags::read_meta(Path::new(path)).map_err(tag_err)?;
            Ok(serde_json::to_value(meta).unwrap_or(Value::Null))
        }
        "tags.artwork" => {
            let path = p
                .get("path")
                .and_then(|x| x.as_str())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 path"))?;
            let b64 = tags::artwork_base64(Path::new(path)).map_err(tag_err)?;
            Ok(json!({ "base64": b64 }))
        }
        "tags.write" => {
            let path = p
                .get("path")
                .and_then(|x| x.as_str())
                .ok_or_else(|| BridgeError::new("Decode", "缺少 path"))?;
            let patch: TagPatch =
                serde_json::from_value(p.get("patch").cloned().unwrap_or(Value::Null))
                    .map_err(|e| BridgeError::new("Decode", format!("patch 无效：{}", e)))?;
            let meta = tags::write_tags(Path::new(path), &patch).map_err(tag_err)?;
            Ok(serde_json::to_value(meta).unwrap_or(Value::Null))
        }

        // ---------- 曲库扫描 ----------
        "lib.scan" => {
            let options: ScanOptions = serde_json::from_value(p.clone())
                .map_err(|e| BridgeError::new("Decode", format!("扫描参数无效：{}", e)))?;
            b.cancel.store(false, std::sync::atomic::Ordering::Relaxed);
            let cancel = Arc::clone(&b.cancel);
            let outbound = b.outbound.clone();
            // 阻塞扫描放独立线程，避免占住 tokio worker
            let summary = tokio::task::spawn_blocking(move || {
                core_scan(&options, &cancel, |meta| {
                    let _ = outbound.send(json!({
                        "ev": "scan",
                        "p": serde_json::to_value(meta).unwrap_or(Value::Null),
                    }));
                })
            })
            .await
            .map_err(|e| BridgeError::new("IO", format!("扫描任务失败：{}", e)))?;
            Ok(serde_json::to_value(summary).unwrap_or(Value::Null))
        }
        "lib.cancel" => {
            b.cancel.store(true, std::sync::atomic::Ordering::Relaxed);
            Ok(Value::Bool(true))
        }

        // ---------- 在线匹配元信息（MusicBrainz / CAA / AcoustID） ----------
        "meta.search" => {
            let req = SearchRequest {
                title: meta_str(p, "title").unwrap_or_default(),
                artist: meta_str(p, "artist").unwrap_or_default(),
                duration_ms: meta_u64(p, "durationMs"),
                limit: meta_u64(p, "limit").map(|v| v.min(100) as u32),
                token: meta_str(p, "token"),
            };
            if req.title.trim().is_empty() {
                return Err(BridgeError::new("Business", "搜索标题不能为空"));
            }
            let candidates = b.meta.search(&req).await.map_err(meta_err)?;
            Ok(json!({ "candidates": candidates }))
        }
        "meta.lookup" => {
            let req = LookupRequest {
                recording_id: meta_str(p, "recordingId").unwrap_or_default(),
                token: meta_str(p, "token"),
            };
            if req.recording_id.trim().is_empty() {
                return Err(BridgeError::new("Business", "缺少 recordingId"));
            }
            let candidate = b.meta.lookup(&req).await.map_err(meta_err)?;
            Ok(json!({ "candidate": candidate }))
        }
        "meta.release" => {
            let req = ReleaseRequest {
                release_id: meta_str(p, "releaseId").unwrap_or_default(),
                recording_id: meta_str(p, "recordingId"),
                token: meta_str(p, "token"),
            };
            if req.release_id.trim().is_empty() {
                return Err(BridgeError::new("Business", "缺少 releaseId"));
            }
            let detail = b.meta.release(&req).await.map_err(meta_err)?;
            Ok(json!({
                "release": detail.release,
                "tracks": detail.tracks,
            }))
        }
        "meta.artwork" => {
            let req = ArtworkRequest {
                release_id: meta_str(p, "releaseId").unwrap_or_default(),
                token: meta_str(p, "token"),
            };
            if req.release_id.trim().is_empty() {
                return Err(BridgeError::new("Business", "缺少 releaseId"));
            }
            let artwork = b.meta.artwork(&req).await.map_err(meta_err)?;
            Ok(json!({
                "artworkBase64": artwork.artwork_base64,
                "mimeType": artwork.mime_type,
                "releaseId": artwork.release_id,
            }))
        }
        "meta.fingerprint" => {
            let req = FingerprintRequest {
                path: meta_str(p, "path").unwrap_or_default(),
                api_key: meta_str(p, "apiKey").unwrap_or_default(),
                fpcalc_path: meta_str(p, "fpcalcPath"),
                token: meta_str(p, "token"),
            };
            if req.path.trim().is_empty() {
                return Err(BridgeError::new("Business", "缺少 path"));
            }
            let candidates = b.meta.fingerprint(&req).await.map_err(meta_err)?;
            Ok(json!({ "candidates": candidates }))
        }
        "meta.cancel" => {
            // 取消立即返回（不等待被取消的请求结束）：被取消的请求会自己回
            // 一条 `Cancelled` 错误响应。
            let token = meta_str(p, "token").unwrap_or_default();
            let _ = b.meta.cancel(&token);
            Ok(json!({ "cancelled": true }))
        }

        other => Err(BridgeError::new(
            "Unsupported",
            format!("未知方法：{}", other),
        )),
    }
}

/// 元信息参数读取（宽松：数字接受字符串 / 浮点）。
fn meta_str(p: &Value, key: &str) -> Option<String> {
    p.get(key)
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn meta_u64(p: &Value, key: &str) -> Option<u64> {
    p.get(key)
        .and_then(|v| v.as_u64())
        .or_else(|| {
            p.get(key)
                .and_then(|v| v.as_f64())
                .map(|f| f.max(0.0) as u64)
        })
        .or_else(|| {
            p.get(key)
                .and_then(|v| v.as_str())
                .and_then(|s| s.trim().parse::<u64>().ok())
        })
}

/// 元信息错误 → 桥接错误码。
fn meta_err(e: MetadataError) -> BridgeError {
    let code = match e {
        MetadataError::Cancelled => "Cancelled",
        MetadataError::MissingApiKey => "MissingApiKey",
        MetadataError::FpcalcMissing(_) => "FpcalcMissing",
        MetadataError::FileMissing(_) => "NotFound",
        MetadataError::Network(_) => "Network",
        MetadataError::Timeout => "Timeout",
        MetadataError::Http { .. } => "Http",
        MetadataError::Decode(_) => "Decode",
        MetadataError::NoArtwork => "NoArtwork",
        MetadataError::TooLarge { .. } => "TooLarge",
        MetadataError::Invalid(_) => "Business",
    };
    BridgeError::new(code, e.to_string())
}

fn tag_err(e: alger_core::tags::TagError) -> BridgeError {
    match e {
        alger_core::tags::TagError::Open { .. } => BridgeError::new("NotFound", e.to_string()),
        alger_core::tags::TagError::Write { .. } | alger_core::tags::TagError::Verify { .. } => {
            BridgeError::new("IO", e.to_string())
        }
        _ => BridgeError::new("Business", e.to_string()),
    }
}

fn task_value(t: &DlTask) -> Value {
    let percent = if t.total == 0 {
        0u32
    } else {
        ((t.downloaded as f64 / t.total as f64) * 100.0).clamp(0.0, 100.0) as u32
    };
    json!({
        "id": t.id,
        "name": t.name,
        "artist": t.artist,
        "album": t.album,
        "durationMs": t.duration_ms,
        "path": t.path,
        "downloaded": t.downloaded,
        "total": t.total,
        "percent": percent,
        "status": t.status,
        "error": t.error,
        "source": t.source,
        "createdAt": t.created_at,
        "updatedAt": t.updated_at,
        "targets": t.targets,
    })
}

/// 解析播放地址：优先官方，失败回退第三方（与 Tauri 命令层一致）。
async fn resolve_for(b: &Bridge, song: &Song) -> Res {
    let quality = b.session.get().quality;
    let mut note: Option<String> = None;

    match b.client.song_url(song.id, &quality).await {
        Ok(official) => {
            if let Some(url) = official.url.clone() {
                if !official.free_trial {
                    match b.resolver.probe_best(&url).await {
                        Ok((url, br, size, _ext)) => {
                            return Ok(json!({
                                "url": url,
                                "br": if br > 0 { br } else { official.br },
                                "size": if size > 0 { size } else { official.size },
                                "source": "netease",
                                "sourceLabel": "网易云官方",
                                "thirdParty": false,
                                "note": note,
                            }));
                        }
                        Err(e) => {
                            note = Some(format!("官方链接不可用（{}），已尝试第三方音源", e));
                        }
                    }
                } else {
                    note = Some("官方链接为试听片段，已尝试第三方音源".into());
                }
            } else {
                note = Some("官方未返回可播放地址（可能为 VIP 或无版权），已尝试第三方音源".into());
            }
        }
        Err(e) => {
            note = Some(format!("官方接口请求失败（{}），已尝试第三方音源", e));
        }
    }

    let kinds: Vec<SourceKind> = b
        .session
        .get()
        .sources
        .iter()
        .filter_map(|s| SourceKind::parse(s))
        .collect();
    if kinds.is_empty() {
        return Err(BridgeError::new(
            "Business",
            format!(
                "{}；请在设置中至少启用一个第三方音源",
                note.unwrap_or_else(|| "未配置可用的第三方音源".into())
            ),
        ));
    }
    let ctx = parse_ctx(song);
    match b.resolver.resolve(&ctx, &kinds).await {
        Ok(audio) => Ok(json!({
            "url": audio.url,
            "br": audio.br,
            "size": audio.size,
            "source": audio.source,
            "sourceLabel": audio.source_label,
            "thirdParty": true,
            "note": note,
        })),
        Err(failures) => {
            let detail = failures
                .iter()
                .map(|(k, e)| format!("{}：{}", k.label(), e))
                .collect::<Vec<_>>()
                .join("；");
            Err(BridgeError::new(
                "Business",
                format!(
                    "{}{}",
                    note.unwrap_or_else(|| "所有音源解析失败".into()),
                    if detail.is_empty() {
                        String::new()
                    } else {
                        format!("。{}", detail)
                    }
                ),
            ))
        }
    }
}
