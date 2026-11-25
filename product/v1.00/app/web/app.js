/* ============================================================
   电脑算力调度中心 · 前端逻辑（无依赖、无内联脚本）
   约束：
     - 只通过 /api/* 与后端交互，所有请求自动带 X-PF-Token
     - 不使用 innerHTML 拼接服务端数据，全部 textContent，天然免疫 XSS
     - 页面隐藏时暂停轮询，减少空转
   ============================================================ */
'use strict';

(function () {
  const TOKEN = (document.querySelector('meta[name="pf-token"]') || {}).content || '';
  const $ = (id) => document.getElementById(id);

  let snapshot = null;          // 最新快照
  let selected = null;          // {pid, name}
  let activeView = 'overview';
  let chatHistory = [];
  let clientLog = [];
  let sceneLoaded = false;
  let settingsLoaded = false;
  let prefsLoaded = false;
  let aboutLoaded = false;
  let securityLoaded = false;
  let scanLoaded = false;
  let scanEngineReady = false;
  let scanRunning = false;
  let scanTimer = null;
  let dialogResolve = null;
  let pollTimer = null;
  let pollErrors = 0;
  let pollIntervalMs = 1000;
  let errBadgeCount = 0;        /* 日志视图错误事件未读数（事件驱动徽章） */

  /* ---------------- 基础工具 ---------------- */
  function el(tag, attrs, ...kids) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const k of Object.keys(attrs)) {
        const v = attrs[k];
        if (v === null || v === undefined || v === false) continue;
        if (k === 'class') node.className = v;
        else if (k === 'text') node.textContent = v;
        else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
        else node.setAttribute(k, v);
      }
    }
    for (const kid of kids) {
      if (kid === null || kid === undefined || kid === false) continue;
      node.appendChild(typeof kid === 'string' ? document.createTextNode(kid) : kid);
    }
    return node;
  }

  function setText(id, text) {
    const n = $(id);
    if (n && n.textContent !== text) n.textContent = text;
  }

  /* 骨架屏：形状匹配的加载占位，感知等待短于 spinner（2026 通行做法） */
  function skeleton(box, n) {
    if (!box) return;
    box.textContent = '';
    for (let i = 0; i < (n || 4); i++) box.appendChild(el('div', { class: 'skel' }));
  }

  /* 侧栏折叠（localStorage 持久化，2026 专业工具标配） */
  function toggleSidebar() {
    const min = document.body.classList.toggle('sb-min');
    try { localStorage.setItem('pf_sidebar', min ? '1' : ''); } catch (_) { /* 隐私模式忽略 */ }
  }

  function restoreSidebar() {
    let v = '';
    try { v = localStorage.getItem('pf_sidebar') || ''; } catch (_) { /* ignore */ }
    if (v === '1') document.body.classList.add('sb-min');
  }

  /* 主题切换（v3：浅色/深色双主题；theme-init.js 已在渲染前设置初始值） */
  function toggleTheme() {
    const cur = document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'light';
    const next = cur === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    try { localStorage.setItem('pf_theme', next); } catch (_) { /* 隐私模式忽略 */ }
  }

  /* 键盘：1-8 切换视图、[ 折叠侧栏；输入控件聚焦或弹窗打开时不劫持 */
  const VIEW_ORDER = ['overview', 'processes', 'scenes', 'models',
    'security', 'bootstrap', 'settings', 'logs', 'about'];
  function onKeydown(e) {
    const t = e.target;
    if (t && /^(INPUT|SELECT|TEXTAREA)$/.test(t.tagName)) return;
    if (document.getElementById('dlg') && document.getElementById('dlg').open) return;
    if (e.key === '[') { toggleSidebar(); return; }
    const idx = Number(e.key);
    if (idx >= 1 && idx <= VIEW_ORDER.length) {
      switchView(VIEW_ORDER[idx - 1]);
    }
  }

  /* 数值格式化（唯一入口）：只接受 number 与数字字符串；
     null/空串/'N/A'/对象/Infinity 一律 '--'，绝不把 NaN 印到界面上 */
  function fmt(n, digits) {
    if (typeof n !== 'number' && typeof n !== 'string') return '--';
    if (n === '') return '--';
    const v = Number(n);
    if (!Number.isFinite(v)) return '--';
    return v.toFixed(digits === undefined ? 1 : digits);
  }

  function toast(msg, kind) {
    const box = $('toasts');
    const node = el('div', { class: 'toast ' + (kind || '') , text: msg });
    box.appendChild(node);
    setTimeout(() => node.remove(), 4200);
    if (kind === 'err' && activeView !== 'logs') setLogBadge(++errBadgeCount);
    logLine('[' + (kind === 'err' ? '错误' : '事件') + '] ' + msg);
  }

  /* 侧栏事件徽章：异常才出现，事件驱动而非用户巡逻（calm tech） */
  function setLogBadge(n) {
    const b = $('navbadge-logs');
    if (!b) return;
    errBadgeCount = n;
    b.hidden = n <= 0;
    b.textContent = n > 99 ? '99+' : String(n);
  }

  function setBootstrapBadge(missing) {
    const b = $('navbadge-bs');
    if (!b) return;
    b.hidden = !(missing > 0);
    b.textContent = String(missing);
  }

  function logLine(text) {
    clientLog.push({ t: new Date().toLocaleTimeString('zh-CN', { hour12: false }), text });
    if (clientLog.length > 200) clientLog.splice(0, clientLog.length - 200);
    if (activeView === 'logs') renderLogs();
  }

  async function api(path, opts) {
    opts = opts || {};
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), opts.timeout || 30000);
    const init = {
      method: opts.method || 'GET',
      signal: ctl.signal,
      cache: 'no-store',
      headers: { 'X-PF-Token': TOKEN }
    };
    if (opts.body !== undefined && opts.body !== null) {
      init.headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(opts.body);
    }
    try {
      const res = await fetch(path, init);
      if (!res.ok) {
        let msg = 'HTTP ' + res.status;
        try {
          const j = await res.json();
          msg = (j && (j.detail || j.message)) || msg;
        } catch (e) { /* 非 JSON 响应 */ }
        const err = new Error(msg);
        err.status = res.status;
        throw err;
      }
      const ct = res.headers.get('content-type') || '';
      return ct.indexOf('application/json') >= 0 ? res.json() : res.text();
    } finally {
      clearTimeout(timer);
    }
  }

  /* ---------------- 确认对话框 ---------------- */
  function confirmDialog(title, text, okLabel, danger) {
    return new Promise((resolve) => {
      dialogResolve = resolve;
      $('dlg-title').textContent = title;
      $('dlg-body').textContent = text;
      $('dlg-ok').textContent = okLabel || '确认';
      $('dlg-ok').className = danger ? 'btn danger' : 'btn primary';
      $('dlg').showModal();
    });
  }

  function closeDialog(value) {
    const dlg = $('dlg');
    if (dlg.open) dlg.close();
    if (dialogResolve) { dialogResolve(value); dialogResolve = null; }
  }

  /* ---------------- 视图切换 ---------------- */
  function switchView(name) {
    activeView = name;
    for (const b of document.querySelectorAll('.navbtn')) {
      b.classList.toggle('active', b.dataset.view === name);
    }
    for (const v of document.querySelectorAll('.view')) {
      v.classList.toggle('active', v.dataset.view === name);
    }
    if (name === 'scenes' && !sceneLoaded) loadScenes();
    if (name === 'models') refreshModels();
    if (name === 'security') { refreshSecurity(); if (!scanLoaded) refreshScan(); }
    if (name === 'bootstrap' && !bootstrapLoaded) loadBootstrap();
    if (name === 'settings' && !settingsLoaded) loadSettings();
    if (name === 'settings' && !prefsLoaded) loadPreferences();
    if (name === 'about' && !aboutLoaded) loadAbout();
    if (name === 'logs') { setLogBadge(0); renderLogs(); }
  }

  /* ---------------- 快照渲染 ---------------- */
  function renderSnapshot(d) {
    snapshot = d;
    const cpu = Number(d.cpu || 0);
    const mem = Number(d.mem_percent || 0);

    /* gauge 阈值变色（calm：紧张才把注意力拉过来） */
    const trackFor = (v) => v >= 95 ? ' danger' : v >= 85 ? ' warn' : '';
    const numFor = (v) => v >= 95 ? ' danger' : v >= 85 ? ' warn' : '';
    $('cpu-num').className = 'num' + numFor(cpu);
    $('cpu-bar').parentElement.className = 'track cpu' + trackFor(cpu);
    $('cpu-bar').style.width = Math.min(cpu, 100) + '%';
    $('mem-num').className = 'num' + numFor(mem);
    $('mem-bar').parentElement.className = 'track mem' + trackFor(mem);
    $('mem-bar').style.width = Math.min(mem, 100) + '%';

    $('kpi-cpu').textContent = fmt(cpu);
    $('kpi-cpu').appendChild(el('small', { text: '%' }));
    $('kpi-cpu-x').textContent = '采样 ' + (d.time || '--');
    $('kpi-mem').textContent = fmt(mem);
    $('kpi-mem').appendChild(el('small', { text: '%' }));
    const gbOf = (mb) => fmt(Math.round(Number(mb || 0) / 1024), 0);
    $('kpi-mem-x').textContent = gbOf(d.mem_used_mb) + ' / ' + gbOf(d.mem_total_mb) + ' GB';
    $('kpi-procs').textContent = String(d.process_count || 0);
    $('kpi-procs-x').textContent = (d.model_loaded ? d.model_loaded.length : 0) + ' 个本地模型已载入';

    const fg = (d.processes || []).find((p) => p.pid === d.foreground_pid);
    $('kpi-fg').textContent = fg ? fg.name : '--';
    setText('foot-fg', fg ? fg.name : '--');
    setText('foot-kernel', d.kernel_version || '--');
    setText('foot-port', String(location.port || '--'));

    $('dot-kernel').className = 'dot ' + (d.kernel_alive ? 'on' : 'off');
    setText('pill-kernel', d.kernel_alive ? '内核在线' : '内核离线');
    $('dot-cloud').className = 'dot ' + (d.model_loaded && d.model_loaded.length ? 'on' : 'warn');
    setText('pill-cloud', d.model_loaded && d.model_loaded.length ? '本地模型 ' + d.model_loaded.length : '云端模式');

    renderTop(d);
    renderFocus(d);
    renderProcessTable(d);
    renderVerdict(d);
    renderModelCard(d);
  }

  /* 总览·本地模型卡：主线是「更好地在本地跑本地模型」，第一屏先回答模型状态 */
  function renderModelCard(d) {
    const loaded = d.model_loaded || [];
    const names = loaded.map((m) => (m && (m.id || m.key)) || String(m || '')).filter(Boolean);
    $('mc-count').textContent = String(names.length);
    $('mc-names').textContent = names.length ? names.slice(0, 3).join('、') + (names.length > 3 ? ' 等 ' + names.length + ' 个' : '') : '未载入';
    const g = (d.gpu && d.gpu.gpus && d.gpu.gpus[0]) || null;
    if (g && Number.isFinite(Number(g.mem_used_mb)) && Number.isFinite(Number(g.mem_total_mb))) {
      $('mc-gpu').textContent = Math.round(g.mem_used_mb) + ' / ' + Math.round(g.mem_total_mb) + ' MB';
    } else {
      $('mc-gpu').textContent = d.gpu && d.gpu.available ? '--' : '无 NVIDIA GPU';
    }
    $('mc-kernel').textContent = d.kernel_alive ? '在线' : '离线';

    const dot = $('mc-dot');
    const status = $('mc-status');
    if (!d.kernel_alive) {
      dot.className = 'dot off';
      status.textContent = '调度内核离线，模型调度不可用';
    } else if (names.length) {
      dot.className = 'dot on';
      status.textContent = '本地模型已载入';
    } else {
      dot.className = 'dot warn';
      status.textContent = '本地模型未载入，可在「模型与对话」页启动';
    }
  }

  /* 状态判定条：总览第一眼回答「现在需要我做什么吗」（calm tech 中心化） */
  function renderVerdict(d) {
    const box = $('ov-verdict');
    const txt = $('verdict-text');
    const items = [];
    if (!d.kernel_alive) items.push(['bad', '内核未响应，调度指令不可用']);
    if (Number(d.mem_percent || 0) >= 95) items.push(['warn', '内存紧张（' + fmt(d.mem_percent) + '%），建议「清理内存」或回收后台进程']);
    else if (Number(d.cpu || 0) >= 95) items.push(['warn', 'CPU 持续饱和（' + fmt(d.cpu) + '%），可在「进程」视图聚焦关键应用']);
    if (items.length) {
      box.className = 'verdict ' + items[0][0];
      txt.textContent = '';
      txt.appendChild(el('b', { text: '需要处理：' }));
      txt.appendChild(document.createTextNode(items.map((x) => x[1]).join('；')));
      return;
    }
    box.className = 'verdict ok';
    txt.textContent = '';
    txt.appendChild(el('b', { text: '一切正常' }));
    txt.appendChild(document.createTextNode(' · 无需操作。异常发生时会在这里给出可执行建议。'));
  }

  function renderTop(d) {
    const list = (d.processes || []).slice()
      .sort((a, b) => (b.cpu - a.cpu) || (b.mem_mb - a.mem_mb))
      .slice(0, 8);
    const box = $('ov-top');
    box.textContent = '';
    if (!list.length) { box.appendChild(el('div', { class: 'empty', text: '暂无进程数据' })); return; }
    for (const p of list) {
      const bar = el('i');
      bar.style.width = Math.min(100, (p.cpu || 0)) + '%';
      box.appendChild(el('div', {
        class: 'topitem',
        title: '点击查看 ' + p.name,
        onclick: () => { switchView('processes'); selectProcess(p.pid, p.name); }
      },
        el('div', { class: 'nm' }, el('div', { text: p.name }), el('div', { class: 'bar' }, bar)),
        el('div', { class: 'tag' + (p.cpu > 20 ? ' hi' : ''), text: fmt(p.cpu) + '%' }),
        el('div', { class: 'tag', text: fmt(p.mem_mb, 0) + ' MB' })
      ));
    }
  }

  function renderFocus(d) {
    const fg = (d.processes || []).find((p) => p.pid === d.foreground_pid);
    const kv = $('ov-focus');
    kv.textContent = '';
    const rows = [
      ['前台应用', fg ? fg.name + '  (PID ' + fg.pid + ')' : '--'],
      ['进程总数', String(d.process_count || 0)],
      ['内核状态', d.kernel_alive ? '在线 · ' + (d.kernel_version || '') : '离线'],
      ['本地模型', (d.model_loaded || []).map((m) => m.id || m.key || m).join(', ') || '未载入'],
      ['采样时刻', d.time || '--']
    ];
    for (const row of rows) {
      kv.appendChild(el('div', { class: 'k', text: row[0] }));
      kv.appendChild(el('div', { class: 'v', text: row[1] }));
    }
  }

  /* ---------------- 进程表（增量更新，避免每秒重建 400 行） ---------------- */
  const rowMap = new Map();
  let lastOrder = '';

  function renderProcessTable(d) {
    if (!d) return;
    const q = ($('proc-search').value || '').trim().toLowerCase();
    const sort = $('proc-sort').value;
    let list = (d.processes || []).filter((p) =>
      !q || String(p.pid) === q || (p.name || '').toLowerCase().indexOf(q) >= 0);
    if (sort === 'cpu') list.sort((a, b) => (b.cpu - a.cpu) || (b.mem_mb - a.mem_mb));
    else if (sort === 'mem') list.sort((a, b) => (b.mem_mb - a.mem_mb) || (b.cpu - a.cpu));
    else if (sort === 'name') list.sort((a, b) => a.name.localeCompare(b.name) || a.pid - b.pid);
    else list.sort((a, b) => a.pid - b.pid);

    setText('proc-count', list.length + ' / ' + (d.process_count || 0) + ' 个进程');

    const body = $('proc-body');
    const order = list.map((p) => p.pid).join(',');
    const alive = new Set();

    for (const p of list) {
      alive.add(p.pid);
      let row = rowMap.get(p.pid);
      if (!row) {
        row = el('div', { class: 'row' });
        row.appendChild(el('span', { class: 'pid' }));
        row.appendChild(el('span', { class: 'nm' }));
        row.appendChild(el('span', { class: 'cpu' }));
        row.appendChild(el('span', { class: 'mem' }));
        row.appendChild(el('span', { class: 'status' }));
        row.appendChild(el('span', { class: 'tag' }));
        row.addEventListener('click', () => selectProcess(p.pid, p.name));
        rowMap.set(p.pid, row);
      }
      row.children[0].textContent = String(p.pid);
      let nm = p.name;
      if (p.children > 0) nm += '  (+' + p.children + ')';
      if (p.pid === d.foreground_pid) nm += '  [前台]';
      row.children[1].textContent = nm;
      row.children[2].textContent = fmt(p.cpu);
      row.children[3].textContent = fmt(p.mem_mb, 0);
      row.children[4].textContent = p.priority || '';
      const tag = row.children[5];
      const isCrit = p.critical === true;
      tag.textContent = isCrit ? '系统' : (p.cpu > 25 ? '占用高' : '');
      tag.className = 'tag' + (isCrit ? ' rt' : (p.cpu > 25 ? ' hi' : (p.cpu < 0.5 ? ' low' : '')));
      row.classList.toggle('sel', !!selected && selected.pid === p.pid);
    }

    for (const [pid, row] of rowMap) {
      if (!alive.has(pid)) { row.remove(); rowMap.delete(pid); }
    }

    if (order !== lastOrder) {
      lastOrder = order;
      if (!list.length) {
        body.textContent = '';
        body.appendChild(el('div', { class: 'empty', text: '没有匹配的进程' }));
      } else {
        const empty = body.querySelector('.empty');
        if (empty) empty.remove();
        body.querySelectorAll('.skel').forEach((n) => n.remove());
        for (const p of list) body.appendChild(rowMap.get(p.pid));
      }
    } else if (!list.length && !body.querySelector('.empty')) {
      body.textContent = '';
      body.appendChild(el('div', { class: 'empty', text: '没有匹配的进程' }));
    }
  }

  function selectProcess(pid, name) {
    selected = { pid, name };
    if (snapshot) renderProcessTable(snapshot);
    $('proc-who').textContent = name + ' (PID ' + pid + ')';
  }

  /* ---------------- 指令执行 ---------------- */
  async function runCommand(action, extra, confirmText) {
    if (confirmText) {
      const ok = await confirmDialog('确认执行', confirmText, '执行', action === 'kill_process');
      if (!ok) return null;
    }
    const body = Object.assign({ action: action }, extra || {});
    if (action === 'kill_process' || action === 'stress_process') body.confirm = true;
    // 后端把 _timeout 夹紧到 [1,600] 秒；前端必须留足余量，否则
    // start_router 这类 180 秒命令会在 90 秒先断开、留下孤儿回执。
    const backendSec = Number((extra && extra._timeout) || 0);
    const budgetMs = Math.max(90000, backendSec > 0 ? backendSec * 1000 + 10000 : 0);
    const r = await api('/api/command', { method: 'POST', body: body, timeout: budgetMs });
    if (!r || r.ok === false) {
      throw new Error((r && r.text) || '内核没有返回结果（可能已离线）');
    }
    logLine('执行 ' + action + (extra && extra.process_name ? ' → ' + extra.process_name : ''));
    return r;
  }

  async function guard(promise, okMsg) {
    try {
      const r = await promise;
      if (okMsg) toast(okMsg + (r && r.text ? '：' + String(r.text).slice(0, 120) : ''), 'ok');
      return r;
    } catch (e) {
      toast(e.message || String(e), 'err');
      return null;
    }
  }

  /* ---------------- 场景 ---------------- */
  async function loadScenes() {
    skeleton($('scene-list'), 3);
    try {
      const d = await api('/api/scenes');
      sceneLoaded = true;
      const box = $('scene-list');
      box.textContent = '';
      const items = d.scenes || [];
      if (!items.length) { box.appendChild(el('div', { class: 'empty', text: 'scenes.json 中没有场景' })); return; }
      for (const s of items) {
        box.appendChild(el('div', { class: 'scene' },
          el('div', { class: 'nm', text: s.name }),
          el('div', { class: 'desc', text: s.desc || '按预设组合调整电源与进程优先级' }),
          el('button', {
            class: 'btn primary sm', text: '套用场景',
            onclick: () => guard(runCommand('apply_scene', { scene: s.name },
              '将套用场景「' + s.name + '」：会切换电源方案并调整相关进程优先级。'), '场景已套用')
          })
        ));
      }
    } catch (e) {
      toast('读取场景失败：' + e.message, 'err');
    }
  }

  /* ---------------- 模型 ---------------- */
  async function refreshModels() {
    try {
      const [r, m] = await Promise.all([api('/api/router', { timeout: 25000 }), api('/api/models')]);
      renderRouter(r);
      const sel = $('router-model');
      const cur = sel.value;
      const items = (m.models || []).filter((x) => !(x.alias || '').match(/embed|rerank/i));
      sel.textContent = '';
      for (const it of items) {
        sel.appendChild(el('option', { value: it.key, text: it.alias || it.key }));
      }
      if (!items.length) sel.appendChild(el('option', { value: '', text: '未发现模型配置' }));
      else if (cur) sel.value = cur;
    } catch (e) {
      toast('读取模型状态失败：' + e.message, 'err');
    }
  }

  function renderRouter(r) {
    const kv = $('router-kv');
    kv.textContent = '';
    const text = (r && (r.text || (r.data && JSON.stringify(r.data)))) || '';
    const running = /running|true|已运行|运行中|state: ?run/i.test(text) && !/not running|stopped/i.test(text);
    $('dot-router').className = 'dot ' + (running ? 'on' : 'warn');
    setText('pill-router', running ? '路由运行中' : '路由未启动');
    const rows = [
      ['状态', running ? '运行中' : '未启动'],
      ['服务地址', 'http://127.0.0.1:8080'],
      ['详情', text ? text.slice(0, 260) : '未返回状态']
    ];
    for (const row of rows) {
      kv.appendChild(el('div', { class: 'k', text: row[0] }));
      kv.appendChild(el('div', { class: 'v', text: row[1] }));
    }
  }

  /* ---------------- 对话 ---------------- */
  function chatAppend(role, text) {
    const node = el('div', { class: 'msg ' + role, text: text });
    $('chat-list').appendChild(node);
    $('chat-list').scrollTop = $('chat-list').scrollHeight;
    return node;
  }

  async function sendChat() {
    const input = $('chat-input');
    const text = (input.value || '').trim();
    if (!text) return;
    input.value = '';
    chatAppend('user', text);
    chatHistory.push({ role: 'user', content: text });
    const target = $('chat-target').value;
    const bubble = chatAppend('bot', '');
    let acc = '';
    try {
      const res = await fetch('/api/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-PF-Token': TOKEN },
        body: JSON.stringify({ target: target, messages: chatHistory })
      });
      if (!res.ok) {
        let msg = 'HTTP ' + res.status;
        try { const j = await res.json(); msg = j.detail || msg; } catch (e) { /* ignore */ }
        throw new Error(msg);
      }
      const reader = res.body.getReader();
      const dec = new TextDecoder('utf-8');
      let buf = '';
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        buf += dec.decode(chunk.value, { stream: true });
        let idx;
        while ((idx = buf.indexOf('\n\n')) >= 0) {
          const block = buf.slice(0, idx);
          buf = buf.slice(idx + 2);
          for (const line of block.split('\n')) {
            if (line.indexOf('data:') !== 0) continue;
            const payload = line.slice(5).trim();
            if (!payload || payload === '[DONE]') continue;
            try {
              const j = JSON.parse(payload);
              if (j.error) { bubble.classList.add('err'); bubble.textContent = String(j.error).slice(0, 400); return; }
              const delta = j.choices && j.choices[0] && j.choices[0].delta && j.choices[0].delta.content;
              if (delta) { acc += delta; bubble.textContent = acc; }
            } catch (e) { /* 跳过非 JSON 分片 */ }
          }
          $('chat-list').scrollTop = $('chat-list').scrollHeight;
        }
      }
      if (!acc) { bubble.classList.add('sys'); bubble.textContent = '（模型没有返回内容）'; }
      else chatHistory.push({ role: 'assistant', content: acc });
    } catch (e) {
      bubble.classList.add('err');
      bubble.textContent = e.message || String(e);
    }
  }

  /* ---------------- 安全态势 ---------------- */
  async function refreshSecurity() {
    if (!securityLoaded) skeleton($('sec-audit'), 5);
    const [secRes, auditRes, posRes] = await Promise.allSettled([
      api('/api/security'), api('/api/audit?limit=40'), api('/api/security/posture', { timeout: 25000 })
    ]);
    if (secRes.status === 'fulfilled') {
      renderSecurity(secRes.value);
      securityLoaded = true;
    } else {
      const e = secRes.reason || {};
      toast('读取安全态势失败：' + (e.message || String(secRes.reason || '未知错误')), 'err');
    }
    if (auditRes.status === 'fulfilled') {
      renderAudit((auditRes.value && auditRes.value.items) || []);
    } else {
      const e = auditRes.reason || {};
      renderAudit([], '审计日志读取失败：' + (e.message || String(auditRes.reason || '未知错误')));
    }
    // 隐私防护 P0：体检失败只在本区块内说，不弹 toast、不影响上面两块
    if (posRes.status === 'fulfilled') {
      renderPosture(posRes.value);
    } else {
      const e = posRes.reason || {};
      renderPosture(null, (e.message || String(posRes.reason || '未知错误')));
    }
  }

  /* 接口字段可能随版本漂移（少一段、类型不对）：逐段归一，缺哪格说“未知”，
     其余照常渲染——不能让一个字段把整页打空（51 号） */
  function renderSecurity(s) {
    const kv = $('sec-kv');
    kv.textContent = '';
    const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v)) ? v : {};
    const arr = (v) => Array.isArray(v) ? v : [];
    const txt = (v) => {
      if (typeof v === 'string') return v || '--';
      if (typeof v === 'number' && Number.isFinite(v)) return String(v);
      if (typeof v === 'boolean') return String(v);
      return '--';
    };
    const num = (v) => (typeof v === 'number' && Number.isFinite(v)) ? String(v) : '--';
    const list = (v) => arr(v).map(txt).filter((x) => x !== '--');
    s = obj(s);
    const bind = obj(s.bind);
    const guard = obj(s.host_guard);
    const tok = obj(s.token);
    const docs = obj(s.docs);
    const lim = obj(s.limits);
    const ck = obj(s.cloud_key);
    const allowed = list(guard.allowed);
    const headers = list(s.headers);
    const host = txt(bind.host);
    const port = num(bind.port);
    const loop = bind.loopback_only === true ? '（仅回环）'
      : (bind.loopback_only === false ? '（对外暴露！）' : '（回环未知）');
    const fingerprint = txt(tok.fingerprint);
    const rpm = num(lim.requests_per_min);
    const aft = num(lim.auth_fail_threshold);
    const body = num(lim.body_bytes);
    const rows = [
      ['监听', host === '--' && port === '--' ? '未知（未回报）' : host + ':' + port + loop],
      ['Host 白名单', allowed.length ? allowed.join(', ') : '--'],
      ['令牌指纹', fingerprint !== '--' ? fingerprint : (tok.ready === false ? '未就绪' : '--')],
      ['令牌文件', txt(tok.path)],
      ['接口地图', docs.disabled === true ? '已关闭（/docs /openapi.json 均 404）'
        : (docs.disabled === false ? '未关闭（风险）' : '未知（未回报）')],
      ['请求限流', rpm === '--' && aft === '--' ? '未知（未回报）' : rpm + ' 次/分钟 · 认证失败 ' + aft + ' 次熔断'],
      ['请求体上限', body === '--' ? '--' : body + ' 字节'],
      ['安全响应头', headers.length ? headers.join(', ') : '--'],
      ['云端密钥', ck.encrypted === true ? 'DPAPI 加密存储'
        : (ck.encrypted === false ? (ck.source === 'env' ? '环境变量明文' : '未配置') : '未知（未回报）')],
      ['审计日志', txt(s.audit_log)]
    ];
    for (const row of rows) {
      kv.appendChild(el('div', { class: 'k', text: row[0] }));
      kv.appendChild(el('div', { class: 'v', text: row[1] }));
    }
    setText('sec-fp', '令牌 ' + fingerprint);
  }

  function renderAudit(items, error) {
    const box = $('sec-audit');
    box.textContent = '';
    if (error) { box.appendChild(el('div', { class: 'empty', text: error })); return; }
    const rows = Array.isArray(items) ? items.filter((it) => it && typeof it === 'object' && !Array.isArray(it)) : [];
    if (!rows.length) { box.appendChild(el('div', { class: 'empty', text: '最近没有安全事件' })); return; }
    for (const it of rows) {
      const meta = Object.keys(it).filter((k) => k !== 'ts' && k !== 'event')
        .map((k) => k + '=' + it[k]).join('  ');
      box.appendChild(el('div', { class: 'item' },
        el('span', { class: 'dt', text: it.ts || '' }),
        el('span', { class: 'ev', text: it.event || '' }),
        el('span', { class: 'meta', text: meta })));
    }
  }

  /* ---------------- 网络暴露面体检（隐私防护 P0，只读） ---------------- */
  async function refreshPosture() {
    setText('posture-summary', '正在体检…');
    try {
      renderPosture(await api('/api/security/posture', { timeout: 25000 }));
    } catch (e) {
      renderPosture(null, (e && e.message) || String(e));
    }
  }

  /* 字段逐段归一（51 号同款）：缺哪格写未知，不让一个坏字段把整块打空 */
  function renderPosture(p, error) {
    const box = $('posture-checks'), sum = $('posture-summary'), score = $('posture-score'), out = $('posture-outbound');
    if (!box || !sum || !score || !out) return;
    box.textContent = '';
    out.textContent = '';
    if (error) {
      score.textContent = '--';
      sum.textContent = '体检失败：' + error;
      box.appendChild(el('div', { class: 'empty', text: '未能读取体检结果' }));
      renderShield(null, error);
      return;
    }
    p = (p && typeof p === 'object' && !Array.isArray(p)) ? p : {};
    const arr = (v) => (Array.isArray(v) ? v : []);
    const txt = (v) => {
      if (typeof v === 'string') return v || '--';
      if (typeof v === 'number' && Number.isFinite(v)) return String(v);
      return '--';
    };
    const badge = { ok: ['ok', '正常'], warn: ['skip', '需注意'], unknown: ['na', '未知'], info: ['na', '信息'] };
    renderShield(p.shield);
    const checks = arr(p.checks).filter((c) => c && typeof c === 'object' && !Array.isArray(c));
    score.textContent = (typeof p.score === 'number' && Number.isFinite(p.score)) ? p.score + ' 分' : '--';
    sum.textContent = txt(p.summary);
    if (!checks.length) box.appendChild(el('div', { class: 'empty', text: '没有体检项目（未回报）' }));
    for (const c of checks) {
      const st = badge[c.status] ? c.status : 'unknown';
      const detail = [txt(c.detail), c.advice ? '建议：' + txt(c.advice) : '']
        .filter((x) => x && x !== '--').join('\n');
      box.appendChild(el('div', { class: 'check' },
        el('span', { class: 'badge ' + badge[st][0], text: badge[st][1] }),
        el('span', { class: 't', text: txt(c.title) + '：' + txt(c.value) }),
        el('span', { class: 'd', text: detail })));
    }
    const ao = (p.app_outbound && typeof p.app_outbound === 'object' && !Array.isArray(p.app_outbound)) ? p.app_outbound : {};
    const ev = (ao.events && typeof ao.events === 'object' && !Array.isArray(ao.events)) ? ao.events : {};
    const last = (ev.last && typeof ev.last === 'object' && !Array.isArray(ev.last)) ? ev.last : {};
    const rows = [['本应用会连出去的地方', '只在下面这些动作发生时，没有静默外联']];
    for (const d of arr(ao.declared)) {
      if (!d || typeof d !== 'object' || Array.isArray(d)) continue;
      rows.push([txt(d.what), txt(d.host) + ' — ' + txt(d.when)]);
    }
    const cnt = (k, label) => {
      const n = ev[k];
      const c = (typeof n === 'number' && Number.isFinite(n)) ? n : null;
      return label + '：' + (c === null ? '--' : c + ' 次' + (last[k] ? '（最近 ' + last[k] + '）' : ''));
    };
    rows.push(['审计日志里的外联（' + txt(ao.events_window) + '）',
      [cnt('chat_cloud', '云端对话'), cnt('bootstrap', '组件下载'), cnt('scan', '安全扫描'), cnt('exitip', 'IP 检测')].join(' · ')]);
    const ob = checks.find((c) => c.id === 'outbound');
    for (const r of arr(ob && ob.rows).slice(0, 20)) {
      if (!r || typeof r !== 'object' || Array.isArray(r)) continue;
      rows.push([txt(r.proc), txt(r.ip) + ':' + txt(r.port) + (r.plain === true ? '（明文端口）' : '') + ' ×' + txt(r.count)]);
    }
    for (const row of rows) {
      out.appendChild(el('div', { class: 'k', text: row[0] }));
      out.appendChild(el('div', { class: 'v', text: row[1] }));
    }
  }

  /* 防护开关：一项一条，状态与上方体检项同源（开关说关上了，体检一定显示正常） */
  let shieldItems = [];
  function renderShield(list, error) {
    const box = $('shield-items');
    if (!box) return;
    box.textContent = '';
    const items = (Array.isArray(list) ? list : []).filter((x) => x && typeof x === 'object' && !Array.isArray(x));
    shieldItems = items;
    if (error) {
      box.appendChild(el('div', { class: 'empty', text: '开关状态读取失败：' + error }));
      return;
    }
    if (!items.length) {
      box.appendChild(el('div', { class: 'empty', text: '没有可用的开关（未回报）' }));
      return;
    }
    const st = { on: ['ok', '已收紧'], off: ['skip', '未收紧'], unknown: ['na', '读不到'] };
    for (const it of items) {
      const s = st[it.state] ? it.state : 'unknown';
      const on = it.state === 'on';
      const title = (typeof it.title === 'string' && it.title) || String(it.id || '开关');
      const btn = el('button', {
        class: 'btn sm', text: on ? '还原' : (it.recommended === true ? '收紧' : '收紧（可选）'),
        onClick: () => shieldRun(on ? 'revert' : 'apply', [it.id])
      });
      if (it.state === 'unknown') btn.disabled = true;
      const scope = (typeof it.scope === 'string' && it.scope) ? ' · ' + it.scope : '';
      const lines = [
        (typeof it.why === 'string' && it.why) || '',
        (typeof it.risk === 'string' && it.risk) ? '影响：' + it.risk : '',
        (!on && it.admin === true) ? '需要管理员权限' : ''
      ].filter(Boolean).join('\n');
      box.appendChild(el('div', { class: 'check' },
        el('span', { class: 'badge ' + st[s][0], text: st[s][1] }),
        el('span', { class: 'grow' },
          el('span', { class: 't', text: title + scope }),
          el('span', { class: 'd', text: lines || ' ' })),
        btn));
    }
  }

  async function shieldRun(kind, ids) {
    const out = $('shield-out');
    const apply = kind !== 'revert';
    const path = apply ? '/api/security/shield/apply' : '/api/security/shield/revert';
    if (out) out.textContent = apply ? '正在收紧…' : '正在还原…';
    try {
      const r = await api(path, { method: 'POST', body: { ids }, timeout: 90000 });
      const res = (r && Array.isArray(r.results)) ? r.results.filter((x) => x && typeof x === 'object') : [];
      /* 名称以后端给的为准；后端没给就用界面上已有的标题，绝不把内部代号（doh_all 这种）甩给用户 */
      const known = {};
      for (const it of shieldItems) if (it && typeof it.id === 'string') known[it.id] = it.title;
      const done = [], failed = [];
      for (const x of res) {
        const fallback = known[x.id];
        const name = (typeof x.title === 'string' && x.title) ||
          (typeof fallback === 'string' && fallback) || '其中一项';
        if (x.ok === true) done.push(name);
        else failed.push(name + '：' + ((typeof x.error === 'string' && x.error) || '没有改成') +
          (typeof x.note === 'string' && x.note ? '\n  ' + x.note.split('\n').join('\n  ') : ''));
      }
      const parts = [];
      if (done.length) parts.push((apply ? '已收紧：' : '已还原：') + done.join('、') + '。');
      if (failed.length) parts.push((apply ? '没改成：' : '没还原成：') + failed.join('\n'));
      if (out) out.textContent = parts.join('\n') || '服务没有返回结果';
      toast(parts[0] ? parts[0].split('\n')[0] : '服务没有返回结果', failed.length ? 'err' : '');
    } catch (e) {
      const msg = (e && e.message) || String(e);
      if (out) out.textContent = (apply ? '收紧失败：' : '还原失败：') + msg;
      toast((apply ? '收紧失败：' : '还原失败：') + msg, 'err');
    } finally {
      refreshPosture();
    }
  }

  async function shieldApplyRecommended() {
    // 只带「确实是未收紧」的；读不到状态的不捎上（单项按钮对它也是禁用的，两个入口保持一致）
    const ids = shieldItems.filter((x) => x.recommended === true && x.state === 'off').map((x) => x.id);
    if (!ids.length) {
      if ($('shield-out')) $('shield-out').textContent = '推荐项本来就是收紧的，没有需要改的。';
      return;
    }
    await shieldRun('apply', ids);
  }

  async function shieldRevertAll() {
    const ids = shieldItems.filter((x) => x.journaled === true).map((x) => x.id);
    if (!ids.length) {
      if ($('shield-out')) $('shield-out').textContent = '没有需要还原的（这个应用没有改过你的设置，或已经还原过）。';
      return;
    }
    await shieldRun('revert', ids);
  }

  /* 实测 DNS：用户点了才做，会发出一次域名查询（查的是一个不存在的随机名字） */
  async function dnsCheck() {
    const btn = $('posture-dnscheck');
    if (!btn || btn.disabled) return;
    btn.disabled = true;
    setText('posture-dnscheck-out', '正在解析一个随机域名并查看连接…');
    try {
      const r = await api('/api/security/shield/dnscheck', { method: 'POST', timeout: 30000 });
      const ok = (r && typeof r === 'object');
      const enc = ok ? r.encrypted : undefined;
      const head = enc === true ? '是密文。' : (enc === false ? '不是密文。' : '这次判断不了。');
      setText('posture-dnscheck-out', head + ((ok && typeof r.detail === 'string' && r.detail) ? r.detail : '服务没有返回结果'));
    } catch (e) {
      setText('posture-dnscheck-out', '验证失败：' + ((e && e.message) || String(e)));
    } finally {
      btn.disabled = false;
    }
  }

  /* 公网 IP 只在用户点击后查一次；页面已明示「对方会看到你的 IP」，点击即知情 */
  async function checkExitIp() {
    const btn = $('posture-exitip');
    if (!btn || btn.disabled) return;
    btn.disabled = true;
    setText('posture-exitip-out', '正在向 api.ipify.org 请求…');
    try {
      const r = await api('/api/security/posture/exitip', { method: 'POST', timeout: 15000 });
      const ip = (r && typeof r === 'object' && typeof r.ip === 'string') ? r.ip : '';
      setText('posture-exitip-out', ip ? '公网 IP：' + ip + '（来源 api.ipify.org，' + ((r && r.ts) || '') + '）'
        : '检测失败：服务没有返回 IP');
    } catch (e) {
      setText('posture-exitip-out', '检测失败：' + ((e && e.message) || String(e)));
    } finally {
      btn.disabled = false;
    }
  }

  function updateScanButton() {
    const btn = $('scan-start');
    const consent = $('scan-eula');
    if (!btn) return;
    btn.disabled = !(scanEngineReady && !scanRunning && consent && consent.checked === true);
  }

  function renderScan(d) {
    d = (d && typeof d === 'object') ? d : {};
    const eng = (d.engine && typeof d.engine === 'object') ? d.engine : {};
    const sig = (eng.signature && typeof eng.signature === 'object') ? eng.signature : {};
    const ready = eng.ready === true;
    const present = eng.present === true;
    scanEngineReady = ready;
    scanRunning = d.running === true;

    let engineText;
    if (eng.available === false) engineText = '模块不可用：' + String(eng.error || '未知错误');
    else if (ready) engineText = '引擎就绪 · ' + String(sig.signer || sig.signer_hint || '已完成验签');
    else if (present) engineText = '已下载，尚未验签';
    else engineText = '未下载（先到「启动依赖自检」补齐 KVRT）';
    setText('scan-engine', engineText);

    const cb = $('scan-eula');
    if (cb) {
      cb.disabled = !ready;
      if (!ready) cb.checked = false;
    }
    updateScanButton();

    let state;
    if (d.running === true) {
      state = '扫描进行中：' + String(d.scope || '--') + ' · 开始于 ' + String(d.started || '--');
    } else if (d.error) {
      state = '上次扫描失败：' + String(d.error);
    } else if (d.finished) {
      const result = (d.result && typeof d.result === 'object') ? d.result : {};
      const verdict = (result.verdict && typeof result.verdict === 'object') ? result.verdict : {};
      state = '上次扫描结束：' + String(d.finished) +
        (verdict.verdict ? ' · 判定 ' + String(verdict.verdict) : '') +
        (verdict.reason ? ' · ' + String(verdict.reason) : '');
    } else {
      state = ready ? '等待你勾选 EULA 后开始' : '引擎尚未就绪，不能开始扫描';
    }
    setText('scan-state', state);

    const out = $('scan-out');
    if (out) {
      const result = (d.result && typeof d.result === 'object') ? d.result : null;
      if (result) {
        const parsed = (result.parsed && typeof result.parsed === 'object') ? result.parsed : {};
        const verdict = (result.verdict && typeof result.verdict === 'object') ? result.verdict : {};
        const scan = (result.scan && typeof result.scan === 'object') ? result.scan : {};
        let text;
        try {
          text = JSON.stringify({
            verdict: verdict.verdict || '--',
            reason: verdict.reason || '--',
            files_scanned: parsed.files_scanned,
            threat_count: parsed.threat_count,
            exit_code: scan.exit_code,
            duration_sec: scan.duration_sec
          }, null, 2);
        } catch (_) { text = String(result); }
        out.hidden = false;
        out.textContent = text;
      } else if (d.error) {
        out.hidden = false;
        out.textContent = String(d.error);
      } else {
        out.hidden = true;
        out.textContent = '';
      }
    }
    if (d.running === true) scheduleScanPoll();
  }

  function scheduleScanPoll() {
    if (scanTimer) return;
    scanTimer = setTimeout(() => {
      scanTimer = null;
      refreshScan();
    }, 2500);
  }

  async function refreshScan() {
    try {
      const d = await api('/api/security/scan/status', { timeout: 10000 });
      scanLoaded = true;
      renderScan(d);
    } catch (e) {
      setText('scan-engine', '状态读取失败');
      setText('scan-state', '无法读取 KVRT 状态：' + (e.message || String(e)));
      scanEngineReady = false;
      updateScanButton();
    }
  }

  function syncScanScope() {
    const custom = $('scan-scope').value === 'custom';
    const label = $('scan-path-label');
    const input = $('scan-path');
    if (label) label.hidden = !custom;
    if (input) input.hidden = !custom;
  }

  async function startScan() {
    const consent = $('scan-eula');
    if (!scanEngineReady) { toast('KVRT 引擎未就绪，请先在组件自检里补齐并验签', 'err'); return; }
    if (!consent || consent.checked !== true) {
      toast('请先勾选并同意 KVRT EULA；应用不代你接受协议', 'err');
      return;
    }
    const scope = $('scan-scope').value;
    const target = scope === 'custom' ? $('scan-path').value.trim() : '';
    if (scope === 'custom' && !target) { toast('自定义范围必须填写绝对路径', 'err'); return; }
    let level = 0;
    try { level = parseInt($('scan-level').value, 10) || 0; } catch (_) { level = 0; }
    if (level > 0) {
      const ok = await confirmDialog('启用威胁处置',
        '处置是删除/清除动作，不可撤销。\n\n本次等级 ' + level +
        '，目标：' + (target || '系统核心区域') + '。\n\n只建议在你明确知道风险时使用；默认应保持「只报告」。',
        '我确认处置', true);
      if (!ok) return;
    }
    let timeout = 3600;
    try { timeout = parseInt($('scan-timeout').value, 10) || 3600; } catch (_) { timeout = 3600; }
    timeout = Math.max(30, Math.min(timeout, 14400));

    const body = {
      scope, path: target, process_level: level, timeout_sec: timeout,
      accept_eula: true
    };
    if (level > 0) body.disinfect_confirm = 'yes';

    const btn = $('scan-start');
    btn.disabled = true;
    btn.textContent = '启动中…';
    try {
      const out = await api('/api/security/scan', { method: 'POST', body, timeout: 30000 });
      toast(out && out.started ? '扫描已启动，正在后台执行' : '扫描未启动', out && out.started ? 'ok' : 'err');
      await refreshScan();
    } catch (e) {
      toast('启动扫描失败：' + e.message, 'err');
      setText('scan-state', '启动失败：' + e.message);
    } finally {
      btn.textContent = '开始扫描';
      updateScanButton();
    }
  }

  async function runSelfcheck() {
    const btn = $('sec-selfcheck');
    btn.disabled = true;
    btn.textContent = '自检中…';
    const box = $('sec-checks');
    box.textContent = '';
    box.appendChild(el('div', { class: 'empty', text: '正在发起真实攻击请求…' }));
    try {
      const r = await api('/api/selfcheck', { method: 'POST', body: {}, timeout: 60000 });
      box.textContent = '';
      for (const c of r.checks || []) {
        box.appendChild(el('div', { class: 'check' },
          el('span', { class: 'badge ' + (c.pass ? 'ok' : 'bad'), text: c.pass ? 'PASS' : 'FAIL' }),
          el('div', {},
            el('div', { class: 't', text: c.name }),
            el('div', { class: 'd', text: '期望 ' + c.expect + ' · 实际 ' + c.actual }))));
      }
      toast(r.ok ? '自检全部通过' : '自检发现未拦截项', r.ok ? 'ok' : 'err');
      refreshSecurity();
    } catch (e) {
      box.textContent = '';
      box.appendChild(el('div', { class: 'empty', text: '自检失败：' + e.message }));
      toast('自检失败：' + e.message, 'err');
    } finally {
      btn.disabled = false;
      btn.textContent = '立即自检';
    }
  }

  /* ---------------- 组件自检（V0.10 bootstrapping） ---------------- */
  let bootstrapLoaded = false;
  let bootstrapData = null;

  function bsBadgeFor(c) {
    if (c.system_impact && c.system_impact.writes_system_drivers) return ['bs-sys', '系统级'];
    if (c.present && c.ready) return ['bs-ok', '就绪'];
    if (c.present) return ['bs-miss', '已装未就绪'];
    return ['bs-miss', '缺失'];
  }

  function renderBootstrap(d) {
    const box = $('bs-list');
    const sum = $('bs-summary');
    const state = $('bs-state');
    box.textContent = '';
    sum.textContent = '';

    if (d.available === false) {
      state.textContent = '模块不可用（应用其余功能不受影响）';
      sum.appendChild(el('div', { class: 'k', text: '自检模块' }));
      sum.appendChild(el('div', { class: 'v', text: String(d.error || '不可用') }));
      box.appendChild(el('div', { class: 'empty',
        text: '组件自检模块加载失败，应用其余功能不受影响。详情见日志视图。' }));
      $('bs-install').disabled = true;
      $('bs-wizard').disabled = true;
      return;
    }

    bootstrapLoaded = true;
    const s = d.summary || {};
    state.textContent = '自检于 ' + String(d.checked_at || '--') + (d.cached ? '（缓存）' : '（实时）');
    const kv = [
      ['组件总数', String(s.total ?? '--')],
      ['已就绪', String(s.present ?? '--')],
      ['缺失', String(s.missing ?? '--')],
      ['阻塞启动', String((d.summary || {}).blocking ?? 0)],
    ];
    for (const [k, v] of kv) {
      sum.appendChild(el('div', { class: 'k', text: k }));
      sum.appendChild(el('div', { class: 'v', text: v }));
    }

    const dp = d.data_paths || {};
    setText('bs-paths', '数据目录：' + String(dp.data_root || '--') +
      (dp.legacy_root ? '\n历史兼容目录：' + dp.legacy_root : ''));

    for (const c of d.components || []) {
      const [cls, label] = bsBadgeFor(c);
      const lines = [String(c.detail || '')];
      if (c.pinned_version) lines.push('锁定版本 ' + c.pinned_version);
      if (c.license_note) lines.push(c.license_note);
      if (!c.present && c.action) lines.push('补齐方式：' + c.action);
      if (c.system_impact && c.system_impact.writes_system_drivers) {
        lines.push('⚠ 系统级安装：写系统驱动/服务、需管理员、可能冲突或要求重启；' +
          (c.system_impact.app_accepts_eula_on_behalf_of_user === false
            ? '应用不代你接受任何协议，向导内一切选项由你亲自决定。' : ''));
      }
      box.appendChild(el('div', { class: 'check' },
        el('span', { class: 'badge ' + cls, text: label }),
        el('div', {},
          el('div', { class: 't', text: c.name + '（' + c.id + '）' + (c.required ? ' · 必需' : ' · 可选') }),
          el('div', { class: 'd', text: lines.filter(Boolean).join('\n') }))));
    }

    const missAcq = (d.components || []).some((x) => !x.present && x.acquirable);
    $('bs-install').disabled = !missAcq;
    const kf = (d.components || []).find((x) => x.id === 'kaspersky_free') || {};
    $('bs-wizard').disabled = !(kf.present);
    setBootstrapBadge((d.summary || {}).missing || 0);
  }

  async function loadBootstrap(force) {
    const btn = $('bs-refresh');
    btn.disabled = true;
    setText('bs-state', force ? '正在重新自检…' : '正在读取…');
    if (!bootstrapLoaded) skeleton($('bs-list'), 6);
    try {
      const d = await api(force ? '/api/bootstrap/refresh' : '/api/bootstrap/check',
        force ? { method: 'POST', body: {}, timeout: 120000 } : { timeout: 20000 });
      bootstrapData = d;
      renderBootstrap(d);
    } catch (e) {
      setText('bs-state', '读取失败');
      const box = $('bs-list');
      box.textContent = '';
      box.appendChild(el('div', { class: 'empty', text: '自检读取失败：' + e.message }));
    } finally {
      btn.disabled = false;
    }
  }

  function bsOut(obj) {
    const box = $('bs-out');
    box.hidden = false;
    let txt;
    try { txt = JSON.stringify(obj, null, 2); } catch (_) { txt = String(obj); }
    if (txt.length > 4000) txt = txt.slice(0, 4000) + '\n…（截断）';
    box.textContent = txt;
  }

  async function bsInstall() {
    const comps = (bootstrapData && bootstrapData.components) || [];
    const target = comps.find((x) => !x.present && x.acquirable);
    if (!target) { toast('没有可在线补齐的缺失组件', 'err'); return; }
    const sys = target.system_impact && target.system_impact.writes_system_drivers;
    const ok = await confirmDialog('同意下载',
      '将从官方源下载「' + target.name + '」并做签名校验。' +
      (sys ? '\n\n注意：这是系统级杀毒软件安装器，后续安装需管理员权限并写入系统驱动与服务。' : '') +
      '\n\n下载只落应用数据目录，不会自动安装；验签不过一律标记不可用。',
      '同意下载', false);
    if (!ok) return;
    // 用户已通过上面的确认框表达同意；一次性同意令牌由服务端在处理该请求时
    // 签发并立即消费，不下发浏览器、不再是源码里可读的硬编码常量。
    const btn = $('bs-install');
    btn.disabled = true;
    btn.textContent = '下载与验签中…';
    try {
      const out = await api('/api/bootstrap/install',
        { method: 'POST', body: { component_id: target.id, consent: 'yes' }, timeout: 300000 });
      bsOut(out);
      toast(out.executed ? ('「' + target.name + '」处理完成') : ('未执行：' + (out.reason || '原因见输出区')),
        out.executed ? 'ok' : 'err');
      await loadBootstrap(true);
    } catch (e) {
      toast('下载失败：' + e.message, 'err');
    } finally {
      btn.disabled = false;
      btn.textContent = '同意并补齐缺失组件';
    }
  }

  async function bsWizard() {
    const comps = (bootstrapData && bootstrapData.components) || [];
    const kf = comps.find((x) => x.id === 'kaspersky_free') || {};
    if (!kf.present) { toast('请先下载官方安装器', 'err'); return; }
    const ok = await confirmDialog('启动厂商安装向导',
      '即将启动卡巴斯基官方交互式安装向导。这是系统级动作：需要管理员权限、写入系统驱动与服务，' +
      '可能与已有安全软件冲突、要求重启。\n\n应用不代你接受 EULA / 隐私政策 / KSN，不静默安装；' +
      '向导中的一切选项由你亲自决定。',
      '启动向导', true);
    if (!ok) return;
    // 第二道同意同样只传意图；一次性令牌由服务端签发并消费。
    const btn = $('bs-wizard');
    btn.disabled = true;
    try {
      const out = await api('/api/bootstrap/wizard',
        { method: 'POST', body: { component_id: 'kaspersky_free', install_consent: 'yes' }, timeout: 60000 });
      bsOut(out);
      toast(out.launched ? '官方安装向导已启动，请在向导中完成安装' : ('未启动：' + (out.reason || '')),
        out.launched ? 'ok' : 'err');
    } catch (e) {
      toast('启动失败：' + e.message, 'err');
    } finally {
      btn.disabled = false;
    }
  }

  /* ---------------- 设置 ---------------- */
  async function loadSettings() {
    try {
      const s = await api('/api/settings');
      settingsLoaded = true;
      $('set-base').value = s.cloud.base_url || '';
      $('set-model').value = s.cloud.model || '';
      $('set-key').value = '';
      $('set-key').placeholder = s.cloud.has_key
        ? '已保存（' + (s.cloud.source === 'vault' ? 'DPAPI 加密' : '环境变量明文') + '），留空则不修改'
        : '尚未配置';
      $('set-prompt').value = s.system_prompt || '';
      const kv = $('set-info');
      kv.textContent = '';
      const rows = [
        ['令牌指纹', s.token_fingerprint || '--'],
        ['内核目录', s.kernel_dir],
        ['程序目录', s.app_dir],
        ['密钥来源', s.cloud.source === 'vault' ? 'DPAPI 加密库' : (s.cloud.source === 'env' ? '环境变量（明文）' : '未配置')]
      ];
      for (const row of rows) {
        kv.appendChild(el('div', { class: 'k', text: row[0] }));
        kv.appendChild(el('div', { class: 'v', text: row[1] }));
      }
    } catch (e) {
      settingsLoaded = false;
      const out = $('set-out');
      out.hidden = false;
      out.textContent = '设置读取失败，暂不允许保存（避免用空值覆盖现有配置）：' + e.message;
      toast('读取设置失败：' + e.message, 'err');
    }
  }

  async function saveSettings() {
    /* 49 号：没成功读过设置就保存，等于用空串覆盖磁盘上的真实配置 */
    if (!settingsLoaded) {
      const out = $('set-out');
      out.hidden = false;
      out.textContent = '设置尚未读取成功，已取消保存（避免用空值覆盖现有配置）';
      toast('设置尚未读取成功，已取消保存', 'err');
      return;
    }
    const body = {
      base_url: $('set-base').value.trim(),
      model: $('set-model').value.trim(),
      system_prompt: $('set-prompt').value
    };
    const key = $('set-key').value.trim();
    if (key) body.api_key = key;
    const out = $('set-out');
    try {
      const r = await api('/api/settings', { method: 'POST', body: body });
      out.hidden = false;
      out.textContent = '已保存：' + (r.changed || []).join(', ') + '；云端可用：' + (r.cloud_ready ? '是' : '否');
      toast('设置已保存', 'ok');
      $('set-key').value = '';
      loadSettings();
    } catch (e) {
      out.hidden = false;
      out.textContent = '保存失败：' + e.message;
      toast('保存失败：' + e.message, 'err');
    }
  }

  async function testCloud() {
    const out = $('set-out');
    out.hidden = false;
    out.textContent = '正在测试云端连接…';
    try {
      const r = await api('/api/cloud/test', { method: 'POST', body: {}, timeout: 40000 });
      out.textContent = (r.ok ? '连接成功' : '连接失败') +
        ' · ' + (typeof r.status === 'number' ? 'HTTP ' + r.status : '未收到上游响应') +
        ' · ' + r.latency_ms + ' ms' + (r.model_count ? ' · ' + r.model_count + ' 个模型' : '') +
        (r.detail ? '\n' + r.detail : '');
    } catch (e) {
      out.textContent = '测试失败：' + e.message;
    }
  }

  async function clearKey() {
    const ok = await confirmDialog('清除云端密钥', '删除本机加密保存的 API Key，之后将回落到环境变量配置。', '清除', true);
    if (!ok) return;
    try {
      await api('/api/settings', { method: 'POST', body: { clear_key: true } });
      toast('已清除本机密钥', 'ok');
      loadSettings();
    } catch (e) {
      toast('清除失败：' + e.message, 'err');
    }
  }

  /* ---------------- 应用偏好 ---------------- */
  async function loadPreferences() {
    try {
      const p = await api('/api/preferences');
      prefsLoaded = true;
      pollIntervalMs = Number(p.poll_interval_ms) || 1000;
      $('pf-autostart').checked = !!p.autostart_active;
      $('pf-close').value = p.close_action === 'tray' ? 'tray' : 'exit';
      $('pf-poll').value = String(p.poll_interval_ms || 1000);
    } catch (e) {
      prefsLoaded = false;
      const out = $('pf-out');
      out.hidden = false;
      out.textContent = '偏好读取失败：' + e.message;
    }
  }

  async function savePreferences() {
    if (!prefsLoaded) { toast('偏好尚未读取成功，已取消保存', 'err'); return; }
    const body = {
      autostart: $('pf-autostart').checked,
      close_action: $('pf-close').value,
      poll_interval_ms: Number($('pf-poll').value) || 1000
    };
    const out = $('pf-out');
    try {
      const r = await api('/api/preferences', { method: 'POST', body });
      pollIntervalMs = Number(r.preferences.poll_interval_ms) || pollIntervalMs;
      schedulePoll();
      out.hidden = false;
      out.textContent = '偏好已保存。' + (r.preferences.autostart_active ? '开机自启已开启。' : '开机自启已关闭。');
      toast('偏好已保存', 'ok');
    } catch (e) {
      out.hidden = false;
      out.textContent = '保存失败：' + e.message;
      toast('保存失败：' + e.message, 'err');
    }
  }

  /* ---------------- 日志 / 配置导出（带令牌拉取 blob） ---------------- */
  async function downloadBlob(path, fallbackName) {
    const res = await fetch(path, { headers: { 'X-PF-Token': TOKEN }, cache: 'no-store' });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const blob = await res.blob();
    const a = document.createElement('a');
    const url = URL.createObjectURL(blob);
    a.href = url;
    a.download = fallbackName;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  async function exportLogs() {
    const out = $('pf-exp-out');
    try {
      await downloadBlob('/api/export/logs', 'powerfocus-logs.txt');
      out.hidden = false;
      out.textContent = '运行日志已导出（本会话与落盘日志汇总，不含密钥）。';
    } catch (e) {
      out.hidden = false;
      out.textContent = '导出失败：' + e.message;
    }
  }

  async function exportConfig() {
    const out = $('pf-exp-out');
    try {
      await downloadBlob('/api/export/config', 'powerfocus-config.json');
      out.hidden = false;
      out.textContent = '非敏感配置已备份；API Key 在本机加密库内，不在此备份。';
    } catch (e) {
      out.hidden = false;
      out.textContent = '导出失败：' + e.message;
    }
  }

  /* ---------------- 关于 / 更新检查 ---------------- */
  async function loadAbout() {
    try {
      const a = await api('/api/about');
      aboutLoaded = true;
      const kv = $('about-kv');
      kv.textContent = '';
      const rows = [
        ['应用', a.name],
        ['对外版本', a.release],
        ['代码槽位', a.slot],
        ['内核版本', a.kernel_version],
        ['Python', a.python],
        ['运行形态', a.frozen ? '打包 exe' : '源码运行']
      ];
      for (const row of rows) {
        kv.appendChild(el('div', { class: 'k', text: row[0] }));
        kv.appendChild(el('div', { class: 'v', text: String(row[1] || '--') }));
      }
      const links = $('about-links');
      links.textContent = '';
      const linkRows = [['源码仓库', a.source_url], ['问题反馈', a.issues_url], ['发布列表', a.releases_url]];
      for (const row of linkRows) {
        links.appendChild(el('div', { class: 'k', text: row[0] }));
        const v = el('div', { class: 'v' });
        v.appendChild(el('a', { href: row[1], target: '_blank', rel: 'noopener noreferrer', text: row[1] }));
        links.appendChild(v);
      }
    } catch (e) {
      aboutLoaded = false;
      toast('关于信息读取失败：' + e.message, 'err');
    }
  }

  async function checkUpdate() {
    const out = $('about-update-out');
    const detail = $('about-update-detail');
    out.textContent = '正在查询公开 Release…';
    detail.hidden = true;
    detail.textContent = '';
    try {
      const r = await api('/api/update-check', { timeout: 8000 });
      if (!r.checked) {
        out.textContent = '未能完成检查：' + (r.reason || '网络不可用');
        return;
      }
      if (r.update_available) {
        out.textContent = '发现新版本：' + r.latest + '（当前 ' + r.current + '）';
        detail.hidden = false;
        detail.textContent = '发布时间：' + (r.published_at || '--') + '。本应用不会自动下载升级，请前往发布页手动获取。';
        detail.appendChild(document.createTextNode(' '));
        detail.appendChild(el('a', { href: r.url, target: '_blank', rel: 'noopener noreferrer', text: '打开发布页' }));
      } else if (r.latest) {
        out.textContent = '已是最新版本（' + r.current + '）';
      } else {
        out.textContent = r.note || '仓库暂无正式 Release';
      }
    } catch (e) {
      out.textContent = '检查失败：' + e.message;
    }
  }

  /* ---------------- 首次引导 ---------------- */
  const ONBOARD_STEPS = [
    { title: '欢迎使用 PowerFocus', body: '这是一台跑在你本机的算力调度台：把有限的 CPU、内存和显存优先让给正在用的应用和本地模型。所有数据只走本机回环，不向外发送。' },
    { title: '选一个要保障的目标', body: '在「进程」页选中一个应用后，可以聚焦提速、回收内存或冻结后台；关键操作都会先二次确认。' },
    { title: '接上你的本地模型', body: '在「模型与对话」页启动本地模型路由，显存与内存状态会摆到总览第一屏；没有本地模型时，它也能作为通用调度台使用。' },
    { title: '安全与隐私基线', body: '「安全态势」页可以只读体检本机暴露面，按需一键收紧；每项改动都先记原值、可还原，并写入审计日志。' }
  ];
  let obIndex = 0;

  function renderOnboard() {
    const s = ONBOARD_STEPS[obIndex];
    $('ob-step').textContent = (obIndex + 1) + ' / ' + ONBOARD_STEPS.length;
    $('ob-title').textContent = s.title;
    $('ob-body').textContent = s.body;
    $('ob-next').textContent = obIndex === ONBOARD_STEPS.length - 1 ? '完成' : '下一步';
  }

  async function finishOnboard() {
    $('onboard').hidden = true;
    try { await api('/api/preferences', { method: 'POST', body: { onboarded: true } }); }
    catch (_) { /* 标记失败不阻断使用，下次启动再问 */ }
  }

  function nextOnboard() {
    if (obIndex < ONBOARD_STEPS.length - 1) { obIndex += 1; renderOnboard(); }
    else finishOnboard();
  }

  function maybeOnboard(prefs) {
    if (prefs && prefs.onboarded) return;
    obIndex = 0;
    renderOnboard();
    $('onboard').hidden = false;
  }

  /* ---------------- 日志 ---------------- */
  function renderLogs() {
    const box = $('log-list');
    const lines = clientLog.map((l) => l.t + '  ' + l.text);
    box.textContent = lines.length ? lines.join('\n') : '（本会话暂无事件）';
  }

  /* ---------------- 轮询 ---------------- */
  function schedulePoll() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = setInterval(async () => {
      if (document.visibilityState === 'hidden') return;
      if (pollErrors >= 5) return;
      try {
        const d = await api('/api/snapshot', { timeout: 8000 });
        pollErrors = 0;
        renderSnapshot(d);
      } catch (e) {
        pollErrors += 1;
        if (pollErrors === 1) toast('快照读取失败：' + e.message + '（已暂停自动刷新）', 'err');
      }
    }, pollIntervalMs);
  }

  /* ---------------- 绑定 ---------------- */
  function bind() {
    for (const b of document.querySelectorAll('.navbtn')) {
      b.addEventListener('click', () => switchView(b.dataset.view));
    }
    const sbt = $('sb-toggle');
    if (sbt) sbt.addEventListener('click', toggleSidebar);
    const tht = $('theme-toggle');
    if (tht) tht.addEventListener('click', toggleTheme);
    document.addEventListener('keydown', onKeydown);

    $('proc-search').addEventListener('input', () => renderProcessTable(snapshot));
    $('proc-sort').addEventListener('change', () => renderProcessTable(snapshot));
    for (const h of document.querySelectorAll('.proc-head span[data-sort]')) {
      h.addEventListener('click', () => { $('proc-sort').value = h.dataset.sort; renderProcessTable(snapshot); });
    }

    for (const b of document.querySelectorAll('.ops [data-cmd]')) {
      b.addEventListener('click', () => {
        if (!selected) { toast('请先在列表里选择进程', 'err'); return; }
        const action = b.dataset.cmd;
        const extra = { process_name: selected.name };
        const needsConfirm = action === 'suspend' || action === 'revoke';
        const map = { focus_high: 'focus', focus_mid: 'focus', focus_low: 'focus','unfocus': 'unfocus', grant: 'authorize', revoke: 'revoke', reclaim: 'trim_memory', suspend: 'suspend_process', resume: 'resume_process' };
        const real = map[action] || action;
        if (action === 'focus_high') extra.mode = 'godmode';
        if (action === 'focus_mid') extra.mode = 'aggressive';
        if (action === 'focus_low') extra.mode = 'gentle';
        if (action === 'unfocus') delete extra.process_name;
        if (action === 'reclaim') delete extra.process_name;
        guard(runCommand(real, action === 'revoke' ? { process_name: selected.name, level: 'normal' } : extra,
          needsConfirm ? '将对 ' + selected.name + ' 执行「' + b.textContent + '」，是否继续？' : null),
          b.textContent);
      });
    }

    const killBtn = document.querySelector('.ops [data-kill]');
    if (killBtn) {
      killBtn.addEventListener('click', async () => {
        if (!selected) { toast('请先在列表里选择进程', 'err'); return; }
        const ok = await confirmDialog('终止进程', '将强制结束 ' + selected.name + ' (PID ' + selected.pid + ')。系统关键进程可能被内核拒绝。', '终止', true);
        if (!ok) return;
        guard(runCommand('kill_process', { process_name: selected.name }, null), '终止指令已发送');
      });
    }

    $('proc-body').addEventListener('click', (ev) => {
      const row = ev.target.closest('.row');
      if (!row) return;
      const pid = Number(row.children[0].textContent);
      const p = (snapshot && snapshot.processes || []).find((x) => x.pid === pid);
      if (p) selectProcess(p.pid, p.name);
    });

    $('proc-body').addEventListener('dblclick', async (ev) => {
      const row = ev.target.closest('.row');
      if (!row || !selected) return;
      const ok = await confirmDialog('终止进程', '将强制结束 ' + selected.name + ' (PID ' + selected.pid + ')。系统关键进程可能被内核拒绝。', '终止', true);
      if (!ok) return;
      guard(runCommand('kill_process', { process_name: selected.name }, null), '终止指令已发送');
    });

    $('cmd-run').addEventListener('click', async () => {
      const text = ($('cmd-input').value || '').trim();
      const out = $('cmd-out');
      out.hidden = false;
      if (!text) { out.textContent = '请输入指令'; return; }
      try {
        const r = await api('/api/parse', { method: 'POST', body: { text: text } });
        if (!r.hit) { out.textContent = '未识别：' + (r.hint || '换个说法，例如「聚焦 Chrome」'); return; }
        out.textContent = '识别为：' + (r.command._explain || JSON.stringify(r.command));
        const ok = await confirmDialog('执行指令', r.command._explain || JSON.stringify(r.command), '执行', false);
        if (!ok) return;
        const cmd = Object.assign({}, r.command);
        delete cmd._explain;
        const res = await api('/api/command', { method: 'POST', body: cmd, timeout: 90000 });
        out.textContent = '结果：' + (res.text || (res.ok ? '成功' : '失败'));
        logLine('指令：' + text + ' → ' + (res.text || ''));
      } catch (e) {
        out.textContent = '执行失败：' + e.message;
      }
    });
    $('cmd-input').addEventListener('keydown', (ev) => { if (ev.key === 'Enter') $('cmd-run').click(); });

    $('cmd-fast').addEventListener('click', () => guard(runCommand('set_power_plan', { plan: 'high' }, '切换到高性能电源方案？'), '已切换高性能'));
    $('cmd-bal').addEventListener('click', () => guard(runCommand('set_power_plan', { plan: 'balanced' }), '已切换平衡'));
    $('cmd-trim').addEventListener('click', () => guard(runCommand('trim_memory', {}), '内存整理完成'));
    $('cmd-unfocus').addEventListener('click', () => guard(runCommand('unfocus', {}), '已解除聚焦'));

    $('router-start').addEventListener('click', async () => {
      const model = $('router-model').value;
      const ok = await confirmDialog('启动本地模型路由', '将载入模型「' + (model || '默认') + '」并占用显存，是否继续？', '启动', false);
      if (!ok) return;
      try {
        const r = await runCommand('start_router', { model: model, _timeout: 180 });
        toast('路由启动：' + String(r.text || '').slice(0, 120), 'ok');
        refreshModels();
      } catch (e) { toast('启动失败：' + e.message, 'err'); }
    });
    $('router-stop').addEventListener('click', async () => {
      const ok = await confirmDialog('停止模型路由', '将停止本地模型服务，正在进行的本地对话会中断。', '停止', true);
      if (!ok) return;
      try { await runCommand('stop_router', {}, null); toast('已停止路由', 'ok'); refreshModels(); }
      catch (e) { toast('停止失败：' + e.message, 'err'); }
    });
    $('boost-run').addEventListener('click', async () => {
      const mode = $('boost-mode').value;
      const out = $('boost-out');
      out.hidden = false;
      out.textContent = '计算中…';
      try {
        const r = await api('/api/boost', { method: 'POST', body: { mode: mode, model: $('boost-target').value.trim() }, timeout: 90000 });
        out.textContent = r.text || (r.ok ? '完成' : '失败');
      } catch (e) { out.textContent = '失败：' + e.message; }
    });

    $('chat-send').addEventListener('click', sendChat);
    $('chat-input').addEventListener('keydown', (ev) => { if (ev.key === 'Enter') sendChat(); });

    $('sec-selfcheck').addEventListener('click', runSelfcheck);
    $('sec-refresh').addEventListener('click', refreshSecurity);
    // 隐私防护 P0：新节点判空绑定，旧页面 / 测试桩缺节点也不报错
    const postureRefresh = $('posture-refresh');
    if (postureRefresh) postureRefresh.addEventListener('click', refreshPosture);
    const postureExitIp = $('posture-exitip');
    if (postureExitIp) postureExitIp.addEventListener('click', checkExitIp);
    // 防护开关 + DNS 实测：同样判空绑定
    const shieldApply = $('shield-apply');
    if (shieldApply) shieldApply.addEventListener('click', shieldApplyRecommended);
    const shieldRevert = $('shield-revert');
    if (shieldRevert) shieldRevert.addEventListener('click', shieldRevertAll);
    const dnsCheckBtn = $('posture-dnscheck');
    if (dnsCheckBtn) dnsCheckBtn.addEventListener('click', dnsCheck);
    $('scan-refresh').addEventListener('click', refreshScan);
    $('scan-start').addEventListener('click', startScan);
    $('scan-eula').addEventListener('change', updateScanButton);
    $('scan-scope').addEventListener('change', syncScanScope);

    const sh = $('scene-help');
    if (sh) sh.addEventListener('click', () => confirmDialog('什么是调度场景',
      '场景是从 scenes.json 读取的预设组合：切换电源方案、批量调整进程优先级、清理后台占用。\n\n执行前会二次确认，避免误伤前台应用。',
      '知道了', false));

    $('bs-refresh').addEventListener('click', () => loadBootstrap(true));
    $('bs-install').addEventListener('click', bsInstall);
    $('bs-wizard').addEventListener('click', bsWizard);

    $('set-save').addEventListener('click', saveSettings);
    $('set-test').addEventListener('click', testCloud);
    $('set-clear').addEventListener('click', clearKey);

    $('pf-save').addEventListener('click', savePreferences);
    $('pf-exp-logs').addEventListener('click', exportLogs);
    $('pf-exp-config').addEventListener('click', exportConfig);
    $('about-check').addEventListener('click', checkUpdate);
    $('ob-skip').addEventListener('click', finishOnboard);
    $('ob-next').addEventListener('click', nextOnboard);

    $('log-refresh').addEventListener('click', renderLogs);
    $('log-clear').addEventListener('click', () => { clientLog = []; renderLogs(); });

    $('dlg-ok').addEventListener('click', () => closeDialog(true));
    $('dlg-cancel').addEventListener('click', () => closeDialog(false));
    $('dlg').addEventListener('cancel', (ev) => { ev.preventDefault(); closeDialog(false); });
  }

  async function boot() {
    restoreSidebar();
    bind();
    skeleton($('ov-top'), 6);
    skeleton($('proc-body'), 10);
    /* 环境健康徽章：全齐时安静，缺失时侧栏亮琥珀点（水壶模式）——
       用户不需要主动巡逻自检页，缺东西会来找他 */
    api('/api/bootstrap/check', { timeout: 20000 })
      .then((d) => setBootstrapBadge((d.summary || {}).missing || 0))
      .catch(() => { /* 自检模块不可用时保持安静，不吵用户 */ });
    let prefs = null;
    try {
      prefs = await api('/api/preferences', { timeout: 5000 });
      pollIntervalMs = Number(prefs.poll_interval_ms) || 1000;
    } catch (_) { /* 偏好不可用就用默认值，不阻断启动 */ }
    try {
      const d = await api('/api/snapshot', { timeout: 8000 });
      renderSnapshot(d);
    } catch (e) {
      toast('启动失败：' + e.message, 'err');
    }
    schedulePoll();
    maybeOnboard(prefs);
    logLine('控制台就绪');
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
