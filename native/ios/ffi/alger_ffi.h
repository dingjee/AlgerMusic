#ifndef ALGER_FFI_H
#define ALGER_FFI_H

/*
 * Alger iOS FFI —— alger-bridge 核心（lib）的进程内 C ABI 封装。
 *
 * 协议语义与 macOS stdio 桥接完全一致（响应 {"id",...} / 事件 {"ev",...}），
 * 区别仅在传输：本库把协议搬进进程内（iOS 禁子进程）。
 *
 * 内存约定：
 * - 行回调收到的 line 由本库 malloc，**调用方必须 free()**；
 * - alger_ffi_last_error() 返回借用指针，不得 free。
 */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 行回调：一条完整 JSON 协议行（NUL 结尾 UTF-8）。可从任意线程调用。 */
typedef void (*AlgerFfiLineHandler)(const char *line);

/*
 * 注册 / 替换全局行回调（响应与事件都走这里）。
 * init 之前或之后调用均可；未注册时协议行被丢弃。
 */
void alger_ffi_set_handler(AlgerFfiLineHandler handler);

/*
 * 打开 FFI 实例，返回不透明句柄；失败返回 NULL（原因经
 * alger_ffi_last_error 取）。session_path 必须是 UTF-8 绝对路径
 * （App 容器内，由调用方提供），否则 fail closed。
 */
void *alger_ffi_init(const char *session_path);

/*
 * 入队一次协议请求。**每个 id 恰好一条响应行**（成功 / 业务错误 /
 * ShuttingDown），入队失败也会回错误行，调用方按 id 配对即可。
 * - method：方法名（如 "net.search"）；
 * - params_json：参数 JSON 文本（对象 / null；解析失败回 Decode 行）。
 */
void alger_ffi_call(void *handle, uint64_t id, const char *method, const char *params_json);

/*
 * 关闭实例：有界收束在途请求与下载队列并释放内存。
 * 调用后句柄立即作废，调用方不得再使用（也不要再 free）。
 */
void alger_ffi_shutdown(void *handle);

/* 最近一次失败的线程局部原因（borrowed；不得 free；下次调用前有效）。 */
const char *alger_ffi_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* ALGER_FFI_H */
