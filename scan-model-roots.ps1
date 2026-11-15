$ErrorActionPreference = 'SilentlyContinue'
$roots = @(
 'D:\AI-Models','D:\heita_models','D:\Models','D:\Model_Zone','D:\AI\models','D:\AI\tts',
 'D:\Aurabot\rvc\models','D:\DSH共享','D:\双模型对话实验','E:\LocModel','E:\Models','E:\Model_Zone',
 'E:\sd\models','E:\LocallyUncensored',
 "${env:USERPROFILE}\.dsh\speech-to-text","${env:USERPROFILE}\.cache\whisper",
 "${env:USERPROFILE}\.deepseek\models","${env:USERPROFILE}\.lmstudio",
 "${env:USERPROFILE}\.ollama","${env:USERPROFILE}\.modelscope",
 "${env:USERPROFILE}\.cache\huggingface"
)
$exts = @('.gguf','.safetensors','.ckpt','.pth','.onnx','.bin','.pt','.msgpack','.model','.npy','.pth.tar','.h5')
$rows = New-Object System.Collections.ArrayList
foreach ($r in $roots) {
  if (-not (Test-Path -LiteralPath $r)) { continue }
  Get-ChildItem -LiteralPath $r -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { ($exts -contains $_.Extension.ToLower()) -and $_.Length -gt 20MB } |
    ForEach-Object {
      [void]$rows.Add([PSCustomObject]@{
        Root = $r; Path = $_.FullName; MB = [math]::Round($_.Length/1MB,1)
        GB = [math]::Round($_.Length/1GB,3); Modified = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
      })
    }
}
# ollama blobs / lmstudio 内部模型（无扩展名）
foreach ($ob in @("${env:USERPROFILE}\.ollama\models\blobs","${env:USERPROFILE}\.lmstudio\models","${env:USERPROFILE}\.lmstudio\.internal\bundled-models")) {
  if (Test-Path -LiteralPath $ob) {
    Get-ChildItem -LiteralPath $ob -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 100MB } |
      ForEach-Object { [void]$rows.Add([PSCustomObject]@{ Root=$ob; Path=$_.FullName; MB=[math]::Round($_.Length/1MB,1); GB=[math]::Round($_.Length/1GB,3); Modified=$_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }) }
  }
}
$rows | Sort-Object Path | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath 'E:\PowerFocus\_model-scan-roots.json' -Encoding utf8
"模型文件数: $($rows.Count)  合计GB: " + [math]::Round((($rows | Measure-Object GB -Sum).Sum),2)
