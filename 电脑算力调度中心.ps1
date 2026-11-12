#Requires -Version 7.0
# ============================================================
# 主入口（v1 原位置）—— 现已切到 v0.05
# 职责：仅做转发，保持桌面快捷方式与计划任务 PowerFocusAutoV2 兼容
#   当前唯一活体：E:\PowerFocus\v3\电脑算力调度中心_v3.ps1（内部版本号 v0.05）
#   v2 已归档：E:\PowerFocus\v2-archive\（不再参与运行，仅作回溯）
# 单一入口约定：脚本、日志、状态、命令总线不再放根目录。
#
# 切到 v0.05 的理由（2026-11-05）：
#   v0.05 = v2 全部能力 + 模型注册表（model-registry.ps1）+ 回滚（rollback.ps1）
#        + 8 个模型的档位档案与实测 tps/显存余量
#   v2 与 v0.05 的实例锁各自独立（.v2.lock / .v3.lock），两个同时跑会互抢进程优先级，
#   所以只允许一个入口活着。本入口只拉 v0.05。
#   注：文件名仍叫 _v3.ps1，锁仍叫 .v3.lock —— 改它需要同步改已注册的计划任务，
#       不值当；版本号以本文件头部 $script:PF_VersionLabel 为准。
# ============================================================

$target = Join-Path $PSScriptRoot "v3\电脑算力调度中心_v3.ps1"
if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "v3 主脚本缺失: $target" -ForegroundColor Red
    exit 2
}
& $target @args
# 透传子脚本退出码（例如被实例锁拒绝时返回 1），让计划任务/快捷方式能识别失败
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }