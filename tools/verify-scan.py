# -*- coding: utf-8 -*-
"""真跑验证：/api/security/scan 的完整链路（不做 mock）。

流程：造一个小目录 → POST 发起扫描 → 轮询 status → 打印退出码与统计。
"""
import json
import os
import sys
import time

ROOT = r'E:\PowerFocus'
sys.path.insert(0, os.path.join(ROOT, 'product', 'v1.00', 'app'))

import server  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

TD = os.path.join(ROOT, 'versions', 'v0.10', 'prototype')
print('测试目录 %s 存在=%s' % (TD, os.path.isdir(TD)))

c = TestClient(server.app, base_url='http://127.0.0.1')
c.headers.update({'X-PF-Token': server._token()})

r = c.post('/api/security/scan',
           json={'scope': 'custom', 'path': TD, 'timeout_sec': 600})
print('POST /api/security/scan -> %d' % r.status_code)
print(json.dumps(r.json(), ensure_ascii=False))
if r.status_code != 200:
    sys.exit(1)

for i in range(200):
    time.sleep(2)
    s = c.get('/api/security/scan/status').json()
    if not s.get('running'):
        print('\n扫描结束: finished=%s error=%r' % (s.get('finished'), s.get('error')))
        res = s.get('result') or {}
        scan = res.get('scan') or {}
        parsed = res.get('parsed') or {}
        print('exit_code=%r duration=%rs timed_out=%r'
              % (scan.get('exit_code'), scan.get('duration_sec'), scan.get('timed_out')))
        print('产出文件 %d 个' % len(scan.get('output_files') or []))
        print('parsed:', json.dumps(parsed, ensure_ascii=False)[:900])
        print('stdout 尾部:', (scan.get('stdout') or '')[-600:])
        sys.exit(0 if scan.get('exit_code') == 0 else 2)
    if i % 10 == 0:
        print('...扫描进行中 %ds' % (i * 2))

print('等待超时（未在 400 秒内结束）')
sys.exit(3)
