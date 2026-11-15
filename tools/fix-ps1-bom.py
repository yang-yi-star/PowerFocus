#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给缺 BOM 的 .ps1 补 UTF-8 BOM，带备份与逐文件解码校验。

自带实时扫描（不依赖外部报告文件），因此可重复执行且幂等。

只处理严格 UTF-8 可解但缺 BOM 的文件，跳过：
  - archive\\ / v2-archive\\        冻结历史，保持原样归档
  - versions\\v0.05..v0.08\\       待废弃的多版本副本
  - tools\\ps1-bom-backup\\        本脚本自己的备份目录
每个文件改前备份到 tools\\ps1-bom-backup\\<相对路径>，
改后立即读回、去 BOM、与原文逐字节比对。

用法：
  python fix-ps1-bom.py            # 干跑，只列清单
  python fix-ps1-bom.py --apply    # 实际执行
"""
import os
import sys
import shutil

ROOT = r'E:\PowerFocus'
BACKUP = os.path.join(ROOT, 'tools', 'ps1-bom-backup')
WALK_SKIP = {'.venv', '.git', '__pycache__', '.pytest_cache', '.ruff_cache',
             'ps1-bom-backup'}
SKIP_PREFIX = (
    'archive\\', 'v2-archive\\',
    'versions\\v0.05\\', 'versions\\v0.06\\',
    'versions\\v0.07\\', 'versions\\v0.08\\',
)


def is_utf8_nobom(path):
    with open(path, 'rb') as f:
        data = f.read()
    if not data or data[:3] == b'\xef\xbb\xbf':
        return False
    try:
        data.decode('utf-8')
    except UnicodeDecodeError:
        return False
    try:
        data.decode('ascii')
        return False          # 纯 ASCII 不需要 BOM
    except UnicodeDecodeError:
        return True           # 含非 ASCII 的干净 UTF-8，需要 BOM


def main():
    candidates = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in WALK_SKIP]
        for fn in filenames:
            if not fn.lower().endswith('.ps1'):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT)
            if any(rel.startswith(pre) for pre in SKIP_PREFIX):
                continue
            if is_utf8_nobom(p):
                candidates.append((p, rel))

    print('实时扫描：需补 BOM 的 .ps1 共 %d 个' % len(candidates))

    dry = '--apply' not in sys.argv
    if dry:
        print('\n[干跑] 以下文件将被加 BOM（加 --apply 执行）：')
        for _, rel in candidates:
            print('  %s' % rel)
        return

    ok, failed = 0, []
    for absp, rel in candidates:
        try:
            with open(absp, 'rb') as f:
                data = f.read()
            text = data.decode('utf-8')

            bp = os.path.join(BACKUP, rel)
            os.makedirs(os.path.dirname(bp), exist_ok=True)
            shutil.copy2(absp, bp)

            with open(absp, 'wb') as f:
                f.write(b'\xef\xbb\xbf' + data)

            with open(absp, 'rb') as f:
                after = f.read()
            if after[:3] != b'\xef\xbb\xbf':
                raise RuntimeError('BOM 未落盘')
            if after[3:] != data:
                raise RuntimeError('内容被改动')
            if after[3:].decode('utf-8') != text:
                raise RuntimeError('解码不一致')

            ok += 1
        except Exception as e:
            failed.append((rel, str(e)))

    print('\n已加 BOM 并校验通过: %d' % ok)
    for rel, e in failed:
        print('失败 %s : %s' % (rel, e))
    print('备份目录: %s' % BACKUP)


if __name__ == '__main__':
    main()
