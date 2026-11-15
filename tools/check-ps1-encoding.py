#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""扫描全仓 .ps1 的真实编码状态。

区分四类，避免「无脑加 BOM」把 GBK 文件变成乱码：
  utf8-bom      已有 UTF-8 BOM（正常）
  utf8-nobom    严格 UTF-8 可解但无 BOM（含中文时是隐患）
  gbk-nobom     严格 UTF-8 解不了、GBK 能解（真危险，加 UTF-8 BOM 会毁文件）
  ascii-nobom   纯 ASCII，无所谓
  empty / utf16 / unknown

用法：
  python check-ps1-encoding.py                 # 只打印汇总
  python check-ps1-encoding.py --json out.json # 同时落清单
"""
import os
import sys
import json

ROOT = r'E:\PowerFocus'
SKIP = {'.venv', '.git', '__pycache__', '.pytest_cache', '.ruff_cache',
        'ps1-bom-backup'}


def sniff(path):
    with open(path, 'rb') as f:
        data = f.read()
    if not data:
        return 'empty'
    if data[:3] == b'\xef\xbb\xbf':
        try:
            data[3:].decode('utf-8')
            return 'utf8-bom'
        except UnicodeDecodeError:
            return 'utf8-bom-bad'
    if data[:2] == b'\xff\xfe':
        return 'utf16le'
    if data[:2] == b'\xfe\xff':
        return 'utf16be'
    try:
        data.decode('utf-8')
        try:
            data.decode('ascii')
            return 'ascii-nobom'
        except UnicodeDecodeError:
            return 'utf8-nobom'
    except UnicodeDecodeError:
        pass
    try:
        data.decode('gbk')
        return 'gbk-nobom'
    except UnicodeDecodeError:
        return 'unknown'


def main():
    rows = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP]
        for fn in filenames:
            if not fn.lower().endswith('.ps1'):
                continue
            p = os.path.join(dirpath, fn)
            try:
                enc = sniff(p)
            except Exception as e:
                enc = 'error'
            rows.append({
                'path': os.path.relpath(p, ROOT),
                'abs': p,
                'enc': enc,
                'size': os.path.getsize(p),
            })

    from collections import Counter
    c = Counter(r['enc'] for r in rows)
    print('全仓 .ps1 共 %d 个' % len(rows))
    for k, v in c.most_common():
        print('  %-14s %d' % (k, v))

    need = [r for r in rows if r['enc'] in ('utf8-nobom', 'gbk-nobom', 'utf8-bom-bad', 'unknown')]
    print('\n需要修复的 %d 个：' % len(need))
    for r in need:
        print('  %-12s %8d B  %s' % (r['enc'], r['size'], r['path']))

    if '--json' in sys.argv:
        i = sys.argv.index('--json')
        if i + 1 < len(sys.argv):
            out = sys.argv[i + 1]
            with open(out, 'w', encoding='utf-8') as f:
                json.dump(rows, f, ensure_ascii=False, indent=1)
            print('\n清单已写: %s' % out)


if __name__ == '__main__':
    main()
