/* PowerFocus v3 主题预载（防闪烁）
   必须以同步 <script> 置于 <head>，渲染前生效。
   优先级：localStorage 显式选择 > 系统偏好 > 默认浅色 */
(function () {
  var t = null;
  try { t = localStorage.getItem('pf_theme'); } catch (e) { /* 隐私模式忽略 */ }
  if (t !== 'dark' && t !== 'light') {
    t = (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
  }
  document.documentElement.setAttribute('data-theme', t);
})();
