# -*- coding: utf-8 -*-
from pathlib import Path
K = Path(r"E:\PowerFocus\versions\v0.13\电脑算力调度中心_v0.13.ps1")
raw = K.read_bytes(); bom = raw.startswith(b"\xef\xbb\xbf")
t = raw.decode("utf-8-sig")

# 修 L101 串行
bad = "$script:CompanionFile         = $null            # 2026-11-15：配套应用清单路径（下方按 $PSScriptRoot 赋值）               # 2026-11-15：补给时开了 EcoQoS 的 PID -> $true，释放时要逐个关掉"
good = ("$script:PowerEcoQos           = @{}               # 2026-11-15：补给时开了 EcoQoS 的 PID -> $true，释放时要逐个关掉\n"
        "$script:CompanionFile         = $null            # 2026-11-15：配套应用清单（下方按 $PSScriptRoot 赋值）")
if bad in t:
    t = t.replace(bad, good, 1)
    print("✓ L101 串行已修")
else:
    print("⚠ L101 未匹配，打印当前内容：")
    for i, line in enumerate(t.splitlines(), 1):
        if "CompanionFile" in line and "$null" in line:
            print(f"  L{i}: {line}")

# 在 AuthFile 那行后补真实赋值
anchor = '$script:AuthFile = Join-Path $script:LogDir "authorized_apps.json"'
if anchor in t:
    t = t.replace(anchor, anchor + '\n$script:CompanionFile = Join-Path $script:LogDir "companion-apps.json"', 1)
    print("✓ CompanionFile 已按 PSScriptRoot 赋值")
else:
    print("✗ AuthFile 锚点未找到")

K.write_bytes((b"\xef\xbb\xbf" if bom else b"") + t.encode("utf-8"))
print("已写回，行数 =", len(t.splitlines()))
