# ============================================================
# v3 多模型注册表（model-profiles v2）
# 职责：读 GGUF 头识别模型身份 → 在档案中解析对应的 profile 集。
# 原则：未命中身份的模型一律不猜，返回 $null，由调用方拒绝加速。
# 说明：只读文件头部元数据，不加载模型；结果按 路径+大小+mtime 缓存。
# ============================================================

$script:GgufMetaCache = @{}

# GGML file_type 枚举 → 名称（llama.cpp 定义）
$script:GgmlFileTypeMap = @{
    0='ALL_F32'; 1='MOSTLY_F16'; 2='MOSTLY_Q4_0'; 3='MOSTLY_Q4_1'; 4='MOSTLY_Q5_0';
    5='MOSTLY_Q5_1'; 6='MOSTLY_Q8_0'; 7='MOSTLY_Q2_K'; 8='MOSTLY_Q3_K_S'; 9='MOSTLY_Q3_K_M';
    10='MOSTLY_Q3_K_L'; 11='MOSTLY_Q4_K_S'; 12='MOSTLY_Q4_K_M'; 13='MOSTLY_Q5_K_S';
    14='MOSTLY_Q5_K_M'; 15='MOSTLY_Q6_K'; 16='MOSTLY_IQ2_XXS'; 17='MOSTLY_IQ2_XS';
    18='MOSTLY_IQ3_XXS'; 19='MOSTLY_IQ1_S'; 20='MOSTLY_IQ4_NL'; 21='MOSTLY_IQ3_S';
    22='MOSTLY_IQ3_M'; 23='MOSTLY_IQ2_S'; 24='MOSTLY_IQ2_M'; 25='MOSTLY_IQ4_XS';
    26='MOSTLY_IQ1_M'; 27='MOSTLY_BF16'; 28='MOSTLY_Q4_0_4_4'; 29='MOSTLY_Q4_0_4_8';
    30='MOSTLY_Q4_0_8_8'; 31='MOSTLY_TQ1_0'; 32='MOSTLY_TQ2_0'
}

function Read-GgufString {
    param($Reader)
    $len = [uint64]$Reader.ReadUInt64()
    if ($len -gt 100MB) { throw "GGUF 字符串长度异常: $len" }
    if ($len -eq 0) { return "" }
    $bytes = $Reader.ReadBytes([int]$len)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Read-GgufValue {
    param($Reader, [uint32]$Type)
    switch ($Type) {
        0  { return [uint64]$Reader.ReadByte() }
        1  { return [int64]$Reader.ReadSByte() }
        2  { return [uint64]$Reader.ReadUInt16() }
        3  { return [int64]$Reader.ReadInt16() }
        4  { return [uint64]$Reader.ReadUInt32() }
        5  { return [int64]$Reader.ReadInt32() }
        6  { return [double]$Reader.ReadSingle() }
        7  { return $Reader.ReadBoolean() }
        8  { return (Read-GgufString -Reader $Reader) }
        9  {
            $elemType = [uint32]$Reader.ReadUInt32()
            $n = [uint64]$Reader.ReadUInt64()
            if ($n -gt 50000000) { throw "GGUF 数组长度异常: $n" }
            for ($i = 0; $i -lt $n; $i++) { $null = Read-GgufValue -Reader $Reader -Type $elemType }
            return $null
        }
        10 { return [uint64]$Reader.ReadUInt64() }
        11 { return [int64]$Reader.ReadInt64() }
        12 { return [double]$Reader.ReadDouble() }
        default { throw "未知 GGUF 值类型: $Type" }
    }
}

function Read-GGUFMetadata {
    param([string]$Path)

    $out = [ordered]@{
        ok = $false; architecture = $null; layers = $null; file_type = $null;
        size_gb = $null; version = $null; error = ""
    }

    if (-not (Test-Path -LiteralPath $Path)) { $out.error = "模型文件不存在"; return [pscustomobject]$out }

    $fi = Get-Item -LiteralPath $Path
    $cacheKey = "$Path|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
    if ($script:GgufMetaCache.ContainsKey($cacheKey)) { return $script:GgufMetaCache[$cacheKey] }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $br = New-Object System.IO.BinaryReader($fs, [System.Text.Encoding]::UTF8, $true)

            $magic = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
            if ($magic -ne "GGUF") { throw "magic='$magic'，不是 GGUF 文件" }

            $ver = [uint32]$br.ReadUInt32()
            if ($ver -lt 2) { throw "GGUF 版本 $ver 不受支持（需 v2/v3）" }
            $out.version = $ver

            $null = $br.ReadUInt64()                        # tensor_count，不关心
            $kvCount = [uint64]$br.ReadUInt64()
            if ($kvCount -gt 500) { throw "metadata 条目异常: $kvCount" }

            $arch = $null
            for ($i = 0; $i -lt $kvCount; $i++) {
                if ($sw.ElapsedMilliseconds -gt 15000) { throw "读取 GGUF 头超时（15s）" }

                $key = Read-GgufString -Reader $br
                $type = [uint32]$br.ReadUInt32()
                $value = Read-GgufValue -Reader $br -Type $type

                switch -Wildcard ($key) {
                    "general.architecture" { $arch = [string]$value }
                    "*.block_count"        { if ($value -ne $null) { $out.layers = [int]$value } }
                    "general.file_type"    { $out.file_type = [int]$value }
                }

                # file_type 仅供参考、不参与身份匹配，不必等它读完词表；arch+layers 齐了就停
                if ($arch -and $out.layers -ne $null) { break }
            }
            $out.architecture = $arch

            if (-not $out.layers -and $arch) {
                # 兜底：部分档案把层数写在 {arch}.block_count，已由通配符捕获；此处仅提示
                $out.error = "未找到 $arch.block_count"
            }
            $out.size_gb = [math]::Round($fi.Length / 1GB, 2)
            $out.ok = $true
        } finally { $fs.Dispose() }
    } catch {
        $out.ok = $false
        $out.error = "$_"
    }

    $script:GgufMetaCache[$cacheKey] = [pscustomobject]$out
    return [pscustomobject]$out
}

function Get-ModelIdentity {
    param([string]$ModelPath)
    $meta = Read-GGUFMetadata -Path $ModelPath
    if (-not $meta.ok -or -not $meta.layers) { return $null }
    $ftName = if ($meta.file_type -ne $null -and $script:GgmlFileTypeMap.ContainsKey([int]$meta.file_type)) {
        $script:GgmlFileTypeMap[[int]$meta.file_type]
    } else { "UNKNOWN" }
    return [pscustomobject]@{
        model_path   = $ModelPath
        architecture = $meta.architecture
        layers       = [int]$meta.layers
        file_type    = $ftName
        size_gb      = [double]$meta.size_gb
    }
}

function Resolve-ModelProfile {
    param([string]$ProfilesPath, [string]$ModelPath)

    if (-not (Test-Path -LiteralPath $ProfilesPath)) { return $null }
    try { $cfg = Get-Content -Raw -LiteralPath $ProfilesPath -Encoding utf8 | ConvertFrom-Json } catch { return $null }
    if (-not $cfg.models) { return $null }

    $id = Get-ModelIdentity -ModelPath $ModelPath
    if (-not $id) { return $null }

    foreach ($prop in $cfg.models.PSObject.Properties) {
        $e = $prop.Value
        if (-not $e.identity) { continue }
        if ([string]$e.identity.architecture -ne [string]$id.architecture) { continue }
        if ([int]$e.identity.layers -ne [int]$id.layers) { continue }
        # 注意：file_type 不参与硬匹配。UD/混合量化的 general.file_type 常与文件名标签不一致
        # （实测 Qwen3.8-27B-UD-Q4_K_M 报 15/MOSTLY_Q6_K），拿它做门槛会永远命中不了。
        $expectSize = [double]$e.identity.size_gb
        if ($expectSize -gt 0 -and [math]::Abs($expectSize - $id.size_gb) -gt ($expectSize * 0.01)) { continue }

        return [pscustomobject]@{
            key      = $prop.Name
            entry    = $e
            identity = $id
            hardware = $cfg.hardware
        }
    }
    return $null
}

function Test-ProfileSelectionClause {
    param([string]$When, [double]$GpuFreeMb, [int]$Ctx)
    if ([string]::IsNullOrWhiteSpace($When)) { return $false }
    if ($When.Trim() -eq 'default') { return $true }
    foreach ($part in ($When -split ' and ')) {
        $p = $part.Trim()
        if ($p -notmatch '^(ctx|gpu_free_mb)\s*(>=|<=|>|<)\s*([0-9]+)$') { return $false }
        $var = $Matches[1]; $op = $Matches[2]; $val = [double]$Matches[3]
        $cur = if ($var -eq 'ctx') { [double]$Ctx } else { $GpuFreeMb }
        switch ($op) {
            '>=' { if (-not ($cur -ge $val)) { return $false } }
            '<=' { if (-not ($cur -le $val)) { return $false } }
            '>'  { if (-not ($cur -gt $val)) { return $false } }
            '<'  { if (-not ($cur -lt $val)) { return $false } }
        }
    }
    return $true
}

function Select-ModelProfile {
    param($ModelEntry, [double]$GpuFreeMb = 0, [int]$Ctx = 8192)
    if (-not $ModelEntry -or -not $ModelEntry.selection) { return $null }
    foreach ($rule in $ModelEntry.selection) {
        if (Test-ProfileSelectionClause -When ([string]$rule.when) -GpuFreeMb $GpuFreeMb -Ctx $Ctx) {
            $name = [string]$rule.use
            if ($ModelEntry.profiles.PSObject.Properties.Name -contains $name) {
                return [pscustomobject]@{ name = $name; profile = $ModelEntry.profiles.$name }
            }
        }
    }
    return $null
}
