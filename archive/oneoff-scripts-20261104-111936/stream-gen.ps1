# stream-gen.ps1 - 流式调用本地模型生成代码（增量落盘，客户端不限时）
param(
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [int]$MaxTokens = 8000
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$prompt = [IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
$body = @{
    model = 'Qwen3.8-27B'
    prompt = $prompt
    max_tokens = $MaxTokens
    temperature = 0.7
    top_k = 20
    top_p = 0.8
    presence_penalty = 1.5
    min_p = 0
    stream = $true
} | ConvertTo-Json

$uri = 'http://127.0.0.1:8080/v1/completions'
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
$req = [System.Net.Http.HttpRequestMessage]::new('Post', $uri)
$req.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$total = 0
try {
    $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) {
        [IO.File]::WriteAllText(($OutFile + '.err'), "HTTP $($resp.StatusCode)", [System.Text.Encoding]::UTF8)
        Write-Output "http_error=$($resp.StatusCode)"; exit 1
    }
    $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { break }
        if ($line.StartsWith('data:')) {
            $json = $line.Substring(5).Trim()
            if ($json -eq '[DONE]') { break }
            try {
                $chunk = $json | ConvertFrom-Json
                $t = [string]$chunk.choices[0].text
                if ($t) {
                    [IO.File]::AppendAllText($OutFile, $t, (New-Object System.Text.UTF8Encoding $false))
                    $total += $t.Length
                }
            } catch {}
        }
    }
    $sw.Stop()
    $meta = "finished tokens_chars=$total wall_s=$([math]::Round($sw.Elapsed.TotalSeconds,1))"
    [IO.File]::WriteAllText(($OutFile + '.meta'), $meta, [System.Text.Encoding]::UTF8)
    Write-Output $meta
} catch {
    $sw.Stop()
    $err = "ERROR: $($_.Exception.Message) partial_chars=$total wall_s=$([math]::Round($sw.Elapsed.TotalSeconds,1))"
    [IO.File]::WriteAllText(($OutFile + '.err'), $err, [System.Text.Encoding]::UTF8)
    Write-Output $err
    exit 1
}
