/* ============================================================
   PowerFocus 前端第一套自动化回归（node:test，零依赖）
   跑法：node --test tests/js/
   分组：
     A. 格式化唯一入口 fmt() 的输入契约（本轮 46 号修复点）
     B. 总览首屏不缺字段时不许印 NaN / undefined（本轮 46 号修复点）
     C. api() 的鉴权头与请求体契约（安全底线，行为级验证）
     D. 徽章与 setText 的写入节流
     E. 结构契约：id / 视图 / 命令白名单 / 无 innerHTML / 无内联脚本
   说明：E 组断言失败说明前后端或模板已经不一致，先查改动再改断言。
   ============================================================ */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { loadApp, findRepoRoot, WEB_REL, VIEW_ORDER_EXPECTED } from './pf-dom-stub.mjs';

const REPO = findRepoRoot();
const WEB = path.join(REPO, WEB_REL);
const APP_SRC = fs.readFileSync(path.join(WEB, 'app.js'), 'utf8');
const HTML_SRC = fs.readFileSync(path.join(WEB, 'index.html'), 'utf8');

/* ---------------- A. fmt() ---------------- */

test('A1 fmt：正常数值按位数格式化', () => {
  const { pf } = loadApp(REPO);
  assert.equal(pf.fmt(0), '0.0');
  assert.equal(pf.fmt(12.345), '12.3');
  assert.equal(pf.fmt(12.345, 2), '12.35');
  assert.equal(pf.fmt(99.9, 0), '100');
});

test('A2 fmt：空值一律 "--"，不许吐 NaN/Infinity（46 号修复点）', () => {
  const { pf } = loadApp(REPO);
  for (const v of [null, undefined, NaN, '', 'abc', 'N/A', {}, [], Infinity, -Infinity]) {
    assert.equal(pf.fmt(v), '--', 'fmt(' + JSON.stringify(v) + ') 应为 --，实际 ' + JSON.stringify(pf.fmt(v)));
  }
});

test('A3 fmt：数字字符串仍按数值处理（内核字符串字段容错）', () => {
  const { pf } = loadApp(REPO);
  assert.equal(pf.fmt('12.5'), '12.5');
  assert.equal(pf.fmt('0'), '0.0');
});

/* ---------------- B. 总览首屏 ---------------- */

test('B1 renderSnapshot：空快照不崩、不印 NaN / undefined（46 号修复点）', () => {
  const { pf, env } = loadApp(REPO);
  pf.renderSnapshot({});
  const ids = ['kpi-cpu', 'kpi-mem', 'kpi-mem-x', 'kpi-procs', 'kpi-procs-x', 'kpi-fg', 'kpi-cpu-x'];
  for (const id of ids) {
    const t = env.document.getElementById(id).textContent;
    assert.ok(!/NaN|undefined|Infinity/.test(t), id + ' 出现坏值：' + JSON.stringify(t));
  }
});

test('B2 renderSnapshot：正常快照的数值与单位', () => {
  const { pf, env } = loadApp(REPO);
  pf.renderSnapshot({
    time: '14:30:00', cpu: 42.5, mem_percent: 63.2,
    mem_used_mb: 8192, mem_total_mb: 32768,
    process_count: 231, kernel_alive: true, kernel_version: 'v0.13',
    model_loaded: [], processes: [], foreground_pid: 0,
  });
  const d = env.document;
  assert.equal(d.getElementById('kpi-cpu').textContent, '42.5%');
  assert.equal(d.getElementById('kpi-mem').textContent, '63.2%');
  assert.equal(d.getElementById('kpi-mem-x').textContent, '8 / 32 GB');
  assert.equal(d.getElementById('kpi-procs').textContent, '231');
  assert.equal(d.getElementById('foot-kernel').textContent, 'v0.13');
  assert.equal(d.getElementById('foot-port').textContent, '18080');
  assert.equal(d.getElementById('pill-kernel').textContent, '内核在线');
});

test('B3 renderSnapshot：大内存四舍五入到 GB', () => {
  const { pf, env } = loadApp(REPO);
  pf.renderSnapshot({ cpu: 1, mem_percent: 1, mem_used_mb: 15500, mem_total_mb: 32600 });
  assert.equal(env.document.getElementById('kpi-mem-x').textContent, '15 / 32 GB');
});

/* ---------------- C. api() ---------------- */

test('C1 api：GET 必带 X-PF-Token，且 no-store', async () => {
  const { pf, env } = loadApp(REPO);
  await pf.api('/api/health');
  assert.equal(env.fetchCalls.length, 1);
  const init = env.fetchCalls[0].init;
  assert.equal(init.headers['X-PF-Token'], 'test-token');
  assert.equal(init.method, 'GET');
  assert.equal(init.cache, 'no-store');
  assert.equal(init.body, undefined);
});

test('C2 api：有 body 时补 Content-Type 并 JSON 序列化', async () => {
  const { pf, env } = loadApp(REPO);
  await pf.api('/api/command', { method: 'POST', body: { action: 'unfocus' } });
  const init = env.fetchCalls[0].init;
  assert.equal(init.method, 'POST');
  assert.equal(init.headers['X-PF-Token'], 'test-token');
  assert.equal(init.headers['Content-Type'], 'application/json');
  assert.deepEqual(JSON.parse(init.body), { action: 'unfocus' });
});

test('C3 api：HTTP 非 2xx 抛错并带 status，detail 优先作消息', async () => {
  const repo = REPO;
  const { pf } = loadApp(repo, {
    fetch: async () => ({
      ok: false, status: 403,
      headers: { get: () => 'application/json' },
      json: async () => ({ detail: '权限不足' }),
      text: async () => '',
    }),
  });
  await assert.rejects(() => pf.api('/api/command', { method: 'POST', body: {} }), (e) => {
    assert.equal(e.message, '权限不足');
    assert.equal(e.status, 403);
    return true;
  });
});

/* ---------------- D. 写入节流 ---------------- */

test('D1 setText：文本未变则不写 DOM（避免每帧重排）', () => {
  const { pf, env } = loadApp(REPO);
  const n = env.document.getElementById('foot-kernel');
  let writes = 0;
  let v = n.textContent;
  Object.defineProperty(n, 'textContent', {
    get() { return v; },
    set(x) { writes++; v = x; },
  });
  pf.setText('foot-kernel', 'v0.13');
  pf.setText('foot-kernel', 'v0.13');
  assert.equal(writes, 1, '同值第二次不该再写');
  pf.setText('foot-kernel', 'v0.12');
  assert.equal(writes, 2);
});

test('D2 setLogBadge：0 隐藏，超 99 显示 99+', () => {
  const { pf, env } = loadApp(REPO);
  const b = env.document.getElementById('navbadge-logs');
  pf.setLogBadge(0);
  assert.equal(b.hidden, true);
  pf.setLogBadge(7);
  assert.equal(b.hidden, false);
  assert.equal(b.textContent, '7');
  pf.setLogBadge(120);
  assert.equal(b.textContent, '99+');
});

/* ---------------- E. 结构契约 ---------------- */

test('E1 id 契约：app.js 用到的每个 id 都必须在 index.html 里存在', () => {
  const used = new Set();
  for (const m of APP_SRC.matchAll(/\$\(\s*'([^']+)'\s*\)/g)) used.add(m[1]);
  for (const m of APP_SRC.matchAll(/getElementById\(\s*'([^']+)'\s*\)/g)) used.add(m[1]);
  for (const m of APP_SRC.matchAll(/setText\(\s*'([^']+)'/g)) used.add(m[1]);
  const defined = new Set([...HTML_SRC.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));
  const missing = [...used].filter((id) => !defined.has(id));
  assert.deepEqual(missing, [], '这些 id 在 index.html 里不存在：' + missing.join(', '));
  assert.ok(used.size >= 60, '采集到的 id 太少（' + used.size + '），断言可能失效');
});

test('E2 视图契约：VIEW_ORDER 与 index.html 的 data-view 一一对应', () => {
  const orderMatch = APP_SRC.match(/VIEW_ORDER\s*=\s*\[([^\]]+)\]/);
  assert.ok(orderMatch, '找不到 VIEW_ORDER');
  const order = orderMatch[1].split(',').map((s) => s.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean);
  assert.deepEqual(order, VIEW_ORDER_EXPECTED);
  const views = new Set([...HTML_SRC.matchAll(/data-view="([^"]+)"/g)].map((m) => m[1]));
  assert.deepEqual([...views].sort(), [...order].sort(), 'data-view 与 VIEW_ORDER 不一致');
  const viewSections = (HTML_SRC.match(/class="view/g) || []).length;
  assert.equal(viewSections, order.length, 'section 数量应与视图数量一致');
  const navbtns = (HTML_SRC.match(/class="navbtn"|class="navbtn active"/g) || []).length;
  assert.equal(navbtns, order.length, '导航按钮数量应与视图数量一致');
});

test('E3 命令契约：前端 data-cmd 映射出的每个真命令，内核都必须有 case 分支', () => {
  const mapMatch = APP_SRC.match(/const map\s*=\s*\{([^}]+)\}/);
  assert.ok(mapMatch, '找不到命令映射表 map');
  const map = {};
  for (const m of mapMatch[1].matchAll(/(\w+)\s*:\s*'([^']+)'/g)) map[m[1]] = m[2];
  assert.ok(map.focus_high === 'focus' && map.suspend === 'suspend_process', '映射表结构变了，先核对');
  const kernelPath = path.join(REPO, 'versions', 'v0.13', '电脑算力调度中心_v0.13.ps1');
  const kernel = fs.readFileSync(kernelPath, 'utf8');
  const cases = new Set([...kernel.matchAll(/^\s+'([a-z_]+)'\s*\{/gm)].map((m) => m[1]));
  const missing = Object.values(map).filter((cmd) => !cases.has(cmd));
  assert.deepEqual(missing, [], '内核没有这些命令分支：' + missing.join(', '));
});

test('E4 XSS 契约：app.js 不得用 innerHTML 系列写入', () => {
  for (const bad of [/\.innerHTML\s*=/, /\.outerHTML\s*=/, /insertAdjacentHTML\(\s*'before/]) {
    assert.ok(!bad.test(APP_SRC), 'app.js 出现危险写入：' + bad);
  }
});

test('E5 index.html 无内联脚本（CSP 友好）', () => {
  const tags = [...HTML_SRC.matchAll(/<script([^>]*)>/g)];
  assert.ok(tags.length > 0, 'index.html 应有外链脚本');
  for (const t of tags) {
    assert.ok(/src=/i.test(t[1]), '出现无 src 的内联脚本：' + t[0]);
  }
  assert.ok(!/<script[^>]*>[^<\s]/.test(HTML_SRC), 'script 标签体内不应有代码');
});

test('E6 轮询门控：页面隐藏时必须退出这一轮', () => {
  assert.ok(/document\.visibilityState\s*===\s*'hidden'/.test(APP_SRC), '缺页面隐藏门控，后台会空转');
  assert.ok(/schedulePoll|pollTimer/.test(APP_SRC), '找不到轮询调度');
});

test('E7 index.html 引用的 css/js 全部真实存在', () => {
  const refs = [...HTML_SRC.matchAll(/(?:src|href)="([^"#]+\.(?:js|css))"/g)].map((m) => m[1]);
  assert.ok(refs.length >= 3, '外链资源太少：' + refs.join(', '));
  for (const r of refs) {
    /* index.html 用 /static/ 绝对前缀，服务端把它挂到 web 目录（server.py:347） */
    const rel = r.replace(/^\/static\//, '').replace(/^\.\//, '');
    const p = path.join(WEB, rel);
    assert.ok(fs.existsSync(p), 'index.html 引用了不存在的文件：' + r);
  }
});
