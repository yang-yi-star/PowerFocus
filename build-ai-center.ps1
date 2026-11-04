# 构建 E:\AI 调度中心：索引 + manifest + 全盘目录 AI 画像
$ErrorActionPreference = 'SilentlyContinue'
$center = 'E:\AI 调度中心'
if (-not (Test-Path -LiteralPath $center)) { New-Item -ItemType Directory -Path $center | Out-Null }

$out = @()
$out += '# AI 调度中心 · 资源索引'
$out += ''
$out += '> 生成时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$out += '> 用途：AI 查看本目录即可知道本机所有 AI 资产的位置、用途与状态。机器可读版见 manifest.json。'
$out += ''
$out += '## 一、核心推理服务（常驻）'
$out += ''
$out += '| 端口 | 模型 | 角色 | 状态定位方式 |'
$out += '|---|---|---|---|'
$out += '| 8080 | Qwen3.8-27B-UD Q4_K_M（64K 上下文） | 主推理服务（受管基线，统一内存模式：GPU 20 层 + CPU 45 层） | netstat -ano \| findstr :8080，按 PID 定位 |'
$out += '| 8686 | Qwen3 4B | 轻量辅助实例（点名保留，不得动） | netstat -ano \| findstr :8686 |'
$out += ''
$out += '## 二、模型资产'
$out += ''
$out += '- **E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\** —— 27B 主模型（Q4_K_M ≈15.3GB，block=65 层，full_attention 16/65）'
$out += ''
$out += '## 三、自建程序（PowerFocus 系列，点名保留）'
$out += ''
$out += '| 文件 | 用途 |'
$out += '|---|---|'
$out += '| E:\PowerFocus\电脑算力调度中心.ps1 | 托盘算力调度工具 |'
$out += '| E:\PowerFocus\统一内存模式.ps1 | 统一内存模式主模块（854 行，mmap 驻留 + GPU/CPU 分层） |'
$out += '| E:\PowerFocus\统一内存模式增强.ps1 | 增强模块 v2：上下文余量/性能骤降告警/清槽重启（监督修正版） |'
$out += ''
$out += '## 四、语音 AI 资产（点名保留，不得删）'
$out += ''
$voice = @()
$names = 'SenseVoice*','EdgeTTS*','*LlamaMonitor*','DeepSeekHarness*','*黑塔*','*RVC*','*rvc*'
$roots = @('C:\','D:\','E:\','F:\','G:\')
foreach ($root in $roots) {
    if (Test-Path -LiteralPath $root) {
        foreach ($n in $names) {
            Get-ChildItem -LiteralPath $root -Directory -Depth 2 -Filter $n -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\Windows\\' -and $_.FullName -notmatch 'WinSxS' -and $_.FullName -notmatch '\\Program Files' -and $_.FullName -notmatch '\\System32' -and $_.FullName -notmatch '\\Temp\\' } |
                ForEach-Object { $voice += $_.FullName }
        }
    }
}
$voice = $voice | Sort-Object -Unique
if ($voice.Count -eq 0) { $out += '（二级目录内未直接匹配到名称，见 manifest 中手工登记项）' }
else { foreach ($v in $voice) { $out += "- $v" } }
$out += ''
$out += '## 五、AI 工具链'
$out += ''
$out += '| 工具 | 位置/版本 | 用途 | 状态 |'
$out += '|---|---|---|---|'
$out += '| llama.cpp b12032 | E:\Program Files\llama.cpp\bin | 推理引擎 | 运行中 |'
$out += '| CUDA Toolkit 12.8 | C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8 | GPU 计算 | 已装 |'
$out += '| NVIDIA 驱动 | 617.42（RTX 5060 Laptop 8GB） | GPU 驱动 | 已装 |'
$out += '| CMake 4.3.2 | C:\Program Files\CMake（已入 PATH） | 编译构建 | 已装 |'
$out += '| Ninja | winget 安装 | 编译加速 | 已装 |'
$out += '| aria2 | winget 安装 | 大文件多线程下载 | 已装 |'
$out += '| Python 3.11.9（AI 统一解释器） | C:\Users\Administrator.医院\AppData\Local\Programs\Python\Python311 | AI 脚本 | 已装（py 默认） |'
$out += '| ffmpeg 9.0.2 | winget（gyan.dev） | 音视频处理 | 已装 |'
$out += '| Ollama 0.35.1 | 用户目录 Programs\Ollama | 模型管理（备用） | 已装 |'
$out += '| LM Studio | winget 安装 | 模型 GUI 管理（对比观察） | 已装 |'
$out += '| ONNX Runtime DirectML | Python 3.11 包 | Windows ML 方向预研 | 已装 |'
$out += '| Git 2.54 + git-lfs 3.7.1 | C:\Program1 | 版本控制/大文件 | 已装 |'
$out += '| pwsh 7.6.9 / Windows Terminal | 系统 | 运行环境 | 已装 |'
$out += ''
$out += '## 六、全盘目录 AI 画像（启发式：按目录名标注，仅作导航参考）'
$out += ''
$out += '| 目录 | 判定 | 说明 |'
$out += '|---|---|---|'
foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $items = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($d in $items) {
        $n = $d.Name
        $tag = '其他'
        $desc = ''
        if ($n -match 'Model|模型|AI|ai|llm|gguf|llama|Qwen|qwen|voice|asr|tts|rvc|RVC|speech|SenseVoice|EdgeTTS|Monitor|Harness|PowerFocus|DeepSeek|torch|onnx|cuda|Python|python|lmstudio|ollama|whisper|funasr|comfy|sd-webui|stable-diffusion|blender') {
            $tag = 'AI 相关'
            if ($n -like 'Qwen*') { $desc = '千问模型' }
            elseif ($n -like '*Model*' -or $n -eq 'model') { $desc = '模型库' }
            elseif ($n -eq 'PowerFocus') { $desc = '自建算力调度/统一内存程序' }
            elseif ($n -match 'voice|asr|tts|rvc|speech|SenseVoice|EdgeTTS') { $desc = '语音 AI' }
        }
        $out += "| $($root)$n | $tag | $desc |"
    }
}
$out += ''
$out += '## 七、本目录定位说明'
$out += ''
$out += '本目录是**索引/台账**，不是物理仓库：所有 AI 资产保持在原路径（避免破坏脚本内绝对路径）。'
$out += 'AI 查目录：先读 manifest.json（机器可读），再按 index.md 定位具体资源。'
$out += '判定规则：目录名启发式匹配（AI/Model/语音等关键词），人工精确项以第一~五节为准。'
$out += ''

$out -join "`n" | Set-Content -LiteralPath "$center\index.md" -Encoding utf8

# manifest.json（机器可读）
$manifest = [ordered]@{
    schema = 'ai-scheduler-center/v1'
    generated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    note = 'AI 资源索引台账。所有资产保持原路径，本中心仅为导航。'
    services = @(
        @{ port = 8080; model = 'Qwen3.8-27B-UD-Q4_K_M'; role = '主推理（受管基线 64K，GPU20/CPU45）'; locate = 'netstat -ano | findstr :8080' },
        @{ port = 8686; model = 'Qwen3 4B'; role = '轻量辅助（点名保留，不得动）'; locate = 'netstat -ano | findstr :8686' }
    )
    models = @(
        @{ name = 'Qwen3.8-27B-UD-Q4_K_M'; path = 'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf'; size_gb = 15.33; layers = 65 }
    )
    programs = @(
        @{ name = '电脑算力调度中心'; path = 'E:\PowerFocus\电脑算力调度中心.ps1' },
        @{ name = '统一内存模式'; path = 'E:\PowerFocus\统一内存模式.ps1' },
        @{ name = '统一内存模式增强'; path = 'E:\PowerFocus\统一内存模式增强.ps1' }
    )
    voice_assets = $voice
    toolchain = @(
        @{ name = 'llama.cpp'; path = 'E:\Program Files\llama.cpp\bin'; version = 'b12032' },
        @{ name = 'CUDA Toolkit'; path = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8'; version = '12.8' },
        @{ name = 'CMake'; path = 'C:\Program Files\CMake'; version = '4.3.2' },
        @{ name = 'Python (AI 统一解释器)'; path = 'C:\Users\Administrator.医院\AppData\Local\Programs\Python\Python311'; version = '3.11.9' },
        @{ name = 'ffmpeg'; path = 'C:\Users\Administrator.医院\AppData\Local\Microsoft\WinGet\Packages'; version = '9.0.2' },
        @{ name = 'Ollama'; version = '0.35.1' },
        @{ name = 'LM Studio'; note = 'winget ElementLabs.LMStudio' },
        @{ name = 'ONNX Runtime DirectML'; note = 'Python 3.11 包 onnxruntime-directml' }
    )
    directory_map_note = '启发式画像见 index.md 第六节；精确资产以上各节为准'
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$center\manifest.json" -Encoding utf8

"索引已生成：$center\index.md + manifest.json，共 $($out.Count) 行" | Set-Content -LiteralPath 'E:\PowerFocus\center-build-result.txt' -Encoding utf8
Get-Content -LiteralPath 'E:\PowerFocus\center-build-result.txt' -Encoding utf8