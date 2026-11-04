. 'E:\PowerFocus\统一内存模式.ps1'
$out = @()
$out += "LlamaHost = [$($script:LlamaHost)]"
$out += "LlamaPort = [$($script:LlamaPort)]"
$url = 'http://' + $script:LlamaHost + ':' + $script:LlamaPort + '/slots'
$out += "URL = [$url]"
try { $r = Invoke-RestMethod -Uri $url -TimeoutSec 5; $out += "OK slots=$($r.Count)" } catch { $out += "FAIL $($_.Exception.Message)" }
$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\scope-probe.txt' -Encoding utf8
