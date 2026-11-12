#Requires -Version 7.0
<#
  版本创建工具 —— 按《VERSIONING.md》规范从既有版本派生新版本目录
  用法:
    pwsh -File new-version.ps1 -From v0.05 -To v0.06 -Title "内存管理模块集成"
  行为:
    1) 复制组件/配置（不含 logs、commands 历史、运行时状态）
    2) 入口脚本重命名为 _v<新版本>.ps1
    3) 改写脚本内 PF_Version / PF_VersionLabel / PF_BuildDate
    4) 生成新的 MANIFEST.json
    5) 创建干净的 logs / commands 目录
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$To,
    [string]$Title = '',
    [ValidateSet('dev','beta','stable')][string]$Stage = 'dev'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot                             # E:\PowerFocus\versions（版本目录本身）
$SrcDir = Join-Path $Root $From
$DstDir = Join-Path $Root $To

if (-not (Test-Path $SrcDir)) { throw "源版本不存在: $SrcDir" }
if (Test-Path $DstDir)       { throw "目标版本已存在，拒绝覆盖: $DstDir（规范禁止原地修改已发布版本）" }
if ($To -notmatch '^v\d+\.\d+$') { throw "版本号格式非法: $To（应为 v0.06 这种形式）" }

$oldVer = $From.TrimStart('v')
$newVer = $To.TrimStart('v')
$today  = Get-Date -Format 'yyyy-MM-dd'

New-Item -ItemType Directory -Force -Path $DstDir, "$DstDir\lib", "$DstDir\logs", "$DstDir\commands\in", "$DstDir\commands\out", "$DstDir\commands\done" | Out-Null

# 1) 复制组件与配置（显式白名单，杜绝把历史日志/状态带进新版本）
$srcManifest = Join-Path $SrcDir 'MANIFEST.json'
if (Test-Path $srcManifest) {
    $m = Get-Content $srcManifest -Raw | ConvertFrom-Json
    $entryOld = $m.entry
} else { $entryOld = $null }
if (-not $entryOld) {
    $entryOld = (Get-ChildItem $SrcDir -Filter '*_v*.ps1' -File | Select-Object -First 1).Name
}
if (-not $entryOld) { throw "找不到源版本入口脚本" }

Copy-Item (Join-Path $SrcDir $entryOld) -Destination $DstDir -Force
foreach ($f in @('rules-engine.ps1','rules.json','scenes.json','models-preset.ini','model-profiles.json','authorized_apps.json')) {
    $p = Join-Path $SrcDir $f
    if (Test-Path $p) { Copy-Item $p -Destination $DstDir -Force }
}
if (Test-Path (Join-Path $SrcDir 'lib')) { Copy-Item (Join-Path $SrcDir 'lib\*') -Destination "$DstDir\lib" -Force }

# 2) 入口脚本改名 + 3) 改写版本标识
$entryNew = $entryOld -replace [regex]::Escape("_v$oldVer"), "_v$newVer"
if ($entryNew -eq $entryOld) { $entryNew = ($entryOld -replace '\.ps1$', '') + "_v$newVer.ps1" }
Rename-Item -LiteralPath (Join-Path $DstDir $entryOld) -NewName $entryNew -Force

$entryPath = Join-Path $DstDir $entryNew
$content = Get-Content -LiteralPath $entryPath -Raw -Encoding utf8
$content = $content -replace "PF_Version(\s*)=(\s*)'[^']*'", "PF_Version`$1=`$2'$newVer'"
$content = $content -replace "PF_VersionLabel(\s*)=(\s*)'[^']*'", "PF_VersionLabel`$1=`$2'v$newVer'"
$content = $content -replace "PF_BuildDate(\s*)=(\s*)'[^']*'", "PF_BuildDate`$1=`$2'$today'"
$content = $content -replace "计算机算力调度中心 v[0-9]+\.[0-9]+", "电脑算力调度中心 v$newVer"
$content = $content -replace "电脑算力调度中心 v[0-9]+\.[0-9]+", "电脑算力调度中心 v$newVer"
Set-Content -LiteralPath $entryPath -Value $content -Encoding utf8 -NoNewline

# 4) 生成 MANIFEST
$manifest = [ordered]@{
    name       = '电脑算力调度中心'
    version    = $newVer
    version_label = $To
    build_date = $today
    stage      = $Stage
    note       = if ($Title) { $Title } else { "由 $From 派生" }
    entry      = $entryNew
    lineage    = $From
    components = @(Get-ChildItem $DstDir -Filter '*.ps1' -File | ForEach-Object { $_.Name }) +
                 @(Get-ChildItem "$DstDir\lib" -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object { "lib/$($_.Name)" })
    configs    = @('rules.json','scenes.json','models-preset.ini','model-profiles.json','authorized_apps.json') |
                 Where-Object { Test-Path (Join-Path $DstDir $_) }
    runtime_isolated = @('logs/','commands/in|out|done','mem-guard.state.json','rules_state.json','v3_heartbeat.json','.v3.lock','.auth_token','router.pid')
    portable   = $true
    depends_on = @('PowerShell 7+','llama.cpp')
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $DstDir 'MANIFEST.json') -Encoding utf8

Write-Host "已创建版本 $To" -ForegroundColor Green
Write-Host "  目录: $DstDir"
Write-Host "  入口: $entryNew"
Write-Host "  来源: $From (version $oldVer -> $newVer, stage=$Stage)"
Write-Host ""
Write-Host "下一步: 在该目录内开发，完成后将 stage 改为 stable；运行方式："
Write-Host "  pwsh -File `"$DstDir\$entryNew`""
