# -*- coding: utf-8 -*-
"""命令总线客户端：I/O 编排层（第二批架构收敛）。

分层约定：
- ``bus_receipt.py`` — 纯协议函数（解析 / 序列化 / 原子写 / GC），零第三方依赖
- ``bus.py``        — 目录、超时、轮询、幂等 id、生命周期编排
- ``server.py``     — 只做路由与编排，不再直接操作命令文件

这样总线逻辑可以脱离 FastAPI 单独单测，也避免 1100 余行的路由枢纽继续膨胀。
"""
import asyncio
import itertools
import time
import uuid
from pathlib import Path

import bus_receipt

_POLL_INTERVAL = 0.2
_GC_INTERVAL = 600.0


class BusClient:
    """文件总线客户端。每个实例持有自己的序号与 GC 节流状态。"""

    def __init__(self, in_dir: Path, done_dir: Path, kernel_name: str = "内核"):
        self.in_dir = Path(in_dir)
        self.done_dir = Path(done_dir)
        self.kernel_name = kernel_name
        self._seq = itertools.count()
        self._gc_last = 0.0

    def _new_id(self) -> str:
        """毫秒时间戳 + 进程内序号 + 随机后缀，保证并发与重启都不碰撞。"""
        return "ui-%d-%d-%s" % (
            int(time.time() * 1000), next(self._seq), uuid.uuid4().hex[:6])

    def _maybe_gc(self):
        now = time.time()
        if now - self._gc_last < _GC_INTERVAL:
            return
        self._gc_last = now
        bus_receipt.gc_done(self.done_dir)

    def _consume(self, name: str, done_path: Path):
        """回执与内核移入 done 的命令副本一起清理。"""
        for p in (done_path, self.done_dir / (name + ".json")):
            try:
                p.unlink(missing_ok=True)
            except OSError:
                pass

    async def call(self, cmd: dict, timeout: float = 30.0) -> tuple[bool, str]:
        """发一条命令并等待回执，返回 ``(是否成功, 干净正文)``。

        幂等 id 随命令下发：当前内核忽略未知字段（行为不变），
        后续内核实现去重时无需再改服务端。
        """
        name = self._new_id()
        payload = dict(cmd)
        payload.setdefault("idempotency_id", name)
        in_path = self.in_dir / (name + ".json")
        done_path = self.done_dir / (name + ".json.result.txt")
        try:
            self.in_dir.mkdir(parents=True, exist_ok=True)
            # .tmp -> os.replace：内核 -Filter *.json 看不到半成品
            bus_receipt.atomic_write(in_path, bus_receipt.dumps_command(payload))
            self._maybe_gc()
        except Exception as e:
            return False, "命令总线写入失败: %s" % e

        deadline = time.time() + timeout
        empty_seen = 0
        while time.time() < deadline:
            if done_path.exists():
                try:
                    raw = done_path.read_text(encoding="utf-8-sig")
                except Exception as e:
                    return False, "读取结果失败: %s" % e
                # 兼容尚未升级的旧内核：它用 Set-Content 非原子直写，服务端可能
                # 读到「已创建但还没写正文」的空文件，把稍后的 ERROR 当成成功。
                # 空文件最多再等 3 轮；升级为原子写后这个分支不会再触发。
                if not raw.strip():
                    empty_seen += 1
                    if empty_seen < 3:
                        await asyncio.sleep(_POLL_INTERVAL)
                        continue
                ok, text = bus_receipt.parse_receipt(raw)
                self._consume(name, done_path)
                return ok, text
            await asyncio.sleep(_POLL_INTERVAL)

        # 超时撤回未处理的命令；若内核稍后才完成，其孤儿回执由 GC 回收
        try:
            in_path.unlink(missing_ok=True)
        except OSError:
            pass
        return False, "命令总线超时（%.0f 秒）：内核未运行？请启动 %s" % (
            timeout, self.kernel_name)
