/* ============================================================
   48 号轮 · 前端交互层回归（真实 app.js + 真实监听器，零依赖）
   覆盖四组：
     A. 导航与键盘：.navbtn 点击、1-8 数字、[_折叠、输入框/弹窗屏蔽
     B. 确认对话框：文案与 danger 样式、OK/取消/Esc 的 resolve 语义、连开两次不串号
     C. 进程选中：总览卡片 → 进程视图（48 号修复点）、行点击、双击确认与取消
     D. 结构契约：不再有 selected 旁路直写、#proc-who 默认文案、dialogResolve 唯一入口
     E. 设置页失败路径（49 号）：读失败禁保存、回填、保存体、400 重试、清除密钥、守卫结构
     G. 安全态势渲染守卫（51 号）：空 payload、分段缺失、坏类型、正常文案、结构契约
   说明：失败先看是哪组——A/B 红说明绑定层坏了，C 红说明选中链路坏了，
         D 红说明有人又写了第二条状态旁路。
   ============================================================ */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { loadApp, findRepoRoot, fire, VIEW_ORDER_EXPECTED, WEB_REL } from './pf-dom-stub.mjs';

const REPO = findRepoRoot();
const WEB = path.join(REPO, WEB_REL);
const APP_SRC = fs.readFileSync(path.join(WEB, 'app.js'), 'utf8');
const HTML_SRC = fs.readFileSync(path.join(WEB, 'index.html'), 'utf8');

const SNAP = {
  time: '15:40:00', cpu: 40, mem_percent: 50, mem_used_mb: 4096, mem_total_mb: 8192,
  process_count: 3, kernel_alive: true, kernel_version: 'v0.13', model_loaded: [], foreground_pid: 0,
  processes: [
    { pid: 111, name: 'alpha.exe', cpu: 30, mem_mb: 900 },
    { pid: 222, name: 'beta.exe', cpu: 10, mem_mb: 120 },
    { pid: 333, name: 'gamma.exe', cpu: 5, mem_mb: 24 },
  ],
};

const tick = () => new Promise((r) => setTimeout(r, 0));

/** 造一个“已经 bind 过”的界面：navbtn + view 全挂到 body 上（数量跟随 VIEW_ORDER_EXPECTED） */
function world(opts) {
  const { pf, env } = loadApp(REPO, Object.assign({ seedTags: { 'proc-search': 'INPUT' } }, opts || {}));
  const doc = env.document;
  const navs = [];
  const views = [];
  for (const v of VIEW_ORDER_EXPECTED) {
    const n = doc.createElement('button');
    n.className = 'navbtn';
    n.dataset.view = v;
    doc.body.appendChild(n);
    navs.push(n);
    const w = doc.createElement('div');
    w.className = 'view';
    w.dataset.view = v;
    doc.body.appendChild(w);
    views.push(w);
  }
  pf.bind();
  return { pf, env, doc, navs, views };
}

const activeOf = (arr) => arr.filter((n) => n.classList.contains('active')).map((n) => n.dataset.view);

/* ---------------- A. 导航与键盘 ---------------- */

test('A1 每个 navbtn 点击都切到自己的视图，且 active 集合唯一', () => {
  const { pf, navs, views } = world();
  for (let i = 0; i < VIEW_ORDER_EXPECTED.length; i++) {
    fire(navs[i], 'click');
    const v = VIEW_ORDER_EXPECTED[i];
    assert.equal(pf.__state().activeView, v, '点第 ' + (i + 1) + ' 个应切到 ' + v);
    assert.deepEqual(activeOf(navs), [v], 'navbtn active 应只有 ' + v);
    assert.deepEqual(activeOf(views), [v], 'view active 应只有 ' + v);
  }
});

test('A2 数字键 1-9 切视图，越界键不动', () => {
  const { pf, doc, navs, views } = world();
  for (let i = 1; i <= VIEW_ORDER_EXPECTED.length; i++) {
    fire(doc, 'keydown', { key: String(i) });
    assert.equal(pf.__state().activeView, VIEW_ORDER_EXPECTED[i - 1]);
  }
  fire(doc, 'keydown', { key: '0' });
  fire(doc, 'keydown', { key: 'x' });
  const last = VIEW_ORDER_EXPECTED[VIEW_ORDER_EXPECTED.length - 1];
  assert.equal(pf.__state().activeView, last, '越界数字不该切走当前视图');
  assert.deepEqual(activeOf(views), [last]);
  assert.deepEqual(activeOf(navs), [last]);
});

test('A3 [_ 折叠侧栏：class 与 localStorage 一起变', () => {
  const { doc, env } = world();
  assert.equal(doc.body.classList.contains('sb-min'), false);
  fire(doc, 'keydown', { key: '[' });
  assert.equal(doc.body.classList.contains('sb-min'), true);
  assert.equal(env.localStorage.getItem('pf_sidebar'), '1');
  fire(doc, 'keydown', { key: '[' });
  assert.equal(doc.body.classList.contains('sb-min'), false);
  assert.equal(env.localStorage.getItem('pf_sidebar'), '');
});

test('A4 输入框聚焦或弹窗打开时，数字键不劫持', () => {
  const { pf, doc } = world();
  fire(doc, 'keydown', { key: '2' });
  assert.equal(pf.__state().activeView, 'processes');
  const input = doc.getElementById('proc-search');
  assert.equal(input.tagName, 'INPUT', 'seedTags 没生效，测不到输入框屏蔽');
  fire(input, 'keydown', { key: '5' });
  assert.equal(pf.__state().activeView, 'processes', '输入框里按 5 不该切视图');
  pf.confirmDialog('占位', '占位', '好', false);
  fire(doc, 'keydown', { key: '6' });
  assert.equal(pf.__state().activeView, 'processes', '弹窗打开时数字键不该切视图');
  pf.closeDialog(false);
});

/* ---------------- B. 确认对话框 ---------------- */

test('B1 confirmDialog：文案、按钮标签、danger 样式都对，且只打开一次', () => {
  const { pf, doc } = world();
  const p = pf.confirmDialog('删除密钥', '这是正文', '清除', true);
  const dlg = doc.getElementById('dlg');
  assert.equal(dlg.open, true);
  assert.equal(doc.getElementById('dlg-title').textContent, '删除密钥');
  assert.equal(doc.getElementById('dlg-body').textContent, '这是正文');
  assert.equal(doc.getElementById('dlg-ok').textContent, '清除');
  assert.equal(doc.getElementById('dlg-ok').className, 'btn danger');
  pf.closeDialog(false);
  const p2 = pf.confirmDialog('普通', '正文2', '确认', false);
  assert.equal(doc.getElementById('dlg-ok').className, 'btn primary', '上一次的 danger 不该残留');
  pf.closeDialog(false);
  return Promise.all([p, p2]);
});

test('B2 点“确认”resolve(true)，点“取消”resolve(false)，各只一次', async () => {
  const { pf, doc } = world();
  const got = [];
  pf.confirmDialog('t', 'b', '执行', false).then((v) => got.push(v));
  fire(doc.getElementById('dlg-ok'), 'click');
  await tick();
  assert.deepEqual(got, [true]);
  assert.equal(doc.getElementById('dlg').open, false);
  fire(doc.getElementById('dlg-ok'), 'click');   /* 已关闭后再点，不该再 resolve 一次 */
  await tick();
  assert.deepEqual(got, [true], '对话框已关闭后重复点击不该二次 resolve');

  pf.confirmDialog('t2', 'b2', '执行', false).then((v) => got.push(v));
  fire(doc.getElementById('dlg-cancel'), 'click');
  await tick();
  assert.deepEqual(got, [true, false]);
});

test('B3 Esc（cancel 事件）：阻止原生关闭 + resolve(false)', async () => {
  const { pf, doc } = world();
  const got = [];
  pf.confirmDialog('t', 'b', '执行', false).then((v) => got.push(v));
  const ev = fire(doc.getElementById('dlg'), 'cancel');
  await tick();
  assert.equal(ev.defaultPrevented, true, '不 preventDefault 会先原生关一次、再走 closeDialog 关一次');
  assert.deepEqual(got, [false]);
  assert.equal(doc.getElementById('dlg').open, false);
});

test('B4 连开两次（第一次已关）互不串号', async () => {
  const { pf, doc } = world();
  const got = [];
  pf.confirmDialog('一号', 'b1', '执行', false).then((v) => got.push(['一', v]));
  fire(doc.getElementById('dlg-ok'), 'click');
  await tick();
  pf.confirmDialog('二号', 'b2', '取消', true).then((v) => got.push(['二', v]));
  fire(doc.getElementById('dlg-cancel'), 'click');
  await tick();
  assert.deepEqual(got, [['一', true], ['二', false]], '两次的答案必须各归各的');
});

test('B5 未打开时的 closeDialog 不抛错、不产生多余 resolve', async () => {
  const { pf, doc } = world();
  const got = [];
  pf.confirmDialog('t', 'b', '执行', false).then((v) => got.push(v));
  fire(doc.getElementById('dlg-cancel'), 'click');
  await tick();
  pf.closeDialog(true);              /* 已经关了再调一次 */
  await tick();
  assert.deepEqual(got, [false], '多余调用不该再 resolve');
  assert.equal(doc.getElementById('dlg').open, false);
});

/* ---------------- C. 进程选中 ---------------- */

test('C1 总览卡片点击：切到进程视图，且“当前选择”跟着更新（48 号修复点）', () => {
  const { pf, doc } = world();
  pf.renderSnapshot(SNAP);
  const card = doc.getElementById('ov-top').children[0];
  assert.ok(card, '总览没有渲染出进程卡片');
  fire(card, 'click');
  assert.equal(pf.__state().activeView, 'processes');
  assert.equal(pf.__state().selected.pid, 111);
  assert.equal(doc.getElementById('proc-who').textContent, 'alpha.exe (PID 111)',
    '卡片点击绕过了 selectProcess，标签还停在旧值');
});

test('C2 卡片点击后，进程表里恰好一行高亮且是它', () => {
  const { pf, doc } = world();
  pf.renderSnapshot(SNAP);
  fire(doc.getElementById('ov-top').children[1], 'click');   /* beta.exe */
  const rows = doc.getElementById('proc-body').querySelectorAll('.row');
  const sel = rows.filter((r) => r.classList.contains('sel'));
  assert.equal(sel.length, 1, '高亮行应唯一');
  assert.equal(sel[0].children[0].textContent, '222');
});

test('C3 行内单元格点击（事件委托 + 行自身监听）：选中跟着走', () => {
  const { pf, doc } = world();
  pf.renderSnapshot(SNAP);
  const rows = doc.getElementById('proc-body').querySelectorAll('.row');
  fire(rows[1].children[0], 'click');
  assert.equal(pf.__state().selected.pid, 222);
  assert.equal(doc.getElementById('proc-who').textContent, 'beta.exe (PID 222)');
});

test('C4 连点两行：选中不残留上一条', () => {
  const { pf, doc } = world();
  pf.renderSnapshot(SNAP);
  const rows = doc.getElementById('proc-body').querySelectorAll('.row');
  fire(rows[0].children[1], 'click');
  assert.equal(pf.__state().selected.pid, 111);
  fire(rows[2].children[1], 'click');
  assert.equal(pf.__state().selected.pid, 333);
  assert.equal(doc.getElementById('proc-who').textContent, 'gamma.exe (PID 333)');
});

test('C5 双击行 → 弹确认框（文案带该行），取消则不发送任何指令', async () => {
  const { pf, env, doc } = world();
  pf.renderSnapshot(SNAP);
  const rows = doc.getElementById('proc-body').querySelectorAll('.row');
  fire(rows[2].children[0], 'click');
  const ev = fire(rows[2].children[0], 'dblclick');
  assert.equal(doc.getElementById('dlg').open, true, '双击应弹确认框');
  assert.match(doc.getElementById('dlg-body').textContent, /gamma\.exe \(PID 333\)/);
  fire(doc.getElementById('dlg-cancel'), 'click');
  await tick();
  await tick();
  assert.equal(ev.errors.length, 0, '取消路径抛了：' + (ev.errors[0] && ev.errors[0].message));
  assert.equal(env.fetchCalls.filter((c) => c.url.indexOf('/api/command') >= 0).length, 0,
    '取消后不该发 kill 指令');
});

test('C6 双击行 → 确认后真的发出 kill_process，且带 confirm 与进程名', async () => {
  const { pf, env, doc } = world();
  pf.renderSnapshot(SNAP);
  const rows = doc.getElementById('proc-body').querySelectorAll('.row');
  fire(rows[0].children[0], 'click');
  fire(rows[0].children[0], 'dblclick');
  fire(doc.getElementById('dlg-ok'), 'click');
  await tick();
  await tick();
  const posts = env.fetchCalls.filter((c) => c.url.indexOf('/api/command') >= 0);
  assert.equal(posts.length, 1);
  const body = JSON.parse(posts[0].init.body);
  assert.equal(body.action, 'kill_process');
  assert.equal(body.process_name, 'alpha.exe');
  assert.equal(body.confirm, true, 'kill 必须带 confirm:true');
});

test('C7 没有选中任何行时双击：不弹框、不抛错、不发指令', async () => {
  const { pf, env, doc } = world();
  pf.renderSnapshot(SNAP);
  const rows = doc.getElementById('proc-body').querySelectorAll('.row');
  const ev = fire(rows[1].children[0], 'dblclick');
  await tick();
  await tick();
  assert.equal(doc.getElementById('dlg').open, false, '无选中双击不该弹框');
  assert.equal(ev.errors.length, 0,
    '无选中双击把 selected 当对象用了，抛了：' + (ev.errors[0] && ev.errors[0].message));
  assert.equal(env.fetchCalls.filter((c) => c.url.indexOf('/api/command') >= 0).length, 0);
});

/* ---------------- D. 结构契约 ---------------- */

test('D1 总览卡片不再旁路直写 selected（必须走 selectProcess）', () => {
  assert.ok(!APP_SRC.includes('selected = { pid: p.pid'),
    'renderTop 又写回了 selected 旁路：标签会与选中状态脱节');
});

test('D2 #proc-who 存在且默认文案是“无”', () => {
  assert.ok(HTML_SRC.includes('id="proc-who"'), 'index.html 里没有 proc-who');
  assert.ok(/<b id="proc-who">无<\/b>/.test(HTML_SRC), 'proc-who 默认文案变了，用户第一眼会看到空');
});

test('D3 dialogResolve 只有一个“接单”入口（confirmDialog 内）', () => {
  const n = (APP_SRC.match(/dialogResolve\s*=\s*resolve/g) || []).length;
  assert.equal(n, 1, '出现了 ' + n + ' 处接单赋值：多人写同一条 promise 必然串号');
  assert.ok(!/function\s+confirmQueue|confirmDialog2/.test(APP_SRC), '冒出第二个确认入口了');
});

/* ---------------- E. 设置页失败路径（49 号） ---------------- */

/** 与 server.py get_settings 同形的正常返回 */
const S_OK = {
  cloud: { base_url: 'https://ark.cn-beijing.volces.com/api/v3', model: 'doubao-pro', has_key: true, source: 'vault' },
  system_prompt: '你是调度助手',
  token_fingerprint: 'abcd1234',
  kernel_dir: 'E:\\PowerFocus\\versions\\v0.13',
  app_dir: 'E:\\PowerFocus\\product\\v1.00\\app',
};

/** 可断言路由表：routes['GET /api/settings'] = {status, body} 或函数 */
function netWorld(routes) {
  const calls = [];
  const { pf, env } = loadApp(REPO, {
    fetch: (url, init) => {
      const method = (init && init.method) || 'GET';
      let body = null;
      if (init && init.body) { try { body = JSON.parse(init.body); } catch (e) { body = init.body; } }
      calls.push({ method, url, body });
      const h = routes[method + ' ' + url];
      const r = typeof h === 'function' ? h(url, init) : h;
      const spec = r || { status: 501, body: { detail: 'unrouted ' + method + ' ' + url } };
      const status = spec.status || 200;
      return Promise.resolve({
        ok: status >= 200 && status < 300,
        status,
        headers: { get: () => 'application/json' },
        json: async () => spec.body,
        text: async () => JSON.stringify(spec.body),
      });
    },
  });
  pf.bind();
  return { pf, env, calls, doc: env.document };
}

async function settle(n) { for (let i = 0; i < (n || 3); i++) await tick(); }

test('E1 设置读取失败后点“保存”不发 POST，且界面说清原因', async () => {
  const { pf, doc, calls } = netWorld({ 'GET /api/settings': { status: 500, body: { detail: 'disk error' } } });
  pf.switchView('settings');
  await settle(5);
  assert.equal(doc.getElementById('set-base').value, '',
    '前提：读取失败时字段确实是空的——这正是会覆盖磁盘配置的那组空值');
  const ev = fire(doc.getElementById('set-save'), 'click');
  await settle(5);
  assert.deepEqual(ev.errors, [], '保存链路抛了异常');
  const posts = calls.filter((c) => c.method === 'POST' && c.url === '/api/settings');
  assert.equal(posts.length, 0,
    '读取失败后仍然发出保存：会把空 base_url/model/system_prompt 写进 config.json（49 号修复点）');
  const out = doc.getElementById('set-out');
  assert.equal(out.hidden, false, '原因必须留在设置页里，不能只靠一个 4.2 秒就消失的 toast');
  assert.match(out.textContent, /避免用空值覆盖/);
});

test('E2 读取成功后字段精确回填，保存没有被误禁', async () => {
  const { pf, doc } = netWorld({ 'GET /api/settings': { body: S_OK } });
  pf.switchView('settings');
  await settle(5);
  assert.equal(doc.getElementById('set-base').value, S_OK.cloud.base_url);
  assert.equal(doc.getElementById('set-model').value, S_OK.cloud.model);
  assert.equal(doc.getElementById('set-prompt').value, S_OK.system_prompt);
  assert.equal(doc.getElementById('set-key').value, '', '密钥框每次重读都该清空');
  assert.match(doc.getElementById('set-key').placeholder, /已保存/);
  assert.notEqual(doc.getElementById('set-save').disabled, true, '读取成功后保存不能被禁用');
  assert.equal(doc.getElementById('set-info').children.length, 8, '信息卡应为 4 行键值 = 8 个节点');
});

test('E3 保存成功：请求体精确、提示列出 changed、清空密钥并重读', async () => {
  const { pf, doc, calls } = netWorld({
    'GET /api/settings': { body: S_OK },
    'POST /api/settings': { body: { ok: true, changed: ['base_url', 'api_key'], cloud_ready: true } },
  });
  pf.switchView('settings');
  await settle(5);
  doc.getElementById('set-base').value = ' https://example.com/api ';
  doc.getElementById('set-model').value = 'm2';
  doc.getElementById('set-prompt').value = 'p2';
  doc.getElementById('set-key').value = 'sk-test';
  const ev = fire(doc.getElementById('set-save'), 'click');
  await settle(6);
  assert.deepEqual(ev.errors, []);
  const post = calls.find((c) => c.method === 'POST' && c.url === '/api/settings');
  assert.ok(post, '没有发出保存请求');
  assert.deepEqual(post.body,
    { base_url: 'https://example.com/api', model: 'm2', system_prompt: 'p2', api_key: 'sk-test' },
    '请求体必须去首尾空格，且密钥为空时不带 api_key');
  assert.match(doc.getElementById('set-out').textContent, /已保存：base_url, api_key/);
  assert.equal(doc.getElementById('set-key').value, '', '保存成功后应清空密钥框');
  assert.equal(calls.filter((c) => c.method === 'GET' && c.url === '/api/settings').length, 2,
    '保存后应重读一次设置');
});

test('E3b 密钥留空时请求体不含 api_key（不能把已存密钥冲成空串）', async () => {
  const { pf, doc, calls } = netWorld({
    'GET /api/settings': { body: S_OK },
    'POST /api/settings': { body: { ok: true, changed: ['model'], cloud_ready: true } },
  });
  pf.switchView('settings');
  await settle(5);
  doc.getElementById('set-model').value = 'm3';
  fire(doc.getElementById('set-save'), 'click');
  await settle(6);
  const post = calls.find((c) => c.method === 'POST');
  assert.ok(post, '没有发出保存请求');
  assert.equal(Object.prototype.hasOwnProperty.call(post.body, 'api_key'), false,
    '密钥框留空表示“不修改”，请求体里就不该出现 api_key（哪怕空串）');
});

test('E3c 保存成功后即使重读失败，密钥框也已清空（密钥不在界面停留）', async () => {
  let getCount = 0;
  const { pf, doc } = netWorld({
    'GET /api/settings': () => (getCount++ === 0
      ? { body: S_OK }
      : { status: 500, body: { detail: 'reload failed' } }),
    'POST /api/settings': { body: { ok: true, changed: ['api_key'], cloud_ready: true } },
  });
  pf.switchView('settings');
  await settle(5);
  doc.getElementById('set-key').value = 'sk-secret';
  fire(doc.getElementById('set-save'), 'click');
  await settle(8);
  assert.equal(doc.getElementById('set-key').value, '', '重读失败也不能让密钥留在输入框里');
});

test('E4 保存被 400 拒绝：显示后端原因、留住用户输入、不锁死重试', async () => {
  const { pf, doc, calls } = netWorld({
    'GET /api/settings': { body: S_OK },
    'POST /api/settings': { status: 400, body: { detail: 'base_url 必须以 http:// 或 https:// 开头' } },
  });
  pf.switchView('settings');
  await settle(5);
  doc.getElementById('set-base').value = 'ftp://bad';
  doc.getElementById('set-key').value = 'sk-typed';
  fire(doc.getElementById('set-save'), 'click');
  await settle(6);
  assert.match(doc.getElementById('set-out').textContent, /保存失败：base_url 必须以 http/);
  assert.equal(doc.getElementById('set-key').value, 'sk-typed', '失败不该清掉用户刚敲的密钥');
  fire(doc.getElementById('set-save'), 'click');
  await settle(6);
  assert.equal(calls.filter((c) => c.method === 'POST').length, 2, '一次失败后不能把保存锁死');
});

test('E5 清除密钥：取消不发请求，确认只发一次 clear_key', async () => {
  const { pf, doc, calls } = netWorld({
    'GET /api/settings': { body: S_OK },
    'POST /api/settings': { body: { ok: true, changed: ['clear_key'], cloud_ready: false } },
  });
  pf.switchView('settings');
  await settle(5);
  fire(doc.getElementById('set-clear'), 'click');
  await settle(3);
  assert.equal(doc.getElementById('dlg').open, true, '清除密钥必须先弹确认框');
  assert.equal(doc.getElementById('dlg-title').textContent, '清除云端密钥');
  fire(doc.getElementById('dlg-cancel'), 'click');
  await settle(5);
  assert.equal(calls.filter((c) => c.method === 'POST').length, 0, '取消后不得发出清除请求');
  fire(doc.getElementById('set-clear'), 'click');
  await settle(3);
  fire(doc.getElementById('dlg-ok'), 'click');
  await settle(6);
  const posts = calls.filter((c) => c.method === 'POST');
  assert.equal(posts.length, 1, '确认后应只发一次');
  assert.deepEqual(posts[0].body, { clear_key: true });
});

test('E6 结构契约：saveSettings 首段必须有 settingsLoaded 守卫', () => {
  const start = APP_SRC.indexOf('async function saveSettings()');
  const end = APP_SRC.indexOf('async function testCloud()');
  assert.ok(start > 0 && end > start, '找不到 saveSettings / testCloud 函数边界');
  const head = APP_SRC.slice(start, start + 420);
  assert.match(head, /if \(!settingsLoaded\)/, '【49 号】守卫被删：读失败后又能用空值覆盖配置了');
  assert.match(head, /避免用空值覆盖/);
  const ls = APP_SRC.slice(APP_SRC.indexOf('async function loadSettings()'), start);
  assert.match(ls, /暂不允许保存/, 'loadSettings 失败分支必须把原因写到设置页');
});

/* ---------------- F. 连接测试结果渲染（50 号） ---------------- */

test('F1 上游连不通（响应无 status）不得印出 undefined', async () => {
  const { doc } = netWorld({ 'POST /api/cloud/test': { status: 200, body: { ok: false, latency_ms: 1234, detail: '连接失败（详情已写入本机日志）' } } });
  const ev = fire(doc.getElementById('set-test'), 'click');
  await settle(6);
  assert.deepEqual(ev.errors, [], '测试连接链路抛了异常');
  const out = doc.getElementById('set-out');
  assert.equal(out.hidden, false, '结果区必须展开');
  assert.match(out.textContent, /^连接失败 · 未收到上游响应 · 1234 ms/,
    '【50 号】异常分支应明确说“未收到上游响应”，而不是 HTTP undefined');
  assert.ok(!/undefined/.test(out.textContent), '结果里出现了 undefined');
  assert.match(out.textContent, /连接失败（详情已写入本机日志）/, '必须显示后端给的 detail');
});

test('F2 上游返回 401 仍应显示真实 HTTP 状态码', async () => {
  const { doc } = netWorld({ 'POST /api/cloud/test': { status: 200, body: { ok: false, status: 401, latency_ms: 88, detail: '上游返回错误（正文不回显）' } } });
  fire(doc.getElementById('set-test'), 'click');
  await settle(6);
  const t = doc.getElementById('set-out').textContent;
  assert.match(t, /^连接失败 · HTTP 401 · 88 ms/, '有 status 时不得改口');
  assert.ok(!/undefined/.test(t));
});

test('F3 成功返回带模型数', async () => {
  const { doc } = netWorld({ 'POST /api/cloud/test': { status: 200, body: { ok: true, status: 200, latency_ms: 42, model_count: 7, detail: '' } } });
  fire(doc.getElementById('set-test'), 'click');
  await settle(6);
  assert.equal(doc.getElementById('set-out').textContent, '连接成功 · HTTP 200 · 42 ms · 7 个模型');
});

test('F4 结构契约：testCloud 不得裸拼 r.status', () => {
  const s = APP_SRC.indexOf('async function testCloud()');
  const e = APP_SRC.indexOf('async function clearKey()');
  assert.ok(s > 0 && e > s, '找不到 testCloud / clearKey 边界');
  const body = APP_SRC.slice(s, e);
  assert.match(body, /typeof r\.status === 'number'/, '【50 号】status 守卫被删：又会回到 HTTP undefined');
  assert.ok(!/' · HTTP ' \+ r\.status \+/.test(body), '仍在裸拼 r.status');
});

/* ---------------- G. 安全态势渲染守卫（51 号） ---------------- */

/** 与 server.py /api/security 同形的正常返回 */
const SEC_OK = {
  bind: { host: '127.0.0.1', port: 18080, loopback_only: true },
  host_guard: { enabled: true, allowed: ['127.0.0.1', 'localhost'] },
  token: { ready: true, fingerprint: 'ABCD1234', path: 'C:\\PF\\http.token' },
  docs: { disabled: true },
  limits: { body_bytes: 1048576, requests_per_min: 600, auth_fail_threshold: 20 },
  headers: ['X-Frame-Options', 'X-Content-Type-Options'],
  cloud_key: { encrypted: true, source: 'vault' },
  audit_log: 'C:\\PF\\security.log',
};

/** #sec-kv 里的 k/v 对（每行两格） */
function secRows(doc) {
  const kv = doc.getElementById('sec-kv');
  const out = [];
  for (let i = 0; i + 1 < kv.children.length; i += 2) {
    out.push([kv.children[i].textContent, kv.children[i + 1].textContent]);
  }
  return out;
}

test('G1 空 payload 不抛错：10 行都在，占位清晰，不出现 undefined/null', () => {
  const { pf, env } = loadApp(REPO);
  const doc = env.document;
  let err = null;
  try { pf.renderSecurity({}); } catch (e) { err = e; }
  assert.equal(err, null, '空 payload 仍抛错：整页又被一个缺失字段打空');
  const rows = secRows(doc);
  assert.equal(rows.length, 10, '十行必须都在，缺的那格显示占位而不是整块消失');
  const text = doc.getElementById('sec-kv').textContent;
  assert.ok(!/undefined|null/.test(text), '占位文案里漏出了 undefined/null');
  assert.equal(rows[0][1], '未知（未回报）', '监听缺段应明说未知');
  assert.equal(rows[6][1], '--', '请求体上限缺字段应显示 --');
  assert.equal(doc.getElementById('sec-fp').textContent, '令牌 --');
});

test('G2 云端密钥整段缺失（schema 漂移）：其余九行照常显示，只有该行说“未知”', async () => {
  const partial = { ...SEC_OK };
  delete partial.cloud_key;
  const { pf, doc } = netWorld({
    'GET /api/security': { status: 200, body: partial },
    'GET /api/audit?limit=40': { status: 200, body: { items: [{ ts: '12:00:00', event: 'auth_fail', who: 'x' }] } },
  });
  pf.switchView('security');
  await settle(6);
  const rows = secRows(doc);
  assert.equal(rows.length, 10, '一个段落缺失不该让整块表消失');
  assert.equal(rows[0][1], '127.0.0.1:18080（仅回环）');
  assert.equal(rows[1][1], '127.0.0.1, localhost');
  assert.equal(rows[2][1], 'ABCD1234');
  assert.equal(rows[8][1], '未知（未回报）', '云端密钥缺失必须明说未知，不能猜“未配置”');
  assert.equal(rows[9][1], 'C:\\PF\\security.log');
  assert.ok(!/undefined/.test(doc.getElementById('sec-kv').textContent));
  assert.equal(doc.getElementById('sec-audit').children.length, 1, '安全态势失败不该连审计列表一起吞掉');
});

test('G3 类型全错也不抛：不印 undefined/null/[object Object]', () => {
  const { pf, env } = loadApp(REPO);
  const doc = env.document;
  const bad = { bind: null, host_guard: { allowed: 'x' }, token: 5, docs: 'x', limits: [], headers: 'abc', cloud_key: null, audit_log: 3 };
  let err = null;
  try { pf.renderSecurity(bad); } catch (e) { err = e; }
  assert.equal(err, null, '坏类型把渲染打穿了');
  const rows = secRows(doc);
  assert.equal(rows.length, 10);
  const text = doc.getElementById('sec-kv').textContent;
  assert.ok(!/undefined|null|\[object Object\]/.test(text), '坏类型被打成了文本：' + text.slice(0, 120));
  assert.equal(rows[0][1], '未知（未回报）');
  assert.equal(rows[7][1], '--');
});

test('G4 正常 payload 文案逐格不漂移，对外暴露告警不丢', () => {
  const { pf, env } = loadApp(REPO);
  const doc = env.document;
  pf.renderSecurity(SEC_OK);
  assert.deepEqual(secRows(doc), [
    ['监听', '127.0.0.1:18080（仅回环）'],
    ['Host 白名单', '127.0.0.1, localhost'],
    ['令牌指纹', 'ABCD1234'],
    ['令牌文件', 'C:\\PF\\http.token'],
    ['接口地图', '已关闭（/docs /openapi.json 均 404）'],
    ['请求限流', '600 次/分钟 · 认证失败 20 次熔断'],
    ['请求体上限', '1048576 字节'],
    ['安全响应头', 'X-Frame-Options, X-Content-Type-Options'],
    ['云端密钥', 'DPAPI 加密存储'],
    ['审计日志', 'C:\\PF\\security.log'],
  ]);
  assert.equal(doc.getElementById('sec-fp').textContent, '令牌 ABCD1234');
  pf.renderSecurity({ ...SEC_OK, bind: { ...SEC_OK.bind, loopback_only: false } });
  assert.equal(secRows(doc)[0][1], '127.0.0.1:18080（对外暴露！）', '对外暴露的告警被守卫吞了');
});

test('G5 结构契约：renderSecurity 必须逐段归一，不得直接链式取深字段', () => {
  const s = APP_SRC.indexOf('function renderSecurity(s)');
  const e = APP_SRC.indexOf('function renderAudit(items');
  assert.ok(s > 0 && e > s, '找不到 renderSecurity / renderAudit 边界');
  const body = APP_SRC.slice(s, e);
  assert.match(body, /const obj = /, '【51 号】对象归一被删：又会被 null 打穿');
  assert.match(body, /const arr = /);
  assert.match(body, /const txt = /);
  assert.ok(!/s\.bind\.host|s\.token\.path|s\.limits\.|s\.cloud_key\.encrypted|s\.docs\.disabled/.test(body),
    '仍在直接取深字段：schema 一漂就整页打空');
});

/* ---------------- H. 安全态势双接口隔离（51-B） ---------------- */

test('H1 审计接口 500 不再连坐安全面板：10 行照常，审计区说清失败', async () => {
  const { pf, doc } = netWorld({
    'GET /api/security': { status: 200, body: SEC_OK },
    'GET /api/audit?limit=40': { status: 500, body: { detail: 'audit db locked' } },
  });
  pf.switchView('security');
  await settle(8);
  assert.equal(secRows(doc).length, 10, '审计 500 把安全面板连坐打空了');
  assert.equal(secRows(doc)[0][1], '127.0.0.1:18080（仅回环）');
  const auditText = doc.getElementById('sec-audit').textContent;
  assert.match(auditText, /审计日志读取失败/, '审计失败没有任何提示：' + auditText);
  assert.match(auditText, /audit db locked/, '失败原因被吞：' + auditText);
  assert.ok(!/undefined/.test(doc.getElementById('sec-kv').textContent), '安全面板漏出 undefined');
});

test('H2 安全接口 500 不再连坐审计列表：审计照常渲染，安全失败有 toast', async () => {
  const { pf, doc } = netWorld({
    'GET /api/security': { status: 500, body: { detail: 'security store broken' } },
    'GET /api/audit?limit=40': { status: 200, body: { items: [{ ts: '12:00:00', event: 'auth_fail', who: 'x' }] } },
  });
  pf.switchView('security');
  await settle(8);
  const audit = doc.getElementById('sec-audit');
  assert.equal(audit.children.length, 1, '安全 500 把审计列表连坐吞了');
  assert.match(audit.textContent, /auth_fail/, '审计条目没渲染：' + audit.textContent);
  assert.match(doc.getElementById('toasts').textContent, /读取安全态势失败/, '安全失败没提示');
  assert.match(doc.getElementById('toasts').textContent, /security store broken/, '安全失败原因被吞');
});

test('H3 结构契约：refreshSecurity 用 allSettled 隔离双接口，不得共用一个 Promise.all', () => {
  const s = APP_SRC.indexOf('async function refreshSecurity()');
  const e = APP_SRC.indexOf('function renderSecurity(s)', s);
  assert.ok(s > 0 && e > s, '找不到 refreshSecurity / renderSecurity 边界');
  const body = APP_SRC.slice(s, e);
  assert.match(body, /Promise\.allSettled/, '【51-B】双接口又共用一个拒绝点：审计 500 会再次连坐安全面板');
  assert.ok(!/Promise\.all\(/.test(body), 'refreshSecurity 仍在用 Promise.all');
  assert.match(body, /secRes\.status === 'fulfilled'/, '安全接口结果未单独判定');
  assert.match(body, /auditRes\.status === 'fulfilled'/, '审计接口结果未单独判定');
});

/* ---------------- H4. 审计条目归一（51-C） ----------------
   真实缺陷是「数组内元素为 null」：refreshSecurity 传 audit.items || []，
   顶层 null 会先被 || [] 变成空数组，走不到 renderAudit 的 null.length。 */

test('H4a 审计 items 首条为 null：跳过坏条目，合法条目照常渲染，不抛', async () => {
  const { pf, doc } = netWorld({
    'GET /api/security': { status: 200, body: SEC_OK },
    'GET /api/audit?limit=40': {
      status: 200,
      body: { items: [null, { ts: '12:00:00', event: 'auth_fail', who: 'x' }, 42, 'x'] },
    },
  });
  pf.switchView('security');
  await settle(8);
  const box = doc.getElementById('sec-audit');
  assert.equal(box.children.length, 1, '坏条目打断渲染，合法审计行没出来');
  assert.match(box.textContent, /auth_fail/, '合法审计行没渲染：' + box.textContent);
  assert.ok(!/undefined|null/.test(box.textContent), '审计区漏出 undefined/null');
});

test('H4b 审计 items 全部非法：走空态，不抛、不漏 undefined/null', async () => {
  for (const items of [[null], [null, 42, 'x']]) {
    const { pf, doc } = netWorld({
      'GET /api/security': { status: 200, body: SEC_OK },
      'GET /api/audit?limit=40': { status: 200, body: { items } },
    });
    pf.switchView('security');
    await settle(8);
    const box = doc.getElementById('sec-audit');
    assert.equal(box.children.length, 1, '全非法 items 没走空态：' + JSON.stringify(items));
    assert.match(box.textContent, /最近没有安全事件/, '空态文案缺失：' + box.textContent);
    assert.ok(!/undefined|null/.test(box.textContent), '空态漏出 undefined/null');
  }
});

test('H4c 结构契约：renderAudit 必须先归一 items，再判空/循环', () => {
  const s = APP_SRC.indexOf('function renderAudit(items');
  assert.ok(s > 0, '找不到 renderAudit 边界');
  const next = APP_SRC.indexOf('\n  function ', s + 10);
  const body = APP_SRC.slice(s, next > s ? next : s + 900);
  assert.match(body, /const rows = Array\.isArray\(items\)/,
    '【51-C】items 没有数组/对象归一：null 元素又会打断整段审计');
  assert.match(body, /if \(!rows\.length\)/, '判空没有改用 rows');
  assert.match(body, /for \(const it of rows\)/, '循环没有改用 rows');
  assert.ok(!/for \(const it of items\)/.test(body), '仍在直接遍历未归一的 items');
});

/* ---------------- S. KVRT 显式同意（P1-2） ---------------- */

function reply(body, status = 200) {
  return Promise.resolve({
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => 'application/json' },
    json: async () => body,
    text: async () => '',
  });
}

function scanWorld(posts) {
  return world({
    fetch: (url, init) => {
      const u = String(url);
      if (u.endsWith('/api/security/scan/status')) {
        return reply({
          ok: true,
          engine: { present: true, ready: true, signature: { signer: 'AO Kaspersky Lab' } },
          running: false, started: '', finished: '', scope: '', path: '', error: '', result: null,
        });
      }
      if (u.endsWith('/api/security/scan') && init && init.method === 'POST') {
        posts.push(JSON.parse(init.body));
        return reply({ ok: true, started: true, process_level: 0, accept_eula: true });
      }
      return reply({ ok: true });
    },
  });
}

test('S1 未验签时勾选框与开始按钮都禁用', () => {
  const { pf, doc } = scanWorld([]);
  pf.renderScan({ engine: { present: false, ready: false }, running: false });
  assert.equal(doc.getElementById('scan-eula').disabled, true);
  assert.equal(doc.getElementById('scan-start').disabled, true);
  assert.match(doc.getElementById('scan-engine').textContent, /未下载/);
});

test('S2 已验签但未勾选 EULA：不发起 POST', async () => {
  const posts = [];
  const { pf, doc } = scanWorld(posts);
  pf.renderScan({ engine: { present: true, ready: true, signature: { signer: 'AO Kaspersky Lab' } }, running: false });
  assert.equal(doc.getElementById('scan-eula').disabled, false);
  assert.equal(doc.getElementById('scan-start').disabled, true);
  await pf.startScan();
  assert.equal(posts.length, 0, '未勾选 EULA 仍发起了扫描请求');
});

test('S3 勾选 EULA 后 POST 必须带 accept_eula=true，默认只报告', async () => {
  const posts = [];
  const { pf, doc } = scanWorld(posts);
  pf.renderScan({ engine: { present: true, ready: true, signature: { signer: 'AO Kaspersky Lab' } }, running: false });
  doc.getElementById('scan-eula').checked = true;
  doc.getElementById('scan-scope').value = 'core';
  doc.getElementById('scan-level').value = '0';
  doc.getElementById('scan-timeout').value = '60';
  pf.updateScanButton();
  await pf.startScan();
  assert.equal(posts.length, 1, '同意后没有发起扫描');
  assert.equal(posts[0].accept_eula, true);
  assert.equal(posts[0].scope, 'core');
  assert.equal(posts[0].process_level, 0);
  assert.ok(!('disinfect_confirm' in posts[0]), '只报告模式不应带处置确认');
});

test('S4 UI 明示 EULA 链接、下载通道和初始禁用状态', () => {
  assert.match(HTML_SRC, /id="scan-eula" type="checkbox" disabled/);
  assert.match(HTML_SRC, /support\.kaspersky\.com\/8530/);
  assert.match(HTML_SRC, /devbuild latest/);
  assert.match(HTML_SRC, /应用不代我同意/);
  assert.match(APP_SRC, /accept_eula: true/);
  assert.match(APP_SRC, /process_level: level/);
});
