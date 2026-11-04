# um-debug-run.ps1 - 前台启动 64K llama-server 并捕获完整日志
$ErrorActionPreference = 'Continue'
$out = @()
$exe = 'E:\Program Files\llama.cpp\bin\llama-server.exe'
$args = @('--model','E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf','--n-gpu-layers','20','--ctx-size','65536','--batch-size','512','--ubatch-size','128','--threads','32','--threads-batch','8','--cache-type-k','q8_0','--cache-type-v','q8_0','--host','127.0.0.1','--port','8080','--verbose')

# 清旧日志
Remove-Item -LiteralPath 'E:\PowerFocus\um-debug-out.log','E:\PowerFocus\um-debug-err.log' -Force -ErrorAction SilentlyContinue

$p = Start-Process -FilePath $exe -ArgumentList $args -RedirectStandardOutput 'E:\PowerFocus\um-debug-out.log' -RedirectStandardError 'E:\PowerFocus\um-debug-err.log' -WindowStyle Hidden -PassThru
$out += "启动 PID: $($p.Id)"

$ready = $false
for ($i = 0; $i -lt 150; $i++) {
    Start-Sleep -Seconds 1
    $p.Refresh()
    if ($p.HasExited) {
        $out += "进程在 $i 秒退出，ExitCode=$($p.ExitCode)"
        break
    }
    try {
        $h = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 2
        if ($h.status -eq 'ok') { $ready = $true; $out += "health OK，第 $i 秒就绪"; break }
    } catch {}
}
$out += "最终就绪: $ready"
$p.Refresh()
$out += "进程状态: exited=$($p.HasExited) RSS=$([math]::Round($p.WorkingSet64/1GB,2))GB"
$mem = Get-CimInstance Win32_OperatingSystem
$out += "系统可用: $([math]::Round($mem.FreePhysicalMemory/1MB,2))GB"

$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\um-debug-result.txt' -Encoding utf8

# 输出日志尾部（各 60 行）
$tail = @()
$tail += '===== stderr 尾部（通常含 KV/加载信息） ====='
if (Test-Path 'E:\PowerFocus\um-debug-err.log') {
    $tail += Get-Content -LiteralPath 'E:\PowerFocus\um-debug-err.log' -Encoding utf8 -Tail 60
}
$tail += ''
$tail += '===== stdout 尾部 ====='
if (Test-Path 'E:\PowerFocus\um-debug-out.log') {
    $tail += Get-Content -LiteralPath 'E:\PowerFocus\um-debug-out.log' -Encoding utf8 -Tail 20
}
$tail -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\um-debug-tail.txt' -Encoding utf8
