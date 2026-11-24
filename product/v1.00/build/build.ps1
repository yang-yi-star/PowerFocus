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
# 2026-11-15 修复（关键）：此前这里写死 versions\v0.10，
# 导致每次打包都把这 4 个 Python 组件（app_paths / dependency_bootstrap /
# kvrt_bundle / engine_adapters / security_scan）的**旧副本**塞进 exe，
# 于是"内核指针已指到新版本、exe 里跑的却是旧组件"。
# 现改为跟随 versions\current.json 的指针：打包自动带上当前正式版的组件。
$CurrentJson = Join-Path $Repo 'versions\current.json'
$V010 = $null
if (Test-Path -LiteralPath $CurrentJson) {
    $curVer = (Get-Content -LiteralPath $CurrentJson -Raw -Encoding UTF8 | ConvertFrom-Json).version
    if ($curVer) {
        $cand = Join-Path $Repo "versions\$curVer"
        if (Test-Path -LiteralPath $cand) { $V010 = $cand }
    }
}
if (-not $V010) {
    # 指针缺失或指向不存在的目录：退回"含这 4 个组件的最高版本目录"
    $best = Get-ChildItem -LiteralPath (Join-Path $Repo 'versions') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^v\d+\.\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'dependency_bootstrap.py')) } |
        Sort-Object { [version]($_.Name.TrimStart('v')) } -Descending |
        Select-Object -First 1
    if ($best) { $V010 = $best.FullName }
}
if (-not $V010) { throw "未找到可打包的版本模块目录（versions\current.json 与 versions\v* 均不可用）" }
Write-Host "打包用的组件目录: $V010"
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
# 2026-11-24（P1-1）：打包前按本机 .venv 重新生成第三方许可证包与 SBOM。
# 许可证是分发物的一部分，生成失败即拒绝打包，不允许“exe 有、附件没有”。
$VenvPy = Join-Path $Repo '.venv\Scripts\python.exe'
$LicenseGen = Join-Path $Repo 'tools\generate_license_bundle.py'
if (-not (Test-Path -LiteralPath $VenvPy)) { throw "未找到打包环境 Python：$VenvPy" }
if (-not (Test-Path -LiteralPath $LicenseGen)) { throw "未找到许可证生成器：$LicenseGen" }
Write-Host "生成第三方许可证包与 SBOM..."
& $VenvPy $LicenseGen
if ($LASTEXITCODE -ne 0) { throw "许可证包生成失败，退出码 $LASTEXITCODE；拒绝打包" }

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

# 2026-11-14 修复：PyInstaller 会往 stderr 写 WARNING（如 webview.platforms.android 缺 android 模块），
# 在 $ErrorActionPreference='Stop' 下被 PowerShell 包成 NativeCommandError 并直接中断脚本，
# 导致打包在真正开始前就退出（exe 时间戳不变、日志为空）。
# 改为全部输出重定向到日志文件，只看退出码。
$ErrorActionPreference = 'Continue'
$packLog = Join-Path $Here 'pack-log.txt'
& $Py @pyArgs *> $packLog
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -ne 0) { throw "打包失败，退出码 $code（详见 $packLog）" }

$out = Join-Path $Root 'dist\电脑算力调度中心.exe'
$Dist = Split-Path $out -Parent
# 2026-11-24（P1-1）：把许可证附件复制到 dist，和 exe 一起分发。
$Attachments = @('LICENSE', 'THIRD_PARTY_NOTICES.md', 'SBOM.cdx.json')
foreach ($name in $Attachments) {
    $src = Join-Path $Repo $name
    if (-not (Test-Path -LiteralPath $src)) { throw "缺少许可证附件：$src" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $Dist $name) -Force
}
$LicSrc = Join-Path $Repo 'LICENSES'
$LicDst = Join-Path $Dist 'LICENSES'
if (-not (Test-Path -LiteralPath $LicSrc)) { throw "缺少许可证目录：$LicSrc" }
New-Item -ItemType Directory -Path $LicDst -Force | Out-Null
Get-ChildItem -LiteralPath $LicSrc -File | Copy-Item -Destination $LicDst -Force
$licCount = (Get-ChildItem -LiteralPath $LicDst -File | Measure-Object).Count
"许可证附件已复制：LICENSE / THIRD_PARTY_NOTICES.md / SBOM.cdx.json / LICENSES（$licCount 个文件）"
"打包完成：$out ($([math]::Round((Get-Item $out).Length/1MB,1)) MB)"
