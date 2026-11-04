#Requires -Version 7.0
<#
============================================================
 PowerFocus 统一工具定位（dot-source 使用，不要直接执行）
 用法：. E:\PowerFocus\tools\env.ps1

 作用：
 1. 把系统里的真实新版工具排到本进程 PATH 最前面（压过软件盒子自带的旧版）
 2. 提供 Get-DevPython / Get-DevNode / Get-DevRea 三个解析函数
 3. 给逆向引擎补上它依赖的两个环境变量
============================================================
#>

$script:DevPythonCandidates = @(
    'D:\Python313\python.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python310\python.exe')
)
$script:DevNodeCandidates = @('C:\Program Files\nodejs\node.exe')

function Get-DevPython {
    foreach ($c in $script:DevPythonCandidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Get-DevNode {
    foreach ($c in $script:DevNodeCandidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-DevRea {
    $npm = Join-Path $env:APPDATA 'npm'
    foreach ($n in 'rea.cmd', 'rea-agents.cmd') {
        $p = Join-Path $npm $n
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command rea -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Add-PathFront {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path $Dir)) { return }
    $keep = @($env:PATH -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $Dir.TrimEnd('\')) })
    $env:PATH = (@($Dir) + $keep) -join ';'
}

function Initialize-DevEnv {
    $py = Get-DevPython
    $node = Get-DevNode
    $rea = Get-DevRea

    # 排到 PATH 最前面：先摘掉旧位置，再插到队首（否则已存在的条目不会前移）
    if ($node) { Add-PathFront (Split-Path -Parent $node) }
    if ($py) { Add-PathFront (Split-Path -Parent $py) }
    if ($rea) { Add-PathFront (Split-Path -Parent $rea) }

    # 逆向引擎优先使用全局安装，并补上它依赖的环境变量
    if ($rea) { $env:POWERFOCUS_REA = $rea }
    if (-not $env:JAVA_HOME -and (Test-Path 'E:\Java\jdk-25')) { $env:JAVA_HOME = 'E:\Java\jdk-25' }
    if (-not $env:GHIDRA_INSTALL_DIR -and (Test-Path 'D:\ghidra_12.1.4_PUBLIC')) { $env:GHIDRA_INSTALL_DIR = 'D:\ghidra_12.1.4_PUBLIC' }
}

Initialize-DevEnv
