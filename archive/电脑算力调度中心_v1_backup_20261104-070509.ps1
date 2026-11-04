#Requires -Version 7.0
# 电脑算力调度中心 - 算力调度托盘工具（pwsh 7 / WPF+WinForms）
# 把整台电脑的算力集中到指定目标应用，持续保证最高优先级，可温和/激进两档。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:TargetPid    = $null
$script:TargetName   = ""
$script:FocusMode    = "gentle"
$script:OriginalPlan = $null
$script:DemotedPids  = @()
$script:TimerObj     = $null
$script:TrayIcon     = $null
$script:LogDir       = "E:\PowerFocus"
$script:LogFile      = Join-Path $script:LogDir "电脑算力调度中心.log"
$script:Whitelist    = @('Idle','System','Registry','Memory Compression','csrss','dwm','explorer','winlogon','lsass','services','svchost','fontdrvhost','conhost','Taskmgr','RuntimeBroker','ShellExperienceHost','SearchHost','TextInputHost','StartMenuExperienceHost','pwsh','powershell','python','DoubaoWork','llama-server')

function Write-Log {
    param([string]$Level, [string]$Msg)
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -LiteralPath $script:LogFile -Value "$ts [$Level] $Msg" -Encoding utf8
    } catch { Write-Host "日志写入失败: $_" }
}

function Show-Balloon {
    param([string]$Title, [string]$Msg)
    try { if ($script:TrayIcon) { $script:TrayIcon.ShowBalloonTip(3000, $Title, $Msg, [System.Windows.Forms.ToolTipIcon]::Info) } } catch {}
}

function Get-ProcList {
    return Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne 0 } | ForEach-Object {
        $cpu = 0.0; try { $cpu = [math]::Round($_.CPU, 1) } catch {}
        $mem = [math]::Round($_.WorkingSet64 / 1MB, 1)
        [PSCustomObject]@{ Name = $_.ProcessName; PID = $_.Id; CPU = $cpu; Mem = $mem }
    } | Sort-Object CPU -Descending
}

function Show-ProcPicker {
    $win = New-Object System.Windows.Window
    $win.Title = "选择目标进程 - 电脑算力调度中心"
    $win.Width = 560; $win.Height = 500
    $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $win.ResizeMode = [System.Windows.ResizeMode]::CanResize

    $grid = New-Object System.Windows.Controls.Grid
    $row1 = New-Object System.Windows.Controls.RowDefinition; $row1.Height = [System.Windows.GridLength]::Auto
    $row2 = New-Object System.Windows.Controls.RowDefinition; $row2.Height = [System.Windows.GridLength]::Auto
    $grid.RowDefinitions.Add($row1); $grid.RowDefinitions.Add($row2)

    $lv = New-Object System.Windows.Controls.ListView
    $lv.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $gv = New-Object System.Windows.Controls.GridView
    $gv.AllowsColumnReorder = $true
    foreach ($col in @(@('进程名',180,'Name'), @('PID',70,'PID'), @('CPU 秒',90,'CPU'), @('内存 MB',100,'Mem'))) {
        $gc = New-Object System.Windows.Controls.GridViewColumn
        $gc.Header = $col[0]; $gc.Width = $col[1]
        $gc.DisplayMemberBinding = (New-Object System.Windows.Data.Binding($col[2]))
        $gv.Columns.Add($gc)
    }
    $lv.View = $gv
    [System.Windows.Controls.Grid]::SetRow($lv, 0)

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $txtInput = New-Object System.Windows.Controls.TextBox
    $txtInput.Width = 270; $txtInput.Margin = (New-Object System.Windows.Thickness(5,5,5,5))
    $txtInput.ToolTip = "输入进程名（默认建议: llama-server）"
    $btnRefresh = New-Object System.Windows.Controls.Button
    $btnRefresh.Content = "刷新"; $btnRefresh.Width = 60; $btnRefresh.Margin = (New-Object System.Windows.Thickness(5,5,5,5))
    $btnOk = New-Object System.Windows.Controls.Button
    $btnOk.Content = "确定"; $btnOk.Width = 60; $btnOk.Margin = (New-Object System.Windows.Thickness(5,5,5,5))
    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = "取消"; $btnCancel.Width = 60; $btnCancel.Margin = (New-Object System.Windows.Thickness(5,5,5,5))
    $panel.Children.Add($txtInput) | Out-Null
    $panel.Children.Add($btnRefresh) | Out-Null
    $panel.Children.Add($btnOk) | Out-Null
    $panel.Children.Add($btnCancel) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($panel, 1)
    $grid.Children.Add($lv) | Out-Null
    $grid.Children.Add($panel) | Out-Null
    $win.Content = $grid

    function Refresh-LV {
        $lv.ItemsSource = @(Get-ProcList)
        $lv.Items.Refresh()
    }
    Refresh-LV

    $script:PickResult = $null
    $btnRefresh.Add_Click({ Refresh-LV })
    $btnOk.Add_Click({
        $sel = $lv.SelectedItem
        if ($sel) {
            $script:PickResult = @{ Name = $sel.Name; PID = [int]$sel.PID }
        } else {
            $nm = $txtInput.Text.Trim()
            if ($nm) {
                $proc = Get-Process -Name $nm -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($proc) { $script:PickResult = @{ Name = $proc.ProcessName; PID = $proc.Id } }
                else { [System.Windows.MessageBox]::Show("未找到进程: $nm", "提示"); return }
            } else {
                [System.Windows.MessageBox]::Show("请选择或输入进程名", "提示"); return
            }
        }
        $win.Close()
    })
    $btnCancel.Add_Click({ $win.Close() })
    $win.Add_KeyDown({ param($s, $e) if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $win.Close() } })

    $win.ShowDialog() | Out-Null
    return $script:PickResult
}

function Set-PowerPlanHigh {
    try {
        $cur = powercfg /getactivescheme | Out-String
        if ($cur -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $script:OriginalPlan = $Matches[1]
            Write-Log "INFO" "原电源计划 GUID: $script:OriginalPlan"
        } else {
            $script:OriginalPlan = $null
            Write-Log "WARN" "未能解析当前电源计划 GUID"
        }
        powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
        Write-Log "INFO" "电源计划已切换为高性能"
    } catch { Write-Log "WARN" "电源计划切换失败: $_" }
}

function Restore-PowerPlan {
    if ($script:OriginalPlan) {
        try {
            powercfg /setactive $script:OriginalPlan | Out-Null
            Write-Log "INFO" "电源计划已恢复: $script:OriginalPlan"
        } catch { Write-Log "WARN" "电源计划恢复失败: $_" }
        $script:OriginalPlan = $null
    }
}

function Start-GentleFocus {
    param([int]$ProcessId, [string]$Name)
    $script:TargetPid = $ProcessId
    $script:TargetName = $Name
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
        Write-Log "INFO" "温和聚焦: $Name (PID $ProcessId) 优先级设为 High"
        Show-Balloon "电脑算力调度中心" "已对 $Name 执行温和聚焦"
    } catch {
        Write-Log "ERROR" "设置优先级失败: $_"
        Show-Balloon "电脑算力调度中心" "设置优先级失败: $_"
    }
    Set-PowerPlanHigh
}

function Start-AggressiveFocus {
    param([int]$ProcessId, [string]$Name)
    Start-GentleFocus -ProcessId $ProcessId -Name $Name
    try {
        $script:DemotedPids = @()
        foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
            if ($p.Id -eq $ProcessId) { continue }
            if ($script:Whitelist -contains $p.ProcessName) { continue }
            try {
                $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
                $script:DemotedPids += $p.Id
            } catch {}
        }
        Write-Log "INFO" "激进聚焦: 已降级 $($script:DemotedPids.Count) 个非白名单进程为 BelowNormal"
        Show-Balloon "电脑算力调度中心" "激进聚焦已生效，降级 $($script:DemotedPids.Count) 个进程"
    } catch {
        Write-Log "ERROR" "激进聚焦降级失败: $_"
    }
}

function Invoke-WatchdogCheck {
    $tp = $script:TargetPid
    if (-not $tp) { return }
    $proc = Get-Process -Id $tp -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Log "WARN" "目标进程 $script:TargetName (PID $tp) 已退出，自动解除聚焦"
        Show-Balloon "电脑算力调度中心" "目标进程 $script:TargetName 已退出，聚焦已自动解除"
        Stop-Focus
        return
    }
    if ($proc.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::High) {
        try {
            $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
            Write-Log "INFO" "监管: $script:TargetName 优先级被降级，已拉回 High"
        } catch {}
    }
}

function Start-Watchdog {
    param([int]$ProcessId, [string]$Name)
    $script:TargetPid = $ProcessId
    $script:TargetName = $Name
    Stop-Watchdog
    # 用 WinForms Timer：回调跑在 UI 线程（消息泵），保证脚本块有运行空间
    $script:TimerObj = New-Object System.Windows.Forms.Timer
    $script:TimerObj.Interval = 10000
    $script:TimerObj.add_Tick({ param($s, $e) Invoke-WatchdogCheck })
    $script:TimerObj.Start()
    Write-Log "INFO" "监管已启动: 每 10 秒检查 $Name"
}

function Stop-Watchdog {
    if ($script:TimerObj) {
        try { $script:TimerObj.Dispose() } catch {}
        $script:TimerObj = $null
    }
}

function Stop-Focus {
    try {
        Stop-Watchdog
        Restore-PowerPlan
        $n = $script:DemotedPids.Count
        foreach ($dp in $script:DemotedPids) {
            try { (Get-Process -Id $dp -ErrorAction Stop).PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal } catch {}
        }
        if ($n -gt 0) { Write-Log "INFO" "已恢复 $n 个进程优先级为 Normal" }
        $script:DemotedPids = @()
        $script:TargetPid = $null
        $script:TargetName = ""
        Show-Balloon "电脑算力调度中心" "聚焦已解除，系统恢复正常"
    } catch {
        Write-Log "ERROR" "解除聚焦异常: $_"
        Show-Balloon "电脑算力调度中心" "解除聚焦时出错: $_"
    }
}

function Toggle-Autostart {
    try {
        $task = Get-ScheduledTask -TaskName "算力调度中心Auto" -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName "算力调度中心Auto" -Confirm:$false
            Write-Log "INFO" "开机自启已关闭"
            Show-Balloon "电脑算力调度中心" "开机自启已关闭"
        } else {
            $scriptPath = $PSCommandPath
            if (-not $scriptPath) { $scriptPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "电脑算力调度中心.ps1" }
            $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
            if (-not $pwshExe) { $pwshExe = "pwsh.exe" }
            $tr = "`"$pwshExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
            schtasks /Create /TN "算力调度中心Auto" /TR $tr /SC ONLOGON /RL HIGHEST /F | Out-Null
            Write-Log "INFO" "开机自启已开启: $scriptPath"
            Show-Balloon "电脑算力调度中心" "开机自启已开启"
        }
    } catch {
        Write-Log "ERROR" "自启切换失败: $_"
        Show-Balloon "电脑算力调度中心" "自启切换失败: $_"
    }
}

function Open-Log {
    try {
        if (Test-Path -LiteralPath $script:LogFile) { Start-Process notepad.exe -ArgumentList "`"$script:LogFile`"" }
        else { Show-Balloon "电脑算力调度中心" "日志文件尚不存在" }
    } catch { Show-Balloon "电脑算力调度中心" "打开日志失败: $_" }
}

function Update-AutoMenuText {
    try {
        $task = Get-ScheduledTask -TaskName "算力调度中心Auto" -ErrorAction SilentlyContinue
        if ($task) { $script:MiAuto.Text = "开机自启: 开" } else { $script:MiAuto.Text = "开机自启: 关" }
    } catch { $script:MiAuto.Text = "开机自启: 关" }
}

# ===== 主入口（被 dot-source 时只加载函数，不启动托盘）=====
if ($MyInvocation.InvocationName -eq '.') { return }

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Shield
$tray.Text = "电脑算力调度中心"
$tray.Visible = $true
$script:TrayIcon = $tray

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miSelect = New-Object System.Windows.Forms.ToolStripMenuItem
$miSelect.Text = "选择目标进程"
$miSelect.Add_Click({
    try {
        $result = Show-ProcPicker
        if ($result) {
            $script:TargetPid = $result.PID
            $script:TargetName = $result.Name
            Write-Log "INFO" "已选定目标进程: $($result.Name) (PID $($result.PID))"
            Show-Balloon "电脑算力调度中心" "目标: $($result.Name)"
        }
    } catch { Write-Log "ERROR" "选择进程失败: $_"; Show-Balloon "电脑算力调度中心" "操作失败: $_" }
})

$miStart = New-Object System.Windows.Forms.ToolStripMenuItem
$miStart.Text = "开始聚焦"
$miStart.Add_Click({
    try {
        if (-not $script:TargetPid) { Show-Balloon "电脑算力调度中心" "请先选择目标进程"; return }
        $proc = Get-Process -Id $script:TargetPid -ErrorAction SilentlyContinue
        if (-not $proc) { Show-Balloon "电脑算力调度中心" "目标进程不存在，请重新选择"; return }
        if ($script:FocusMode -eq "gentle") {
            Start-GentleFocus -ProcessId $script:TargetPid -Name $script:TargetName
        } else {
            Start-AggressiveFocus -ProcessId $script:TargetPid -Name $script:TargetName
        }
        Start-Watchdog -ProcessId $script:TargetPid -Name $script:TargetName
        Write-Log "INFO" "聚焦已启动 (模式: $script:FocusMode)"
    } catch { Write-Log "ERROR" "启动聚焦失败: $_"; Show-Balloon "电脑算力调度中心" "启动聚焦失败: $_" }
})

$miStop = New-Object System.Windows.Forms.ToolStripMenuItem
$miStop.Text = "解除聚焦"
$miStop.Add_Click({ Stop-Focus })

$miToggle = New-Object System.Windows.Forms.ToolStripMenuItem
$miToggle.Text = "聚焦强度: 温和"
$miToggle.Add_Click({
    if ($script:FocusMode -eq "gentle") {
        $script:FocusMode = "aggressive"
        $miToggle.Text = "聚焦强度: 激进"
    } else {
        $script:FocusMode = "gentle"
        $miToggle.Text = "聚焦强度: 温和"
    }
    Write-Log "INFO" "聚焦强度切换为 $script:FocusMode"
    Show-Balloon "电脑算力调度中心" "当前模式: $(if ($script:FocusMode -eq 'gentle') { '温和' } else { '激进' })"
})

$miLog = New-Object System.Windows.Forms.ToolStripMenuItem
$miLog.Text = "打开日志"
$miLog.Add_Click({ Open-Log })

$miAuto = New-Object System.Windows.Forms.ToolStripMenuItem
$miAuto.Text = "开机自启: 关"
$miAuto.Add_Click({ Toggle-Autostart; Update-AutoMenuText })

$miExit = New-Object System.Windows.Forms.ToolStripMenuItem
$miExit.Text = "退出"
$miExit.Add_Click({
    try { Stop-Focus } catch {}
    try { $tray.Visible = $false; $tray.Dispose() } catch {}
    Write-Log "INFO" "电脑算力调度中心已退出"
    [System.Windows.Forms.Application]::Exit()
})

$menu.Items.Add($miSelect) | Out-Null
$menu.Items.Add($miStart) | Out-Null
$menu.Items.Add($miStop) | Out-Null
$menu.Items.Add($miToggle) | Out-Null
$menu.Items.Add($miLog) | Out-Null
$menu.Items.Add($miAuto) | Out-Null
$menu.Items.Add($miExit) | Out-Null
$tray.ContextMenuStrip = $menu

Update-AutoMenuText
Write-Log "INFO" "电脑算力调度中心已启动 (默认建议目标: llama-server)"

# 隐藏窗体承载消息泵
$form = New-Object System.Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$form.Show()
$form.Hide()
[System.Windows.Forms.Application]::Run($form)
