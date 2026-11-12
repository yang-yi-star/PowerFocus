# 电脑算力调度中心 v1.00 · 安装脚本
# 用法：
#   .\install.ps1              # 创建桌面 + 开始菜单快捷方式
#   .\install.ps1 -AutoStart   # 同时加入开机启动
#   .\install.ps1 -Uninstall   # 移除快捷方式（不删除程序文件）
param(
    [switch]$Uninstall,
    [switch]$AutoStart
)

$ErrorActionPreference = 'Stop'
$AppDir = $PSScriptRoot
$Exe = Join-Path $AppDir 'dist\电脑算力调度中心.exe'
# 项目图标（11-03 制作的古早 ico 副本；ASCII 路径避免 .lnk 编码差异）
$IconPath = Join-Path $AppDir 'app.ico'
$Shell = New-Object -ComObject WScript.Shell
$Desktop = [Environment]::GetFolderPath('Desktop')
$StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) '电脑算力调度中心'
$StartLnk = Join-Path $StartMenu '电脑算力调度中心.lnk'
$DesktopLnk = Join-Path $Desktop '电脑算力调度中心.lnk'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '电脑算力调度中心.lnk'

function New-Lnk([string]$Path) {
    $s = $Shell.CreateShortcut($Path)
    $s.TargetPath = $Exe
    $s.WorkingDirectory = Split-Path $Exe -Parent
    # 2026-11-12 修复：CreateShortcut() 就地改写已存在的 lnk 时会保留未赋值字段。
    # 必须显式清空 Arguments，否则旧 PowerShell 托盘参数会残留到新 exe 上（11-05 事故根因）。
    $s.Arguments = ''
    if (Test-Path -LiteralPath $IconPath) { $s.IconLocation = "$IconPath,0" }
    else { $s.IconLocation = "$Exe,0" }
    $s.Description = '通用电脑算力调度中心'
    $s.Save()
}

if ($Uninstall) {
    foreach ($p in @($DesktopLnk, $StartLnk, $StartupLnk)) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; "已移除 $p" }
    }
    if (Test-Path -LiteralPath $StartMenu) { Remove-Item -LiteralPath $StartMenu -Force -Recurse -ErrorAction SilentlyContinue }
    "卸载完成（程序文件保留在 $AppDir）"
    return
}

if (-not (Test-Path -LiteralPath $Exe)) {
    throw "未找到主程序：$Exe。请先执行 build\build.ps1 打包。"
}

New-Item -ItemType Directory -Force -Path $StartMenu | Out-Null
# 2026-11-12：桌面只保留「电脑算力调度中心.lnk」一个入口。
# 历史重复入口「算力调度中心.lnk」已归档；若再出现只提示，不自动删除用户文件。
$LegacyLnk = Join-Path $Desktop '算力调度中心.lnk'
if (Test-Path -LiteralPath $LegacyLnk) {
    Write-Warning "检测到历史重复入口 $LegacyLnk ，请手动归档，避免桌面出现两个图标。"
}
New-Lnk $DesktopLnk
New-Lnk $StartLnk
"已创建桌面快捷方式：$DesktopLnk"
"已创建开始菜单快捷方式：$StartLnk"

if ($AutoStart) {
    New-Lnk $StartupLnk
    "已加入开机启动：$StartupLnk"
}

"安装完成。双击桌面图标即可启动。"
