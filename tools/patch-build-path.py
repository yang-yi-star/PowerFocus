# -*- coding: utf-8 -*-
"""build.ps1：把写死的 versions\v0.10 改成按 current.json 动态解析最高稳定版本。
保持 UTF-8 BOM（Parser::ParseFile 需要）。"""
from pathlib import Path
import sys

B = Path(r"E:\PowerFocus\product\v1.00\build\build.ps1")
raw = B.read_bytes()
bom = raw.startswith(b"\xef\xbb\xbf")
t = raw.decode("utf-8-sig")

old = '''$V010 = Join-Path $Repo 'versions\\v0.10'
if (-not (Test-Path -LiteralPath $V010)) { throw "未找到 V0.10 模块目录：$V010" }'''

new = '''# 2026-11-15 修复（关键）：此前这里写死 versions\\v0.10，
# 导致每次打包都把这 4 个 Python 组件（app_paths / dependency_bootstrap /
# kvrt_bundle / engine_adapters / security_scan）的**旧副本**塞进 exe，
# 于是"内核指针已指到新版本、exe 里跑的却是旧组件"。
# 现改为跟随 versions\\current.json 的指针：打包自动带上当前正式版的组件。
$CurrentJson = Join-Path $Repo 'versions\\current.json'
$V010 = $null
if (Test-Path -LiteralPath $CurrentJson) {
    $curVer = (Get-Content -LiteralPath $CurrentJson -Raw -Encoding UTF8 | ConvertFrom-Json).version
    if ($curVer) {
        $cand = Join-Path $Repo "versions\\$curVer"
        if (Test-Path -LiteralPath $cand) { $V010 = $cand }
    }
}
if (-not $V010) {
    # 指针缺失或指向不存在的目录：退回"含这 4 个组件的最高版本目录"
    $best = Get-ChildItem -LiteralPath (Join-Path $Repo 'versions') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^v\\d+\\.\\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'dependency_bootstrap.py')) } |
        Sort-Object { [version]($_.Name.TrimStart('v')) } -Descending |
        Select-Object -First 1
    if ($best) { $V010 = $best.FullName }
}
if (-not $V010) { throw "未找到可打包的版本模块目录（versions\\current.json 与 versions\\v* 均不可用）" }
Write-Host "打包用的组件目录: $V010"'''

if old not in t:
    print("✗ 未找到 V010 锚点，实际内容：")
    for line in t.splitlines():
        if 'V010' in line or 'v0.10' in line:
            print("   ", line)
    sys.exit(1)

t = t.replace(old, new, 1)
B.write_bytes((b"\xef\xbb\xbf" if bom else b"") + t.encode("utf-8"))
print("✓ build.ps1 组件目录已改为动态跟随 current.json")
