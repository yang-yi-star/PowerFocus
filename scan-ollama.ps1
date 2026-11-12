$ErrorActionPreference = 'SilentlyContinue'
# 1) ollama 各模型体积（按 manifest 层大小汇总）
$mroot = 'D:\Models\ollama\manifests'
$rows = New-Object System.Collections.ArrayList
if (Test-Path -LiteralPath $mroot) {
  Get-ChildItem -LiteralPath $mroot -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($mroot.Length + 1)
    $parts = $rel -split '\\'
    $tag = $parts[-1]
    $repo = ($parts[-2] -replace ':','/')
    $model = "$repo`:$tag"
    $json = Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 | ConvertFrom-Json
    $sum = 0
    foreach ($l in $json.layers) { $sum += [int64]$l.size }
    [void]$rows.Add([PSCustomObject]@{ Model=$model; GB=[math]::Round($sum/1GB,3); Path=$_.FullName })
  }
}
$rows | Sort-Object GB -Descending | Format-Table -AutoSize
'ollama 模型数: ' + $rows.Count + '  合计GB: ' + [math]::Round((($rows | Measure-Object GB -Sum).Sum),2)

# 2) ComfyUI 剩余文件的硬链接情况（判断是否重复占盘）
'=== ComfyUI 全量文件硬链接 ==='
Get-ChildItem -LiteralPath 'D:\AI\tools\ComfyUI\models' -Recurse -File -Force | Where-Object { $_.Length -gt 20MB } | ForEach-Object {
  $hl = (& fsutil hardlink list $_.FullName) -split "`n" | Where-Object { $_.Trim() }
  [PSCustomObject]@{ File=$_.Name; Links=$hl.Count; Others=($hl | Where-Object { $_ -notmatch 'ComfyUI' } | ForEach-Object { $_.Trim() }) -join ' | ' }
} | Format-Table -AutoSize -Wrap
