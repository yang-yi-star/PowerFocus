# -*- coding: utf-8 -*-
"""
电脑算力调度中心 V0.10 · 多引擎适配层（应用内识别 / 探测 / 调用 / 报告）
======================================================================

本模块把「应用内置引擎」与「客户机已装安全软件」统一到同一个接口，
是 V0.10 第 4 条路线（多引擎适配器）的真实实现，不是接口契约占位。

设计前提（用户 2026-11-12 强调）：
    本对话环境的命令要过审核、可能被拦；「电脑算力调度中心」是本机应用，
    自己进程里没有这层审核。因此识别、探测、调用、解析、落盘必须全部写成
    应用内代码，由应用自己执行，不能靠外部工具一条条手搓。

2026-11-12 本机实证（决定了本模块的三条硬约束）：
  1. WMI 给的 pathToSignedProductExe 可能是**卸载残留**：
     「腾讯电脑管家系统防护」注册路径 ...\\QQPCMgr\\18.2.30648.204\\QQPCMgr.exe，
     但 C:\\Program Files (x86)\\Tencent\\QQPCMgr 整个目录都不存在。
     -> 识别结果必须带「可调用性」判定，不能把 WMI 名字当成能跑的引擎。
  2. Windows Defender 二进制齐全、安全中心也注册了，productState=401664(0x62000)，
     WinDefend Start=3；MpCmdRun.exe -? 可执行（rc=0），但真实 -Scan 立刻返回
     `CmdTool: Failed with hr = 0x800106ba`（官方文档：Defender 服务已禁用）。
     -> 被第三方接管后不可调用，如实判为 unavailable，不去改系统服务状态。
  3. 项目边界是「只报告不处置」。KES 的 avp.com SCAN 默认动作是 /i2
     （清除失败即删除文件），必须显式 /i0（仅通知）；Defender 的
     -DisableRemediation 仅在自定义扫描(-ScanType 3)有效，因此不开放全盘扫描。

官方命令行依据（2026-11-12 逐条查证，未查到的一律标「无公开接口」）：
  * Microsoft Defender : learn.microsoft.com/.../command-line-arguments-microsoft-defender-antivirus
      -Scan [-ScanType 0|1|2|3] [-File <path> [-DisableRemediation] [-CpuThrottling]]
      退出码 0=无威胁或已修复；2=发现未修复/扫描错误
  * Kaspersky KES      : support.kaspersky.com/kes-for-windows/14.0/181236
      avp.com SCAN [/R[A]:<report>] [/ALL] [/i0..i4] <paths>
      /i0=仅通知（不处置）；/ALL=整机；/RA:=保存全部事件
  * ESET ecls.exe      : help.eset.com/efsw/12.0/en-US/advanced_cmd.html
      ecls.exe /clean-mode=none /log-file=<file> <path>
      退出码 0=无威胁 1=已清除 10=部分未扫 50=发现威胁 100=错误
  * 火绒：官方仅 Linux 服务器版提供 hrconsole scan，Windows 桌面版只有 GUI
  * 腾讯电脑管家 / 360：未查到本体公开命令行扫描接口（网上流传的
      hrun.exe /scan、TencentPCMgr.exe /scan 无官方依据，不予采信）
  * WMI 识别          : root\\SecurityCenter2 -> AntiVirusProduct

安全边界：
  * 不注册系统计划任务、不写系统目录、不改服务状态、不启用/停用任何防护。
  * 未在本机实测过的引擎默认拒绝真实执行，需显式 --allow-unverified。
  * 引导型引擎（无公开 CLI）绝不伪造调用，只给「打开主程序」的引导结论。
  * 原型 CLI 默认 dry-run；真实执行必须显式 --execute。
"""
from __future__ import annotations

import argparse
import ctypes
import glob
import json
import os
import re
import subprocess
import sys
import time
import winreg
from ctypes import wintypes
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

CODE_DIR = Path(__file__).resolve().parent
if str(CODE_DIR) not in sys.path:
    sys.path.insert(0, str(CODE_DIR))
try:
    import app_paths
except ImportError:
    sys.path.insert(0, str(CODE_DIR.parents[1]))
    import app_paths

DATA_ROOT = app_paths.data_root()
REPORT_DIR = DATA_ROOT / "reports"
ROOT = CODE_DIR                 # 兼容旧引用，语义为「代码目录」
CREATE_NO_WINDOW = 0x08000000

# 同目录模块：应用内真实 KVRT 链路（下载 / 验签 / 扫描 / 官方报告解析）
try:
    import kvrt_bundle as kvrt
except Exception as _kvrt_import_error:      # 缺失时降级，不影响其余适配器
    kvrt = None

DOCS: Dict[str, str] = {
    "kvrt": "https://support.kaspersky.com/kvrt-for-windows/2026/269475",
    "defender": "https://learn.microsoft.com/defender-endpoint/command-line-arguments-microsoft-defender-antivirus",
    "kaspersky_kes": "https://support.kaspersky.com/kes-for-windows/14.0/181236",
    "eset": "https://help.eset.com/efsw/12.0/en-US/advanced_cmd.html",
    "huorong": "https://www.huorong.cn/document/tech/safety-classroom/1966",
}

# 本机实测证据（2026-11-12），只读快照，供引擎页与报告页标注「实测」而非「模拟」
LOCAL_EVIDENCE: Dict[str, str] = {
    "kvrt": "2026-11-12 13:12:35 真扫 6943 对象，Found/Detected=0，exit 0，366.0s；官方 .klr.enc1 报告已解析",
    "defender": "2026-11-12 13:37 真跑 -Scan -ScanType 3，返回 hr=0x800106ba（服务被禁用），0.0s",
}


def _decode(b: bytes) -> str:
    """不同电脑代码页不同：先 UTF-8，失败再 GBK。"""
    try:
        return b.decode("utf-8")
    except UnicodeDecodeError:
        return b.decode("gbk", errors="replace")


# ---------------------------------------------------------------------------
# 只读系统探测：全部纯 Python，不调 sc.exe / reg.exe / PowerShell
# ---------------------------------------------------------------------------

class _SERVICE_STATUS(ctypes.Structure):
    _fields_ = [
        ("dwServiceType", wintypes.DWORD),
        ("dwCurrentState", wintypes.DWORD),
        ("dwControlsAccepted", wintypes.DWORD),
        ("dwWin32ExitCode", wintypes.DWORD),
        ("dwServiceSpecificExitCode", wintypes.DWORD),
        ("dwCheckPoint", wintypes.DWORD),
        ("dwWaitHint", wintypes.DWORD),
    ]


SERVICE_STATES = {1: "STOPPED", 2: "START_PENDING", 3: "STOP_PENDING",
                  4: "RUNNING", 5: "CONTINUE_PENDING", 6: "PAUSE_PENDING", 7: "PAUSED"}


def service_state(name: str) -> Tuple[int, str]:
    """查询服务运行状态，返回 (状态码, 状态名)。失败返回 (-1, 错误说明)。"""
    try:
        adv = ctypes.WinDLL("advapi32", use_last_error=True)
        adv.OpenSCManagerW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD]
        adv.OpenSCManagerW.restype = wintypes.HANDLE
        adv.OpenServiceW.argtypes = [wintypes.HANDLE, wintypes.LPCWSTR, wintypes.DWORD]
        adv.OpenServiceW.restype = wintypes.HANDLE
        adv.QueryServiceStatus.argtypes = [wintypes.HANDLE, ctypes.POINTER(_SERVICE_STATUS)]
        adv.QueryServiceStatus.restype = wintypes.BOOL
        adv.CloseServiceHandle.argtypes = [wintypes.HANDLE]
        adv.CloseServiceHandle.restype = wintypes.BOOL
        scm = adv.OpenSCManagerW(None, None, 0x0001)      # SC_MANAGER_CONNECT
        if not scm:
            return -1, "无法连接服务管理器"
        svc = adv.OpenServiceW(scm, name, 0x0004)          # SERVICE_QUERY_STATUS
        if not svc:
            adv.CloseServiceHandle(scm)
            return -1, "服务未注册"
        st = _SERVICE_STATUS()
        ok = adv.QueryServiceStatus(svc, ctypes.byref(st))
        adv.CloseServiceHandle(svc)
        adv.CloseServiceHandle(scm)
        if not ok:
            return -1, "QueryServiceStatus 失败"
        code = int(st.dwCurrentState)
        return code, SERVICE_STATES.get(code, "UNKNOWN-%d" % code)
    except Exception as e:
        return -1, "%s: %s" % (type(e).__name__, e)


def service_start_type(name: str) -> int:
    """读注册表服务启动类型：2=自动 3=手动 4=禁用；读不到返回 -1。"""
    try:
        k = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                           "SYSTEM\\CurrentControlSet\\Services\\" + name)
        return int(winreg.QueryValueEx(k, "Start")[0])
    except Exception:
        return -1


def find_mpcmdrun() -> str:
    """按 Microsoft Learn 说明优先取 Platform 下最新版本，再回退 Program Files。"""
    cands: List[Path] = []
    plat = Path(os.environ.get("ProgramData", r"C:\ProgramData")) / "Microsoft" / "Windows Defender" / "Platform"
    if plat.is_dir():
        for d in sorted((x for x in plat.iterdir() if x.is_dir()),
                        key=lambda p: p.name, reverse=True):
            cands.append(d / "MpCmdRun.exe")
    cands.append(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Windows Defender" / "MpCmdRun.exe")
    for c in cands:
        if c.is_file():
            return str(c)
    return ""


def find_first(patterns: List[str]) -> str:
    """在常见安装根下找可执行文件；只做存在性判断，不执行。"""
    for pat in patterns:
        for hit in sorted(glob.glob(pat), reverse=True):
            if os.path.isfile(hit):
                return hit
    return ""


def find_kes_avp() -> str:
    pf = os.environ.get("ProgramFiles", r"C:\Program Files")
    pf86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    return find_first([
        pf + r"\Kaspersky Lab\Kaspersky Endpoint Security for Windows\avp.com",
        pf86 + r"\Kaspersky Lab\Kaspersky Endpoint Security for Windows\avp.com",
        pf + r"\Kaspersky Lab\*\avp.com",
        pf86 + r"\Kaspersky Lab\*\avp.com",
    ])


def find_eset_ecls() -> str:
    pf = os.environ.get("ProgramFiles", r"C:\Program Files")
    pf86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    return find_first([
        pf + r"\ESET\*\ecls.exe",
        pf86 + r"\ESET\*\ecls.exe",
        pf + r"\ESET\ESET Security\ecls.exe",
    ])


def discover_products() -> Tuple[List[Dict[str, Any]], str]:
    """
    真实只读识别本机安全中心已注册产品，并逐条校验 signed_exe 是否真实存在。

    返回 (产品清单, 错误说明)。path_exists 是本轮新增的关键字段：
    WMI 注册项可能残留，路径不存在就绝不能当成可调用引擎。
    """
    out: List[Dict[str, Any]] = []
    try:
        import security_scan
        items = security_scan.discover_engines()
    except Exception as e:
        return out, "%s: %s" % (type(e).__name__, e)
    for p in items:
        d = p.to_dict()
        raw = d.get("signed_exe") or ""
        d["path_exists"] = bool(raw and os.path.isfile(raw))
        d["path_kind"] = ("file" if d["path_exists"] else
                          ("uri" if "://" in raw else ("stale" if raw else "empty")))
        out.append(d)
    return out, ""


# ---------------------------------------------------------------------------
# 引擎描述：识别结果 + 可调用性判定，供设置页与后端共用
# ---------------------------------------------------------------------------

@dataclass
class EngineInfo:
    id: str
    name: str
    origin: str                       # app_download | windows | external | guide
    available: bool
    reason_code: str                  # ready | service_disabled | stale_registration |
                                      # not_installed | no_public_cli | no_signature | unverified
    reason: str
    executable: str = ""
    doc_url: str = ""
    doc_verified: bool = False
    local_verified: bool = False      # 是否在本机真实调用过（成功或失败都算）
    local_result: str = ""
    callable_mode: str = "cli"        # cli | delegate | guide | none
    remediation: str = "report_only"  # 只报告不处置
    detected: bool = False            # 是否被 WMI 识别到
    detected_raw_path: str = ""
    detected_product_state: int = 0
    allowed_scopes: List[str] = None
    license_note: str = ""

    def __post_init__(self):
        if self.allowed_scopes is None:
            self.allowed_scopes = []

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass
class ScanRequest:
    """一次扫描的输入。上层业务只构造它，不关心具体厂商命令。"""
    engine: str = "auto"
    scope: str = "custom"             # custom | quick | full
    path: str = ""
    cpu_limit: int = 30
    timeout_sec: int = 1800
    trigger: str = "手动真实扫描"
    report_only: bool = True


# ---------------------------------------------------------------------------
# 适配器：统一接口，切换引擎不改上层业务代码
# ---------------------------------------------------------------------------

class BaseAdapter:
    id = ""
    name = ""
    origin = "external"
    doc_verified = False
    callable_mode = "cli"
    remediation = "report_only"
    license_note = ""

    def doc_url(self) -> str:
        return DOCS.get(self.id, "")

    def probe(self, detected: Dict[str, Dict[str, Any]]) -> EngineInfo:
        raise NotImplementedError

    def build_command(self, req: ScanRequest) -> List[str]:
        raise NotImplementedError

    def parse(self, scan: Dict[str, Any], req: ScanRequest,
              report_path: str = "") -> Dict[str, Any]:
        """把厂商原始输出归一到统一报告字段。"""
        raise NotImplementedError

    def run(self, req: ScanRequest, allow_unverified: bool = False) -> Dict[str, Any]:
        raise NotImplementedError


class KVRTAdapter(BaseAdapter):
    """应用内置能力：委托已跑通的 kvrt_bundle 真实链路（下载/验签/扫描/官方报告）。"""

    id = "kvrt"
    name = "Kaspersky Virus Removal Tool（应用内下载）"
    origin = "app_download"
    doc_verified = True
    callable_mode = "delegate"
    license_note = "KVRT EULA 5.4 禁止随第三方安装包再分发；用户主动下载到应用目录，不预置、不入库"

    def probe(self, detected):
        info = EngineInfo(
            id=self.id, name=self.name, origin=self.origin, available=False,
            reason_code="no_signature", reason="引擎尚未下载或未通过验签",
            doc_url=self.doc_url(), doc_verified=True,
            local_verified=True, local_result=LOCAL_EVIDENCE["kvrt"],
            callable_mode=self.callable_mode, remediation="只报告不处置（默认不传 -processlevel）",
            allowed_scopes=["custom", "quick", "full"], license_note=self.license_note,
        )
        if kvrt is None:
            info.reason_code = "module_missing"
            info.reason = "kvrt_bundle 模块不可用"
            return info
        st = kvrt.status()
        sig = st.get("signature") or {}
        info.executable = str(kvrt.engine_exe_path())
        info.license_note += "；签名者 " + str(sig.get("company") or sig.get("signer_hint") or "")
        if st.get("ready"):
            info.available = True
            info.reason_code = "ready"
            info.reason = "已下载并通过 WinVerifyTrust 验签，可调用"
        else:
            info.reason = str(st.get("note") or "引擎未就绪，请先在应用内一键下载并校验")
        return info

    def build_command(self, req: ScanRequest) -> List[str]:
        if kvrt is None:
            raise RuntimeError("kvrt_bundle 模块不可用")
        scope = {"custom": "custom", "full": "allvolumes", "quick": "core"}.get(req.scope, "custom")
        r = kvrt.ScanRequest(scope=scope, custom_path=req.path,
                             process_level=0 if req.report_only else 1,
                             timeout_sec=req.timeout_sec)
        return [str(kvrt.engine_exe_path())] + kvrt.build_scan_args(r)

    def parse(self, scan, req, report_path=""):
        # 官方 .klr.enc1 可能落在历史数据目录，取第一个真实存在的目录。
        dirs = app_paths.existing_dirs("reports/KVRT_Data")
        parsed = kvrt.parse_kvrt_output(str(dirs[0]), scan.get("stdout", ""))
        return parsed

    def run(self, req: ScanRequest, allow_unverified: bool = False) -> Dict[str, Any]:
        if kvrt is None:
            raise RuntimeError("kvrt_bundle 模块不可用")
        scope = {"custom": "custom", "full": "allvolumes", "quick": "core"}.get(req.scope, "custom")
        r = kvrt.ScanRequest(scope=scope, custom_path=req.path,
                             process_level=0 if req.report_only else 1,
                             timeout_sec=req.timeout_sec)
        scan = kvrt.run_scan(r)                       # 内部含验签与管理员校验
        parsed = kvrt.parse_kvrt_output(r.data_dir, scan.get("stdout", ""))
        out = kvrt.write_report(scan, parsed, r, trigger=req.trigger)
        return json.loads(out.read_text(encoding="utf-8"))


class DefenderAdapter(BaseAdapter):
    """Windows 自带 Defender；命令来自 Microsoft Learn，本机 -? 与 -Scan 均已实测。"""

    id = "defender"
    name = "Microsoft Defender 防病毒"
    origin = "windows"
    doc_verified = True
    license_note = "Windows 系统组件，无需安装；需管理员权限，且服务须处于运行状态"

    def probe(self, detected):
        exe = find_mpcmdrun()
        state_code, state_name = service_state("WinDefend")
        start = service_start_type("WinDefend")
        d = detected.get("defender", {})
        info = EngineInfo(
            id=self.id, name=self.name, origin=self.origin, available=False,
            reason_code="not_installed", reason="未找到 MpCmdRun.exe",
            executable=exe, doc_url=self.doc_url(), doc_verified=True,
            local_verified=True, local_result=LOCAL_EVIDENCE["defender"],
            remediation="仅自定义扫描可用 -DisableRemediation；全盘/快速扫描会走系统默认处置策略，故不开放",
            allowed_scopes=["custom"], license_note=self.license_note,
            detected=bool(d), detected_raw_path=str(d.get("signed_exe") or ""),
            detected_product_state=int(d.get("product_state") or 0),
        )
        if not exe:
            return info
        if state_code != 4:
            info.reason_code = "service_disabled"
            info.reason = ("WinDefend 服务状态 %s（Start=%s），官方错误 0x800106ba："
                           "服务被禁用时 -Scan 无法执行。常见于已被第三方安全软件接管"
                           % (state_name, start))
            return info
        info.available = True
        info.reason_code = "ready"
        info.reason = "MpCmdRun.exe 存在且 WinDefend 服务 RUNNING，可执行自定义扫描"
        return info

    def build_command(self, req: ScanRequest) -> List[str]:
        exe = find_mpcmdrun()
        if not exe:
            raise RuntimeError("未找到 MpCmdRun.exe")
        if req.scope != "custom" or not req.path:
            raise ValueError(
                "Defender 只允许自定义扫描：-DisableRemediation 仅对 -ScanType 3 有效，"
                "开放全盘/快速扫描会违背「只报告不处置」边界")
        cmd = [exe, "-Scan", "-ScanType", "3", "-File", os.path.normpath(req.path)]
        if req.report_only:
            cmd.append("-DisableRemediation")
        cmd += ["-CpuThrottling", str(max(1, min(100, req.cpu_limit)))]
        return cmd

    def parse(self, scan, req, report_path=""):
        stdout = scan.get("stdout", "") or ""
        stderr = scan.get("stderr", "") or ""
        code = scan.get("exit_code")
        hr = re.search(r"(?:Failed with hr\s*=\s*|hr\s*=\s*)(0x[0-9a-fA-F]+)", stdout + stderr)
        failed = bool(hr) or scan.get("timed_out") or (code not in (0, 2))
        parsed: Dict[str, Any] = {
            "files_scanned": 0,
            "threat_count": 0,
            "threat_lines": [],
            "authoritative": not failed,
            "stdout_stats": {},
            "official_reports": [],
            "official_clean": (code == 0 and not failed),
            "parser_note": "MpCmdRun 不输出扫描对象数，files_scanned 记为 0；结论以退出码与 CmdTool 行据为准",
            "raw_lines": [x.strip() for x in stdout.splitlines() if x.strip()][-40:],
        }
        if failed:
            parsed["status"] = "failed"
            parsed["failure_hresult"] = hr.group(1) if hr else ""
            parsed["failure_reason"] = (
                "0x800106ba 对应 Microsoft Learn 的「Defender 服务已禁用」；"
                "本机由第三方安全软件接管，应用不改动系统服务状态" if hr and "800106ba" in hr.group(1).lower()
                else (scan.get("stderr") or stderr or "MpCmdRun 返回非零退出码"))
        elif code == 2:
            parsed["status"] = "threats"
            parsed["threat_count"] = 0
            parsed["parser_note"] += "；退出码 2 表示发现未修复威胁或扫描错误，需查 Defender 事件日志"
        else:
            parsed["status"] = "clean"
        return parsed

    def run(self, req: ScanRequest, allow_unverified: bool = False) -> Dict[str, Any]:
        info = self.probe({})
        if not info.available:
            raise RuntimeError("Defender 当前不可用：" + info.reason)
        cmd = self.build_command(req)
        started = time.time()
        scan: Dict[str, Any] = {"executed": True, "command": cmd,
                                "started": datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
        try:
            p = subprocess.run(cmd, capture_output=True, timeout=req.timeout_sec,
                               creationflags=CREATE_NO_WINDOW)
            scan["exit_code"] = p.returncode
            scan["stdout"] = _decode(p.stdout or b"")[-6000:]
            scan["stderr"] = _decode(p.stderr or b"")[-2000:]
        except subprocess.TimeoutExpired as e:
            scan["exit_code"] = -1
            scan["timed_out"] = True
            scan["stdout"] = _decode(e.stdout or b"")[-3000:]
            scan["stderr"] = "扫描超过 %d 秒超时" % req.timeout_sec
        scan["duration_sec"] = round(time.time() - started, 1)
        scan["finished"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        parsed = self.parse(scan, req)
        return write_report(self, scan, parsed, req)


class KasperskyKESAdapter(BaseAdapter):
    """卡巴斯基企业版命令行 avp.com；/i0 保证只通知不处置。本机未安装，仅文档核对。"""

    id = "kaspersky_kes"
    name = "Kaspersky Endpoint Security for Windows"
    origin = "external"
    doc_verified = True
    license_note = "商业专有；仅可调用客户机已安装实例；内嵌引擎需 Kaspersky OEM SDK 商业授权"

    def probe(self, detected):
        exe = find_kes_avp()
        d = detected.get("kaspersky", {})
        info = EngineInfo(
            id=self.id, name=self.name, origin=self.origin, available=False,
            reason_code="not_installed" if not exe else "unverified",
            reason=("本机未安装 KES，未找到 avp.com" if not exe
                    else "已找到 avp.com，但本机未实测过调用，默认拒绝执行"),
            executable=exe, doc_url=self.doc_url(), doc_verified=True,
            local_verified=False, local_result="本机未安装，仅核对官方文档 181236",
            remediation="/i0 仅通知（不处置）；不加 /i0 时默认 /i2 会删文件",
            allowed_scopes=["custom", "full"], license_note=self.license_note,
            detected=bool(d), detected_raw_path=str(d.get("signed_exe") or ""),
            detected_product_state=int(d.get("product_state") or 0),
        )
        return info

    def build_command(self, req: ScanRequest, report_path: str = "") -> List[str]:
        exe = find_kes_avp()
        if not exe:
            raise RuntimeError("未找到 avp.com")
        rp = report_path or str(REPORT_DIR / ("kes-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".txt"))
        cmd = [exe, "SCAN", "/i0", "/RA:" + rp]
        if req.scope == "full":
            cmd.append("/ALL")
        elif req.path:
            cmd.append(os.path.normpath(req.path))
        else:
            raise ValueError("KES 自定义扫描必须提供 --path")
        return cmd

    def parse(self, scan, req, report_path=""):
        stdout = scan.get("stdout", "") or ""
        code = scan.get("exit_code")
        detected = len(re.findall(r"(?im)^\s*(detected|threat|infected)\b[^\n]*", stdout))
        return {
            "files_scanned": 0, "threat_count": detected,
            "threat_lines": [x.strip() for x in stdout.splitlines()
                             if re.search(r"(?i)(detected|threat|infected)", x)][:30],
            "authoritative": code == 0,
            "stdout_stats": {}, "official_reports": [report_path] if report_path else [],
            "official_clean": code == 0 and detected == 0,
            "parser_note": "KES 文本报告格式未在本机实测，解析为保守版；结论以 /RA: 原始报告为准",
            "raw_lines": [x.strip() for x in stdout.splitlines() if x.strip()][-40:],
            "status": "clean" if code == 0 and detected == 0 else
                      ("threats" if detected else "incomplete"),
        }

    def run(self, req: ScanRequest, allow_unverified: bool = False) -> Dict[str, Any]:
        if not allow_unverified:
            raise RuntimeError("KES 未在本机实测，拒绝执行；如确需调用请显式 --allow-unverified")
        info = self.probe({})
        if not info.executable:
            raise RuntimeError("未找到 avp.com")
        REPORT_DIR.mkdir(parents=True, exist_ok=True)
        rp = str(REPORT_DIR / ("kes-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".txt"))
        cmd = self.build_command(req, rp)
        started = time.time()
        scan: Dict[str, Any] = {"executed": True, "command": cmd,
                                "started": datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
        try:
            p = subprocess.run(cmd, capture_output=True, timeout=req.timeout_sec,
                               creationflags=CREATE_NO_WINDOW)
            scan["exit_code"] = p.returncode
            scan["stdout"] = _decode(p.stdout or b"")[-6000:]
            scan["stderr"] = _decode(p.stderr or b"")[-2000:]
        except subprocess.TimeoutExpired as e:
            scan["exit_code"] = -1
            scan["timed_out"] = True
            scan["stdout"] = _decode(e.stdout or b"")[-3000:]
            scan["stderr"] = "扫描超过 %d 秒超时" % req.timeout_sec
        scan["duration_sec"] = round(time.time() - started, 1)
        scan["finished"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        parsed = self.parse(scan, req, rp)
        return write_report(self, scan, parsed, req)


class ESETAdapter(BaseAdapter):
    """ESET ecls.exe 命令行扫描器；/clean-mode=none 保证只报告不处置。"""

    id = "eset"
    name = "ESET Command Line Scanner (ecls.exe)"
    origin = "external"
    doc_verified = True
    license_note = "商业软件；仅可调用客户机已安装实例，且需确认该版本附带 ecls.exe"

    def probe(self, detected):
        exe = find_eset_ecls()
        d = detected.get("eset", {})
        info = EngineInfo(
            id=self.id, name=self.name, origin=self.origin, available=False,
            reason_code="not_installed" if not exe else "unverified",
            reason=("本机未安装 ESET，未找到 ecls.exe" if not exe
                    else "已找到 ecls.exe，但本机未实测过调用，默认拒绝执行"),
            executable=exe, doc_url=self.doc_url(), doc_verified=True,
            local_verified=False, local_result="本机未安装，仅核对 ESET 官方 ecls 参数文档",
            remediation="/clean-mode=none 不做任何清除或删除",
            allowed_scopes=["custom"], license_note=self.license_note,
            detected=bool(d), detected_raw_path=str(d.get("signed_exe") or ""),
            detected_product_state=int(d.get("product_state") or 0),
        )
        return info

    def build_command(self, req: ScanRequest, log_path: str = "") -> List[str]:
        exe = find_eset_ecls()
        if not exe:
            raise RuntimeError("未找到 ecls.exe")
        if not req.path:
            raise ValueError("ESET 扫描必须提供 --path")
        lp = log_path or str(REPORT_DIR / ("eset-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".log"))
        return [exe, "/clean-mode=none", "/log-file=" + lp,
                "/no-log-console", "/subdir", os.path.normpath(req.path)]

    def parse(self, scan, req, report_path=""):
        code = scan.get("exit_code")
        stdout = scan.get("stdout", "") or ""
        # ESET 官方退出码：0 无威胁 / 1 已清除 / 10 部分未扫 / 50 发现威胁 / 100 错误
        mapping = {0: "clean", 1: "threats", 10: "incomplete", 50: "threats", 100: "failed"}
        status = mapping.get(code, "failed" if (code is None or code < 0) else "incomplete")
        return {
            "files_scanned": 0,
            "threat_count": 1 if status == "threats" else 0,
            "threat_lines": [x.strip() for x in stdout.splitlines()
                             if re.search(r"(?i)(threat|infected|virus)", x)][:30],
            "authoritative": code in (0, 1, 10, 50, 100),
            "stdout_stats": {"exit_code_eset": code if code is not None else -1},
            "official_reports": [report_path] if report_path else [],
            "official_clean": code == 0,
            "parser_note": "ecls.exe 退出码按官方 KB2285 映射；扫描对象数不写 stdout，记为 0",
            "raw_lines": [x.strip() for x in stdout.splitlines() if x.strip()][-40:],
            "status": status,
        }

    def run(self, req: ScanRequest, allow_unverified: bool = False) -> Dict[str, Any]:
        if not allow_unverified:
            raise RuntimeError("ESET 未在本机实测，拒绝执行；如确需调用请显式 --allow-unverified")
        if not find_eset_ecls():
            raise RuntimeError("未找到 ecls.exe")
        REPORT_DIR.mkdir(parents=True, exist_ok=True)
        lp = str(REPORT_DIR / ("eset-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".log"))
        cmd = self.build_command(req, lp)
        started = time.time()
        scan: Dict[str, Any] = {"executed": True, "command": cmd,
                                "started": datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
        try:
            p = subprocess.run(cmd, capture_output=True, timeout=req.timeout_sec,
                               creationflags=CREATE_NO_WINDOW)
            scan["exit_code"] = p.returncode
            scan["stdout"] = _decode(p.stdout or b"")[-6000:]
            scan["stderr"] = _decode(p.stderr or b"")[-2000:]
        except subprocess.TimeoutExpired as e:
            scan["exit_code"] = -1
            scan["timed_out"] = True
            scan["stdout"] = _decode(e.stdout or b"")[-3000:]
            scan["stderr"] = "扫描超过 %d 秒超时" % req.timeout_sec
        scan["duration_sec"] = round(time.time() - started, 1)
        scan["finished"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        parsed = self.parse(scan, req, lp)
        return write_report(self, scan, parsed, req)


class GuidedAdapter(BaseAdapter):
    """无官方公开 Windows 命令行扫描接口的产品：只识别、只引导，绝不伪造调用。"""

    id = "guide"
    name = ""
    origin = "guide"
    doc_verified = False
    callable_mode = "guide"
    license_note = "第三方商业软件，扫描入口由厂商 GUI 决定"

    def __init__(self, adapter_id: str, name: str, why: str, doc: str = ""):
        self.id = adapter_id
        self.name = name
        self.why = why
        self._doc = doc

    def doc_url(self) -> str:
        return self._doc or DOCS.get(self.id, "")

    def probe(self, detected):
        d = detected.get(self.id, {}) or detected.get(self.id.replace("_", ""), {})
        raw = str(d.get("signed_exe") or "")
        stale = bool(raw) and not d.get("path_exists", True) and "://" not in raw
        if stale:
            code = "stale_registration"
            reason = ("安全中心仍注册该产品，但登记路径已不存在（%s）——卸载残留，"
                      "不能当作可调用引擎" % raw)
        elif d:
            code = "no_public_cli"
            reason = "已识别到产品，但" + self.why
        else:
            code = "not_installed"
            reason = "本机未识别到该产品；" + self.why
        return EngineInfo(
            id=self.id, name=self.name, origin=self.origin, available=False,
            reason_code=code, reason=reason,
            executable=raw if d.get("path_exists") else "",
            doc_url=self.doc_url(), doc_verified=False,
            local_verified=False, local_result="未调用（无官方 CLI）",
            callable_mode="guide", remediation="不适用",
            allowed_scopes=[], license_note=self.license_note,
            detected=bool(d), detected_raw_path=raw,
            detected_product_state=int(d.get("product_state") or 0),
        )

    def build_command(self, req: ScanRequest) -> List[str]:
        raise NotImplementedError(self.name + " 无官方公开命令行扫描接口，拒绝伪造调用")

    def parse(self, scan, req, report_path=""):
        raise NotImplementedError(self.name + " 不产生可解析的官方命令行报告")

    def run(self, req: ScanRequest, allow_unverified: bool = False) -> Dict[str, Any]:
        raise NotImplementedError(
            self.name + " 只能引导用户在软件界面内扫描；应用不会伪造成一次扫描作业")


def registry() -> Dict[str, BaseAdapter]:
    """引擎注册表：内置 KVRT + 有官方 CLI 的三家 + 引导型四家。"""
    out: Dict[str, BaseAdapter] = {
        "kvrt": KVRTAdapter(),
        "defender": DefenderAdapter(),
        "kaspersky_kes": KasperskyKESAdapter(),
        "eset": ESETAdapter(),
    }
    guides = [
        ("qqpcmgr", "腾讯电脑管家", "腾讯未公开本体的命令行查杀接口（仅有的一次性 CVE 专杀工具不是产品本体）"),
        ("360", "360 安全卫士", "360 未公开本体的命令行查杀接口"),
        ("huorong", "火绒安全软件", "火绒官方仅 Linux 服务器版提供 hrconsole scan，Windows 桌面版只有 GUI"),
        ("other", "其他安全软件", "未查到官方公开命令行扫描接口"),
    ]
    for aid, name, why in guides:
        out[aid] = GuidedAdapter(aid, name, why, DOCS.get(aid, ""))
    return out


def probe_all() -> Dict[str, Any]:
    """完整探测：WMI 原始识别 + 每个引擎的可调用性判定。"""
    products, err = discover_products()
    detected: Dict[str, Dict[str, Any]] = {}
    for p in products:
        aid = str(p.get("adapter_id") or "other")
        detected.setdefault(aid, p)
        # security_scan 把卡巴斯基标成 kaspersky，这里映射到 KES 适配器
        if aid == "kaspersky":
            detected.setdefault("kaspersky_kes", p)
    reg = registry()
    engines = [a.probe(detected) for a in reg.values()]
    return {
        "probe_time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "wmi_products": products,
        "wmi_error": err,
        "engines": [x.to_dict() for x in engines],
        "available_count": sum(1 for x in engines if x.available),
        "note": "识别不等于可调用：available 以真实路径、服务状态、验签结果为准",
    }


def choose_engine(policy: str, specified: str, infos: List[Dict[str, Any]]) -> Tuple[str, str]:
    """按设置页策略挑引擎，返回 (engine_id, 说明)。"""
    by_id = {x["id"]: x for x in infos}
    if policy == "specified":
        x = by_id.get(specified)
        if not x:
            return "kvrt", "指定引擎不存在，回退内置 KVRT"
        return specified, ("可用" if x["available"] else "当前不可用：" + x["reason"])
    if policy == "builtin":
        return "kvrt", "策略为「始终使用应用内置能力」"
    for eid in ("kvrt", "defender", "kaspersky_kes", "eset"):
        x = by_id.get(eid)
        if x and x["available"]:
            return eid, "自动选择第一个实测可用的引擎：" + x["name"]
    return "kvrt", "没有可用的外部引擎，回退内置 KVRT（无杀软也能扫）"


# ---------------------------------------------------------------------------
# 统一报告：字段与 kvrt_bundle 报告兼容，kvrt_bundle.list_reports() 可直接读取
# ---------------------------------------------------------------------------

def write_report(adapter: BaseAdapter, scan: Dict[str, Any],
                 parsed: Dict[str, Any], req: ScanRequest) -> Dict[str, Any]:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    scope_map = {"custom": req.path or "自定义目录", "quick": "系统核心区域", "full": "整机全盘"}
    report = {
        "id": "RPT-" + stamp + "-" + adapter.id,
        "date": scan.get("finished") or datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "engine_id": adapter.id,
        "engine_name": adapter.name,
        "adapter": "engine_adapters.py",
        "scope": scope_map.get(req.scope, req.scope),
        "trigger": req.trigger,
        "duration_sec": scan.get("duration_sec", 0),
        "exit_code": scan.get("exit_code"),
        "files_scanned": parsed.get("files_scanned", 0),
        "threat_count": parsed.get("threat_count", 0),
        "neutralized": 0,
        "threat_lines": parsed.get("threat_lines", []),
        "status": parsed.get("status", "incomplete"),
        "authoritative": bool(parsed.get("authoritative")),
        "failure_hresult": parsed.get("failure_hresult", ""),
        "failure_reason": parsed.get("failure_reason", ""),
        "stdout_stats": parsed.get("stdout_stats", {}),
        "official_reports": parsed.get("official_reports", []),
        "official_clean": bool(parsed.get("official_clean")),
        "simulated": False,
        "command": scan.get("command", []),
        "stdout": scan.get("stdout", ""),
        "raw_log_tail": parsed.get("raw_lines", [])[-60:],
        "parser_note": parsed.get("parser_note", ""),
        "doc_url": adapter.doc_url(),
        "remediation": adapter.remediation,
        "local_verified": adapter.id in LOCAL_EVIDENCE,
        "license_note": adapter.license_note,
    }
    out = REPORT_DIR / ("scan-" + stamp + "-" + adapter.id + ".json")
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    report["report_file"] = str(out)
    return report


def list_reports() -> List[Dict[str, Any]]:
    """列出全部真实报告（含 kvrt_bundle 产出的），按时间倒序；合并历史目录并按 id 去重。"""
    candidates: List[Path] = []
    for d in app_paths.existing_dirs("reports"):
        candidates.extend(d.glob("scan-*.json"))
    if not candidates:
        return []
    out, seen = [], set()
    for p in sorted(candidates, key=lambda x: x.name, reverse=True):
        if p.name.endswith(".bak") or "before-calibration" in p.name:
            continue
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        rid = d.get("id") or p.name
        if rid in seen:
            continue
        seen.add(rid)
        out.append(d)
    return out


def run_engine(engine_id: str, req: ScanRequest,
               allow_unverified: bool = False) -> Dict[str, Any]:
    """应用内统一调用入口：由 server.py 路由或应用主进程直接 import 调用。"""
    reg = registry()
    adapter = reg.get(engine_id)
    if not adapter:
        raise RuntimeError("未知引擎: " + engine_id)
    info = adapter.probe({})
    if info.callable_mode == "guide":
        raise RuntimeError(adapter.name + " 无官方 CLI，只能引导，不产生扫描作业")
    if not info.local_verified and not allow_unverified:
        raise RuntimeError(adapter.name + " 未在本机实测，拒绝真实执行（可显式 --allow-unverified）")
    if not info.available:
        raise RuntimeError(adapter.name + " 当前不可用：" + info.reason)
    req.engine = engine_id
    return adapter.run(req, allow_unverified=allow_unverified)


# ---------------------------------------------------------------------------
# CLI：--list / --discover / --dry-run / --scan / --reports
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="V0.10 多引擎适配层：应用内识别 / 探测 / 调用 / 报告")
    ap.add_argument("--list", action="store_true", help="输出引擎清单与可调用性判定（只读）")
    ap.add_argument("--discover", action="store_true", help="输出 WMI 原始识别与路径存在性校验")
    ap.add_argument("--dry-run", action="store_true", help="只构造命令，不执行")
    ap.add_argument("--scan", action="store_true", help="发起扫描（默认 dry-run，需 --execute 才真跑）")
    ap.add_argument("--engine", default="auto", help="引擎 id 或 auto")
    ap.add_argument("--policy", default="auto", help="builtin | auto | specified（配合 auto 引擎）")
    ap.add_argument("--scope", default="custom", choices=["custom", "quick", "full"])
    ap.add_argument("--path", default="", help="自定义扫描路径")
    ap.add_argument("--cpu-limit", type=int, default=30)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--execute", action="store_true", help="显式允许真实执行")
    ap.add_argument("--allow-unverified", action="store_true", help="显式允许调用未本机实测的引擎")
    ap.add_argument("--reports", action="store_true", help="列出全部真实报告")
    args = ap.parse_args(argv)

    if args.list:
        print(json.dumps(probe_all(), ensure_ascii=False, indent=2))
        return 0

    if args.discover:
        products, err = discover_products()
        print(json.dumps({"products": products, "error": err}, ensure_ascii=False, indent=2))
        return 0

    if args.reports:
        print(json.dumps(list_reports(), ensure_ascii=False, indent=2))
        return 0

    if args.dry_run or args.scan:
        result = probe_all()
        infos = result["engines"]
        if args.engine == "auto":
            eid, why = choose_engine(args.policy, "kvrt", infos)
        else:
            eid, why = args.engine, "用户指定"
        req = ScanRequest(engine=eid, scope=args.scope, path=args.path,
                          cpu_limit=args.cpu_limit, timeout_sec=args.timeout)
        adapter = registry().get(eid)
        preview: Dict[str, Any] = {"engine": eid, "choice_reason": why,
                                   "request": asdict(req), "executed": False}
        if adapter is None:
            preview["error"] = "未知引擎"
        else:
            # 复用 probe_all 的完整上下文（含 WMI 识别结果），避免 dry-run 与 --list
            # 对同一引擎给出不一致的可调用性结论（例如卸载残留被误报成「未安装」）
            info_map = {x["id"]: x for x in infos}
            info = info_map.get(eid) or adapter.probe({}).to_dict()
            preview["engine_status"] = {k: info[k] for k in
                                        ("available", "reason_code", "reason",
                                         "doc_verified", "local_verified", "callable_mode")}
            try:
                preview["command"] = adapter.build_command(req)
            except (NotImplementedError, ValueError, RuntimeError) as e:
                preview["command_error"] = str(e)
        if args.scope == "custom" and not args.path:
            # 不给路径就退化成引擎默认范围（可能是整机核心区域甚至全盘），
            # 属于典型的「模糊执行」，真实执行前必须拦下
            preview["error"] = "custom 范围必须显式提供 --path，拒绝以空路径发起真实扫描"
            preview["returncode"] = 2
        elif args.scan and args.execute:
            try:
                preview["report"] = run_engine(eid, req, args.allow_unverified)
                preview["executed"] = True
            except Exception as e:
                preview["error"] = "%s: %s" % (type(e).__name__, e)
                preview["returncode"] = 2
        print(json.dumps(preview, ensure_ascii=False, indent=2))
        return int(preview.get("returncode", 0))

    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
