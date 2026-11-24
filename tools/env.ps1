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

<#
 工具对齐判定（32 号）。
 背景：Doubao Work 等宿主会话会把 python / node / pwsh 注入成沙箱别名，或把 sandbox_runtime
 前置到 PATH。此时裸 `Get-Command python` 命中的是别名，`.Source` 恒为空 —— 那是宿主行为，
 不是产品缺陷，也不能据此判"python 未找到"。
 判据改为：Get-Dev* 解析出的真实路径（已排除盒内版本）必须存在，且能实跑出版本号。
 回执三类：未找到 / 仅盒内（或仅别名）可达 / 真实可用。裸命令现状只作诊断信息，不参与判死。
#>
function Get-ToolAlignment {
    $real = [ordered]@{
        python = Get-DevPython
        node   = Get-DevNode
        rea    = Get-DevRea
    }
    $bad = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()

    foreach ($k in $real.Keys) {
        $path = $real[$k]
        $bare = Get-Command $k -ErrorAction SilentlyContinue

        # 裸命令现状：只记录，不作判据
        if (-not $bare) {
            $notes.Add("$k 裸命令不可达")
        } elseif ($bare.CommandType -eq 'Alias') {
            $tag = if (Test-InBox $bare.Definition) { '指向盒内' } else { '指向非盒内' }
            $notes.Add("$k 裸命令是别名（$tag：$($bare.Definition)）")
        } elseif (Test-InBox $bare.Source) {
            $notes.Add("$k 裸命令命中盒内（$($bare.Source)）")
        } else {
            $notes.Add("$k 裸命令=$($bare.Source)")
        }

        # 真实工具判据
        if (-not $path) {
            if ($bare -and $bare.CommandType -eq 'Alias' -and (Test-InBox $bare.Definition)) {
                $bad.Add("$k 仅别名可达且指向盒内：$($bare.Definition)")
            } elseif ($bare -and $bare.CommandType -eq 'Application' -and (Test-InBox $bare.Source)) {
                $bad.Add("$k 仅盒内版本可达：$($bare.Source)")
            } else {
                $bad.Add("$k 未找到可用的真实版本")
            }
            continue
        }
        if (Test-InBox $path) { $bad.Add("$k 真实版解析回落盒内：$path"); continue }
        if (-not (Test-Path -LiteralPath $path)) { $bad.Add("$k 解析结果不存在：$path"); continue }

        # 类型校验：解释器/CLI 必须是可执行文件，避免"存在但打不开"被当可用
        $allowedExt = if ($k -eq 'rea') { @('.cmd', '.bat', '.ps1', '.exe') } else { @('.exe') }
        $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        if ($ext -notin $allowedExt) { $bad.Add("$k 不可执行类型（$ext）：$path"); continue }

        if ($k -eq 'rea') { $notes.Add("rea=$path"); continue }

        # 实跑一次版本命令：证"能用"，不只是"存在"
        $versionArg = if ($k -eq 'python') { '-V' } else { '--version' }
        $vArr = @()
        try {
            $vArr = @(& $path $versionArg 2>&1)
        } catch {
            $bad.Add("$k 无法执行：$($_.Exception.Message)"); continue
        }
        if ($LASTEXITCODE -ne 0) {
            $bad.Add("$k 执行失败 exit=$LASTEXITCODE：$((@($vArr | Select-Object -First 2) -join ' '))"); continue
        }
        $vTxt = ([string](@($vArr | Select-Object -First 1))).Trim()
        if (-not $vTxt) { $bad.Add("$k 版本命令无输出（exit=0）：$path"); continue }
        if ($vTxt.Length -gt 48) { $vTxt = $vTxt.Substring(0,48) + '...' }
        $notes.Add("$k=$path（$vTxt）")
    }

    $detail = if ($bad.Count -gt 0) { ((@($bad) + @($notes)) -join ' ;; ') } else { (@($notes) -join '；') }
    return [pscustomobject]@{
        Ok     = ($bad.Count -eq 0)
        Bad    = @($bad)
        Notes  = @($notes)
        Items  = $real
        Detail = $detail
    }
}
