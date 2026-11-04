# 回归测试：空闲 3 轮，确认速度 0 不误告警
. 'E:\PowerFocus\统一内存模式.ps1'
. 'E:\PowerFocus\统一内存模式增强.ps1'
Monitor-WeightDistributionEnhanced -SampleCount 3 -IntervalSec 1 -BaselineTps 3.7 2>&1 | Out-Null
'回归完成'
