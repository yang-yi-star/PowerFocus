# run-um-gen.ps1 - 把统一内存模式提示词交给本地 Qwen3.8-27B 生成（/v1/completions 原生接口）
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$prompt = [IO.File]::ReadAllText('E:\PowerFocus\um-prompt.txt', [System.Text.Encoding]::UTF8)
$body = @{
    model = 'Qwen3.8-27B'
    prompt = $prompt
    max_tokens = 16000
    temperature = 0.7
    top_k = 20
    top_p = 0.8
    presence_penalty = 1.5
    min_p = 0
} | ConvertTo-Json
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$resp = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/completions' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 3600
$sw.Stop()
$text = [string]$resp.choices[0].text
[IO.File]::WriteAllText('E:\PowerFocus\um-model-output.txt', $text, (New-Object System.Text.UTF8Encoding $false))
$meta = "done tokens=$($resp.usage.completion_tokens) prompt_tokens=$($resp.usage.prompt_tokens) wall_s=$([math]::Round($sw.Elapsed.TotalSeconds,1)) chars=$($text.Length)"
[IO.File]::WriteAllText('E:\PowerFocus\um-model-meta.txt', $meta, (New-Object System.Text.UTF8Encoding $false))
Write-Output $meta
