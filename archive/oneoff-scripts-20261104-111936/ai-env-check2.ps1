$out = @()
$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwsh) { $out += "pwsh: $(& pwsh --version 2>&1 | Select-Object -First 1) 位置 $($pwsh.Source)" } else { $out += 'pwsh: 无（注意：本会话工具 shell 显示为 5.1）' }
$term = Get-Command wt -ErrorAction SilentlyContinue
if ($term) { $out += "Windows Terminal: 有 ($($term.Source))" } else { $out += 'Windows Terminal: 命令行不可用（可能未装或别名缺失）' }
$t = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*Terminal*' }
if ($t) { $t | ForEach-Object { $out += "Terminal 相关: $($_.DisplayName) :: $($_.DisplayVersion)" } } else { $out += 'Terminal 相关注册表项: 无' }
$out += ''
$out += '磁盘空间:'
Get-PSDrive -PSProvider FileSystem | ForEach-Object { $out += "  $($_.Name) 盘 剩余 $([Math]::Round($_.Free/1GB,1)) GB / 总 $([Math]::Round(($_.Free+$_.Used)/1GB,1)) GB" }
$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\ai-env-check2.txt' -Encoding utf8
