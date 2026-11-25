/* ============================================================
   PowerFocus 前端测试底座（零依赖，仅用 node 内置能力）
   v2（48 号轮）：在原 v1 上补齐“交互”所需的 DOM 能力——
     1) 元素级 matches / closest / querySelector(All)：撑住事件委托（ev.target.closest('.row')）
     2) document.querySelectorAll 走 body 子树：撑住 bind() 的 .navbtn / .view 查询
     3) <dialog> 忠实语义：showModal() 在已打开时抛 InvalidStateError；close() 派发 close 事件
     4) fire() 气泡派发助手：从目标沿 parentElement 向上调用监听器，带 preventDefault 记录
     5) getElementById 可预置真实标签（opts.seedTags），否则自动造的节点一律是 DIV，
        测不出 onKeydown 的 INPUT/SELECT/TEXTAREA 屏蔽
     6) setTimeout 加 unref：避免 toast 的 4.2s 定时器把 node --test 进程拖住
     7) __PF 增导出 bind，让测试能跑真实的事件绑定，而不是自己装监听器
   目的：在 Node 里把真实的 web/app.js 跑起来，测真实函数与真实监听器，不做源码正则糊弄。
   做法：
     - 手写一个够用的 DOM 桩（document/element/textNode/classList/localStorage/fetch）
     - 读 app.js，在收尾的 `})();` 之前注入一行导出（测试侧注入，产品代码零改动）
     - 用 vm.runInNewContext 执行，拿到内部函数表
   约束：
     - 不触发 boot()（document.readyState 置 'loading' 且不派发 DOMContentLoaded）
     - 不改 index.html、不改 app.js
   ============================================================ */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

export const HERE = path.dirname(fileURLToPath(import.meta.url));

/** 从 tests/js 往上找仓库根（含 product/v1.00/app/web 的目录） */
export function findRepoRoot(start = HERE) {
  let dir = start;
  for (let i = 0; i < 6; i++) {
    if (fs.existsSync(path.join(dir, 'product', 'v1.00', 'app', 'web', 'app.js'))) return dir;
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  throw new Error('找不到仓库根（product/v1.00/app/web/app.js 不在任何上层目录）');
}

/* ---------------- 最小 DOM ---------------- */

class ClassList {
  constructor(node) { this.node = node; }
  _set() { return new Set(String(this.node.className || '').split(/\s+/).filter(Boolean)); }
  _flush(set) { this.node.className = [...set].join(' '); }
  add(...names) { const s = this._set(); for (const n of names) s.add(n); this._flush(s); }
  remove(...names) { const s = this._set(); for (const n of names) s.delete(n); this._flush(s); }
  contains(name) { return this._set().has(name); }
  toggle(name, force) {
    const s = this._set();
    const want = force === undefined ? !s.has(name) : !!force;
    if (want) s.add(name); else s.delete(name);
    this._flush(s);
    return want;
  }
}

class DomNode {
  constructor(tagName, doc) {
    this.tagName = String(tagName || '').toUpperCase();
    this.ownerDocument = doc;
    this.children = [];
    this._parent = null;
    this.attributes = {};
    this.className = '';
    this.style = {};
    this.dataset = {};
    this.hidden = false;
    this.open = false;
    this.value = '';
    this.checked = false;
    this.id = '';
    this._text = '';
    this._listeners = {};
    this.classList = new ClassList(this);
  }
  /* 真 DOM 里元素必有父节点；桩里延迟造一个，保证 parentElement 永不为 null */
  get parentElement() {
    if (!this._parent) {
      const p = new DomNode('div', this.ownerDocument);
      p.children.push(this);
      this._parent = p;
    }
    return this._parent;
  }
  set parentElement(p) { this._parent = p; }
  get textContent() {
    if (this.children.length === 0) return this._text;
    return this._text + this.children.map((c) => c.textContent).join('');
  }
  set textContent(v) {
    this.children = [];
    this._text = v === null || v === undefined ? '' : String(v);
  }
  appendChild(child) {
    if (!child) return child;
    child.parentElement = this;
    this.children.push(child);
    return child;
  }
  remove() {
    if (!this._parent) return;
    const i = this._parent.children.indexOf(this);
    if (i >= 0) this._parent.children.splice(i, 1);
    this._parent = null;
  }
  setAttribute(k, v) {
    this.attributes[k] = String(v);
    if (k === 'id') this.id = String(v);
    if (k === 'class') this.className = String(v);
    if (k.startsWith('data-')) this.dataset[k.slice(5)] = String(v);
  }
  getAttribute(k) {
    if (k === 'class') return this.className || null;
    if (k === 'id') return this.id || null;
    return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null;
  }
  addEventListener(type, fn) {
    (this._listeners[type] = this._listeners[type] || []).push(fn);
    return fn;
  }
  removeEventListener(type, fn) {
    const arr = this._listeners[type] || [];
    const i = arr.indexOf(fn);
    if (i >= 0) arr.splice(i, 1);
  }
  /* 只支持测试用到的简单选择器：.class / #id / tag / tag[attr] / [attr="v"] */
  matches(sel) {
    if (!sel) return false;
    const s = String(sel).trim();
    if (s[0] === '.') return (' ' + this.className + ' ').indexOf(' ' + s.slice(1) + ' ') >= 0;
    if (s[0] === '#') return this.id === s.slice(1);
    const attr = /^([A-Za-z0-9]+)?\[([^\]=]+)(?:=["']?([^\]"']*)["']?)?\]$/.exec(s);
    if (attr) {
      if (attr[1] && this.tagName !== attr[1].toUpperCase()) return false;
      const v = this.getAttribute(attr[2]);
      return attr[3] === undefined ? v !== null : v === attr[3];
    }
    const tag = /^([A-Za-z0-9]+)$/.exec(s);
    if (tag) return this.tagName === tag[1].toUpperCase();
    return false;
  }
  closest(sel) {
    let n = this;
    while (n && typeof n.matches === 'function') {
      if (n.matches(sel)) return n;
      n = n._parent;
    }
    return null;
  }
  querySelectorAll(sel) {
    const out = [];
    this.walk((n) => { if (n !== this && typeof n.matches === 'function' && n.matches(sel)) out.push(n); });
    return out;
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  /* <dialog> 忠实语义：已打开时再 showModal 抛 InvalidStateError（真浏览器就是这样） */
  showModal() {
    if (this.open) {
      const e = new Error('InvalidStateError: 对话框已打开，不能重复 showModal');
      e.name = 'InvalidStateError';
      throw e;
    }
    this.open = true;
  }
  close() {
    if (!this.open) return;
    this.open = false;
    const ev = { type: 'close', target: this };
    for (const fn of (this._listeners.close || [])) fn(ev);
  }
  /* 测试辅助：本节点子树里所有节点 */
  walk(fn) { fn(this); for (const c of this.children) { if (typeof c.walk === 'function') c.walk(fn); } }
}

class TextNode {
  constructor(text) { this.nodeType = 3; this._text = String(text); this.parentElement = null; this.children = []; }
  get textContent() { return this._text; }
  set textContent(v) { this._text = String(v); }
  remove() { if (this.parentElement) { const i = this.parentElement.children.indexOf(this); if (i >= 0) this.parentElement.children.splice(i, 1); } }
}

function makeDocument(opts = {}) {
  const byId = new Map();
  const created = [];

  const document = {
    readyState: 'loading',            /* 关键：让 app.js 注册监听而不 boot */
    visibilityState: 'visible',
    _listeners: {},
    _byId: byId,
    _created: created,
    createElement(tag) {
      const n = new DomNode(tag, document);
      created.push(n);
      return n;
    },
    createTextNode(text) {
      const t = new TextNode(text);
      created.push(t);
      return t;
    },
    getElementById(id) {
      if (!byId.has(id)) { const n = new DomNode('div', document); n.id = String(id); byId.set(id, n); }
      return byId.get(id);
    },
    querySelector(sel) {
      /* 令牌 meta 是 app.js 启动时唯一读的“文档级”选择器，必须保留 v1 的假 meta */
      if (sel === 'meta[name="pf-token"]') return { content: opts.token === undefined ? 'test-token' : opts.token };
      return document.body.querySelector(sel);
    },
    querySelectorAll(sel) { return document.body.querySelectorAll(sel); },
    addEventListener(type, fn) { (document._listeners[type] = document._listeners[type] || []).push(fn); },
    removeEventListener() {},
  };

  document.documentElement = new DomNode('html', document);
  document.body = new DomNode('body', document);
  document.head = new DomNode('head', document);

  /* 预置真实标签：只管“标签名”，其余与自动造的一致 */
  for (const [id, tag] of Object.entries(opts.seedTags || {})) {
    const n = new DomNode(tag, document);
    n.id = id;
    byId.set(id, n);
  }
  return document;
}

function makeLocalStorage() {
  const m = new Map();
  return {
    getItem(k) { return m.has(k) ? m.get(k) : null; },
    setItem(k, v) { m.set(k, String(v)); },
    removeItem(k) { m.delete(k); },
    clear() { m.clear(); },
    _dump() { return Object.fromEntries(m); },
  };
}

/**
 * 气泡派发：真 DOM 里监听器从 target 沿祖先链依次触发。
 * app.js 的进程表就是靠这个（proc-body 上委托 + 行上直挂）。
 * @returns {object} 事件对象（含 defaultPrevented / _stopped 记录）
 */
export function fire(node, type, extra = {}) {
  const ev = Object.assign({
    type,
    target: node,
    currentTarget: null,
    defaultPrevented: false,
    _stopped: false,
    errors: [],          /* async 监听器里抛的异常记在这，别被静默吞掉 */
  }, extra);
  ev.target = node;
  ev.preventDefault = () => { ev.defaultPrevented = true; };
  ev.stopPropagation = () => { ev._stopped = true; };
  let cur = node;
  while (cur) {
    const arr = (cur._listeners && cur._listeners[type]) || [];
    ev.currentTarget = cur;
    for (const fn of arr) {
      if (ev._stopped) break;
      const r = fn(ev);
      /* async 监听器（如 dblclick 里的 await confirmDialog）不阻塞派发，与浏览器一致；
         异常记进 ev.errors，测试必须断言它为空，否则等于把崩溃藏起来 */
      if (r && typeof r.catch === 'function') r.catch((e) => { ev.errors.push(e); });
    }
    if (ev._stopped) break;
    cur = cur._parent || null;
  }
  return ev;
}

/**
 * 把真实的 app.js 装进 Node 跑起来。
 * @returns {{ pf: object, env: object, source: string }}
 */
export function loadApp(repoRoot, opts = {}) {
  const webDir = path.join(repoRoot, 'product', 'v1.00', 'app', 'web');
  const appPath = path.join(webDir, 'app.js');
  let source = fs.readFileSync(appPath, 'utf8');

  const EXPORTS = [
    'fmt', 'el', 'setText', 'skeleton', 'toggleSidebar', 'toggleTheme', 'onKeydown',
    'toast', 'setLogBadge', 'setBootstrapBadge', 'logLine', 'api', 'confirmDialog',
    'closeDialog', 'switchView', 'renderSnapshot', 'renderVerdict', 'renderTop',
    'renderFocus', 'renderProcessTable', 'selectProcess', 'runCommand', 'guard', 'bind',
    'renderSecurity', 'renderAudit', 'renderBootstrap', 'bsBadgeFor', 'bsOut',
    'renderScan', 'updateScanButton', 'syncScanScope', 'startScan', 'refreshScan',
    'renderPosture', 'renderShield', 'shieldRun', 'shieldApplyRecommended', 'shieldRevertAll', 'dnsCheck',
    'renderModelCard', 'loadPreferences', 'savePreferences', 'loadAbout', 'checkUpdate',
    'exportLogs', 'exportConfig', 'finishOnboard', 'nextOnboard', 'maybeOnboard',
  ];
  const injection = '\n  globalThis.__PF = { ' + EXPORTS.join(', ') + ', __state: () => ({ snapshot, selected, activeView, clientLog, errBadgeCount }) };\n';
  const tail = /\n\s*\}\s*\)\s*\(\s*\)\s*;?\s*$/;
  if (!tail.test(source)) throw new Error('app.js 收尾不是 `})();`，注入点找不到');
  source = source.replace(tail, (m) => injection + m);

  const document = makeDocument(opts);
  const localStorage = makeLocalStorage();
  const fetchCalls = [];
  const fetchImpl = opts.fetch || ((url, init) => {
    fetchCalls.push({ url, init });
    return Promise.resolve({
      ok: true, status: 200,
      headers: { get: () => 'application/json' },
      json: async () => ({ ok: true }),
      text: async () => '',
    });
  });

  /* unref：toast 的 4.2s 清理定时器不该把测试进程拖着不退 */
  const timer = (fn, ms) => {
    const h = setTimeout(fn, ms);
    if (h && typeof h.unref === 'function') h.unref();
    return h;
  };
  const interval = (fn, ms) => {
    const h = setInterval(fn, ms);
    if (h && typeof h.unref === 'function') h.unref();
    return h;
  };

  const sandbox = {
    document,
    localStorage,
    location: { port: opts.port === undefined ? '18080' : opts.port, href: 'http://127.0.0.1:18080/' },
    fetch: fetchImpl,
    setTimeout: timer,
    clearTimeout: (h) => clearTimeout(h),
    setInterval: interval,
    clearInterval: (h) => clearInterval(h),
    AbortController,
    console,
    navigator: { userAgent: 'node' },
  };
  sandbox.window = sandbox;
  sandbox.globalThis = sandbox;
  const ctx = vm.createContext(sandbox);
  vm.runInContext(source, ctx, { filename: 'app.js' });

  const pf = ctx.__PF || sandbox.__PF || sandbox.globalThis.__PF;
  if (!pf) throw new Error('注入失败：app.js 里没拿到 __PF');
  return { pf, env: { document, localStorage, fetchCalls, sandbox }, source };
}

export const VIEW_ORDER_EXPECTED = ['overview', 'processes', 'scenes', 'models', 'security', 'bootstrap', 'settings', 'logs', 'about'];
export const WEB_REL = path.join('product', 'v1.00', 'app', 'web');
