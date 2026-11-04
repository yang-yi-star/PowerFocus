# um-debug.ps1 - 排查 GGUF 解析与 nvidia-smi 定位
$out = @()
$out += "pwsh: $($PSVersionTable.PSVersion.ToString())"

# --- nvidia-smi 定位 ---
$cmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($cmd) { $out += "nvidia-smi 路径: $($cmd.Source)" } else { $out += "nvidia-smi: 未在 PATH 找到" }
$probe = & nvidia-smi --query-gpu=index,memory.total,memory.used,memory.free --format=csv,noheader,nounits 2>&1
$out += "nvidia-smi 输出: $($probe -join ' | ')"

# --- GGUF 头部解析（逐键打印前 30 个键） ---
$path = 'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf'
$fs = [System.IO.File]::OpenRead($path)
try {
    $br = New-Object System.IO.BinaryReader($fs)
    $magic = $br.ReadUInt32()
    $ver = $br.ReadUInt32()
    $tensorCnt = $br.ReadUInt64()
    $kvCount = $br.ReadUInt64()
    $out += "magic=$magic ver=$ver tensor=$tensorCnt kv=$kvCount"
    for ($i = 0; $i -lt [math]::Min($kvCount, 30); $i++) {
        $keyLen = $br.ReadUInt64()
        $keyBytes = $br.ReadBytes([int]$keyLen)
        $key = [System.Text.Encoding]::UTF8.GetString($keyBytes)
        $vtype = $br.ReadUInt32()
        # 打印键与类型，并尝试读值
        $valDesc = ''
        switch ($vtype) {
            0  { $valDesc = "uint8=$($br.ReadByte())" }
            1  { $valDesc = "int8=$([sbyte]$br.ReadByte())" }
            2  { $valDesc = "uint16=$($br.ReadUInt16())" }
            3  { $valDesc = "int16=$($br.ReadInt16())" }
            4  { $valDesc = "uint32=$($br.ReadUInt32())" }
            5  { $valDesc = "int32=$($br.ReadInt32())" }
            6  { $valDesc = "float32=$($br.ReadSingle())" }
            7  { $valDesc = "bool=$($br.ReadByte())" }
            8  { $sLen = $br.ReadUInt64(); if ($sLen -lt 4096) { $valDesc = "string=$([System.Text.Encoding]::UTF8.GetString($br.ReadBytes([int]$sLen)))" } else { $br.ReadBytes([int]$sLen) | Out-Null; $valDesc = "string(len=$sLen)" } }
            9  { $eType = $br.ReadUInt32(); $eCnt = $br.ReadUInt64(); $valDesc = "array(type=$eType,cnt=$eCnt)"; for ($k = 0; $k -lt [math]::Min($eCnt, 3); $k++) { switch ($eType) { 0 { $br.ReadByte() | Out-Null } 4 { $br.ReadUInt32() | Out-Null } 8 { $sl = $br.ReadUInt64(); $br.ReadBytes([int]$sl) | Out-Null } default { $br.BaseStream.Position += 4 } } } }
            10 { $valDesc = "uint64=$($br.ReadUInt64())" }
            11 { $valDesc = "int64=$($br.ReadInt64())" }
            12 { $valDesc = "float64=$($br.ReadDouble())" }
            default { $valDesc = "unknown_type_$vtype" }
        }
        $out += "  [$i] $key (type=$vtype) $valDesc"
    }
} catch {
    $out += "解析异常: $($_.Exception.Message)"
} finally { $fs.Dispose() }

$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\um-debug-result.txt' -Encoding utf8
