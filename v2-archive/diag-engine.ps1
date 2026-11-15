[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$out = New-Object System.Collections.Generic.List[string]
$out.Add("工具调用进程优先级: $((Get-Process -Id $PID).PriorityClass)")
$V2 = Join-Path $PSScriptRoot "v2"
try { . (Join-Path $V2 "rules-engine.ps1"); $out.Add("dot-source OK") } catch { $out.Add("dot-source 错误: $_") }
try {
    $res = Invoke-RulesEngineOnce
    $out.Add("单次评估: OK")
} catch { $out.Add("单次评估异常: $_") }
Start-Sleep -Milliseconds 600
$rsPath = Join-Path $V2 "rules_state.json"
if (Test-Path $rsPath) { $out.Add("心跳: " + (Get-Content -Raw $rsPath -Encoding utf8)) } else { $out.Add("心跳未生成") }
Start-RulesEngine
Start-Sleep -Seconds 8
if (Test-Path $rsPath) { $out.Add("Timer心跳: " + (Get-Content -Raw $rsPath -Encoding utf8)) } else { $out.Add("Timer心跳未生成") }
$out.Add("本进程优先级: $((Get-Process -Id $PID).PriorityClass)")
$out.Add("RuleActive: $($script:RuleActive.Keys -join ',')")
Stop-RulesEngine
Start-Sleep -Seconds 1
$out.Add("停止后本进程优先级: $((Get-Process -Id $PID).PriorityClass)")
[IO.File]::WriteAllText('E:\PowerFocus\diag-out.txt', ($out -join "`n"), (New-Object Text.UTF8Encoding $false))
