/**
 * 平台判断。
 *
 * 后端快照带 `platform` 字段（`macos` / `ios` / 其它），在快照到达前
 * 用 UA 做兜底判断；两者都不可用时按桌面处理。
 */

import { state } from './store';

/** 从 UA 推断是否 iOS（含 iPadOS 桌面 UA 的触屏判定）。 */
function uaIsIos(): boolean {
  if (typeof navigator === 'undefined') return false;
  const ua = navigator.userAgent ?? '';
  if (/iPhone|iPod/.test(ua)) return true;
  // iPadOS 13+ 默认伪装 macOS UA，用触屏点位数量辅助判断
  if (/iPad/.test(ua)) return true;
  return /Macintosh/.test(ua) && navigator.maxTouchPoints > 1;
}

/** 当前是否运行在 iOS（App 内）。 */
export function isIos(): boolean {
  if (typeof window === 'undefined') return false;
  const platform = state.snapshot?.platform;
  if (platform === 'ios') return true;
  if (platform === 'macos' || platform === 'other') return false;
  return uaIsIos();
}
