# 电脑算力调度中心 v1.00 · 卸载脚本
# 由 install.ps1 注册到 HKCU 卸载表项（UninstallString 指向本文件），也可手动执行。
# 用法：
#   .\uninstall.ps1                # 卸载；交互式运行时询问是否删除数据目录
#   .\uninstall.ps1 -DeleteData    # 卸载并直接删除 %LOCALAPPDATA%\PowerFocus 数据
# 幂等：任何步骤目标不存在时静默跳过，重复执行不报错。
param(
    [switch]$DeleteData
)

$ErrorActionPreference = 'Stop'
$AppDir = $PSScriptRoot
$Exe = Join-Path $AppDir 'dist\电脑算力调度中心.exe'
# 与 install.ps1 中的注册表键保持一致（微软规范见「Uninstall Registry Key」：
# https://learn.microsoft.com/en-us/windows/win32/msi/uninstall-registry-key）
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PowerFocus_v1.00'
$DesktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '电脑算力调度中心.lnk'
$StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) '电脑算力调度中心'
$StartLnk = Join-Path $StartMenu '电脑算力调度中心.lnk'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '电脑算力调度中心.lnk'
# 数据目录含 v0.10 引擎数据（config/审计/报告）与 v1.00 桌面日志
$DataDir = Join-Path $env:LOCALAPPDATA 'PowerFocus'

# 1. 结束运行中的实例（尽力而为，找不到不报错）
$procName = [IO.Path]::GetFileNameWithoutExtension($Exe)
Get-Process -Name $procName -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

# 2. 快捷方式与开始菜单目录
foreach ($p in @($DesktopLnk, $StartLnk, $StartupLnk)) {
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; "已移除 $p" }
}
if (Test-Path -LiteralPath $StartMenu) {
    Remove-Item -LiteralPath $StartMenu -Force -Recurse -ErrorAction SilentlyContinue
    "已移除开始菜单目录 $StartMenu"
}

# 3. 注册表卸载项
if (Test-Path -LiteralPath $UninstallKey) {
    Remove-Item -LiteralPath $UninstallKey -Force
    "已移除注册表卸载项 $UninstallKey"
}

# 4. 程序文件（单文件 exe；dist 内无其他交付物时一并清掉空目录）
if (Test-Path -LiteralPath $Exe) {
    Remove-Item -LiteralPath $Exe -Force
    "已移除程序文件 $Exe"
}
$distDir = Split-Path $Exe -Parent
if (Test-Path -LiteralPath $distDir) {
    Remove-Item -LiteralPath $distDir -Force -Recurse -ErrorAction SilentlyContinue
}

# 5. 数据目录（可选）：默认询问；-DeleteData 跳过询问；非交互式不询问一律保留
$delete = $false
if ($DeleteData) {
    $delete = $true
}
elseif ([Environment]::UserInteractive) {
    $answer = Read-Host "是否同时删除应用数据目录 $DataDir ？(y/N)"
    $delete = $answer -match '^[Yy]'
}
if ($delete -and (Test-Path -LiteralPath $DataDir)) {
    Remove-Item -LiteralPath $DataDir -Force -Recurse
    "已删除数据目录 $DataDir"
}
else {
    "数据目录保留：$DataDir"
}

"卸载完成。"
