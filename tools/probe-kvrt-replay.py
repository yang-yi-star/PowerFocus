# -*- coding: utf-8 -*-
"""决定性实验：逐字复刻 2026-11-12 成功那次的命令行。

历史成功（DEVELOPMENT_LOG.md:1115 / real-scan-console.log）：
  KVRT.exe -accepteula -silent -d E:\\PowerFocus\\versions\\v0.10\\reports\\KVRT_Data
           -custom E:\\PowerFocus\\versions\\v0.10\\prototype
结果：366.0s / Processed=6943 / finish with status 0

如果这次同参数仍 status -1，说明不是代码差异，是环境或引擎自身状态变了。
"""
import os
import subprocess
import sys
import time

ROOT = r'E:\PowerFocus'
EXE = os.path.join(ROOT, 'versions', 'v0.10', 'engines', 'KVRT', 'KVRT.exe')
DATA = os.path.join(ROOT, 'versions', 'v0.10', 'reports', 'KVRT_Data')
TARGET = os.path.join(ROOT, 'versions', 'v0.10', 'prototype')

print('EXE   =', EXE, '存在=', os.path.isfile(EXE))
print('DATA  =', DATA, '存在=', os.path.isdir(DATA))
print('TARGET=', TARGET, '存在=', os.path.isdir(TARGET))

cmd = [EXE, '-accepteula', '-silent', '-d', DATA, '-custom', TARGET]
print('\n命令行:')
print(' '.join(cmd))
print()

t0 = time.time()
proc = subprocess.run(cmd, capture_output=True, timeout=700,
                      creationflags=0x08000000)
out = (proc.stdout or b'').decode('utf-8', 'replace')
err = (proc.stderr or b'').decode('utf-8', 'replace')
print('exit_code=%r duration=%.1fs' % (proc.returncode, time.time() - t0))
print('\n--- stdout ---')
print(out[-2500:] if out else '(空)')
print('\n--- stderr ---')
print(err[-1500:] if err else '(空)')
