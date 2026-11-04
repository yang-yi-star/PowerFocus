# live 验证 v2：Start-Job 后台生成 + Monitor 差分测速
$job = Start-Job -ScriptBlock {
    $body = @{ prompt = '请用中文写一段关于本地大模型部署的短文，约一百字。'; n_predict = 120; temperature = 0.4; stream = $false } | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/completion' -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 300
    "后台生成速度=$($resp.timings.predicted_per_second) t/s"
}
Start-Sleep -Seconds 4
. 'E:\PowerFocus\统一内存模式.ps1'
. 'E:\PowerFocus\统一内存模式增强.ps1'
Monitor-WeightDistributionEnhanced -SampleCount 8 -IntervalSec 1 -BaselineTps 3.7 2>&1 | Out-Null
$jobOut = Receive-Job $job -Wait -TimeoutSec 120 2>$null
"--- 后台生成结果 ---"
if ($jobOut) { $jobOut } else { 'job 超时或无输出' }
Remove-Job $job -Force -ErrorAction SilentlyContinue
