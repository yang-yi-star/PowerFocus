#Requires -Version 7.0
<#
============================================================
 PowerFocus 统一工具定位（dot-source 使用，不要直接执行）
 用法：. E:\PowerFocus\tools\env.ps1

 设计原则：不写死任何盘符和绝对路径。
 - Python：优先用官方 py 启动器（注册表驱动），取它报告的真实解释器
 - Node：读系统注册表 InstallPath（安装器自己写的，搬家也不会失效）
 - 逆向引擎：读 %APPDATA%\npm（环境变量拼出来，随用户目录走）
 只有当前裸命令确实命中了盒子自带旧版时，才动手调整 PATH；
 一切正常时本文件不做任何事。
============================================================
#>

# 盒子自带的运行时特征：命中即视为“旧版”
$script:InBoxPattern = 'sandbox_runtime'

function Test-InBox {
    param([string]$Path)
    return ($Path -and ($Path -match $script:InBoxPattern))
}

function Get-DevPython {
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd -and -not (Test-InBox $cmd.Source)) { return $cmd.Source }

    # 官方启动器：按注册表里登记的版本挑最新，不需要知道装在哪
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        try {
            $real = (& $py.Source -c "import sys;print(sys.executable)" 2>$null | Select-Object -First 1)
            if ($real -and (Test-Path $real) -and -not (Test-InBox $real)) { return $real }
        } catch { }
    }
    return $null
}

function Get-DevNode {
    foreach ($k in 'HKLM:\SOFTWARE\Node.js', 'HKCU:\SOFTWARE\Node.js') {
        if (Test-Path $k) {
            $ip = (Get-ItemProperty $k -ErrorAction SilentlyContinue).InstallPath
            if ($ip) {
                $exe = Join-Path $ip 'node.exe'
                if (Test-Path $exe) { return $exe }
            }
        }
    }
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd -and -not (Test-InBox $cmd.Source)) { return $cmd.Source }
    return $null
}

function Get-DevRea {
    $npm = Join-Path $env:APPDATA 'npm'
    foreach ($n in 'rea.cmd', 'rea-agents.cmd', 'rea.ps1', 'rea-agents.ps1') {
        $p = Join-Path $npm $n
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command rea -ErrorAction SilentlyContinue
    if ($cmd -and -not (Test-InBox $cmd.Source)) { return $cmd.Source }
    return $null
}

function Add-PathFront {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path $Dir)) { return }
    $keep = @($env:PATH -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $Dir.TrimEnd('\')) })
    $env:PATH = (@($Dir) + $keep) -join ';'
}

function Initialize-DevEnv {
    # 只在被盒子接管时纠正；本来就用系统版则一动不动
    $barePython = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
    $bareNode = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
    $bareRea = (Get-Command rea -ErrorAction SilentlyContinue).Source

    if (Test-InBox $barePython) {
        $py = Get-DevPython
        if ($py) { Add-PathFront (Split-Path -Parent $py) }
    }
    if (Test-InBox $bareNode) {
        $node = Get-DevNode
        if ($node) { Add-PathFront (Split-Path -Parent $node) }
    }
    if (Test-InBox $bareRea) {
        $rea = Get-DevRea
        if ($rea) { Add-PathFront (Split-Path -Parent $rea) }
    }

    # 给调度中心的代理进程一个稳定的入口（值来自环境变量拼装，不是写死路径）
    $reaPath = Get-DevRea
    if ($reaPath) { $env:POWERFOCUS_REA = $reaPath }

    # 逆向引擎依赖：只补空值，已有配置不覆盖
    if (-not $env:JAVA_HOME) {
        $jdk = Get-ChildItem 'E:\Java' -Directory -ErrorAction SilentlyContinue |
               Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } |
               Sort-Object Name -Descending | Select-Object -First 1
        if ($jdk) { $env:JAVA_HOME = $jdk.FullName }
    }
    if (-not $env:GHIDRA_INSTALL_DIR) {
        $ghidra = Get-ChildItem 'D:\' -Directory -Filter 'ghidra_*' -ErrorAction SilentlyContinue |
                  Sort-Object Name -Descending | Select-Object -First 1
        if ($ghidra) { $env:GHIDRA_INSTALL_DIR = $ghidra.FullName }
    }
}

Initialize-DevEnv
