Start-Process -FilePath 'pwsh' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File E:\PowerFocus\gen-test.ps1' -WindowStyle Hidden
Start-Sleep -Seconds 4
. 'E:\PowerFocus\统一内存模式.ps1'
. 'E:\PowerFocus\统一内存模式增强.ps1'
Monitor-WeightDistributionEnhanced -SampleCount 6 -IntervalSec 1 -BaselineTps 3.7 2>&1 | Out-Null
Start-Sleep -Seconds 6
'--- 后台生成完成标志 ---'
if (Test-Path 'E:\PowerFocus\gen-test-done.txt') { Get-Content -LiteralPath 'E:\PowerFocus\gen-test-done.txt' -Encoding utf8 } else { '未完成' }
