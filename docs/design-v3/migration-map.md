# PowerFocus v3 迁移映射表（style.css → design-tokens.css）

> 依据：`E:\PowerFocus\product\v1.00\app\web\style.css`（v2，413 行）逐段扫描。
> 配套文件：`design-tokens.css`（token 定义 + 兼容别名层）、`theming.md`（切换方案）。
> 红线提醒：本表已把 v2 中违反 v3 克制红线的样式标出（渐变 logo、紫色第二强调色）。

## 0. 总策略：三步走

| 步骤 | 动作 | style.css 改动量 | 效果 |
|---|---|---|---|
| A | 引入 design-tokens.css（置于 style.css 之前）；加上 theming.md 的主题初始化 | **零改动**（兼容别名层接住全部旧变量） | 立刻获得双主题换肤，可能仍有细节违和 |
| B | 按下文映射表逐段替换硬编码值与「需改结构」项 | 中等（约 30 处替换 + 9 项结构调整） | 完全符合 v3 规范 |
| C | 删除 design-tokens.css 末尾的兼容别名层区块 | 零改动 | token 收敛到 `--pf-*` 单命名空间 |

原则：每一步完成后界面都可用，不存在"改一半坏掉"的中间态。

## 1. 旧 `:root` 变量映射（17 个）

兼容别名层已内置下表全部映射（步骤 A 生效）；步骤 B 中应把组件规则里的旧名直接改写为新名。

| 旧变量 | 新 token | 类型 | 备注 |
|---|---|---|---|
| `--bg` | `--pf-bg-page` | 纯替换 | 深色 #0a0b0d→#221e19（变暖） |
| `--bg-nav` | `--pf-nav-bg` | 纯替换 | 浅色下= 米白，反转「导航暗一档」为暖化版 |
| `--surface` | `--pf-bg-panel` | 纯替换 | |
| `--surface2` | `--pf-bg-panel` | 需改结构 | v3 输入框/hover 底不再有独立层级，见 §4-4 |
| `--surface3` | `--pf-bg-elevated` | 纯替换 | |
| `--line` | `--pf-border-default` | 纯替换 | |
| `--line-strong` | `--pf-border-strong` | 纯替换 | |
| `--txt` | `--pf-text-primary` | 纯替换 | |
| `--dim` | `--pf-text-secondary` | 纯替换 | |
| `--faint` | `--pf-text-tertiary` | 纯替换 | 仲裁终值 #7a6f62（4.91 on white / 4.56 on page，全过 AA）；ghost 仍禁正文，见 §4-7 |
| `--ghost` | `--pf-text-ghost` | 纯替换 | 仅装饰字，禁用于正文 |
| `--accent` | `--pf-accent` | 纯替换 | **浅 #b4531f / 深 #e08850（Phase 2 修订值）** |
| `--accent-dim` | `--pf-accent-dim` | 纯替换 | |
| `--accent-line` | `--pf-accent-line` | 纯替换 | |
| `--green` | `--pf-status-success-graphic` | 需改结构 | 圆点/边框处用 graphic；**文字处必须改用 `-text`** |
| `--amber` | `--pf-status-warning-graphic` | 需改结构 | 同上 |
| `--red` | `--pf-status-danger-graphic` | 需改结构 | 同上 |
| `--r1/r2/r3` | `--pf-radius-xs/sm/md` | 纯替换 | 4/8/12px，圆角封顶 12px |
| `--font` | `--pf-font` | 纯替换 | 加 PingFang/思源兜底 |
| `--mono` | `--pf-font-mono` | 纯替换 | tabular-nums 保留 |

## 2. 硬编码颜色扫描（按选择器，均为「纯替换」）

| 位置 | 现值 | 新 token | 备注 |
|---|---|---|---|
| `::-webkit-scrollbar-thumb` | `#26282e` / hover `#33363e` | `--pf-scrollbar-thumb(-hover)` | |
| `.logo` background | `linear-gradient(135deg, var(--accent), #2a7fd4)` | `--pf-accent` 纯色 | **红线 1：去渐变去第二色** |
| `.logo` box-shadow | `rgba(255,255,255,.10) inset` | 删除 | 浅色主题上白色 inset 无意义 |
| `.track` background | `#1c1e24`（冷灰） | `--pf-track-bg` | |
| `.track.mem i` | `#8f7ff0`（紫） | `--pf-accent` | **红线 1：第二强调色，删除**；内存条与 CPU 条同色，靠 label 区分 |
| `.btn.primary` | `accent-dim 底 + accent 字 + accent-line 边` | `--pf-btn-primary-bg/fg` | 需改结构，见 §4-2 |
| `.btn.primary:hover` | `rgba(76,194,255,.22)` | `--pf-btn-primary-bg-hover` | |
| `.btn.danger` 全套 | `#f08a84` / `rgba(229,84,75,…)` | `--pf-btn-danger-*` | 需改结构，见 §4-3 |
| `.check .badge.ok/.bs-ok` | `#58c98a` + `rgba(63,185,111,.12)` | `--pf-badge-success-*` | |
| `.check .badge.bad/.bs-sys` | `#f08a84` + `rgba(229,84,75,.12)` | `--pf-badge-danger-*` | |
| `.check .badge.skip/.bs-miss` | `#e2b95c` + `rgba(217,165,63,.12)` | `--pf-badge-warning-*` | |
| `.navbadge` / `.navbadge.amber` | `rgba(229,84,75,.18)` 等 | `--pf-badge-danger-*` / `-warning-*` | |
| `.gauge .num.danger` | `#f08a84` | `--pf-status-danger-text` | **文字必须用 text 轨**（4.46→5.26:1） |
| `.gauge .num.warn` | `var(--amber)` | `--pf-status-warning-text` | 原 amber 作文字仅 2.7:1，FAIL |
| `.verdict.warn/.bad` 底色 | `rgba(217,165,63,.07)` 等 | `--pf-verdict-*-bg` | 判定条底色加浓一档，三态可辨 |
| `.verdict .vdot` | `var(--green)` 等 | `--pf-status-*-graphic` | 圆点用 graphic 轨 |
| `dialog` box-shadow | `rgba(0,0,0,.55)` | `--pf-shadow-modal` | 浅色下换暖阴影，深色保留弱环境影 |
| `dialog::backdrop` | `rgba(5,6,8,.6)` | `--pf-backdrop` | backdrop-filter 建议删除，见 theming.md §5 |
| `.toast` box-shadow | `rgba(0,0,0,.4)` | `--pf-shadow-elevated` | toast 属悬浮层 |
| `.toast` border-left | `var(--accent)/(--green)/(--red)` | `--pf-status-*-graphic` | |
| `.msg.user` | `accent-dim + accent-line` | `--pf-msg-user-*` | |
| `.msg.model` | `surface2 + line` | `--pf-msg-model-*` | |
| `.kpi.alt` | `linear-gradient(180deg, surface2, surface)` | 删除 | **红线 1**：KPI 卡一律 `--pf-bg-panel` 平铺 |
| `.row.sel` / `.navbtn.active` | `var(--accent-dim)` | `--pf-accent-dim` | 选中底统一 accent 10-12% |
| `.skel` 渐变 | `surface2/3` 引用 | 保留结构，值随 token 自动变暖 | |

## 3. 字号映射

| 现值 | 新值 | 新 token | 说明 |
|---|---|---|---|
| `10px`（.sub/.group/.meta） | `12px` | `--pf-fs-12` | **全站最小 12px**（Phase 2 可读性下限），极小字全部上调 |
| `10.5px`（hint/desc/badge） | `12px` | `--pf-fs-12` | 同上 |
| `11px`（gauge name/kpi k） | `12px` | `--pf-fs-12` | |
| `11.5px`（out/mono/dt） | `12px` 或 `13px` | `--pf-fs-12/13` | 输出区正文取 13 |
| `12px / 12.5px`（主体） | `13px` / `14px` | `--pf-fs-13/14` | 按钮与导航取 14，表格取 13 |
| `13px`（brand h1/mdl） | `14px` 或 `22px` | 视语境 | 页面级标题才升 22 |
| `24px`（.kpi .v） | `22px` | `--pf-fs-22` | KPI 大数字统一 22/30 |
| 聊天 `.msg` `12.5px` | `15px` | `--pf-fs-15` | 聊天正文唯一放宽处 |

行高统一采用各字号的配对 `--pf-lh-*`；字重只保留 400/500/600。

## 4. 「需改结构」清单（9 项）

1. **`.logo` 重绘**：去渐变 → `--pf-accent` 纯色 22×22、`--pf-radius-xs`；去 inset 阴影。
2. **`.btn.primary` 反转为实底**：v2 是「accent-dim 浅底 + accent 彩字」，v3 是「accent 实底 + 白字（深色主题深字）」。一行内主按钮 ≤1 的纪律靠 HTML 检查，CSS 不强制。
3. **`.btn.danger` 次按钮化**：常态视觉 = 次按钮（`--pf-btn-danger-border` + text-primary），仅 `:hover` 转 `--pf-btn-danger-hover-bg/fg`。注意 HTML 中 `data-kill` 的终止进程按钮已有 `btn sm danger`，行为不变。
4. **输入框/hover 底合并**：`--surface2` 层级取消。输入框底 = panel 白（深色 panel），hover 底用 `--pf-btn-secondary-bg-hover`（暖化透明底）或 `--pf-accent-dim`。涉及 `input,select,textarea`、`.navbtn:hover`、`.row:hover`、`.topitem:hover`、`#sb-toggle:hover`。
5. **行高密度升级**：`.row`/`.topitem` `30px → 44px`（默认宽松档）；`--pf-radius-xs` 行 hover 底。可在设置视图加「紧凑模式」切换 `36px`（body 上挂 `.dense` 类覆盖一个变量 `--pf-row-h`）。
6. **判定条（.verdict）胶囊化**：`--pf-radius-md → --pf-radius-full`，高 32px；danger 态 `.vdot` 的 `breathe` 呼吸动画**删除**（Phase 1 红线：危险不闪烁），保留 200ms 颜色过渡；`.verdict .vact` 行内按钮仅 danger 态显示。
7. **ghost 用途收紧**：`.hint`、`.extra`、`.d`（检查项描述）这类"必须能读"的辅助文字从 `--ghost` 升为 `--pf-text-tertiary`（仲裁终值全过 AA，可用于辅助正文）；`--pf-text-ghost` 只留给纯装饰字（.sub、装饰副注），任何承载信息的文字不得使用。
8. **`.form` 样式缺失**：index.html 设置视图用了 `div.form` + label，v2 CSS 无 `.form` 规则。v3 顺手补：`display:grid; gap: 8px; max-width: 520px;`，label 用 `--pf-fs-13` + secondary。
9. **`index.html` 头部两处改动**（HTML 改动，非 CSS）：
   - `<meta name="color-scheme" content="dark">` → `content="light dark"`；
   - 增加 `<script src="/static/theme-init.js"></script>`（同步、置于 style.css link 之前，代码见 theming.md）。

## 5. 新增（v2 没有的）规则清单

| 规则 | 出处 |
|---|---|
| `:focus-visible` 全局焦点环（2px 实色 accent + offset 1px，仲裁终值规格，无透明环） | design-tokens.css 已含 |
| `::selection`（accent 20% 底） | 建议随 style.css 补 |
| 状态判定条从 v2 沿用，但需按 §4-6 改形 | |
| `body.dense` 紧凑密度档 | §4-5 |
| `prefers-reduced-motion` | v2 已有全局降级，保留原样即可 |

## 6. 不动的部分

- 布局骨架（body grid、`body.sb-min` 折叠、`.split`、`.kpis` 四列）不在本阶段重构范围；
- `tabular-nums` 的全部使用保留；
- `@keyframes viewIn/toastIn/shimmer` 保留（reduced-motion 下已被 v2 全局降级覆盖）；
- CSP 约束（`default-src 'self'`、无内联样式/脚本）维持，theming.md 方案已按此设计。
