# gguf-kv-params.ps1 - 精确读取 Qwen3.8-27B 的 KV 相关 GGUF 参数
$path = 'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf'
$fs = [System.IO.File]::OpenRead($path)
$br = New-Object System.IO.BinaryReader($fs)
function Skip-GgufValue($br, $type) {
    switch ($type) {
        0 { $br.ReadByte() | Out-Null } 1 { $br.ReadByte() | Out-Null }
        2 { $br.ReadUInt16() | Out-Null } 3 { $br.ReadInt16() | Out-Null }
        4 { $br.ReadUInt32() | Out-Null } 5 { $br.ReadInt32() | Out-Null }
        6 { $br.ReadSingle() | Out-Null } 7 { $br.ReadByte() | Out-Null }
        8 { $sl = $br.ReadUInt64(); if ($sl -lt 64MB) { $br.ReadBytes([int]$sl) | Out-Null } }
        9 { $et = $br.ReadUInt32(); $ec = $br.ReadUInt64(); for ($k = 0; $k -lt $ec; $k++) { Skip-GgufValue $br $et } }
        10 { $br.ReadUInt64() | Out-Null } 11 { $br.ReadInt64() | Out-Null }
        12 { $br.ReadDouble() | Out-Null } default { $br.ReadByte() | Out-Null }
    }
}
$null = $br.ReadUInt32(); $null = $br.ReadUInt32(); $null = $br.ReadUInt64(); $kv = $br.ReadUInt64()
$want = @('qwen35.block_count','qwen35.attention.head_count','qwen35.attention.head_count_kv','qwen35.attention.key_length','qwen35.attention.value_length','qwen35.embedding_length','qwen35.context_length')
$found = @{}
for ($i = 0; $i -lt $kv; $i++) {
    $kl = $br.ReadUInt64(); if ($kl -gt 4096) { break }
    $k = [System.Text.Encoding]::UTF8.GetString($br.ReadBytes([int]$kl))
    $vt = $br.ReadUInt32()
    $val = $null
    switch ($vt) {
        4 { $val = $br.ReadUInt32() }
        11 { $val = $br.ReadInt64() }
        default { Skip-GgufValue $br $vt; continue }
    }
    if ($k -in $want) { $found[$k] = $val }
}
$fs.Dispose()
$out = @('GGUF 精确参数：')
foreach ($k in $want) { $out += "  $k = $($found[$k])" }
# KV 每 token 元素数与各量化字节开销
$layers = [int]$found['qwen35.block_count']
$kvheads = [int]$found['qwen35.attention.head_count_kv']
$kd = [int]$found['qwen35.attention.key_length']
$vd = [int]$found['qwen35.attention.value_length']
$elemsPerToken = $layers * $kvheads * ($kd + $vd)
$out += "  KV 元素/每token = $elemsPerToken (=$layers层 x $kvheads KV头 x ($kd+$vd)维)"
$out += "  KV f16 : $([math]::Round($elemsPerToken*2/1MB,2)) MB/token x 524288 = $([math]::Round($elemsPerToken*2*524288/1GB,2)) GB @512K"
$out += "  KV q8_0: $([math]::Round($elemsPerToken*1/1MB,2)) MB/token x 524288 = $([math]::Round($elemsPerToken*1*524288/1GB,2)) GB @512K"
$out += "  KV q4_0: $([math]::Round($elemsPerToken*0.5/1MB,2)) MB/token x 524288 = $([math]::Round($elemsPerToken*0.5*524288/1GB,2)) GB @512K"
$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\gguf-kv-params.txt' -Encoding utf8
