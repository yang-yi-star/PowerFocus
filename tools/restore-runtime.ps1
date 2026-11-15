# 还原运行时工具（一键回到删除前）
# 用法：pwsh -File E:\PowerFocus\tools\restore-runtime.ps1
$bases = 'C:\Users\Administrator.医院\AppData\Local\DoubaoWork\User Data\sandbox_runtime\bases'
foreach ($d in Get-ChildItem $bases -Directory) {
    foreach ($name in 'node', 'python') {
        $disabled = Join-Path $d.FullName "$name.disabled-20261104"
        $target   = Join-Path $d.FullName $name
        if ((Test-Path $disabled) -and -not (Test-Path $target)) {
            Rename-Item $disabled $name
            "已还原 $($d.Name)\$name"
        }
    }
}
