#Requires -Version 7.0
# ============================================================
# 兼容壳（原 v2 副本位置）—— 转发到主入口
# 用途：历史引用若仍指向本文件，自动转发到当前唯一活体，不再抛「v2 主脚本缺失」。
#
# 历史沿革：
#   - 曾指向 v2\电脑算力调度中心_v2.ps1
#   - 2026-11-05 v2 目录归档为 v2-archive\，旧指向变成死链（exit 2）
#   - 2026-11-12 主入口已改为跟随 versions\current.json（v0.09），本壳随之复活
#
# 单一入口约定：产品入口是 product\v1.00\dist\电脑算力调度中心.exe；
#               本文件与主入口仅保留给旧引用 / 内核调试使用。
# ============================================================

$target = Join-Path $PSScriptRoot "电脑算力调度中心.ps1"
if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "入口脚本缺失: $target" -ForegroundColor Red
    exit 2
}
& $target @args
# 透传子脚本退出码（例如被实例锁拒绝时返回 1），让旧快捷方式能识别失败
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
