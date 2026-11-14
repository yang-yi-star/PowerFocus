# -*- coding: utf-8 -*-
"""命令总线回执协议层（纯标准库，零第三方依赖）。

从 server.py 抽出的原因：回执解析、原子写、历史回收属于协议职责，
不应与 1100 余行的路由枢纽混在一起；独立模块也让 CI 能零依赖单测。
"""
import json
import os
import re
import time
from pathlib import Path

_STAMP = re.compile(r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}$")
_ERROR = re.compile(r"^\s*ERROR\s*[:：]", re.IGNORECASE)


def parse_receipt(text: str) -> tuple[bool, str]:
    """把内核回执解析为 (是否成功, 干净正文)。

    兼容两代格式：
    - 旧格式：首行是 ``yyyy-MM-dd HH:mm:ss`` 时间戳，其后才是正文；
    - 新格式：直接是正文。

    内核执行异常时正文以 ``ERROR:`` 开头，必须判为失败。历史上
    server.py 只看 done 文件存在就返回 ok=True，导致失败操作被前端
    提示为成功；时间戳首行还让 /api/router 的 json.loads 恒为 None。
    """
    body = (text or "").strip()
    lines = body.splitlines()
    if lines and _STAMP.match(lines[0].strip()):
        body = "\n".join(lines[1:]).strip()
    if not body:
        return True, ""
    if _ERROR.match(body):
        return False, body
    return True, body


def atomic_write(path: Path, text: str, encoding: str = "utf-8") -> None:
    """先写同目录 .tmp 再 os.replace，保证内核不会读到半截 JSON。

    .tmp 后缀不被内核的 ``-Filter *.json`` 匹配，因此替换前不可见。
    """
    path = Path(path)
    tmp = path.with_name(path.name + ".tmp")
    try:
        tmp.write_text(text, encoding=encoding)
        os.replace(tmp, path)
    finally:
        # os.replace 失败时不要留半成品：下一次同 id 写入可能覆盖到错误内容。
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass


def dumps_command(cmd: dict) -> str:
    """命令序列化（与内核 ConvertFrom-Json 对齐）。"""
    return json.dumps(cmd, ensure_ascii=False)


def gc_done(directory: Path, max_age: float = 86400.0, now: float | None = None) -> int:
    """清理 done 目录中超龄的回执与命令副本，返回删除数量。

    内核把执行完的命令 Move 进 done 后从不删除，实测已残留 72 个文件。
    """
    directory = Path(directory)
    if not directory.is_dir():
        return 0
    ref = time.time() if now is None else now
    removed = 0
    for pattern in ("*.result.txt", "*.json"):
        for p in directory.glob(pattern):
            try:
                if ref - p.stat().st_mtime > max_age:
                    p.unlink(missing_ok=True)
                    removed += 1
            except OSError:
                pass
    return removed
