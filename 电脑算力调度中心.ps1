#Requires -Version 7.0
# ============================================================
# 主入口（v1 原位置，现由 v2 接管）
# 职责：仅做转发，保持桌面快捷方式与计划任务 PowerFocusAutoV2 兼容
#   v2 真身：E:\PowerFocus\v2\电脑算力调度中心_v2.ps1
#   v3 引擎：E:\PowerFocus\v3\电脑算力调度中心_v3.ps1（独立目录，不由此入口启动）
# 单一入口约定：脚本、日志、状态、命令总线不再放根目录。
# ============================================================

$target = Join-Path $PSScriptRoot "v2\电脑算力调度中心_v2.ps1"
if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "v2 主脚本缺失: $target" -ForegroundColor Red
    exit 2
}
& $target @args
# 透传子脚本退出码（例如被实例锁拒绝时返回 1），让计划任务/快捷方式能识别失败
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
