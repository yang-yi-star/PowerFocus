# 电脑算力调度中心 v1.00 · 安装脚本
# 用法：
#   .\install.ps1              # 创建桌面 + 开始菜单快捷方式，并注册「添加或删除程序」卸载项
#   .\install.ps1 -AutoStart   # 同时加入开机启动
#   .\install.ps1 -Uninstall   # 完整卸载（委托 uninstall.ps1：快捷方式/注册表/程序文件）
# 2026-11-13（审计修复）：写入 HKCU 卸载注册表项，使其出现在「添加或删除程序」。
# 依据：微软「Uninstall Registry Key」规范（DisplayName / DisplayVersion / Publisher /
# DisplayIcon / UninstallString / EstimatedSize(KB, REG_DWORD)）：
#   https://learn.microsoft.com/en-us/windows/win32/msi/uninstall-registry-key
# 幂等：注册表 New-Item -Force / Set-ItemProperty -Force，快捷方式先删后建，重复安装不报错。
param(
    [switch]$Uninstall,
    [switch]$AutoStart
)

$ErrorActionPreference = 'Stop'
$AppDir = $PSScriptRoot
$Exe = Join-Path $AppDir 'dist\电脑算力调度中心.exe'
# 图标说明（2026-11-12 二次修复）：11-03 古早 ico 已由 build\build.ps1 的 --icon 内嵌进 exe。
# 安装脚本不再给 lnk 写 IconLocation —— 实测 Shell 不采纳写入的该字段（无论指向 .ico 还是 exe），
# 会退化成「白纸 + 箭头」通用图标；不指定时 Shell 自动取 Target exe 的内嵌图标，效果一致且可靠。
$Shell = New-Object -ComObject WScript.Shell
$Desktop = [Environment]::GetFolderPath('Desktop')
$StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) '电脑算力调度中心'
$StartLnk = Join-Path $StartMenu '电脑算力调度中心.lnk'
$DesktopLnk = Join-Path $Desktop '电脑算力调度中心.lnk'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '电脑算力调度中心.lnk'
$UninstallScript = Join-Path $AppDir 'uninstall.ps1'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PowerFocus_v1.00'

function New-Lnk([string]$Path) {
    # CreateShortcut() 就地改写已存在的 lnk 时会保留未赋值字段（Arguments / IconLocation 都会残留）。
    # 11-05 事故根因就是旧 PowerShell 托盘参数残留；11-12 又发现残留的 IconLocation 会让图标变白纸。
    # 因此先移除旧 lnk 再原生生成一份全新的，只赋必需字段，不写 IconLocation。
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $s = $Shell.CreateShortcut($Path)
    $s.TargetPath = $Exe
    $s.WorkingDirectory = Split-Path $Exe -Parent
    $s.Arguments = ''
    $s.Description = '通用电脑算力调度中心'
    $s.Save()
}

if ($Uninstall) {
    # 2026-11-13：卸载闭环 —— 有完整卸载脚本时委托它（含注册表与程序文件）。
    if (Test-Path -LiteralPath $UninstallScript) {
        & $UninstallScript
        return
    }
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

# ---------- 注册「添加或删除程序」卸载项（HKCU，每用户安装无需管理员） ----------
if (-not (Test-Path -LiteralPath $UninstallScript)) {
    throw "未找到卸载脚本：$UninstallScript。请确认 uninstall.ps1 与 install.ps1 同目录。"
}
$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshExe) { $pwshExe = (Get-Command powershell.exe).Source }
$EstimatedSizeKb = 0
if (Test-Path -LiteralPath $Exe) {
    $EstimatedSizeKb = [int][math]::Ceiling((Get-Item -LiteralPath $Exe).Length / 1KB)
}
New-Item -Path $UninstallKey -Force | Out-Null
Set-ItemProperty -Path $UninstallKey -Name 'DisplayName'    -Value '电脑算力调度中心' -Type String -Force
Set-ItemProperty -Path $UninstallKey -Name 'DisplayVersion' -Value '1.00' -Type String -Force
Set-ItemProperty -Path $UninstallKey -Name 'Publisher'      -Value 'PowerFocus' -Type String -Force
Set-ItemProperty -Path $UninstallKey -Name 'DisplayIcon'    -Value $Exe -Type String -Force
Set-ItemProperty -Path $UninstallKey -Name 'InstallLocation' -Value $AppDir -Type String -Force
Set-ItemProperty -Path $UninstallKey -Name 'UninstallString' -Value ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $pwshExe, $UninstallScript) -Type String -Force
Set-ItemProperty -Path $UninstallKey -Name 'EstimatedSize'  -Value $EstimatedSizeKb -Type DWord -Force
Set-ItemProperty -Path $UninstallKey -Name 'NoModify'       -Value 1 -Type DWord -Force
Set-ItemProperty -Path $UninstallKey -Name 'NoRepair'       -Value 1 -Type DWord -Force
"已注册卸载项：$UninstallKey"

"安装完成。双击桌面图标即可启动；可在「添加或删除程序」中卸载。"
