#Requires -Version 7.0
<#
============================================================
 停用运行时自带工具（需先完全关闭编辑器，否则会拒绝执行）
 用法：右键“使用 PowerShell 运行”，或命令行 pwsh -File 本文件
 还原：pwsh -File E:\PowerFocus\tools\restore-runtime.ps1
============================================================
#>

$root = "${env:USERPROFILE}\AppData\Local\DoubaoWork\User Data\sandbox_runtime\bases"
$stamp = '20261104'

# 安全闸：有进程正在使用运行时里的工具时，一律不执行
$busy = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -like "$root*" } |
        Select-Object Id, ProcessName, Path

if ($busy) {
    Write-Host '拒绝执行：仍有进程在使用运行时自带工具。' -ForegroundColor Red
    $busy | Format-Table Id, ProcessName -AutoSize
    Write-Host '请先完全退出编辑器（含托盘），再运行本脚本。' -ForegroundColor Yellow
    exit 1
}

# 只处理最新的那份（按创建时间），旧的那份留着当兜底
$base = Get-ChildItem $root -Directory | Sort-Object CreationTime -Descending | Select-Object -First 1
if (-not $base) { Write-Host '找不到运行时目录，什么都没做。' -ForegroundColor Yellow; exit 1 }

Write-Host "目标：$($base.FullName)"
foreach ($name in 'node', 'python') {
    $src = Join-Path $base.FullName $name
    $dst = Join-Path $base.FullName "$name.disabled-$stamp"
    if ((Test-Path $src) -and -not (Test-Path $dst)) {
        Rename-Item $src $dst
        Write-Host "已停用：$name -> $name.disabled-$stamp" -ForegroundColor Green
    } elseif (Test-Path $dst) {
        Write-Host "已停用过：$name（跳过）" -ForegroundColor DarkGray
    } else {
        Write-Host "不存在：$name（跳过）" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host '下一步：重新打开编辑器，观察是否报错、是否会自行恢复旧工具。' -ForegroundColor Cyan
Write-Host '若起不来：运行 E:\PowerFocus\tools\restore-runtime.ps1 即可原样还原。' -ForegroundColor Cyan
