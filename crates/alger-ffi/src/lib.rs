//! Alger iOS FFI：进程内复用 `alger-bridge` 的核心（`Bridge` / `dispatch`）。
//!
//! iOS 禁止 fork/exec，因此不走 stdio 子进程，而是把同一套协议 **搬进
//! 进程内**：Swift 注册一个行回调，FFI 把 **每一条外发协议行**（响应
//! `{"id",...}` 与事件 `{"ev",...}`）以 JSON 文本交给它。
//!
//! # C ABI 约定
//!
//! - `alger_ffi_init(session_path)` → 不透明句柄（` *mut AlgerFfi`）；
//!   `session_path` 必须是 **UTF-8 绝对路径**（App 容器内，Swift 提供；
//!   fail closed，不合法返回 null，原因经 `alger_ffi_last_error()` 取）。
//! - `alger_ffi_call(h, id, method, params_json)`：入队一次请求；
//!   **每个 id 恰好一条响应行**（成功 / 业务错误 / ShuttingDown）。
//! - `alger_ffi_shutdown(h)`：有界等待在途请求，超时回 ShuttingDown 并
//!   中止任务；下载队列在块边界暂停并持久化可恢复状态。调用后句柄作废，
//!   Swift 侧必须置 nil 且不再使用。
//! - 回调收到的 `*const c_char` 是 `CString::into_raw` 转移的所有权：
//!   **由 Swift 侧 `free()` 释放**（测试里对应 `CString::from_raw`）。
//! - 回调可能从任意工作线程触发；Swift 侧必须自行派发到它的队列。
//! - 错误字符串（`alger_ffi_last_error`）是线程局部借用指针：
//!   **不得 free**，在下一次 FFI 调用前有效。
//!
//! # 与 macOS stdio 桥接的关系
//!
//! 方法名、参数、响应 / 事件结构、错误码、exactly-once 语义
//! （`Responder` 先发为准）完全一致——Swift 侧的协议解析层可两地共用。

use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use alger_bridge::{dispatch, shutting_down_response, Bridge, Responder};
use parking_lot::Mutex;
use serde_json::{json, Value};
use tokio::sync::{mpsc, Notify};

/// 行回调：`line` 是一条完整 JSON 协议行（NUL 结尾 UTF-8）。
///
/// - 所有权转移给调用方：Swift 用完后必须 `free()`；
/// - 可能从任意线程调用。
pub type AlgerFfiLineHandler = extern "C" fn(*const c_char);

/// 全局行回调（iOS 单例桥接；测试用互斥串行化）。
static LINE_HANDLER: AtomicHandler = AtomicHandler::new();

struct AtomicHandler(AtomicBool, std::sync::atomic::AtomicUsize);

impl AtomicHandler {
    const fn new() -> Self {
        AtomicHandler(AtomicBool::new(false), std::sync::atomic::AtomicUsize::new(0))
    }
    fn set(&self, h: AlgerFfiLineHandler) {
        self.1
            .store(h as usize, std::sync::atomic::Ordering::SeqCst);
        self.0.store(true, std::sync::atomic::Ordering::SeqCst);
    }
    fn clear(&self) {
        self.0.store(false, std::sync::atomic::Ordering::SeqCst);
    }
    fn get(&self) -> Option<AlgerFfiLineHandler> {
        if self.0.load(std::sync::atomic::Ordering::SeqCst) {
            // SAFETY：仅在 set() 之后读取；usize 保存的是有效 fn 指针。
            let p = self.1.load(std::sync::atomic::Ordering::SeqCst);
            Some(unsafe { std::mem::transmute::<usize, AlgerFfiLineHandler>(p) })
        } else {
            None
        }
    }
}

/// 把一条协议行交给回调；回调未注册时丢弃（诊断走 stderr，不回传凭证）。
fn emit_line(value: &Value) {
    let Ok(line) = serde_json::to_string(value) else {
        eprintln!("alger-ffi: 协议行序列化失败（跳过）");
        return;
    };
    let c_line = CString::new(line).expect("JSON 不含 NUL");
    if let Some(handler) = LINE_HANDLER.get() {
        handler(c_line.into_raw());
    } else {
        eprintln!("alger-ffi: 行回调未注册，丢弃一行");
    }
}

thread_local! {
    static LAST_ERROR: std::cell::RefCell<Option<CString>> = const { std::cell::RefCell::new(None) };
}

fn set_last_error(message: impl Into<String>) {
    LAST_ERROR.with(|e| *e.borrow_mut() = Some(CString::new(message.into()).expect("消息不含 NUL")));
}

fn ok_last_error() {
    LAST_ERROR.with(|e| *e.borrow_mut() = None);
}

/// 有界等待时长（测试可用 ALGER_FFI_EXIT_WAIT_MS 覆盖）。
fn exit_wait() -> std::time::Duration {
    let ms = std::env::var("ALGER_FFI_EXIT_WAIT_MS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(10_000)
        .min(120_000);
    std::time::Duration::from_millis(ms)
}

/// FFI 实例：一个独立桥接核心 + 自己的 tokio 运行时。
///
/// Swift 句柄即 `*mut AlgerFfi`；`shutdown` 消费并释放它。
pub struct AlgerFfi {
    rt: tokio::runtime::Runtime,
    bridge: Arc<Bridge>,
    responder: Responder,
    /// seq → 请求 id（退出时为仍**没答**的请求补 ShuttingDown）。
    in_flight: Arc<Mutex<HashMap<u64, u64>>>,
    handles: Arc<Mutex<HashMap<u64, tokio::task::JoinHandle<()>>>>,
    notify: Arc<Notify>,
    seq_gen: std::sync::atomic::AtomicU64,
    shutting_down: AtomicBool,
}

impl AlgerFfi {
    fn new(session_path: &str) -> Result<AlgerFfi, String> {
        let path = std::path::PathBuf::from(session_path);
        if !path.is_absolute() {
            return Err(format!(
                "session_path 必须是绝对路径（收到 {}）",
                path.display()
            ));
        }
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("tokio runtime 构建失败：{e}"))?;
        let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
        let bridge = Arc::new(Bridge::open(Some(path), tx.clone()));
        let responder = Responder {
            tx,
            answered: Arc::new(parking_lot::Mutex::new(std::collections::HashSet::new())),
        };
        // 外发通道（响应 + 事件）→ 行回调。
        rt.spawn(async move {
            while let Some(value) = rx.recv().await {
                emit_line(&value);
            }
        });
        Ok(AlgerFfi {
            rt,
            bridge,
            responder,
            in_flight: Arc::new(Mutex::new(HashMap::new())),
            handles: Arc::new(Mutex::new(HashMap::new())),
            notify: Arc::new(Notify::new()),
            seq_gen: std::sync::atomic::AtomicU64::new(0),
            shutting_down: AtomicBool::new(false),
        })
    }

    fn spawn_call(&self, id: u64, method: String, params: Value) {
        let seq = self.seq_gen.fetch_add(1, Ordering::Relaxed);
        self.in_flight.lock().insert(seq, id);
        let bridge = Arc::clone(&self.bridge);
        let responder = Responder {
            tx: self.responder.tx.clone(),
            answered: Arc::clone(&self.responder.answered),
        };
        let in_flight = Arc::clone(&self.in_flight);
        let handles = Arc::clone(&self.handles);
        let notify = Arc::clone(&self.notify);
        let handle = self.rt.spawn(async move {
            let result = dispatch(&bridge, &method, &params).await;
            let response = match result {
                Ok(r) => json!({"id": id, "ok": true, "r": r}),
                Err(e) => json!({"id": id, "ok": false, "e": e.into_value()}),
            };
            responder.respond(seq, response);
            in_flight.lock().remove(&seq);
            handles.lock().remove(&seq);
            notify.notify_waiters();
        });
        self.handles.lock().insert(seq, handle);
    }

    fn shutdown(&self) {
        self.shutting_down.store(true, Ordering::SeqCst);
        // 有界等待在途请求完成；超时未答的回 ShuttingDown 并中止任务
        // （与 macOS stdio 版退出路径同语义：每个已接受 id 恰好一个结果）。
        let deadline = std::time::Instant::now() + exit_wait();
        loop {
            let pending: Vec<(u64, u64)> =
                self.in_flight.lock().iter().map(|(s, i)| (*s, *i)).collect();
            if pending.is_empty() {
                break;
            }
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                eprintln!(
                    "alger-ffi: {} 个在途请求未在有界时间内完成，回 ShuttingDown 并中止",
                    pending.len()
                );
                for (s, i) in &pending {
                    self.responder.respond(*s, shutting_down_response(*i));
                }
                self.bridge
                    .cancel
                    .store(true, std::sync::atomic::Ordering::Relaxed);
                for (s, h) in self.handles.lock().iter() {
                    if pending.iter().any(|(ps, _)| ps == s) {
                        h.abort();
                    }
                }
                break;
            }
            let notified = self.notify.notified();
            self.rt.block_on(async {
                tokio::pin!(notified);
                notified.as_mut().enable();
                if self.in_flight.lock().is_empty() {
                    return;
                }
                let _ = tokio::time::timeout(remaining, notified).await;
            });
        }
        // 下载收束：在途下载暂停、持久化可恢复状态（事件经外发通道先行）。
        if let Some(dlq) = &self.bridge.dlq {
            let _remaining = dlq.begin_shutdown(std::time::Duration::from_secs(5));
        }
        // 有界排空外发通道：drain 任务跑在本运行时上，若队列未清空就
        // drop 运行时，残余行（ShuttingDown / dl 收束事件）会丢失。
        // 固定短暂等待（与 macOS writer 的 2s 有界等待同思路；残余行
        // 只有几条，300ms 足够调度一轮 drain）。
        self.rt.block_on(async {
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        });
    }
}

/// 打开 FFI 实例。
///
/// - `session_path`：UTF-8 绝对路径（App 容器内，由 Swift 提供）；
///   不合法 / 运行时不起来 → null（原因经 `alger_ffi_last_error` 取）。
/// - 可在 init **之前**注册行回调；事件不会在 init 期间产生。
#[no_mangle]
pub extern "C" fn alger_ffi_init(session_path: *const c_char) -> *mut AlgerFfi {
    ok_last_error();
    let Some(raw) = (unsafe { session_path.as_ref() }) else {
        set_last_error("session_path 不能为 null");
        return std::ptr::null_mut();
    };
    let path = match unsafe { CStr::from_ptr(raw) }.to_str() {
        Ok(s) => s.to_owned(),
        Err(_) => {
            set_last_error("session_path 不是合法 UTF-8");
            return std::ptr::null_mut();
        }
    };
    match AlgerFfi::new(&path) {
        Ok(instance) => Box::into_raw(Box::new(instance)),
        Err(e) => {
            set_last_error(e);
            std::ptr::null_mut()
        }
    }
}

/// 注册 / 替换全局行回调（响应与事件都走这里）。
#[no_mangle]
pub extern "C" fn alger_ffi_set_handler(handler: Option<AlgerFfiLineHandler>) {
    match handler {
        Some(h) => LINE_HANDLER.set(h),
        None => LINE_HANDLER.clear(),
    }
}

/// 入队一次协议请求。
///
/// **每个 id 恰好一条响应行**：入队失败（shutdown 后 / 参数不合法）也会
/// 回一条明确的错误行，Swift 侧按 id 配对即可，无需轮询返回值。
///
/// - `method`：方法名（如 `"net.search"`）；
/// - `params_json`：参数 JSON 文本（`null` / 对象均可；解析失败回 Decode 行）。
#[no_mangle]
pub extern "C" fn alger_ffi_call(
    handle: *mut AlgerFfi,
    id: u64,
    method: *const c_char,
    params_json: *const c_char,
) {
    let Some(instance) = (unsafe { handle.as_ref() }) else {
        return; // 句柄作废后再调用：无 id 归属，静默丢弃（Swift 不得如此用）
    };
    let method = unsafe { method.as_ref() }.and_then(|m| unsafe { CStr::from_ptr(m) }.to_str().ok());
    let params = unsafe { params_json.as_ref() }
        .and_then(|p| unsafe { CStr::from_ptr(p) }.to_str().ok());
    let (Some(method), Some(params)) = (method, params) else {
        emit_line(&json!({
            "id": id,
            "ok": false,
            "e": { "code": "Decode", "message": "method/params 不是合法 UTF-8" },
        }));
        return;
    };
    if instance.shutting_down.load(Ordering::SeqCst) {
        emit_line(&shutting_down_response(id));
        return;
    }
    let params = serde_json::from_str::<Value>(params).unwrap_or(Value::Null);
    instance.spawn_call(id, method.to_owned(), params);
}

/// 关闭实例：有界收束在途请求与下载队列，然后释放运行时与内存。
///
/// 调用后句柄 **立即作废**；Swift 侧必须将变量置 nil 并停止一切调用。
#[no_mangle]
pub extern "C" fn alger_ffi_shutdown(handle: *mut AlgerFfi) {
    if handle.is_null() {
        return;
    }
    // SAFETY：调用方保证句柄有效且只 shutdown 一次。
    let instance = unsafe { Box::from_raw(handle) };
    instance.shutdown();
    // 外发发送方随 instance 丢弃，drain 任务自然结束；drop 运行时收束线程。
}

/// 最近一次失败的线程局部原因（borrowed；不得 free；下次调用前有效）。
#[no_mangle]
pub extern "C" fn alger_ffi_last_error() -> *const c_char {
    LAST_ERROR.with(|e| match &*e.borrow() {
        Some(cs) => cs.as_ptr(),
        None => std::ptr::null(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc as std_mpsc;

    /// 测试互斥：全局行回调是进程级共享，测试串行执行。
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    struct HandlerGuard;

    impl HandlerGuard {
        fn install() -> (HandlerGuard, std_mpsc::Receiver<String>) {
            let (tx, rx) = std_mpsc::channel::<String>();
            let tx = Box::into_raw(Box::new(tx));
            extern "C" fn trampoline(line: *const c_char) {
                // SAFETY：指针来自 emit_line 的 CString::into_raw；此处回收。
                let c = unsafe { CString::from_raw(line as *mut c_char) };
                let s = c.to_string_lossy().into_owned();
                let tx = unsafe { &*(TRAMPOLINE_TX.load(Ordering::SeqCst) as *const std_mpsc::Sender<String>) };
                let _ = tx.send(s);
            }
            static TRAMPOLINE_TX: std::sync::atomic::AtomicUsize =
                std::sync::atomic::AtomicUsize::new(0);
            TRAMPOLINE_TX.store(tx as usize, Ordering::SeqCst);
            LINE_HANDLER.set(trampoline);
            (HandlerGuard, rx)
        }
    }

    impl Drop for HandlerGuard {
        fn drop(&mut self) {
            LINE_HANDLER.clear();
        }
    }

    fn temp_session_path(tag: &str) -> String {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir()
            .join(format!("alger-ffi-test-{}-{}-{}", std::process::id(), nanos, tag))
            .join("session.json")
            .to_string_lossy()
            .into_owned()
    }

    fn wait_line(rx: &std_mpsc::Receiver<String>, id: u64) -> Value {
        loop {
            let line = rx
                .recv_timeout(std::time::Duration::from_secs(30))
                .expect("应收到协议行");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id").and_then(|i| i.as_u64()) == Some(id) {
                return v;
            }
        }
    }

    #[test]
    fn init_rejects_relative_and_bad_utf8_paths() {
        let _lock = TEST_LOCK.lock();
        let _guard = HandlerGuard::install();
        ok_last_error();
        let rel = CString::new("relative/session.json").unwrap();
        assert!(alger_ffi_init(rel.as_ptr()).is_null());
        let err = unsafe { CStr::from_ptr(alger_ffi_last_error()) }.to_string_lossy();
        assert!(err.contains("绝对路径"), "实际：{err}");
        // 非法 UTF-8 字节
        let bad = [0x66_u8, 0x6f, 0x6f, 0x80, 0x00];
        assert!(alger_ffi_init(bad.as_ptr() as *const c_char).is_null());
        let err = unsafe { CStr::from_ptr(alger_ffi_last_error()) }.to_string_lossy();
        assert!(err.contains("UTF-8"), "实际：{err}");
    }

    #[test]
    fn unknown_method_round_trips_through_handler() {
        let _lock = TEST_LOCK.lock();
        let (_guard, rx) = HandlerGuard::install();
        let path = temp_session_path("unknown");
        let c_path = CString::new(path.clone()).unwrap();
        let handle = alger_ffi_init(c_path.as_ptr());
        assert!(!handle.is_null());
        alger_ffi_call(
            handle,
            42,
            CString::new("bogus.method").unwrap().as_ptr(),
            CString::new("{}").unwrap().as_ptr(),
        );
        let v = wait_line(&rx, 42);
        assert_eq!(v["ok"], false);
        assert_eq!(v["e"]["code"], "Unsupported");
        alger_ffi_shutdown(handle);
        // 会话文件已被创建（父目录自动建）
        assert!(std::path::Path::new(&path).exists());
    }

    #[test]
    fn top_playlists_is_readonly_and_anonymous() {
        let _lock = TEST_LOCK.lock();
        let (_guard, rx) = HandlerGuard::install();
        let c_path = CString::new(temp_session_path("toplists")).unwrap();
        let handle = alger_ffi_init(c_path.as_ptr());
        assert!(!handle.is_null());
        alger_ffi_call(
            handle,
            7,
            CString::new("net.topPlaylists").unwrap().as_ptr(),
            CString::new(r#"{"limit":3,"offset":0}"#).unwrap().as_ptr(),
        );
        let v = wait_line(&rx, 7);
        if v["ok"] == true {
            assert!(v["r"]["playlists"].is_array());
        } else {
            let code = v["e"]["code"].as_str().unwrap_or_default();
            assert_eq!(code, "Network", "匿名公开歌单只应因网络失败：{v}");
        }
        alger_ffi_shutdown(handle);
    }

    #[test]
    fn in_flight_call_gets_shutting_down_on_shutdown() {
        let _lock = TEST_LOCK.lock();
        let (_guard, rx) = HandlerGuard::install();
        // test.slow 是桥接的测试钩子（审查 E1 语义），需要显式开环境开关。
        std::env::set_var("ALGER_BRIDGE_TEST_HOOKS", "1");
        let c_path = CString::new(temp_session_path("shutdown")).unwrap();
        let handle = alger_ffi_init(c_path.as_ptr());
        assert!(!handle.is_null());
        // 慢请求在途时立即 shutdown → 恰好一条 ShuttingDown（不发成功结果）。
        // 有界等待设得比慢请求短：超时未答 → ShuttingDown 并中止任务。
        std::env::set_var("ALGER_FFI_EXIT_WAIT_MS", "500");
        alger_ffi_call(
            handle,
            9,
            CString::new("test.slow").unwrap().as_ptr(),
            CString::new(r#"{"ms":10000}"#).unwrap().as_ptr(),
        );
        alger_ffi_shutdown(handle);
        let v = wait_line(&rx, 9);
        assert_eq!(v["ok"], false);
        assert_eq!(v["e"]["code"], "ShuttingDown");
    }
}
