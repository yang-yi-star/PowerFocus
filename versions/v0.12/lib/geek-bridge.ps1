# ============================================================
# Geek Bridge —— 调用 Geek Uninstaller 完成卸载（供调度中心命令总线使用）
# ID 格式已实证：Uninstall 注册表子键名（Geek cache.dat 的 key 字段）
# ============================================================

function Get-GeekPath {
    $cands = @(
        'C:\Users\Administrator.医院\Desktop\geek.exe',
        'C:\Temp\geek64.exe',
        'D:\电脑文件\桌面\geek.exe',
        'D:\旧账户文件\Desktop\geek.exe'
    )
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    $found = Get-ChildItem 'C:\' -Filter 'geek*.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Get-GeekAppList {
    param([string]$Filter = '')
    $roots = @(
        @{ Hive = 'HKCU'; Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Hive = 'HKLM'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Hive = 'HKLM'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
    )
    $out = @()
    foreach ($r in $roots) {
        Get-ChildItem $r.Path -ErrorAction SilentlyContinue | ForEach-Object {
            $key = $_.PSChildName
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if (-not $p.DisplayName) { return }
            if ($Filter -and $p.DisplayName -notlike ('*' + $Filter + '*') -and $key -notlike ('*' + $Filter + '*')) { return }
            $out += [pscustomobject]@{
                Id        = $key
                Name      = [string]$p.DisplayName
                Version   = [string]$p.DisplayVersion
                Publisher = [string]$p.Publisher
                Location  = [string]$p.InstallLocation
                Hive      = $r.Hive
            }
        }
    }
    return $out
}

function Invoke-GeekUninstall {
    param($Cmd, [scriptblock]$Logger = $null)

    function _log([string]$m) { if ($Logger) { & $Logger $m } }

    $geek = Get-GeekPath
    if (-not $geek) { return "ERROR: 未找到 geek.exe" }

    $appId = [string]$Cmd.app_id
    $appName = [string]$Cmd.app

    # 优先用 app_id 精确匹配
    $target = $null
    if ($appId) {
        $list = Get-GeekAppList
        $target = $list | Where-Object { $_.Id -eq $appId } | Select-Object -First 1
    }
    if (-not $target -and $appName) {
        $list = Get-GeekAppList -Filter $appName
        $exact = $list | Where-Object { $_.Name -eq $appName } | Select-Object -First 1
        $target = if ($exact) { $exact } else { $list | Select-Object -First 1 }
    }

    if (-not $target) {
        $hint = if ($appName -or $appId) { "未找到匹配「$appName $appId」的应用" } else { "未指定 app 或 app_id" }
        return "ERROR: $hint。可用 list_apps 查看全部（ID 为 Uninstall 注册表子键名）"
    }

    _log "Geek 目标: $($target.Name) [$($target.Version)]  id=$($target.Id)"

    # 保护：Microsoft 运行库与系统组件不通过此通道卸载
    $blockNames = @(
        'Microsoft Visual C++ 2015', 'Microsoft Visual C++ 2017',
        'Microsoft Visual C++ 2019', 'Microsoft Visual C++ 2022',
        'Microsoft .NET', 'Windows Driver Package'
    )
    foreach ($b in $blockNames) {
        if ($target.Name -like ('*' + $b + '*')) {
            return "ERROR: 拒绝执行 —— 「$($target.Name)」属于系统运行库，卸载会导致其他程序异常"
        }
    }

    # 调用 Geek。它会弹出自己的确认与残留扫描界面（安全闸门，不静默删除）
    $argList = @(('--uninstall-app-id=' + $target.Id))
    _log "调用: $geek $($argList -join ' ')"

    try {
        $p = Start-Process -FilePath $geek -ArgumentList $argList -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
        return ("OK: 已调用 Geek Uninstaller 处理「$($target.Name)」。`n" +
                "  ID: $($target.Id)`n" +
                "  版本: $($target.Version)`n" +
                "  发布者: $($target.Publisher)`n" +
                "  安装目录: $($target.Location)`n" +
                ">>> Geek 会弹出确认窗口，确认后自动执行卸载并扫描残留，点「完成」即清理干净。")
    } catch {
        return "ERROR: 调用 Geek 失败: $($_.Exception.Message)"
    }
}
