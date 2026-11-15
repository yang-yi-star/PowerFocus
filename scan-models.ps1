$ErrorActionPreference = 'SilentlyContinue'
$out = 'E:\PowerFocus\_model-scan.json'
$roots = @('C:\Users\Administrator.医院', 'D:\', 'E:\')
$exts = @('.gguf', '.safetensors', '.ckpt', '.pth', '.onnx', '.msgpack')
$items = New-Object System.Collections.ArrayList
foreach ($r in $roots) {
    Get-ChildItem -LiteralPath $r -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $exts -contains $_.Extension.ToLower() -and
            $_.FullName -notmatch '\\node_modules\\|\\WinSxS\\|\\Windows\\|\\_model-scan' -and
            $_.Length -gt 20MB
        } |
        ForEach-Object {
            [void]$items.Add([PSCustomObject]@{
                Path = $_.FullName
                Name = $_.Name
                Bytes = $_.Length
                GB = [math]::Round($_.Length / 1GB, 3)
                Modified = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            })
        }
}
# ollama 的 blobs 没有扩展名，单独登记
$ob = 'C:\Users\Administrator.医院\.ollama\models\blobs'
if (Test-Path -LiteralPath $ob) {
    Get-ChildItem -LiteralPath $ob -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 20MB } |
        ForEach-Object {
            [void]$items.Add([PSCustomObject]@{
                Path = $_.FullName
                Name = $_.Name
                Bytes = $_.Length
                GB = [math]::Round($_.Length / 1GB, 3)
                Modified = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            })
        }
}
$items | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $out -Encoding utf8
"扫描文件数: $($items.Count)"
"总体积 GB: " + [math]::Round((($items | Measure-Object Bytes -Sum).Sum) / 1GB, 1)
