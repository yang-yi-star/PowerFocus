# -*- coding: utf-8 -*-
"""把补给返回文案改成报告 visible/idle/EcoQoS/工作集修剪的真实统计。"""
from pathlib import Path
import sys

K = Path(r"E:\PowerFocus\versions\v0.12\电脑算力调度中心_v0.12.ps1")
raw = K.read_bytes()
bom = raw.startswith(b"\xef\xbb\xbf")
text = raw.decode("utf-8-sig")

old = '''    $killNote = ""
    if ($script:PowerKilled.Count -gt 0) { $killNote = "，清理 $($script:PowerKilled.Count) 个明显无用进程（$($script:PowerKilled -join ' / ')）" }
    Write-Log "INFO" "算力补给: $($tp.Name)($TargetPid) level=$Level duration=$DurationSec reason=$Reason，压低 $($script:PowerDemoted.Count) 进程$killNote"
    return "OK: 算力已补给 $($tp.Name) (PID $TargetPid) level=$Level，持续 $DurationSec 秒，已压低 $($script:PowerDemoted.Count) 个其他应用（DeepSeek/系统关键/授权/前台/豆包/调度中心未动）$killNote"'''

new = '''    $detail = "开着但没在用的应用 $visibleCount 个、彻底闲置的后台 $idleCount 个"
    if ($ecoOn -gt 0) { $detail += "，其中 $ecoOn 个进 EcoQoS 效率模式" }
    if ($trimmed -gt 0) { $detail += "，$trimmed 个工作集已换出" }
    Write-Log "INFO" "算力补给: $($tp.Name)($TargetPid) level=$Level duration=$DurationSec reason=$Reason，压低 $($script:PowerDemoted.Count) 进程（visible=$visibleCount idle=$idleCount eco=$ecoOn trim=$trimmed），未杀任何进程"
    return "OK: 算力已补给 $($tp.Name) (PID $TargetPid) level=$Level，持续 $DurationSec 秒。压低 $($script:PowerDemoted.Count) 个进程：$detail。未杀任何进程（前台/DeepSeek/系统关键/授权/豆包/调度中心完全不碰）。"'''

if old not in text:
    print("✗ 未找到返回文案锚点")
    sys.exit(1)
text = text.replace(old, new, 1)
print("✓ 已更新补给返回文案")

# PowerRequest 对象里 killed 计数改成实际口径
old_obj = '''        demoted = $script:PowerDemoted.Count; killed = $script:PowerKilled.Count'''
new_obj = '''        demoted = $script:PowerDemoted.Count; killed = 0; visible = $visibleCount; idle = $idleCount; eco = $ecoOn; trimmed = $trimmed'''
if old_obj in text:
    text = text.replace(old_obj, new_obj, 1)
    print("✓ 已更新申请记录字段")
else:
    print("⚠ 申请记录字段未匹配（不影响主流程）")

if bom:
    K.write_bytes(b"\xef\xbb\xbf" + text.encode("utf-8"))
else:
    K.write_bytes(text.encode("utf-8"))
print("已写回，新行数 =", len(text.splitlines()))
