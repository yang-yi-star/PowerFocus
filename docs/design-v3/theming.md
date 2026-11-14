# PowerFocus v3 零依赖主题切换方案

> 适用约束：frozen 应用无 SSR、CSP `default-src 'self'`（**禁止内联脚本与样式**）、
> 目标浏览器为用户本机现代浏览器（Chromium 为主）。

## 1. 方案概览

- 主题状态 = `<html data-theme="light|dark">`，纯 CSS 变量切换（见 design-tokens.css）。
- 优先级：`localStorage['pf-theme']` 显式选择 > `prefers-color-scheme` 系统回退 > 默认浅色。
- **防闪烁脚本不能内联**（CSP 禁止），做成同源独立文件 `theme-init.js`，在 `<head>` 中**同步加载**（不加 defer/async），保证首次渲染前完成属性设置——同步脚本会阻塞解析，因此渲染时 `data-theme` 已就位，无白闪/黑闪。

## 2. 首次渲染防闪烁（theme-init.js，完整代码）

新建 `app/web/theme-init.js`（约 15 行，无依赖，后续可压缩）：

```js
/* PowerFocus v3 · 主题初始化：必须在任何渲染前同步执行 */
(function () {
  try {
    var t = localStorage.getItem('pf-theme');
    if (t !== 'light' && t !== 'dark') {
      t = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    }
  } catch (e) {
    t = 'light'; // localStorage 被禁用等极端情况，走默认浅色
  }
  var el = document.documentElement;
  el.setAttribute('data-theme', t);
  // 原生控件（select/滚动条/password 显隐）跟随主题
  el.style.colorScheme = t;
})();
```

`index.html` `<head>` 改动（配合 migration-map.md §4-9）：

```html
<meta name="color-scheme" content="light dark">   <!-- 原 content="dark" 删除 -->
<script src="/static/theme-init.js"></script>     <!-- 必须在 style.css link 之前 -->
<link rel="stylesheet" href="/static/style.css">
<link rel="stylesheet" href="/static/design-tokens.css"> <!-- 或合并进 style.css 顶部 -->
```

> 顺序说明：theme-init 在前或后均可（都在首次渲染前执行），但必须在 `<link>` 所在 head 内；
> token 文件与 style.css 的先后无所谓（后者引用前者的变量）。若服务端打包合并 CSS，token 块放最前即可。

## 3. 运行时切换（app.js 内新增片段）

```js
var Theme = {
  get: function () {
    return document.documentElement.getAttribute('data-theme') || 'light';
  },
  set: function (t) {
    if (t !== 'light' && t !== 'dark') return;
    document.documentElement.setAttribute('data-theme', t);
    document.documentElement.style.colorScheme = t;
    try { localStorage.setItem('pf-theme', t); } catch (e) {}
  },
  toggle: function () { this.set(this.get() === 'dark' ? 'light' : 'dark'); }
};
```

接入点：设置视图加一个「外观」分组（原生开关/分段控件），调用 `Theme.set`；快捷键可顺带挂 `Shift+D`（可选，不与现有 1-8 / `[` 冲突）。

### 3.1 跟随系统变化（仅当用户未显式选择时）

```js
var mq = window.matchMedia('(prefers-color-scheme: dark)');
mq.addEventListener('change', function (e) {
  var saved = null;
  try { saved = localStorage.getItem('pf-theme'); } catch (err) {}
  if (saved !== 'light' && saved !== 'dark') {
    Theme.set(e.matches ? 'dark' : 'light'); // 自动跟随，且不写入 localStorage
  }
});
```

要点：自动跟随**不落盘**，用户一旦手动选择即永久覆盖系统偏好；设置里提供「跟随系统」选项（删除 localStorage 键即恢复跟随）。

## 4. prefers-reduced-motion 降级

v2 已有全局降级（`*, *::before, *::after { animation:none!important; transition:none!important }`），**原样保留**即可，v3 无新增动画。两点补充：

1. JS 侧的 300ms KPI 数字 accent 高亮（若有实现）需同样检查该媒体查询：
   ```js
   var reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
   if (!reduceMotion) { /* 加高亮类，300ms 后移除 */ }
   ```
2. v2 的全局降级写得较激进（连 width 过渡也关了），保持不动——调度中心的动效本就不该承载数据语义。

## 5. 渲染性能注意点

双主题本质是**变量换值**，只触发 repaint 不触发重排，切换成本天然很低。需守住以下几条：

1. **transition 白名单**：所有过渡只允许 `color / background-color / border-color / opacity`（即 `--pf-transition` 的内容）。禁止对 `width/height/box-shadow` 做过渡——gauge 进度条的 `width .45s` 过渡是数据语义（数值变化），保留；主题切换不涉及它。
2. **阴影不做过渡**：`--pf-shadow-*` 切换是瞬时换值。box-shadow 过渡会强制逐帧重绘大面积模糊层，是仪表盘切换卡顿的头号来源。
3. **切换只动 `<html>` 一个属性**：不要按主题给 body 加/减类、不要重建 DOM；滚动位置与 `<dialog>` 状态天然不受影响。
4. **删除 `dialog::backdrop` 的 `backdrop-filter: blur(2px)`**：合成层开销大且主题切换时整层重采样；v3 靠 `--pf-backdrop` 半透明暖色已足够分层。toast 同理不加 blur。
5. **大列表 hover**：`.row:hover` 换 background 只 repaint 单行，可接受；禁止给 `.proc-body` 整体加 filter/transform（会创建合成层，几百行时内存翻倍）。
6. **呼吸动画收敛**：v2 `.dot.on` 的 2.4s 无限 `breathe` 动画每帧都跑。v3 中状态圆点不做呼吸（Phase 1 红线），只保留 toast 进场与 viewIn 各一次的短动画，空闲时 0 动画。
7. **字体无加载风险**：全部系统字体栈，无 FOUT/FOIT；`tabular-nums` 保留，数字跳动不抖布局。
8. **验证方法**：DevTools Performance 面板录制一次主题切换，应只出现 Paint（无 Layout/Composite 风暴）；Chromium 下可用 `Rendering > Paint flashing` 目测绿色闪区范围是否限于文字与边框。

## 6. 验收清单

- [ ] 冷启动：系统深色偏好时首屏即为深色，无浅色闪烁帧
- [ ] 切换主题后刷新页面，选择被保留（localStorage）
- [ ] 删除 localStorage 键后跟随系统，且系统切换时实时跟随
- [ ] localStorage 被禁用时不报错，回落浅色
- [ ] CSP 校验通过（theme-init.js 走 `default-src 'self'`，无内联）
- [ ] 开启 reduced-motion 后无任何动画/过渡
- [ ] 原生控件（select 下拉、滚动条）颜色随主题（colorScheme 已同步）
- [ ] 主题切换录制中无 Layout 抖动，仅 Paint
