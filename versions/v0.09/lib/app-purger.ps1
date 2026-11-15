# ============================================================
# App Purger —— 彻底卸载模块（供 电脑算力调度中心 v2 命令总线调用）
# 设计原则：
#   1. 默认 dry_run，只有显式 dry_run=false 才真正执行
#   2. 系统关键路径一律拒绝（Windows / WinSxS / WindowsApps / System32）
#   3. 每步写日志，可追溯
#   4. 不留残留：进程 → 卸载器 → 目录 → 注册表 → 服务 → 计划任务 → 快捷方式
# ============================================================

function Get-InstalledAppList {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $out = foreach ($k in $keys) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object {
            [pscustomobject]@{
                Name          = [string]$_.DisplayName
                Version       = [string]$_.DisplayVersion
                Publisher     = [string]$_.Publisher
                Location      = [string]$_.InstallLocation
                Uninstall     = [string]$_.UninstallString
                QuietUninstall= [string]$_.QuietUninstallString
                RegKey        = [string]$_.PSPath
            }
        }
    }
    return $out
}

function Test-PurgeGuard {
    param([string]$InstallLocation, [string]$Name)

    $protectedPaths = @(
        'C:\Windows',
        'C:\Windows\System32',
        'C:\Windows\SysWOW64',
        'C:\Windows\WinSxS',
        'C:\Program Files\WindowsApps',
        'C:\ProgramData\Microsoft'
    )
    $protectedNames = @(
        'Microsoft Visual C++ 2015',
        'Microsoft Visual C++ 2017',
        'Microsoft Visual C++ 2019',
        'Microsoft Visual C++ 2022',
        'Microsoft .NET',
        'Windows Driver Package',
        'Microsoft Edge',
        'Microsoft Update',
        'Windows Software Development Kit'
    )

    if ($InstallLocation) {
        foreach ($p in $protectedPaths) {
            if ($InstallLocation -like ($p + '*')) {
                return @{ Blocked = $true; Reason = "安装目录位于受保护路径: $p" }
            }
        }
        if ($InstallLocation.Length -lt 12) {
            return @{ Blocked = $true; Reason = "安装目录过短，疑似异常: $InstallLocation" }
        }
    }
    foreach ($n in $protectedNames) {
        if ($Name -like ('*' + $n + '*')) {
            return @{ Blocked = $true; Reason = "属于受保护组件: $n" }
        }
    }
    return @{ Blocked = $false; Reason = '' }
}

function Get-AppResidual {
    param([string]$AppName, [string]$InstallLocation)

    $res = [ordered]@{
        Processes   = @()
        Directories = @()
        RegKeys     = @()
        Services    = @()
        Tasks       = @()
        Shortcuts   = @()
    }

    # 1. 相关进程（按可执行路径在安装目录下匹配）
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($InstallLocation -and $p.Path -and $p.Path -like ($InstallLocation + '*')) {
                $res.Processes += "$($p.ProcessName) (PID $($p.Id))"
            }
        } catch {}
    }

    # 2. 目录
    if ($InstallLocation -and (Test-Path -LiteralPath $InstallLocation)) {
        $res.Directories += $InstallLocation
    }
    foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData)) {
        $cand = Join-Path $base $AppName
        if (Test-Path -LiteralPath $cand) { $res.Directories += $cand }
    }

    # 3. 注册表残留
    foreach ($rk in @(
        "HKCU:\SOFTWARE\$AppName",
        "HKLM:\SOFTWARE\$AppName",
        "HKLM:\SOFTWARE\WOW6432Node\$AppName"
    )) {
        if (Test-Path $rk) { $res.RegKeys += $rk }
    }

    # 4. 服务
    foreach ($s in (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
        if ($InstallLocation -and $s.PathName -and $s.PathName -like ('*' + $InstallLocation + '*')) {
            $res.Services += "$($s.Name) [$($s.State)]"
        }
    }

    # 5. 计划任务
    foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        try {
            foreach ($a in $t.Actions) {
                if ($InstallLocation -and $a.Execute -and $a.Execute -like ('*' + $InstallLocation + '*')) {
                    $res.Tasks += "$($t.TaskPath)$($t.TaskName)"
                }
            }
        } catch {}
    }

    # 6. 快捷方式
    $lnkDirs = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:USERPROFILE\Desktop",
        "$env:PUBLIC\Desktop"
    )
    foreach ($d in $lnkDirs) {
        Get-ChildItem $d -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -like ('*' + $AppName + '*') } |
            ForEach-Object { $res.Shortcuts += $_.FullName }
    }

    return $res
}

function Invoke-AppPurge {
    param($Cmd, [scriptblock]$Logger = $null)

    function _log([string]$m) { if ($Logger) { & $Logger $m } }

    $appName  = [string]$Cmd.app
    $dryRun   = $true
    if ($null -ne $Cmd.dry_run) { $dryRun = [bool]$Cmd.dry_run }

    if (-not $appName) {
        $all = Get-InstalledAppList
        $lines = $all | Sort-Object Name | ForEach-Object { "  $($_.Name)  [$($_.Version)]" }
        return ("ERROR: 未指定 app。当前已登记应用共 $($all.Count) 个:`n" + (($lines | Select-Object -First 60) -join "`n") + "`n（用 list_apps 可看全量）")
    }

    # 匹配应用（精确优先，其次包含）
    $apps = Get-InstalledAppList
    $hit = $apps | Where-Object { $_.Name -eq $appName } | Select-Object -First 1
    if (-not $hit) {
        $hit = $apps | Where-Object { $_.Name -like ('*' + $appName + '*') } | Select-Object -First 1
    }
    if (-not $hit) {
        return "ERROR: 未找到匹配「$appName」的已安装应用"
    }

    _log "目标定位: $($hit.Name) [$($hit.Version)]"
    _log "安装目录: $($hit.Location)"

    # 保护检查
    $guard = Test-PurgeGuard -InstallLocation $hit.Location -Name $hit.Name
    if ($guard.Blocked) {
        _log "已拦截: $($guard.Reason)"
        return "ERROR: 拒绝执行 —— $($guard.Reason)"
    }

    # 残留扫描
    $res = Get-AppResidual -AppName $hit.Name -InstallLocation $hit.Location
    $report = @()
    $report += "目标: $($hit.Name)  [$($hit.Version)]"
    $report += "发布者: $($hit.Publisher)"
    $report += "安装目录: $($hit.Location)"
    $report += "卸载命令: $($hit.Uninstall)"
    $report += "静默卸载: $($hit.QuietUninstall)"
    $report += ""
    $report += "--- 残留扫描 ---"
    $report += "进程   : $($res.Processes.Count) 个  $(($res.Processes | Select-Object -First 5) -join '; ')"
    $report += "目录   : $($res.Directories.Count) 个  $(($res.Directories | Select-Object -First 5) -join '; ')"
    $report += "注册表 : $($res.RegKeys.Count) 个  $(($res.RegKeys | Select-Object -First 5) -join '; ')"
    $report += "服务   : $($res.Services.Count) 个  $(($res.Services | Select-Object -First 5) -join '; ')"
    $report += "任务   : $($res.Tasks.Count) 个  $(($res.Tasks | Select-Object -First 5) -join '; ')"
    $report += "快捷方式: $($res.Shortcuts.Count) 个  $(($res.Shortcuts | Select-Object -First 5) -join '; ')"

    if ($dryRun) {
        $report += ""
        $report += ">>> DRY-RUN：以上仅为预览，未执行任何删除。"
        $report += ">>> 确认无误后，发送 {`"action`":`"uninstall_app`",`"app`":`"$($hit.Name)`",`"dry_run`":false}"
        return ($report -join "`n")
    }

    # ============ 实际执行 ============
    _log "DRY-RUN=false，开始执行彻底卸载"

    # 1. 结束进程
    $killed = 0
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($hit.Location -and $p.Path -and $p.Path -like ($hit.Location + '*')) {
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                $killed++
                _log "已结束进程: $($p.ProcessName) (PID $($p.Id))"
            }
        } catch {}
    }

    # 2. 调用卸载器
    $uninst = $hit.QuietUninstall
    if (-not $uninst) { $uninst = $hit.Uninstall }
    $uninstRan = $false
    if ($uninst) {
        try {
            if ($uninst -match '^MsiExec\.exe') {
                $guid = [regex]::Match($uninst, '\{[0-9A-Fa-f\-]{36}\}').Value
                if ($guid) {
                    $proc = Start-Process 'msiexec.exe' -ArgumentList @('/x', $guid, '/quiet', '/norestart') -Wait -PassThru
                    $uninstRan = $true
                    _log "MSI 卸载完成，退出码 $($proc.ExitCode)"
                }
            } else {
                $exe = $uninst
                $args = ''
                if ($uninst -match '^"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $args = $Matches[2] }
                elseif ($uninst -match '^(\S+\.exe)\s*(.*)$') { $exe = $Matches[1]; $args = $Matches[2] }
                if (Test-Path -LiteralPath ($exe -replace '"','')) {
                    if ($args -match '/S|/silent|/quiet') {
                        $proc = Start-Process -FilePath ($exe -replace '"','') -ArgumentList $args -Wait -PassThru
                        $uninstRan = $true
                        _log "卸载器执行完成，退出码 $($proc.ExitCode)"
                    } else {
                        _log "卸载器缺少静默参数，跳过自动执行，需人工处理: $uninst"
                    }
                }
            }
        } catch { _log "卸载器执行异常: $_" }
    }

    Start-Sleep -Seconds 2

    # 3. 删除目录
    $delDirs = 0
    foreach ($d in $res.Directories) {
        try {
            if (Test-Path -LiteralPath $d) {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                $delDirs++
                _log "已删除目录: $d"
            }
        } catch { _log "删除目录失败[$d]: $($_.Exception.Message)" }
    }

    # 4. 清理注册表
    $delKeys = 0
    foreach ($k in @($res.RegKeys + $hit.RegKey)) {
        try {
            if ($k -and (Test-Path $k)) {
                Remove-Item -Path $k -Recurse -Force -ErrorAction Stop
                $delKeys++
                _log "已删除注册表项: $k"
            }
        } catch { _log "删除注册表失败[$k]: $($_.Exception.Message)" }
    }

    # 5. 删除服务
    $delSvc = 0
    foreach ($s in $res.Services) {
        $svcName = ($s -split ' ')[0]
        try {
            $sv = Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
            if ($sv) {
                if ($sv.State -eq 'Running') { Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue }
                $null = Invoke-CimMethod -InputObject $sv -MethodName Delete -ErrorAction Stop
                $delSvc++
                _log "已删除服务: $svcName"
            }
        } catch { _log "删除服务失败[$svcName]: $($_.Exception.Message)" }
    }

    # 6. 删除计划任务
    $delTask = 0
    foreach ($t in $res.Tasks) {
        try {
            Unregister-ScheduledTask -TaskName (Split-Path $t -Leaf) -Confirm:$false -ErrorAction Stop
            $delTask++
            _log "已删除计划任务: $t"
        } catch { _log "删除任务失败[$t]: $($_.Exception.Message)" }
    }

    # 7. 删除快捷方式
    $delLnk = 0
    foreach ($l in $res.Shortcuts) {
        try { Remove-Item -LiteralPath $l -Force -ErrorAction Stop; $delLnk++; _log "已删除快捷方式: $l" } catch {}
    }

    $summary = @()
    $summary += "彻底卸载完成: $($hit.Name)"
    $summary += "  结束进程     : $killed"
    $summary += "  卸载器执行   : $(if ($uninstRan) { '是' } else { '否（需人工）' })"
    $summary += "  删除目录     : $delDirs / $($res.Directories.Count)"
    $summary += "  清理注册表   : $delKeys"
    $summary += "  删除服务     : $delSvc / $($res.Services.Count)"
    $summary += "  删除计划任务 : $delTask / $($res.Tasks.Count)"
    $summary += "  删除快捷方式 : $delLnk / $($res.Shortcuts.Count)"
    return ($summary -join "`n")
}
