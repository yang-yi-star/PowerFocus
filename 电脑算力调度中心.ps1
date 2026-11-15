#Requires -Version 7.0
# ============================================================
# 主入口（v1 原位置）—— 兼容转发壳，跟随 versions\current.json
# 职责：仅做转发，让旧引用（快捷方式 / 计划任务 / 历史文档）不至于变成死链。
#   当前内核 = versions\current.json 的 version 字段（2026-11-12 实测为 v0.09）
#   v2\ / v3\ 已于 11-05 03:20 归档为 v2-archive\ 与 archive\v3-legacy-*，不再参与运行。
#   真正的产品入口是 product\v1.00\dist\电脑算力调度中心.exe（桌面端 WebView2）。
# 单一入口约定：脚本、日志、状态、命令总线不再放根目录；本文件只做版本指针转发。
#
# 2026-11-12 修复记录：
#   原实现写死转发到 v3\电脑算力调度中心_v3.ps1，v3 目录归档后即 exit 2 死链，
#   计划任务 PowerFocusAutoV2 因此从 11-05 起开机自启失败。
#   改为读取版本指针动态拼路径，今后切版本只需改 current.json，不再改本文件。
# ============================================================

# 2026-11-12 修复：跟随版本指针，不再写死已归档的 v3\ 路径
$pointer = Join-Path $PSScriptRoot 'versions\current.json'
if (-not (Test-Path -LiteralPath $pointer)) {
    Write-Host "版本指针缺失: $pointer" -ForegroundColor Red
    exit 2
}
$ver = (Get-Content -LiteralPath $pointer -Raw -Encoding UTF8 | ConvertFrom-Json).version
$target = Join-Path $PSScriptRoot ("versions\{0}\电脑算力调度中心_{0}.ps1" -f $ver)
if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "内核主脚本缺失: $target" -ForegroundColor Red
    exit 2
}
& $target @args
# 透传子脚本退出码（例如被实例锁拒绝时返回 1），让计划任务/快捷方式能识别失败
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }