/**
 * 主题：浅色 / 深色跟随系统，强调色跟随系统 accent color。
 *
 * - 浅色 / 深色由 CSS 的 `prefers-color-scheme` 媒体查询处理，运行时自动跟随系统；
 * - 强调色通过后端桥接系统强调色（macOS 的 `NSColor.controlAccentColor`、
 *   iOS 的 UIKit 系统动态色）后写入 CSS 变量
 *   （WebKit 对 `AccentColor` 标准属性的支持有限）。
 *
 * 刷新策略：后端在 macOS 上会监听系统强调色变化并推送事件；
 * 但 tao 在 iOS 上不派发 `WindowEvent::ThemeChanged`，因此这里额外在
 * 「系统外观变化」与「应用回到前台」时重新读取一次，
 * 避免在手机上常驻轮询、反复唤醒主线程。
 */

import { listen } from '@tauri-apps/api/event';

import { api } from './api';

/** 主题事件名（后端推送强调色）。 */
const ACCENT_EVENT = 'theme://accent';

/** 是否正在读取强调色（避免并发重复请求）。 */
let refreshing = false;

/** 把 `#RRGGBB` 转成 `R G B` 三元组，便于在 CSS 中做透明度合成。 */
function toRgbTriple(hex: string): string {
  const value = hex.replace('#', '').trim();
  if (value.length === 3) {
    const r = value[0];
    const g = value[1];
    const b = value[2];
    return `${parseInt(r + r, 16)} ${parseInt(g + g, 16)} ${parseInt(b + b, 16)}`;
  }
  if (value.length >= 6) {
    return `${parseInt(value.slice(0, 2), 16)} ${parseInt(value.slice(2, 4), 16)} ${parseInt(
      value.slice(4, 6),
      16,
    )}`;
  }
  return '47 111 235';
}

/** 写入强调色 CSS 变量。 */
export function applyAccent(hex: string): void {
  const root = document.documentElement;
  root.style.setProperty('--accent', hex);
  root.style.setProperty('--accent-rgb', toRgbTriple(hex));
  // 同步更新 <meta name="theme-color">，让窗口标题栏配色跟随强调色
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute('content', hex);
}

/**
 * 重新读取系统强调色。
 *
 * 后端命令是同步命令，在主线程读取系统颜色，因此不会与 UI 线程竞争。
 */
export async function refreshAccent(): Promise<void> {
  if (refreshing) return;
  refreshing = true;
  try {
    const accent = await api.themeAccent();
    if (accent) applyAccent(accent);
  } catch {
    // 取不到时保留当前值（CSS 兜底值）
  } finally {
    refreshing = false;
  }
}

/** 监听系统外观变化（浅色 / 深色切换）。 */
function watchColorScheme(): void {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return;
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  const handler = (): void => {
    void refreshAccent();
  };
  if (typeof media.addEventListener === 'function') {
    media.addEventListener('change', handler);
  } else if (typeof media.addListener === 'function') {
    // 旧版 WebKit（Safari < 14）只提供 addListener
    media.addListener(handler);
  }
}

/** 监听应用回到前台（切回前台时外观可能已变化）。 */
function watchVisibility(): void {
  if (typeof document === 'undefined') return;
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      void refreshAccent();
    }
  });
}

/** 初始化主题：读取当前强调色，并订阅后续变化。 */
export async function initTheme(): Promise<void> {
  await refreshAccent();
  try {
    await listen<{ accent: string }>(ACCENT_EVENT, (event) => {
      if (event.payload?.accent) applyAccent(event.payload.accent);
    });
  } catch {
    // 非 Tauri 环境下忽略
  }
  watchColorScheme();
  watchVisibility();
}

/** 当前配色方案（'light' | 'dark'），仅用于展示与调试。 */
export function currentScheme(): 'light' | 'dark' {
  return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}
