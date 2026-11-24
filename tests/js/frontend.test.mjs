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
import { loadApp, findRepoRoot, WEB_REL, VIEW_ORDER_EXPECTED, fire } from './pf-dom-stub.mjs';

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

/* ---------------- F. 隐私防护：内容保密 + 防护开关 ----------------
   这组钉的是本轮对用户的原话：
     「别人只看得到我在用浏览器、在访问哪个网站，看不到我打开了哪一页」。
   所以界面必须说清「谁看得到什么」、不许出现「隐藏 IP / 绝对安全」这类没兑现的承诺；
   开关的收紧 / 还原必须逐项如实汇报，读不到状态的不许一键改。 */

const SHIELD_ITEMS = [
  { id: 'https_only_edge', title: '浏览器强制加密', scope: '当前用户 · Edge 140 以上', recommended: true, admin: false, state: 'off', why: '手动输入的 http 网址也会先走加密连接。', risk: '只对 Edge 生效。', journaled: false },
  { id: 'doh_all', title: 'DNS 查询全加密', scope: '本机', recommended: true, admin: true, state: 'off', why: '所有解析服务器都走加密通道。', risk: '', journaled: false },
  { id: 'remote_assist', title: '远程协助', scope: '本机', recommended: true, admin: true, state: 'on', why: '别人拿到邀请文件就能远程操作。', risk: '', journaled: true },
  { id: 'ad_id', title: '广告 ID', scope: '当前用户', recommended: true, admin: false, state: 'unknown', why: '应用凭广告 ID 追踪你。', risk: '', journaled: false },
  { id: 'name_broadcast', title: '名称广播', scope: '本机', recommended: false, admin: true, state: 'off', why: '不再广播电脑名。', risk: '重启后生效。', journaled: false },
];

const shieldRows = (env) => env.document.getElementById('shield-items').querySelectorAll('.check');
const jsonOk = (body) => ({ ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => '', json: async () => body });
const tick = () => new Promise((r) => setTimeout(r, 0));

test('F1 renderShield：一项一条，状态、按钮文案、权限提示各就各位', () => {
  const { pf, env } = loadApp(REPO);
  pf.renderShield(SHIELD_ITEMS);
  const rows = shieldRows(env);
  assert.equal(rows.length, 5);
  const badge = (i) => rows[i].children[0].textContent;
  const body = (i) => rows[i].children[1].textContent;
  const btn = (i) => rows[i].children[2];
  assert.deepEqual([0, 1, 2, 3, 4].map(badge), ['未收紧', '未收紧', '已收紧', '读不到', '未收紧']);
  assert.equal(btn(0).textContent, '收紧');
  assert.equal(btn(4).textContent, '收紧（可选）');       // 不在推荐项里的，明确标成可选
  assert.equal(btn(2).textContent, '还原');
  assert.equal(btn(3).disabled, true);                     // 读不到状态的不许一键改
  assert.ok(body(1).includes('需要管理员权限') && body(1).includes('所有解析服务器都走加密通道'));
  assert.equal(body(2).includes('需要管理员权限'), false);  // 已经收紧的不再催权限
  assert.ok(body(4).includes('影响：重启后生效。'));
  assert.ok(body(0).includes('当前用户 · Edge 140 以上'));
});

test('F2 renderShield：缺数据时说清楚，不印 undefined', () => {
  const { pf, env } = loadApp(REPO);
  const box = env.document.getElementById('shield-items');
  pf.renderShield(null, 'HTTP 500');
  assert.equal(box.textContent, '开关状态读取失败：HTTP 500');
  pf.renderShield(undefined);
  assert.equal(box.textContent, '没有可用的开关（未回报）');
  pf.renderShield([null, 'x', 3]);
  assert.equal(box.textContent, '没有可用的开关（未回报）');
  pf.renderShield([{ id: 'ad_id' }]);
  assert.equal(box.textContent.includes('undefined'), false, box.textContent);
  assert.equal(box.textContent.includes('收紧'), true);    // 字段残缺也只给可选按钮，不当成推荐项
});

test('F3 收紧推荐项：只发「推荐且确实未收紧」的，结果逐项如实汇报', async () => {
  const calls = [];
  const { pf, env } = loadApp(REPO, {
    fetch: async (url, init) => {
      calls.push({ url, init });
      if (url === '/api/security/shield/apply') {
        return jsonOk({ results: [
          { id: 'https_only_edge', ok: true, state: 'on', title: '浏览器强制加密', note: '只对 Edge 生效。' },
          { id: 'doh_all', ok: false, error: '没有权限写入（这一项需要以管理员身份运行本应用）' },
        ] });
      }
      return jsonOk({ score: 100, summary: 'x', checks: [], shield: [] });
    },
  });
  pf.renderShield(SHIELD_ITEMS);
  await pf.shieldApplyRecommended();
  await tick();
  const post = calls.find((c) => c.url === '/api/security/shield/apply');
  assert.ok(post, '没有发出收紧请求');
  assert.equal(post.init.method, 'POST');
  /* 已收紧的、读不到状态的、可选的都不带 */
  assert.deepEqual(JSON.parse(post.init.body), { ids: ['https_only_edge', 'doh_all'] });
  const out = env.document.getElementById('shield-out').textContent;
  assert.ok(out.includes('已收紧：浏览器强制加密。'), out);
  assert.ok(out.includes('没改成：DNS 查询全加密：没有权限写入'), out);
  assert.equal(out.includes('undefined'), false, out);
  assert.ok(calls.some((c) => c.url === '/api/security/posture'), '操作后要重新体检');
});

test('F4 全部还原：只还原这个应用改过的；没改过就不发请求', async () => {
  const calls = [];
  const { pf, env } = loadApp(REPO, {
    fetch: async (url, init) => {
      calls.push({ url, init });
      return jsonOk(url.endsWith('/revert') ? { results: [{ id: 'remote_assist', ok: true }] }
        : { score: 100, summary: 'x', checks: [], shield: [] });
    },
  });
  pf.renderShield(SHIELD_ITEMS);
  await pf.shieldRevertAll();
  await tick();
  const post = calls.find((c) => c.url === '/api/security/shield/revert');
  assert.equal(post.init.method, 'POST');
  assert.deepEqual(JSON.parse(post.init.body), { ids: ['remote_assist'] });
  assert.ok(env.document.getElementById('shield-out').textContent.includes('已还原：远程协助。'));

  calls.length = 0;
  pf.renderShield(SHIELD_ITEMS.map((x) => Object.assign({}, x, { journaled: false })));
  await pf.shieldRevertAll();
  assert.equal(calls.length, 0, '没有可还原的却不该发请求');
  assert.ok(env.document.getElementById('shield-out').textContent.includes('没有需要还原的'));
});

test('F5 DNS 实测：只在点击时发一次，结论与依据原样呈现，按钮会恢复', async () => {
  let reply = { encrypted: true, via: ['223.5.5.5:443'], detail: '这次查询只连了 223.5.5.5:443——加密通道（443 端口）。' };
  const calls = [];
  const { pf, env } = loadApp(REPO, {
    fetch: async (url, init) => { calls.push({ url, init }); return jsonOk(reply); },
  });
  pf.renderShield(SHIELD_ITEMS);
  assert.equal(calls.length, 0);                           // 渲染不触发任何请求
  const out = env.document.getElementById('posture-dnscheck-out');
  const btn = env.document.getElementById('posture-dnscheck');
  await pf.dnsCheck();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, '/api/security/shield/dnscheck');
  assert.equal(calls[0].init.method, 'POST');
  assert.ok(out.textContent.startsWith('是密文。') && out.textContent.includes('223.5.5.5:443'), out.textContent);
  assert.equal(btn.disabled, false);
  reply = { encrypted: false, detail: '抓到明文查询：DNS 服务连的是 53 端口。' };
  await pf.dnsCheck();
  assert.ok(out.textContent.startsWith('不是密文。'), out.textContent);
  reply = { encrypted: null, detail: '没抓到正在进行的 DNS 连接。' };
  await pf.dnsCheck();
  assert.ok(out.textContent.startsWith('这次判断不了。'), out.textContent);

  /* 请求挂着的时候按钮必须是禁用的：不许连点 */
  let release;
  const gate = new Promise((r) => { release = r; });
  const slow = loadApp(REPO, { fetch: async () => { await gate; return jsonOk({ encrypted: null, detail: 'd' }); } });
  const pending = slow.pf.dnsCheck();
  assert.equal(slow.env.document.getElementById('posture-dnscheck').disabled, true);
  release();
  await pending;
  assert.equal(slow.env.document.getElementById('posture-dnscheck').disabled, false);
});

test('F6 renderPosture：内容保密项与开关一起渲染，明文端口有标记', () => {
  const { pf, env } = loadApp(REPO);
  pf.renderPosture({
    score: 50, summary: '1 项需要注意',
    checks: [
      { id: 'dnsenc', status: 'ok', title: 'DNS 查询加密', value: '已加密（223.5.5.5）', detail: '域名查询走加密通道。' },
      { id: 'httpsonly', status: 'warn', title: '浏览器强制加密（Edge）', value: '未强制（Edge 158.0.4370.33）',
        detail: '手动输入的 http 网址不保证。', advice: '用下面的开关。' },
      { id: 'eavesdrop', status: 'info', title: '本机能解开你加密流量的东西', value: '1 个私有 CA', detail: '第一行\n第二行' },
      { id: 'outbound', status: 'info', title: '谁在往外连', value: '2 个', detail: '', rows: [
        { proc: 'x.exe', ip: '1.1.1.1', port: 80, count: 1, plain: true },
        { proc: 'y.exe', ip: '1.0.0.1', port: 443, count: 3, plain: false },
      ] },
    ],
    app_outbound: { declared: [], events: {}, events_window: 'w' },
    shield: SHIELD_ITEMS,
  });
  const checks = env.document.getElementById('posture-checks').textContent;
  assert.ok(checks.includes('DNS 查询加密：已加密（223.5.5.5）'), checks);
  assert.ok(checks.includes('需注意浏览器强制加密（Edge）：未强制（Edge 158.0.4370.33）'), checks);
  assert.ok(checks.includes('建议：用下面的开关。'), checks);
  assert.equal(shieldRows(env).length, 5);                 // 开关区跟着同一次体检结果一起渲染
  const outbound = env.document.getElementById('posture-outbound').textContent;
  assert.ok(outbound.includes('1.1.1.1:80（明文端口） ×1'), outbound);
  assert.ok(outbound.includes('1.0.0.1:443 ×3') && !outbound.includes('443（明文端口）'), outbound);
  assert.equal((checks + outbound).includes('undefined'), false);

  pf.renderPosture(null, '服务没起来');
  assert.equal(env.document.getElementById('shield-items').textContent, '开关状态读取失败：服务没起来');
});

test('F7 文案契约：说清「谁看得到什么」，不承诺没兑现的事', () => {
  const panel = HTML_SRC.slice(HTML_SRC.indexOf('id="posture-score"'), HTML_SRC.indexOf('id="scan-engine"'));
  assert.ok(panel.length > 200, '没截到隐私防护面板');
  assert.ok(panel.includes('谁看得到我在浏览器里干什么'), '缺「谁看得到什么」的说明');
  assert.ok(panel.includes('看得到你在上网、连的是哪个网站（域名）'), '要说清旁观者看得到哪个网站');
  assert.ok(panel.includes('<b>看不到</b>你打开了哪一页'), '要说清看不到具体页面');
  assert.ok(panel.includes('前提是那个网站是加密的'), '要写明前提');
  assert.ok(panel.includes('网站自己当然知道你在它那里做了什么'), '要如实说明网站自己知道');
  assert.ok(panel.includes('每项可还原'), '要写明可以还原');
  for (const id of ['shield-apply', 'shield-revert', 'shield-items', 'shield-out', 'posture-dnscheck', 'posture-dnscheck-out']) {
    assert.ok(panel.includes('id="' + id + '"'), '缺节点 ' + id);
  }
  for (const bad of ['隐藏 IP', '隐藏你的 IP', '隐藏身份', '多重加密', '防黑客', '绝对安全', '100% 安全', '完全匿名']) {
    assert.equal(panel.includes(bad), false, '隐私面板不许出现承诺性用语：' + bad);
  }
});

test('F8 收紧 / 还原失败：原样说出原因，不吞错', async () => {
  const { pf, env } = loadApp(REPO, {
    fetch: async () => ({ ok: false, status: 403, headers: { get: () => 'application/json' },
      json: async () => ({ detail: '令牌无效' }), text: async () => '' }),
  });
  pf.renderShield(SHIELD_ITEMS);
  await pf.shieldRun('apply', ['doh_all']);
  await tick();
  assert.ok(env.document.getElementById('shield-out').textContent.startsWith('收紧失败：令牌无效'));
  await pf.shieldRun('revert', ['remote_assist']);
  await tick();
  assert.ok(env.document.getElementById('shield-out').textContent.startsWith('还原失败：令牌无效'));
});

test('F9 三个按钮都真的绑上了（不是摆设）', async () => {
  const calls = [];
  const { pf, env } = loadApp(REPO, Object.assign({ seedTags: { 'proc-search': 'INPUT' } }, {
    fetch: async (url, init) => {
      calls.push(url);
      /* 重新体检时后端会把完整的开关列表带回来（含「已记入还原日志」标记），照真实形状造 */
      return jsonOk(url.includes('dnscheck') ? { encrypted: null, detail: 'd' }
        : { results: [], score: 1, summary: 'x', checks: [], shield: SHIELD_ITEMS });
    },
  }));
  pf.bind();
  pf.renderShield(SHIELD_ITEMS);
  fire(env.document.getElementById('posture-dnscheck'), 'click');
  await tick();
  assert.ok(calls.includes('/api/security/shield/dnscheck'), '实测按钮没绑上');
  fire(env.document.getElementById('shield-apply'), 'click');
  await tick();
  assert.ok(calls.includes('/api/security/shield/apply'), '收紧按钮没绑上');
  fire(env.document.getElementById('shield-revert'), 'click');
  await tick();
  assert.ok(calls.includes('/api/security/shield/revert'), '还原按钮没绑上');
});
