# 测试：开机自启开关（pwsh 7）
$p = 'E:\PowerFocus\PowerFocus.ps1'
. $p
Write-Output ("pwsh=" + $PSVersionTable.PSVersion)
$t0 = Get-ScheduledTask -TaskName 'PowerFocusAuto' -ErrorAction SilentlyContinue
Write-Output ("before: exists=" + [bool]$t0)
Toggle-Autostart
Start-Sleep -Seconds 2
$t1 = Get-ScheduledTask -TaskName 'PowerFocusAuto' -ErrorAction SilentlyContinue
Write-Output ("after ON: exists=" + [bool]$t1)
if ($t1) {
  Write-Output ("action=" + $t1.Actions[0].Execute + " | " + $t1.Actions[0].Arguments)
  Write-Output ("trigger=" + $t1.Triggers[0].CimClass.CimClassName + " | " + $t1.Settings.Priority)
}
Toggle-Autostart
Start-Sleep -Seconds 2
$t2 = Get-ScheduledTask -TaskName 'PowerFocusAuto' -ErrorAction SilentlyContinue
Write-Output ("after OFF: exists=" + [bool]$t2)
