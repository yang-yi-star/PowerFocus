# 电脑算力调度中心 v1.00 · 打包脚本
# 用途：在源码改动后重新生成单文件 exe。
# 依赖：项目 .venv 内已安装 pyinstaller / pywebview / psutil / fastapi / uvicorn / httpx
#   （路径一律由 $PSScriptRoot 推导，不再写死开发机的 E:\... ）
param([switch]$Clean)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Root = Split-Path $Here -Parent
# 2026-11-13：把 V0.10 自检/引擎模块与统一数据目录模块一起收进 exe，
# 让应用进程自己就能跑组件自检，不依赖外部源码目录或对话环境。
$Repo = Split-Path (Split-Path $Root -Parent) -Parent
$V010 = Join-Path $Repo 'versions\v0.10'
if (-not (Test-Path -LiteralPath $V010)) { throw "未找到 V0.10 模块目录：$V010" }
$Py = Join-Path $Repo '.venv\Scripts\pyinstaller.exe'
if (-not (Test-Path -LiteralPath $Py)) {
    $cmd = Get-Command pyinstaller -ErrorAction SilentlyContinue
    if ($cmd) { $Py = $cmd.Source } else { throw "未找到 pyinstaller：请在本项目 .venv 中安装" }
}
# 2026-11-12 修复：给 exe 内嵌项目图标（此前一直用 PyInstaller 默认图标）
$Icon = Join-Path $Root 'app.ico'
# 2026-11-13（审计修复）：exe 显式内嵌 asInvoker UAC manifest（设计为普通权限运行，不要求管理员）。
# 依据：PyInstaller CLI 选项 --manifest（https://pyinstaller.org/en/stable/usage.html
# 「Add manifest FILE or XML to the exe」）；不使用 --uac-admin 即不请求提权。
$Manifest = Join-Path $Here 'app.manifest'

if (-not (Test-Path $Py)) { throw "未找到 pyinstaller：$Py" }
if (-not (Test-Path $Icon)) { throw "未找到图标：$Icon（由根目录 电脑算力调度中心.ico 复制而来）" }
if (-not (Test-Path $Manifest)) { throw "未找到 manifest：$Manifest（应为 build\app.manifest）" }

$webPath = Join-Path $Root 'app\web'
$pyArgs = @(
    '--noconfirm',
    $(if ($Clean) { '--clean' } else { '--log-level=WARN' }),
    '--onefile', '--windowed',
    '--name', '电脑算力调度中心',
    "--icon=$Icon",
    '--manifest', $Manifest,
    "--add-data=$webPath;web",
    '--paths', $Repo,
    '--paths', $V010,
    '--hidden-import', 'app_paths',
    '--hidden-import', 'dependency_bootstrap',
    '--hidden-import', 'kvrt_bundle',
    '--hidden-import', 'engine_adapters',
    '--hidden-import', 'security_scan',
    '--collect-all', 'uvicorn',
    '--collect-all', 'webview',
    '--collect-all', 'pythonnet',
    '--collect-all', 'clr_loader',
    '--distpath', (Join-Path $Root 'dist'),
    '--workpath', (Join-Path $Root 'build\pyi'),
    '--specpath', (Join-Path $Root 'build'),
    (Join-Path $Root 'app\main.py')
)

& $Py @pyArgs
if ($LASTEXITCODE -ne 0) { throw "打包失败，退出码 $LASTEXITCODE" }
$out = Join-Path $Root 'dist\电脑算力调度中心.exe'
"打包完成：$out ($([math]::Round((Get-Item $out).Length/1MB,1)) MB)"
