#Requires -Version 7.0
# ============================================================
# 兼容入口（原 v2 副本位置）
# 用途：桌面快捷方式「算力调度中心.lnk」等旧引用仍指向本文件；
#       内容已改为转发壳，避免出现第二份 v2 源码导致版本漂移。
# v2 真身：E:\PowerFocus\v2\电脑算力调度中心_v2.ps1
# ============================================================

$target = Join-Path $PSScriptRoot "v2\电脑算力调度中心_v2.ps1"
if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "v2 主脚本缺失: $target" -ForegroundColor Red
    exit 2
}
& $target @args
# 透传子脚本退出码（例如被实例锁拒绝时返回 1），让旧快捷方式能识别失败
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
