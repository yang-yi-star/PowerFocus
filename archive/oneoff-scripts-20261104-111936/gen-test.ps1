# 后台生成任务，用于验证 Monitor 速度差分
$body = @{ prompt = '请用中文写一段关于本地大模型部署的短文，约三百字。'; n_predict = 300; temperature = 0.4; stream = $false } | ConvertTo-Json
$resp = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/completion' -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 600
$speed = $resp.timings.predicted_per_second
"后台生成完成 速度=$speed t/s" | Set-Content -LiteralPath 'E:\PowerFocus\gen-test-done.txt' -Encoding utf8
