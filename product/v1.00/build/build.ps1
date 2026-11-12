# 电脑算力调度中心 v1.00 · 打包脚本
# 用途：在源码改动后重新生成单文件 exe。
# 依赖：E:\PowerFocus\.venv 内已安装 pyinstaller / pywebview / psutil / fastapi / uvicorn / httpx
param([switch]$Clean)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Root = Split-Path $Here -Parent
$Py = 'E:\PowerFocus\.venv\Scripts\pyinstaller.exe'
# 2026-11-12 修复：给 exe 内嵌项目图标（此前一直用 PyInstaller 默认图标）
$Icon = Join-Path $Root 'app.ico'

if (-not (Test-Path $Py)) { throw "未找到 pyinstaller：$Py" }
if (-not (Test-Path $Icon)) { throw "未找到图标：$Icon（由根目录 电脑算力调度中心.ico 复制而来）" }

$webPath = Join-Path $Root 'app\web'
$pyArgs = @(
    '--noconfirm',
    $(if ($Clean) { '--clean' } else { '--log-level=WARN' }),
    '--onefile', '--windowed',
    '--name', '电脑算力调度中心',
    "--icon=$Icon",
    "--add-data=$webPath;web",
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
