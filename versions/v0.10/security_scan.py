# -*- coding: utf-8 -*-
"""
电脑算力调度中心 V0.10 · 应用内安全扫描适配层（最基础原型）
============================================================

本模块的定位是「接口契约 + 真实识别 + 安全占位」，不是成品杀毒功能：

  * 已实现：识别本机已安装的杀毒/安全软件（WMI 安全中心，只读）、
            引擎适配器注册表、扫描命令构造、统一报告数据结构、
            应用内自动扫描的频次与下次执行时间计算。
  * 未实现：真实执行扫描、解析各厂商原始日志、报告持久化、
            后端 API 路由、随包引擎二进制与病毒库分发。
  * 安全约定：原型阶段严禁真实拉起整机扫描。run() 默认只做 dry-run，
            需要显式 allow_execute=True 才允许，且仍需外部授权校验。

三条引擎路径（务必与前端原型保持一致）：
  1. 内置引擎（ClamAV GPLv2 portable）——可随安装包分发，无需系统另装杀软；
  2. 卡巴斯基 OEM（Scan Engine / Anti-Virus SDK v8）——需商业授权，不能自由再分发；
  3. 外部适配器——识别客户机已装安全软件，按官方命令行调用或降级为引导。

命令依据（均为官方公开文档，未查证的一律标「无公开接口」）：
  * Kaspersky KES for Windows: avp.com SCAN [/R[A]:报告] /MEMORY /STARTUP <路径>
  * Microsoft Defender: MpCmdRun.exe -Scan -ScanType 1|2|3 [-CpuThrottling N]
  * WMI 识别: root\\SecurityCenter2 -> AntiVirusProduct (displayName / productState / pathToSignedProductExe)
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, field, asdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# 常量：不臆造接口，未查到官方命令行的产品一律标为「仅引导」
# ---------------------------------------------------------------------------

PWSH_CANDIDATES = [
    shutil.which("pwsh") or "",
    os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WindowsApps", "pwsh.exe"),
]

# 安全中心 productState 位掩码（官方未正式文档化，社区通行解读，仅作参考展示）
PRODUCT_STATE_MASK = {
    "scanner": 0xF000,       # 0x1000 = 开启
    "realtime": 0x00F0,      # 0x0010 = 实时防护开启
    "definitions": 0x000F,   # 0x0000 = 病毒库最新
}

WMI_QUERY = (
    "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
    "Get-CimInstance -Namespace root\\SecurityCenter2 "
    "-ClassName AntiVirusProduct | "
    "Select-Object displayName,productState,pathToSignedProductExe | "
    "ConvertTo-Json -Compress"
)


def find_pwsh() -> Optional[str]:
    """定位 PowerShell 7（版本规范要求 7+，不使用 5.1）。"""
    for p in PWSH_CANDIDATES:
        if p and os.path.isfile(p):
            return p
    return None


# ---------------------------------------------------------------------------
# 引擎识别：只读，不改系统状态
# ---------------------------------------------------------------------------

@dataclass
class DetectedProduct:
    """一条已识别的安全产品记录。"""
    display_name: str
    product_state: int
    signed_exe: str
    source: str = "SecurityCenter2"
    # 以下为按公开资料推断的能力，不保证准确；真实落地需逐厂商验证
    adapter_id: str = ""
    callable_mode: str = "unknown"   # cli | guide | oem | builtin | unknown

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def classify(display_name: str) -> Tuple[str, str]:
    """按名称匹配适配器。找不到官方命令行时明确标为「仅引导」。"""
    n = display_name.lower()
    if "kaspersky" in n or "卡巴" in n:
        return "kaspersky", "cli"          # 企业版 avp.com，家用版未查证
    if "defender" in n:
        return "defender", "cli"
    if "tencent" in n or "腾讯" in n or "电脑管家" in n:
        return "qqpcmgr", "guide"
    if "360" in n:
        return "360", "guide"
    if "huorong" in n or "火绒" in n:
        return "huorong", "guide"
    if "eset" in n or "nod32" in n:
        return "eset", "cli"
    if "avast" in n or "avg" in n:
        return "avast", "unknown"
    if "bitdefender" in n:
        return "bitdefender", "unknown"
    if "norton" in n or "mcafee" in n or "avira" in n:
        return "other", "unknown"
    return "unknown", "unknown"


def discover_engines() -> List[DetectedProduct]:
    """
    真实识别本机安全中心已注册的反病毒 / 安全防护产品。

    只读查询，不需要管理员权限，不会启动或停止任何服务。
    在原型阶段这是唯一真正执行的系统交互。
    """
    exe = find_pwsh()
    if not exe:
        raise RuntimeError("未找到 PowerShell 7，无法查询安全中心")
    proc = subprocess.run(
        [exe, "-NoProfile", "-NonInteractive", "-Command", WMI_QUERY],
        capture_output=True, timeout=30,
    )
    # 不同电脑的系统代码页不同：pwsh 管道输出可能是 UTF-8 也可能是 GBK。
    # 先按 UTF-8，失败再按 GBK，避免中文产品名（如「腾讯电脑管家」）解码崩溃。
    def decode(b: bytes) -> str:
        try:
            return b.decode("utf-8")
        except UnicodeDecodeError:
            return b.decode("gbk", errors="replace")

    stdout = decode(proc.stdout or b"")
    if proc.returncode != 0 or not stdout.strip():
        raise RuntimeError("安全中心查询失败: " + decode(proc.stderr or b"").strip())
    raw = json.loads(stdout)
    if isinstance(raw, dict):
        raw = [raw]
    out: List[DetectedProduct] = []
    for item in raw:
        name = str(item.get("displayName") or "未知产品")
        adapter, mode = classify(name)
        out.append(DetectedProduct(
            display_name=name,
            product_state=int(item.get("productState") or 0),
            signed_exe=str(item.get("pathToSignedProductExe") or ""),
            adapter_id=adapter,
            callable_mode=mode,
        ))
    return out


# ---------------------------------------------------------------------------
# 引擎适配器：统一接口，切换引擎不改上层业务代码
# ---------------------------------------------------------------------------

@dataclass
class EngineAdapter:
    """一个扫描引擎的静态描述与命令构造规则。"""
    id: str
    name: str
    origin: str                  # builtin | external | oem
    bundled: bool                # 是否随安装包分发
    license_note: str
    command_template: str        # 官方公开文档中的命令；无接口时写说明文字
    verified: bool = False       # 命令是否经过官方文档核对
    report_format: str = "text"

    def build_command(self, scope: str, report_path: str, cpu_limit: int = 50) -> List[str]:
        """只构造命令，不执行。scope: full | quick | custom。"""
        raise NotImplementedError("由子类实现")

    def describe(self) -> Dict[str, Any]:
        return {
            "id": self.id, "name": self.name, "origin": self.origin,
            "bundled": self.bundled, "verified": self.verified,
            "license_note": self.license_note,
            "command_template": self.command_template,
            "report_format": self.report_format,
        }


class BuiltinClamAVAdapter(EngineAdapter):
    """随包自带的开源引擎（GPLv2 portable）。原型阶段不含二进制。"""

    def __init__(self, bundle_dir: str = ""):
        super().__init__(
            id="builtin", name="应用内置扫描引擎 (ClamAV)",
            origin="builtin", bundled=True, verified=True,
            license_note="GPLv2；官方提供 Windows portable ZIP，可随包分发；病毒库需单独维护更新",
            command_template="clamscan.exe -r --database=<bundle>/db --max-filesize=64M <path>",
            report_format="clamscan-text",
        )
        self.bundle_dir = bundle_dir

    def build_command(self, scope: str, report_path: str, cpu_limit: int = 50) -> List[str]:
        exe = os.path.join(self.bundle_dir, "clamscan.exe") if self.bundle_dir else "clamscan.exe"
        target = "C:\\" if scope == "full" else os.environ.get("SystemRoot", "C:\\Windows")
        return [exe, "-r", "--database=" + os.path.join(self.bundle_dir or ".", "db"),
                "--log=" + report_path, target]


class KasperskyAdapter(EngineAdapter):
    """
    外部适配器：检测客户机已装的卡巴斯基并调用官方命令行。

    重要：卡巴斯基引擎与病毒库不能随第三方安装包再分发。
    若产品要求「内嵌卡巴斯基品牌引擎」，须走官方 OEM 授权
    （Kaspersky Scan Engine / Anti-Virus SDK v8），本类保留接入位。
    """

    def __init__(self, avp_com: str = ""):
        super().__init__(
            id="kaspersky", name="卡巴斯基 Kaspersky",
            origin="external", bundled=False, verified=True,
            license_note="商业专有；仅可调用已安装实例；内嵌需 OEM SDK 商业授权",
            command_template="avp.com SCAN /RA:<report> /MEMORY /STARTUP <path>",
            report_format="kaspersky-text",
        )
        self.avp_com = avp_com

    def build_command(self, scope: str, report_path: str, cpu_limit: int = 50) -> List[str]:
        exe = self.avp_com or "avp.com"
        target = "C:\\" if scope == "full" else "C:\\Windows"
        return [exe, "SCAN", "/RA:" + report_path, "/MEMORY", "/STARTUP", target]


class DefenderAdapter(EngineAdapter):
    """Windows 自带 Defender，无需安装；命令来自 Microsoft Learn。"""

    def __init__(self, mpcmdrun: str = ""):
        super().__init__(
            id="defender", name="Windows Defender",
            origin="external", bundled=False, verified=True,
            license_note="Windows 系统组件，无需安装；需管理员权限且服务须处于启用状态",
            command_template="MpCmdRun.exe -Scan -ScanType 2 -CpuThrottling 50",
            report_format="defender-exitcode+eventlog",
        )
        self.mpcmdrun = mpcmdrun or os.path.join(
            os.environ.get("ProgramFiles", "C:\\Program Files"),
            "Windows Defender", "MpCmdRun.exe")

    def build_command(self, scope: str, report_path: str, cpu_limit: int = 50) -> List[str]:
        scan_type = "2" if scope == "full" else "1"
        return [self.mpcmdrun, "-Scan", "-ScanType", scan_type,
                "-CpuThrottling", str(cpu_limit)]


class GuidedOnlyAdapter(EngineAdapter):
    """未查到官方公开命令行扫描接口的产品：只识别、只引导，绝不伪造调用。"""

    def __init__(self, adapter_id: str, name: str, main_exe: str = ""):
        super().__init__(
            id=adapter_id, name=name, origin="external", bundled=False,
            verified=False, license_note="第三方商业软件，调用方式由厂商决定",
            command_template="（无公开命令行扫描接口）→ 打开主程序引导用户扫描",
            report_format="none",
        )
        self.main_exe = main_exe

    def build_command(self, scope: str, report_path: str, cpu_limit: int = 50) -> List[str]:
        raise NotImplementedError(
            self.name + " 未查到官方公开的全盘扫描命令行接口，原型拒绝伪造调用；"
            "真实落地应降级为打开主程序并引导用户手动扫描，报告标记为「引导扫描」")


def default_registry() -> Dict[str, EngineAdapter]:
    """内置能力 + 卡巴斯基 + Defender + 常见国产安全软件（引导模式）。"""
    return {
        "builtin": BuiltinClamAVAdapter(),
        "kaspersky": KasperskyAdapter(),
        "defender": DefenderAdapter(),
        "qqpcmgr": GuidedOnlyAdapter("qqpcmgr", "腾讯电脑管家"),
        "360": GuidedOnlyAdapter("360", "360 安全卫士"),
        "huorong": GuidedOnlyAdapter("huorong", "火绒安全软件"),
    }


# ---------------------------------------------------------------------------
# 扫描报告：与前端原型字段一致
# ---------------------------------------------------------------------------

@dataclass
class Threat:
    name: str
    path: str
    risk: str = "低"
    action: str = "待处理"


@dataclass
class ScanReport:
    id: str
    date: str
    engine_id: str
    engine_name: str
    scope: str
    trigger: str                     # 手动 | 每日自动
    duration_sec: int = 0
    files_scanned: int = 0
    threats: List[Threat] = field(default_factory=list)
    status: str = "clean"            # clean | threats | failed
    simulated: bool = True           # 原型必须为 True，防止把模拟结果当真实结论
    cpu_limit: int = 50
    raw_log: str = ""

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["threats"] = [asdict(t) for t in self.threats]
        return d

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# 应用内自动扫描配置与调度（纯计算，不注册系统计划任务）
# ---------------------------------------------------------------------------

@dataclass
class ScanSettings:
    enabled: bool = True
    frequency: str = "daily"         # daily | 12h | weekly | custom
    custom_hours: int = 24
    daily_time: str = "03:00"
    engine_policy: str = "builtin"   # builtin | auto | specified
    specified_engine: str = "builtin"
    default_scope: str = "full"
    cpu_limit: int = 50
    keep_days: int = 30

    def label(self) -> str:
        if self.frequency == "daily":
            return "每天 " + self.daily_time
        if self.frequency == "12h":
            return "每 12 小时"
        if self.frequency == "weekly":
            return "每周 " + self.daily_time
        return "每 " + str(self.custom_hours) + " 小时"

    def engine_id(self, detected: List[DetectedProduct]) -> str:
        if self.engine_policy == "builtin":
            return "builtin"
        if self.engine_policy == "specified":
            return self.specified_engine
        for p in detected:                       # auto：挑第一个可命令行调用的
            if p.callable_mode == "cli":
                return p.adapter_id
        return "builtin"                         # 兜底回内置，保证「无杀软也能扫」

    def next_run(self, now: Optional[datetime] = None) -> datetime:
        """计算下次执行时间。真实调度器用应用内定时器轮询，不写系统任务计划。"""
        now = now or datetime.now()
        if self.frequency in ("daily", "weekly"):
            hh, mm = (self.daily_time.split(":") + ["0"])[:2]
            d = now.replace(hour=int(hh), minute=int(mm), second=0, microsecond=0)
            if d <= now:
                d += timedelta(days=7 if self.frequency == "weekly" else 1)
            return d
        hours = 12 if self.frequency == "12h" else max(1, self.custom_hours)
        return now + timedelta(hours=hours)


# ---------------------------------------------------------------------------
# 执行边界：原型阶段拒绝真实整机扫描
# ---------------------------------------------------------------------------

def run_scan(adapter: EngineAdapter, scope: str, report_path: str,
             cpu_limit: int = 50, allow_execute: bool = False):
    """
    原型阶段只返回将要执行的命令（dry-run）。
    allow_execute 默认 False；即便置 True，也仍须在上层完成引擎授权、
    管理员权限与用户确认校验后才可放开——本函数不做这些业务判断。
    """
    cmd = adapter.build_command(scope, report_path, cpu_limit)
    if not allow_execute:
        return {"executed": False, "dry_run": True, "command": cmd,
                "note": "原型模式：未执行。真实扫描需后端适配层 + 引擎授权 + 管理员权限"}
    raise NotImplementedError(
        "真实执行尚未实现：v0.10 为最基础原型，禁止在未完成授权与联调前拉起整机扫描")


# ---------------------------------------------------------------------------
# CLI：--discover 真实只读识别；--dry-run 展示命令；--settings 展示调度
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="V0.10 应用内安全扫描适配层（原型）")
    ap.add_argument("--discover", action="store_true", help="只读识别本机已装安全软件")
    ap.add_argument("--dry-run", action="store_true", help="展示各引擎将执行的命令，不执行")
    ap.add_argument("--settings", action="store_true", help="展示默认配置与下次执行时间")
    args = ap.parse_args(argv)

    if args.discover:
        try:
            items = discover_engines()
        except Exception as e:
            print("识别失败:", e)
            return 2
        print(json.dumps([x.to_dict() for x in items], ensure_ascii=False, indent=2))
        return 0

    if args.dry_run:
        reg = default_registry()
        for a in reg.values():
            try:
                cmd = a.build_command("full", "reports/dry-run.log", 50)
                print("%-12s %s" % (a.id, " ".join(cmd)))
            except NotImplementedError as e:
                print("%-12s [仅引导] %s" % (a.id, e))
        return 0

    if args.settings:
        s = ScanSettings()
        print(json.dumps({
            "frequency": s.label(),
            "engine_policy": s.engine_policy,
            "engine_fallback": s.engine_id([]),
            "next_run": s.next_run().isoformat(timespec="seconds"),
            "scheduler": "应用内定时器，不注册 Windows 任务计划程序",
        }, ensure_ascii=False, indent=2))
        return 0

    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
