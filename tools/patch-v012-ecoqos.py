# -*- coding: utf-8 -*-
"""补 EcoQoS 状态记录与还原：全局声明 + 清场前复位 + Restore 关闭。"""
from pathlib import Path
import sys

K = Path(r"E:\PowerFocus\versions\v0.12\电脑算力调度中心_v0.12.ps1")
raw = K.read_bytes()
bom = raw.startswith(b"\xef\xbb\xbf")
text = raw.decode("utf-8-sig")

# 1) 全局声明：在 PowerKilled 那行后面加 PowerEcoQos
anchor = "$script:PowerKilled            = @()               # 阶段五增强：本次补给清理的\"明显无用\"进程记录（pid/name）"
if anchor not in text:
    print("✗ 未找到 PowerKilled 声明锚点")
    sys.exit(1)
new_anchor = anchor + "\n$script:PowerEcoQos           = @{}               # 2026-11-15：补给时开了 EcoQoS 的 PID -> $true，释放时要逐个关掉"
text = text.replace(anchor, new_anchor, 1)
print("✓ 已加全局 PowerEcoQos 声明")

# 2) 清场前复位
old_reset = """    if ($script:PowerRequest) { Restore-PowerSupply | Out-Null }
    $script:PowerDemoted = @{}"""
new_reset = """    if ($script:PowerRequest) { Restore-PowerSupply | Out-Null }
    $script:PowerDemoted = @{}
    $script:PowerEcoQos  = @{}"""
if old_reset not in text:
    print("✗ 未找到清场前复位锚点")
    sys.exit(1)
text = text.replace(old_reset, new_reset, 1)
print("✓ 已在清场前复位 PowerEcoQos")

# 3) Restore-PowerSupply：恢复优先级之后、清空状态之前，先关 EcoQoS
old_restore = """    $n = $script:PowerDemoted.Count
    $script:PowerRequest = $null
    $script:PowerDemoted = @{}
    $script:PowerKilled = @()"""
new_restore = """    # 先关 EcoQoS 效率模式，再还原优先级——否则闲置进程留在能效核档位上
    $ecoRestored = 0
    $hasEco = [bool](Get-Command Set-EcoQos -ErrorAction SilentlyContinue)
    if ($hasEco -and $script:PowerEcoQos.Count -gt 0) {
        foreach ($ecoPid in $script:PowerEcoQos.Keys) {
            try {
                if (Set-EcoQos -ProcId ([int]$ecoPid) -On $false) { $ecoRestored++ }
            } catch {}
        }
    }
    $n = $script:PowerDemoted.Count
    $script:PowerRequest = $null
    $script:PowerDemoted = @{}
    $script:PowerEcoQos  = @{}
    $script:PowerKilled = @()"""
if old_restore not in text:
    print("✗ 未找到 Restore 段落锚点")
    sys.exit(1)
text = text.replace(old_restore, new_restore, 1)
print("✓ 已在 Restore 里加 EcoQoS 关闭")

# 4) 返回文案带上 EcoQoS 与修剪统计
old_msg = '''    Write-Log "INFO" "算力释放: $($req.name)($($req.pid))，还原 $n 进程"
    return "OK: 算力已释放，还原 $n 个进程（$($req.name) 已回 Normal）"'''
new_msg = '''    Write-Log "INFO" "算力释放: $($req.name)($($req.pid))，还原 $n 进程，关闭 EcoQoS $ecoRestored 个"
    return "OK: 算力已释放，还原 $n 个进程、关闭 EcoQoS $ecoRestored 个（$($req.name) 已回 Normal）"'''
if old_msg not in text:
    print("✗ 未找到释放文案锚点")
    sys.exit(1)
text = text.replace(old_msg, new_msg, 1)
print("✓ 已更新释放文案")

if bom:
    K.write_bytes(b"\xef\xbb\xbf" + text.encode("utf-8"))
else:
    K.write_bytes(text.encode("utf-8"))
print("已写回，新行数 =", len(text.splitlines()))
