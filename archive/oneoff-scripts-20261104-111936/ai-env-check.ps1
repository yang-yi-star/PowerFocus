# AI 环境盘点脚本：命令行工具 + 已装软件 + 关键目录
$out = @()
$out += '===== 1 命令行工具检查 ====='
$cmds = 'python','py','pip','git','git-lfs','node','npm','ffmpeg','ffprobe','nvcc','nvidia-smi','cmake','ninja','cl','curl','jq','conda','winget','docker','ollama','aria2c'
foreach ($c in $cmds) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd) {
        $ver = ''
        try { $ver = (& $c --version 2>&1 | Select-Object -First 1) } catch { try { $ver = (& $c -version 2>&1 | Select-Object -First 1) } catch {} }
        $out += "[有] $c :: $ver"
    } else {
        $out += "[无] $c"
    }
}

$out += ''
$out += '===== 2 NVIDIA 驱动与 CUDA ====='
try { $smi = & nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1; $out += "nvidia-smi: $($smi -join '; ')" } catch { $out += 'nvidia-smi 不可用' }
$nvcc = Get-Command nvcc -ErrorAction SilentlyContinue
if ($nvcc) { $out += "nvcc: $(& nvcc --version 2>&1 | Select-Object -Last 1)" } else { $out += 'nvcc: 无（未装 CUDA Toolkit，编译 llama.cpp 需要时才装）' }

$out += ''
$out += '===== 3 已安装软件（AI 相关关键词过滤）====='
$paths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$apps = Get-ItemProperty $paths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object @{n='Name';e={$_.DisplayName}}, @{n='Ver';e={$_.DisplayVersion}}, @{n='Loc';e={$_.InstallLocation}} |
    Sort-Object Name -Unique
$kws = 'Python','Git','ffmpeg','CUDA','NVIDIA','Visual Studio','VS Code','Cursor','Ollama','LM Studio','Anaconda','Miniconda','PyTorch','TensorRT','ONNX','Node.js','Windows Terminal','PowerShell','Docker','Blender','CMake','Rust','Go ','OpenSSH','7-Zip','Everything','HWiNFO','Afterburner','AutoHotkey','Windows SDK','C++ Build'
foreach ($a in $apps) {
    foreach ($k in $kws) {
        if ($a.Name -like "*$k*") { $out += "$($a.Name) :: $($a.Ver) :: $($a.Loc)"; break }
    }
}

$out += ''
$out += '===== 4 关键目录/文件确认 ====='
$checks = @(
    'E:\Program Files\llama.cpp\bin\llama-server.exe',
    'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf',
    'E:\PowerFocus\统一内存模式.ps1',
    'E:\PowerFocus\电脑算力调度中心.ps1',
    'E:\PowerFocus\统一内存模式增强.ps1',
    'G:\ProgramFiles',
    'C:\Program1'
)
foreach ($p in $checks) {
    if (Test-Path -LiteralPath $p) { $out += "[有] $p" } else { $out += "[缺] $p" }
}

$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\ai-env-check.txt' -Encoding utf8
