/** 极简 DOM 辅助函数（不依赖任何前端框架）。 */

import { icon, iconLabel, type IconName } from './icons';

type Attrs = Record<string, string | number | boolean | undefined | null>;
type Child = Node | string | number | null | undefined | false;

/** 创建元素。 */
export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs?: Attrs,
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (attrs) {
    for (const [key, value] of Object.entries(attrs)) {
      if (value === undefined || value === null || value === false) continue;
      if (key === 'class') node.className = String(value);
      else if (key === 'text') node.textContent = String(value);
      else if (key === 'html') node.innerHTML = String(value);
      else if (key.startsWith('data-') || key.startsWith('aria-')) {
        node.setAttribute(key, String(value));
      } else if (key === 'disabled' || key === 'checked') {
        if (value) node.setAttribute(key, '');
      } else {
        node.setAttribute(key, String(value));
      }
    }
  }
  append(node, children);
  return node;
}

export function append(parent: Node, children: Child[]): void {
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    parent.appendChild(
      typeof child === 'string' || typeof child === 'number'
        ? document.createTextNode(String(child))
        : child,
    );
  }
}

/** 清空节点内容。 */
export function clear(node: Element): void {
  while (node.firstChild) node.removeChild(node.firstChild);
}

/** 按钮。 */
export function button(
  label: string,
  onClick: () => void,
  attrs?: Attrs,
): HTMLButtonElement {
  const node = el('button', { class: 'btn', type: 'button', ...attrs });
  node.textContent = label;
  node.addEventListener('click', onClick);
  return node;
}

/**
 * 图标按钮。
 *
 * 图标是装饰性的，可访问名称由 `aria-label` 与 `title` 提供，
 * 因此读屏软件与键盘用户都能识别该按钮。
 */
export function iconButton(
  name: IconName,
  onClick: () => void,
  attrs?: Attrs,
  label?: string,
): HTMLButtonElement {
  const accessibleName = label ?? iconLabel(name);
  const node = el('button', {
    class: 'btn btn-icon',
    type: 'button',
    'aria-label': accessibleName,
    title: accessibleName,
    ...attrs,
  });
  node.appendChild(icon(name));
  node.addEventListener('click', onClick);
  return node;
}

/** 带图标与文字的按钮（文字本身即为可访问名称）。 */
export function iconTextButton(
  name: IconName,
  label: string,
  onClick: () => void,
  attrs?: Attrs,
): HTMLButtonElement {
  const node = el('button', {
    class: 'btn',
    type: 'button',
    'aria-label': label,
    title: label,
    ...attrs,
  });
  node.appendChild(icon(name));
  node.appendChild(el('span', { class: 'btn-label', text: label }));
  node.addEventListener('click', onClick);
  return node;
}

/** 输入框。 */
export function input(attrs: Attrs): HTMLInputElement {
  return el('input', { class: 'input', ...attrs });
}

/** 文本域。 */
export function textarea(attrs: Attrs): HTMLTextAreaElement {
  return el('textarea', { class: 'input textarea', ...attrs });
}

/** 全局提示。 */
export function toast(message: string, kind: 'info' | 'error' | 'success' = 'info'): void {
  let host = document.getElementById('toast-host');
  if (!host) {
    host = el('div', { id: 'toast-host', class: 'toast-host' });
    document.body.appendChild(host);
  }
  const node = el('div', { class: `toast toast-${kind}`, text: message });
  host.appendChild(node);
  window.setTimeout(() => {
    node.classList.add('toast-out');
    window.setTimeout(() => node.remove(), 300);
  }, kind === 'error' ? 5200 : 2800);
}

/* ------------------------------------------------------------------ *
 * 应用内弹层：替代 window.prompt / window.confirm
 *
 * 背景：
 * - wry（Wry / WKWebView）没有实现 JS 的 prompt / confirm；
 * - tauri-plugin-dialog 的 confirm 只是 polyfill 出来的 *异步*
 *   window.confirm，返回的是 Promise，取不到同步布尔值；
 * - 早期「从歌单移除」处写成 `if (!window.confirm(...)) return;`，
 *   把 Promise 对象当布尔值用 —— Promise 恒为真，用户点「取消」
 *   依然会发出删除请求（网络歌单现已只读，这条只作为历史背景）。
 *
 * 这里是通用控件（表单 / 确认框），与具体的业务写操作解耦：
 * - 一律用真正的异步 Promise：提交 → resolve 结果；取消 → resolve null / false；
 * - 一次性的完成回调：提交、取消按钮、Esc、点击遮罩都只结算一次；
 * - 打开时捕获焦点、关闭时还原；Tab 键在弹层内循环（焦点陷阱）；
 * - 样式复用 .modal-backdrop / .modal / .card，跟随系统浅色 / 深色主题。
 * ------------------------------------------------------------------ */

/** 下拉选项（`type: 'select'`）。 */
export interface FieldOption {
  /** 内部值（提交给后端）。 */
  value: string;
  /** 选项文字（展示给用户）。 */
  label: string;
}

/** 应用内表单的字段定义。 */
export interface FieldSpec {
  /** 字段名（结果对象的键）。 */
  name: string;
  /** 字段标题。 */
  label: string;
  /** 控件类型：`text`（默认）/ `textarea` / `number`（只接受正整数）/ `select`。 */
  type?: 'text' | 'textarea' | 'number' | 'select';
  placeholder?: string;
  /** 初始值。 */
  value?: string;
  /** 文本域行数（`type: 'textarea'`）。 */
  rows?: number;
  /** 下拉选项（`type: 'select'`）。 */
  options?: FieldOption[];
  /** 为 true 时不允许为空。 */
  required?: boolean;
  /** 自定义校验：返回错误文案表示不通过，返回 null 表示通过。 */
  validate?: (value: string) => string | null;
}

/** 表单控件。 */
type FieldControl = HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement;

/** 弹层骨架。 */
interface ModalShell {
  /** 遮罩（已挂到 document.body）。 */
  backdrop: HTMLElement;
  /** 对话框本体。 */
  dialog: HTMLElement;
  /** 关闭弹层（幂等）：移除 DOM、注销监听、还原焦点。 */
  close: () => void;
}

/**
 * 打开弹层骨架。
 *
 * 统一负责：Esc 取消、焦点捕获 / 还原、点击遮罩取消、Tab 焦点陷阱。
 */
function openModal(
  title: string,
  onCancel: () => void,
  getFocusables: () => HTMLElement[] = () => [],
): ModalShell {
  const previousFocus = document.activeElement as HTMLElement | null;
  const backdrop = el('div', { class: 'modal-backdrop' });
  const dialog = el('div', {
    class: 'modal card',
    role: 'dialog',
    'aria-modal': 'true',
    'aria-label': title,
  });
  dialog.appendChild(el('h3', { class: 'modal-title', text: title }));
  backdrop.appendChild(dialog);

  let closed = false;
  const close = (): void => {
    if (closed) return;
    closed = true;
    document.removeEventListener('keydown', onKeyDown, true);
    backdrop.remove();
    try {
      previousFocus?.focus?.();
    } catch {
      /* 焦点还原失败不影响主流程 */
    }
  };

  const onKeyDown = (event: KeyboardEvent): void => {
    if (event.key === 'Escape') {
      event.preventDefault();
      onCancel();
      return;
    }
    trapTab(event, getFocusables());
  };

  backdrop.addEventListener('click', (event) => {
    // 只有点在遮罩本身（而非弹层内部）时才当作取消
    if (event.target === backdrop) onCancel();
  });
  document.addEventListener('keydown', onKeyDown, true);
  document.body.appendChild(backdrop);

  return { backdrop, dialog, close };
}

/** 把 Tab 焦点限制在弹层内（items 需按 Tab 顺序排列）。 */
function trapTab(event: KeyboardEvent, items: HTMLElement[]): void {
  if (event.key !== 'Tab') return;
  const focusables = items.filter((node) => !node.hasAttribute('disabled'));
  if (focusables.length === 0) return;
  const active = document.activeElement as HTMLElement | null;
  const index = active ? focusables.indexOf(active) : -1;
  let next: HTMLElement | undefined;
  if (event.shiftKey) {
    if (index <= 0) next = focusables[focusables.length - 1];
  } else if (index === -1 || index === focusables.length - 1) {
    next = focusables[0];
  }
  if (next) {
    event.preventDefault();
    next.focus();
  }
}

/**
 * 应用内表单弹层（替代 `window.prompt`）。
 *
 * 提交后 resolve 字段值表（键为字段名）；用户取消（取消按钮 / Esc / 点击遮罩）
 * 时 resolve `null` —— 调用方必须先判空再决定是否发起写请求。
 */
export function requestFields(
  title: string,
  fields: FieldSpec[],
): Promise<Record<string, string> | null> {
  return new Promise((resolve) => {
    let shell: ModalShell | null = null;
    let settled = false;
    const focusables: HTMLElement[] = [];

    const finish = (value: Record<string, string> | null): void => {
      if (settled) return;
      settled = true;
      shell?.close();
      resolve(value);
    };

    shell = openModal(title, () => finish(null), () => focusables);

    const form = el('form', { class: 'modal-form', novalidate: 'true' });
    const controls = new Map<string, FieldControl>();
    const error = el('p', { class: 'modal-error', role: 'status', 'aria-live': 'polite' });

    for (const field of fields) {
      const id = `modal-field-${field.name}`;
      const wrap = el('div', { class: 'modal-field' });
      wrap.appendChild(el('label', { class: 'field-label', text: field.label, for: id }));
      let control: FieldControl;
      if (field.type === 'textarea') {
        control = textarea({
          rows: field.rows ?? 3,
          placeholder: field.placeholder ?? undefined,
        });
        control.value = field.value ?? '';
      } else if (field.type === 'select') {
        // 下拉：选项文字给用户看，内部值（歌单 ID 之类）由调用方决定
        control = el('select', { class: 'input', name: field.name });
        for (const option of field.options ?? []) {
          control.appendChild(el('option', { value: option.value, text: option.label }));
        }
        if (field.value) control.value = field.value;
      } else {
        control = input({
          type: 'text',
          placeholder: field.placeholder ?? undefined,
          inputmode: field.type === 'number' ? 'numeric' : undefined,
          autocomplete: 'off',
          spellcheck: 'false',
        });
        control.value = field.value ?? '';
      }
      control.setAttribute('id', id);
      wrap.appendChild(control);
      form.appendChild(wrap);
      controls.set(field.name, control);
      focusables.push(control);
    }

    const submit = el('button', { class: 'btn btn-primary', type: 'submit', text: '确定' });
    const cancel = button('取消', () => finish(null));
    const actions = el('div', { class: 'row gap modal-actions' }, submit, cancel);
    form.appendChild(error);
    form.appendChild(actions);

    const submitForm = (): void => {
      const values: Record<string, string> = {};
      for (const field of fields) {
        const control = controls.get(field.name);
        const value = (control?.value ?? '').trim();
        if (field.type === 'select') {
          const options = field.options ?? [];
          if (options.length === 0) {
            error.textContent = `暂无可选项：${field.label}`;
            control?.focus();
            return;
          }
          if (!value || !options.some((option) => option.value === value)) {
            error.textContent = `请选择${field.label}`;
            control?.focus();
            return;
          }
        } else {
          if (field.required && !value) {
            error.textContent = `请填写${field.label}`;
            control?.focus();
            return;
          }
          if (field.type === 'number') {
            const num = Number(value);
            if (!value || !Number.isInteger(num) || num <= 0) {
              error.textContent = `${field.label}需为正整数`;
              control?.focus();
              return;
            }
          }
        }
        const custom = field.validate?.(value);
        if (custom) {
          error.textContent = custom;
          control?.focus();
          return;
        }
        values[field.name] = value;
      }
      error.textContent = '';
      finish(values);
    };

    submit.addEventListener('click', (event) => {
      // 阻止浏览器默认提交（表单自己的 submit 事件会走同一条路径）
      event.preventDefault();
      submitForm();
    });
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      submitForm();
    });

    shell.dialog.appendChild(form);
    focusables.push(submit, cancel);
    focusables[0]?.focus();
  });
}

/**
 * 应用内确认框（替代 `window.confirm`）。
 *
 * 用户点「确定」resolve `true`；取消按钮 / Esc / 点击遮罩 resolve `false`。
 */
export function confirmAction(message: string): Promise<boolean> {
  return new Promise((resolve) => {
    let shell: ModalShell | null = null;
    let settled = false;
    const focusables: HTMLElement[] = [];

    const finish = (ok: boolean): void => {
      if (settled) return;
      settled = true;
      shell?.close();
      resolve(ok);
    };

    shell = openModal('请确认', () => finish(false), () => focusables);
    shell.dialog.appendChild(el('p', { class: 'modal-message', text: message }));

    const ok = el('button', { class: 'btn btn-primary', type: 'button', text: '确定' });
    const cancel = button('取消', () => finish(false));
    ok.addEventListener('click', () => finish(true));
    const actions = el('div', { class: 'row gap modal-actions' }, ok, cancel);
    shell.dialog.appendChild(actions);

    focusables.push(ok, cancel);
    ok.focus();
  });
}
