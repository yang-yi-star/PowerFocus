# -*- coding: utf-8 -*-
"""对照实验：-d 数据目录含中文 vs 纯 ASCII，是否导致 KVRT 秒退 status -1。

不写任何业务代码，只调 kvrt_bundle 已验证的 run_scan。
"""
import os
import sys
import time

ROOT = r'E:\PowerFocus'
sys.path.insert(0, os.path.join(ROOT, 'versions', 'v0.10'))
import kvrt_bundle as k  # noqa: E402

TARGET = os.path.join(ROOT, '.scan-test')
os.makedirs(TARGET, exist_ok=True)
for n in ('a.txt', 'b.txt', 'c.txt'):
    with open(os.path.join(TARGET, n), 'w', encoding='utf-8') as f:
        f.write('powerfocus probe ' + n)

CASES = [
    ('ASCII 数据目录', os.path.join(ROOT, '.scan-data-ascii')),
    ('中文 数据目录', os.path.join(os.environ['LOCALAPPDATA'], 'PowerFocus',
                              'v0.10', 'reports', 'KVRT_Data')),
]

for label, dd in CASES:
    print('\n' + '=' * 70)
    print('%s -> %s' % (label, dd))
    print('=' * 70)
    req = k.ScanRequest(scope='custom', custom_path=TARGET, data_dir=dd,
                        process_level=0, timeout_sec=180)
    t0 = time.time()
    try:
        out = k.run_scan(req)
    except Exception as e:
        print('抛异常: %s: %s' % (type(e).__name__, e))
        continue
    print('exit_code=%r duration=%rs' % (out.get('exit_code'), out.get('duration_sec')))
    print('产出文件 %d 个' % len(out.get('output_files') or []))
    stdout = (out.get('stdout') or '')
    print('--- stdout ---')
    print(stdout[-1200:])
