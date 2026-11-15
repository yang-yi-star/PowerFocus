# 探针：验证命令总线 action 'unified-plan' 端到端（必须在 pwsh 7 下跑）
# 用法：pwsh -NoProfile -File tools\probe-unified-action.ps1

$ErrorActionPreference = 'Stop'

$k = 'E:\PowerFocus\versions\v0.11\电脑算力调度中心_v0.11.ps1'
$m = 'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf'

. $k

"--- 1. 直接调 Invoke-CommandObject ---"
$ret = Invoke-CommandObject -Cmd @{ action = 'unified-plan'; model_path = $m }
"返回: $ret"
""

"--- 2. 落盘文件是否生成 ---"
$out = Join-Path $script:CmdOut 'unified-plan.json'
"路径: $out"
"存在: $(Test-Path -LiteralPath $out)"
if (Test-Path -LiteralPath $out) {
    "大小: $((Get-Item -LiteralPath $out).Length) 字节"
    "BOM : $([BitConverter]::ToString([IO.File]::ReadAllBytes($out)[0..2]))  <- EF-BB-BF = UTF-8 BOM"
    ""
    "--- 3. 内容（中文必须正常，不能是乱码）---"
    (Get-Content -LiteralPath $out -Raw -Encoding utf8BOM) -split "`n" | Select-Object -First 22
}
""
"--- 4. 不给模型路径（应走 note 分支）---"
$ret2 = Invoke-CommandObject -Cmd @{ action = 'unified-plan' }
"返回: $ret2"
