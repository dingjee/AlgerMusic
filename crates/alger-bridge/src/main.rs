//! Alger 原生桥接进程：stdin/stdout JSON 行 **宿主**。
//!
//! 核心（Bridge / dispatch / 协议语义）在 `lib.rs`，与 iOS FFI
//! （`crates/alger-ffi`）共用；本文件只做进程级的事：参数解析
//! （`--session-path` fail closed）、stdio reader/writer、退出收束。

use std::path::PathBuf;
use std::sync::Arc;

use alger_bridge::{dispatch, shutting_down_response, Bridge, Responder};
use serde_json::{json, Value};
use tokio::sync::mpsc;

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

    // 会话与客户端等核心构造在 lib 的 `Bridge::open`（iOS FFI 进程内复用
    // 同一份）。--session-path 显式指定时用它（测试隔离）；不 repurpose
    // HOME，避免触到真实 profile；参数不合法 fail closed（审查 E0-3）。
    let session_path = match session_path_arg() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("alger-bridge: {}", e);
            std::process::exit(2);
        }
    };
    let bridge = Arc::new(Bridge::open(session_path, tx.clone()));

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

