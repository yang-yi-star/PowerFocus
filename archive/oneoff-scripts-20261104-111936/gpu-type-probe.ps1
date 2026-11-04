. 'E:\PowerFocus\统一内存模式.ps1'
$out = @()
$g = Get-GpuMemoryInfo
$out += "类型=$($g.GetType().FullName) Count=$($g.Count)"
if ($g -is [System.Array]) {
    $out += "数组元素0类型=$($g[0].GetType().FullName)"
    $out += "元素0: $($g[0] | ConvertTo-Json -Compress)"
    $out += "FreeMB 访问=$($g[0].FreeMB)"
} elseif ($g -is [System.Collections.IDictionary]) {
    $out += "哈希表键: $($g.Keys -join ',')"
    $out += "TotalMB=$($g['TotalMB']) FreeMB=$($g['FreeMB'])"
} else {
    $out += "其他类型: $($g | ConvertTo-Json -Compress)"
}
# 花括号 URL 构造验证
$url = "http://${script:LlamaHost}:8080/slots"
$out += "花括号URL=[$url]"
try { $r = Invoke-RestMethod -Uri $url -TimeoutSec 5; $out += "访问 OK slots=$($r.Count)" } catch { $out += "访问 FAIL $($_.Exception.Message)" }
$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\gpu-type-probe.txt' -Encoding utf8
