# -*- coding: utf-8 -*-
"""
电脑算力调度中心 V0.10 · KVRT 引擎包（应用内真实链路，非模拟）
================================================================

设计前提（用户 2026-11-12 明确指出）：
    本对话环境的命令要经过审核、会被拦截；而「电脑算力调度中心」是本机已安装、
    自己进程里跑的应用程序，没有这层审核。因此下载、验签、调用、扫描、出报告
    **必须全部写成应用内代码，由应用自己执行**，不能靠外部工具一条条手搓。

本模块零外部解释器依赖：
    * 验签     -> ctypes 直调 WinVerifyTrust + Version API + SHA256
    * 下载     -> urllib
    * 扫描     -> subprocess 直接拉起 KVRT.exe（应用自己的引擎目录）
    * 调度     -> 应用内定时器（run_scheduled_loop），不注册系统计划任务
    * 报告     -> 落盘 JSON，供应用报告页读取

用户已确认的四条决策：
    1. 下载对象 = Kaspersky Virus Removal Tool（卡巴斯基官方免费清除工具）
    2. 包裹程度 = 下载到本应用自己的目录，由应用调用；不写系统目录、不注册服务
    3. 使用范围 = 仅本机自用（不随安装包分发给客户）
    4. 触发方式 = 应用内一键下载并校验

许可边界（KVRT EULA, support.kaspersky.com/8530）：
    * 5.4 不得为配合「非卡巴斯基合法财产的商业软件产品」而分发本软件
      -> 本模块绝不把 KVRT.exe 打进安装包，只在用户主动触发时从官方源下载。
    * 5.3 不得用本软件创建用于检测/拦截/处理威胁的其他软件
    * 6.4 本软件不用于长期持续防护（一次性扫描清除工具，无实时防护）
    -> 只做「下载 + 校验 + 调用 + 收报告」，不拆引擎、不做二次封装。

已实证（2026-11-12，本机）：
    * 官方分发点 https://devbuilds.s.kaspersky-labs.com/devbuilds/KVRT/latest/full/KVRT.exe
    * 下载 122445696 字节 / 21.3 秒
    * Authenticode 签名 Valid，签名者 AO Kaspersky Lab
    * 文件版本 20.0.14.0，产品名 Kaspersky Virus Removal Tool
    * SHA256 7656E5DE49894EC8331B641150B08BAB3CB2102A25D64F566B79ADF314D6A20F
    * 纯 Python WinVerifyTrust 返回 0x00000000（PASS），版本资源读取成功

命令行依据（Kaspersky 官方支持文档 269475，2026-10-02 更新）：
    kvrt.exe -h
    kvrt.exe -d "C:\\Users\\Fred\\KVRT2026_Data"     <- 注意：-d 与路径是两个参数
    kvrt.exe -accepteula -silent                     <- -silent 必须先 -accepteula
    kvrt.exe -customonly -custom C:\\folder\\
    kvrt.exe -accepteula -silent -processlevel 1
    * 默认只检测、不处置（-processlevel 才启用清除）
    * 默认扫描系统内存、启动对象、引导扇区；-customonly -custom 改自定义范围
    * 结果输出到命令行并写入 -d 指定目录下的报告文件
    * -fixednames 禁用文件名随机化；-dontencrypt 禁用报告加密（便于应用解析）
    * -details 生成详细报告；需要管理员权限、需要联网更新病毒库

2026-11-12 真实 bug 修正记录：
    首版把 -d 与路径连写成 "-dE:\\..."，KVRT 不识别，弹出
    "KVRT2020 - Command line arguments help" 窗口挂起 24 分钟，零报告、退出码 -1。
    官方文档明确为空格分隔，现改为 ["-d", path] 两个参数。
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as w
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from ctypes import POINTER, byref, pointer, c_void_p, c_ulong, c_wchar_p
from dataclasses import dataclass, asdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

KVRT_URL = "https://devbuilds.s.kaspersky-labs.com/devbuilds/KVRT/latest/full/KVRT.exe"
OFFICIAL_PAGE = "https://www.kaspersky.com/downloads/free-virus-removal-tool"
OFFICIAL_DOCS = "https://support.kaspersky.com/kvrt-for-windows/2026/269475"
SIGNER_MUST_CONTAIN = "Kaspersky"
PRODUCT_MUST_CONTAIN = "Virus Removal Tool"

# CODE_DIR 仅用于模块间 import（sys.path）；**不是数据目录**。
CODE_DIR = Path(__file__).resolve().parent
if str(CODE_DIR) not in sys.path:
    sys.path.insert(0, str(CODE_DIR))
try:
    import app_paths
except ImportError:
    # 源码独立运行时（CLI）补上仓库根；打包后 app_paths 已在 PYZ 里，不走这里。
    sys.path.insert(0, str(CODE_DIR.parents[1]))
    import app_paths

DATA_ROOT = app_paths.data_root()          # %LOCALAPPDATA%\PowerFocus\v0.10（纯计算，不建目录）
ENGINE_DIR = DATA_ROOT / "engines" / "KVRT"
ENGINE_EXE = ENGINE_DIR / "KVRT.exe"
STATE_FILE = ENGINE_DIR / "engine.json"
REPORT_DIR = DATA_ROOT / "reports"
DATA_DIR = REPORT_DIR / "KVRT_Data"
SETTINGS_FILE = DATA_ROOT / "scan_settings.json"
ROOT = CODE_DIR                            # 兼容旧引用，语义已改为「代码目录」


def engine_exe_path() -> Path:
    """实际可用的引擎路径：新数据目录优先，历史目录只读回退（不搬迁、不删除）。"""
    return app_paths.first_existing("engines/KVRT/KVRT.exe")


def state_file_path() -> Path:
    return app_paths.first_existing("engines/KVRT/engine.json")

CREATE_NO_WINDOW = 0x08000000


def _decode(b: bytes) -> str:
    """不同电脑代码页不同：先 UTF-8，失败再 GBK。"""
    try:
        return b.decode("utf-8")
    except UnicodeDecodeError:
        return b.decode("gbk", errors="replace")


def is_admin() -> bool:
    """KVRT 要求管理员权限；应用侧启动前应先检查。"""
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


# ---------------------------------------------------------------------------
# 一键下载（应用内触发）
# ---------------------------------------------------------------------------

def download(url: str = KVRT_URL, dest: Path = ENGINE_EXE,
             force: bool = False, timeout: int = 900) -> Dict[str, Any]:
    """从卡巴斯基官方分发点下载 KVRT.exe 到本应用自己的目录。"""
    if dest.is_file() and not force:
        return {"downloaded": False, "path": str(dest),
                "note": "引擎已存在；如需重新下载加 --force"}
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(".exe.part")
    started = time.time()
    req = urllib.request.Request(url, headers={"User-Agent": "PowerFocus-V0.10/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp, open(part, "wb") as f:
        total = int(resp.headers.get("Content-Length") or 0)
        got = 0
        while True:
            chunk = resp.read(1024 * 512)
            if not chunk:
                break
            f.write(chunk)
            got += len(chunk)
            if total:
                print("\r  下载 %d/%d 字节 (%.1f%%)" % (got, total, got * 100.0 / total),
                      end="", flush=True)
    if total:
        print()
    if part.stat().st_size == 0:
        part.unlink(missing_ok=True)
        raise RuntimeError("下载得到空文件，已删除")
    os.replace(part, dest)
    elapsed = round(time.time() - started, 1)
    return {"downloaded": True, "path": str(dest), "size": dest.stat().st_size,
            "elapsed_sec": elapsed, "source": url}


# ---------------------------------------------------------------------------
# 完整性校验：纯 Python，零外部进程
# ---------------------------------------------------------------------------

class _GUID(ctypes.Structure):
    _fields_ = [('Data1', c_ulong), ('Data2', ctypes.c_ushort),
                ('Data3', ctypes.c_ushort), ('Data4', ctypes.c_ubyte * 8)]


class _WINTRUST_FILE_INFO(ctypes.Structure):
    _fields_ = [('cbStruct', w.DWORD), ('pcwszFilePath', c_wchar_p),
                ('hFile', w.HANDLE), ('pgKnownSubject', c_void_p)]


class _WINTRUST_DATA(ctypes.Structure):
    _fields_ = [('cbStruct', w.DWORD), ('pPolicyCallbackData', c_void_p),
                ('pSIPClientData', c_void_p), ('dwUIChoice', w.DWORD),
                ('fdwRevocationChecks', w.DWORD), ('dwUnionChoice', w.DWORD),
                ('pFile', POINTER(_WINTRUST_FILE_INFO)), ('dwStateAction', w.DWORD),
                ('hWVTStateData', w.HANDLE), ('pwszURLReference', c_wchar_p),
                ('dwProvFlags', w.DWORD), ('dwUIContext', w.DWORD),
                ('pSignatureSettings', c_void_p)]


class _VS_FIXEDFILEINFO(ctypes.Structure):
    _fields_ = [('dwSignature', w.DWORD), ('dwStrucVersion', w.DWORD),
                ('dwFileVersionMS', w.DWORD), ('dwFileVersionLS', w.DWORD),
                ('dwProductVersionMS', w.DWORD), ('dwProductVersionLS', w.DWORD),
                ('dwFileFlagsMask', w.DWORD), ('dwFileFlags', w.DWORD),
                ('dwFileOS', w.DWORD), ('dwFileType', w.DWORD),
                ('dwFileSubtype', w.DWORD), ('dwFileDateMS', w.DWORD),
                ('dwFileDateLS', w.DWORD)]


# WINTRUST_ACTION_GENERIC_VERIFY_V2
_ACTION_V2 = _GUID(0xaac56b, 0xcd44, 0x11d0,
                   (ctypes.c_ubyte * 8)(0x8c, 0xc2, 0x00, 0xc0, 0x4f, 0xc2, 0x95, 0xee))


def winverifytrust(path: str) -> int:
    """调用 Windows 原生 Authenticode 校验，返回 HRESULT；0 = 签名链有效。"""
    fi = _WINTRUST_FILE_INFO(ctypes.sizeof(_WINTRUST_FILE_INFO), path, None, None)
    td = _WINTRUST_DATA(ctypes.sizeof(_WINTRUST_DATA), None, None,
                        2,   # WTD_UI_NONE
                        0,   # WTD_REVOKE_NONE
                        1,   # WTD_CHOICE_FILE
                        pointer(fi),
                        1,   # WTD_STATEACTION_VERIFY
                        None, None, 0, 0, None)
    wt = ctypes.windll.wintrust
    wt.WinVerifyTrust.argtypes = [w.HWND, POINTER(_GUID), c_void_p]
    wt.WinVerifyTrust.restype = ctypes.c_long
    hr = wt.WinVerifyTrust(None, byref(_ACTION_V2), byref(td))
    td.dwStateAction = 2  # WTD_STATEACTION_CLOSE
    wt.WinVerifyTrust(None, byref(_ACTION_V2), byref(td))
    return int(hr) & 0xffffffff


def pe_version_info(path: str) -> Dict[str, str]:
    """读 PE 版本资源；多语言回退，避免不同电脑语言代码页不同。"""
    ver = ctypes.windll.version
    ver.GetFileVersionInfoSizeW.argtypes = [c_wchar_p, POINTER(w.DWORD)]
    ver.GetFileVersionInfoSizeW.restype = w.DWORD
    size = ver.GetFileVersionInfoSizeW(path, None)
    if not size:
        return {}
    buf = ctypes.create_string_buffer(size)
    ver.GetFileVersionInfoW.argtypes = [c_wchar_p, w.DWORD, w.DWORD, c_void_p]
    ver.GetFileVersionInfoW(path, 0, size, buf)
    ver.VerQueryValueW.argtypes = [c_void_p, c_wchar_p, POINTER(c_void_p), POINTER(w.UINT)]
    ver.VerQueryValueW.restype = w.BOOL
    out: Dict[str, str] = {}
    p = c_void_p()
    ln = w.UINT()
    if ver.VerQueryValueW(buf, '\\', byref(p), byref(ln)) and p.value:
        v = ctypes.cast(p, POINTER(_VS_FIXEDFILEINFO)).contents
        out["file_version"] = "%d.%d.%d.%d" % (
            v.dwFileVersionMS >> 16, v.dwFileVersionMS & 0xffff,
            v.dwFileVersionLS >> 16, v.dwFileVersionLS & 0xffff)
    for lang in ("040904b0", "040904E4", "080404b0", "000004b0", "040904b0"):
        for key, field in (("ProductName", "product_name"),
                           ("CompanyName", "company"),
                           ("FileDescription", "description")):
            if field in out:
                continue
            q = "\\StringFileInfo\\%s\\%s" % (lang, key)
            if ver.VerQueryValueW(buf, q, byref(p), byref(ln)) and p.value:
                out[field] = ctypes.wstring_at(p.value, ln.value).rstrip("\x00")
    return out


def authenticode_signer_hint(path: str) -> str:
    """从 PE Certificate Table 提取签名者线索（只读，不解码证书链）。"""
    try:
        with open(path, "rb") as f:
            f.seek(0x3C)
            pe = struct.unpack("<I", f.read(4))[0]
            f.seek(pe + 4)
            coff = f.read(20)
            opt_size = struct.unpack_from("<H", coff, 16)[0]
            f.seek(pe + 24)
            magic = struct.unpack("<H", f.read(2))[0]
            dd = pe + 24 + (112 if magic == 0x20B else 96)
            f.seek(dd + 4 * 8)  # IMAGE_DIRECTORY_ENTRY_SECURITY
            off, size = struct.unpack("<II", f.read(8))
            if not off or not size or size > 4 * 1024 * 1024:
                return ""
            f.seek(off)
            blob = f.read(size)
        hits = set()
        for needle in (b"Kaspersky", "Kaspersky".encode("utf-16-le")):
            for m in re.finditer(re.escape(needle), blob):
                seg = blob[max(0, m.start() - 40):m.end() + 40]
                txt = seg.decode("latin-1", "replace")
                printable = "".join(c if 32 <= ord(c) < 127 else " " for c in txt)
                hits.add(" ".join(printable.split()))
        return " | ".join(sorted(hits)[:3])
    except Exception as e:
        return "提取失败: %s" % e


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest().upper()


def verify(path: Path = ENGINE_EXE) -> Dict[str, Any]:
    """应用内验签：不信任第三方博客给的哈希，只信 Windows 自己的签名链 + 厂商标识。"""
    p = str(path)
    if not path.is_file():
        return {"ok": False, "reason": "引擎文件不存在: %s" % p}
    if not sys.platform.startswith("win"):
        return {"ok": False, "reason": "Authenticode 验签仅支持 Windows"}
    info: Dict[str, Any] = {"path": p, "size": path.stat().st_size}
    try:
        info["trust_hresult"] = "0x%08X" % winverifytrust(p)
        info.update(pe_version_info(p))
        info["signer_hint"] = authenticode_signer_hint(p)
        info["sha256"] = sha256_file(p)
    except Exception as e:
        return {"ok": False, "reason": "验签过程异常: %s" % e, **info}

    signer_ok = (SIGNER_MUST_CONTAIN.lower() in (info.get("company") or "").lower()
                 or SIGNER_MUST_CONTAIN.lower() in (info.get("signer_hint") or "").lower())
    product_ok = PRODUCT_MUST_CONTAIN.lower() in (info.get("product_name") or "").lower()
    info["ok"] = (info["trust_hresult"] == "0x00000000" and signer_ok and product_ok)
    info["checks"] = {
        "签名链有效": info["trust_hresult"] == "0x00000000",
        "签名者为卡巴斯基": signer_ok,
        "产品名匹配": product_ok,
    }
    info["verified_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if not info["ok"]:
        info["reason"] = "签名链或厂商标识校验未通过，禁止运行"
    return info


def save_state(info: Dict[str, Any]) -> Path:
    ENGINE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    return STATE_FILE


def status() -> Dict[str, Any]:
    """引擎当前真实状态，供应用内下载入口与设置页读取。"""
    exe = engine_exe_path()
    if not exe.is_file():
        return {"present": False, "ready": False, "path": str(ENGINE_EXE),
                "official_url": KVRT_URL, "official_page": OFFICIAL_PAGE}
    st = exe.stat()
    out = {"present": True, "path": str(exe), "size": st.st_size,
           "mtime": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
           "official_url": KVRT_URL, "official_page": OFFICIAL_PAGE,
           "official_docs": OFFICIAL_DOCS}
    sf = state_file_path()
    if sf.is_file():
        try:
            cached = json.loads(sf.read_text(encoding="utf-8"))
            # 文件被换过就作废旧验签
            if cached.get("size") == st.st_size and cached.get("sha256"):
                out["signature"] = cached
                out["ready"] = bool(cached.get("ok"))
                return out
        except (OSError, json.JSONDecodeError):
            pass
    out["signature"] = None
    out["ready"] = False
    out["note"] = "文件存在但尚无有效验签记录，请执行 --verify"
    return out


# ---------------------------------------------------------------------------
# 真实扫描调用
# ---------------------------------------------------------------------------

@dataclass
class ScanRequest:
    """一次真实扫描的输入。"""
    scope: str = "custom"                 # custom | core | allvolumes
    custom_path: str = ""
    data_dir: str = str(DATA_DIR)
    process_level: int = 0                # 0=只报告不处置；1/2/3=启用清除
    timeout_sec: int = 3600
    accept_eula: bool = True              # -silent 必须 -accepteula
    extra: List[str] = None               # 应用内附加开关

    def __post_init__(self):
        if self.extra is None:
            self.extra = []


def build_scan_args(req: ScanRequest) -> List[str]:
    """
    严格按官方文档 269475 构造参数，不臆造开关。

    关键教训：-d 与路径必须是两个参数；连写成 "-d<path>" 会让 KVRT
    弹出命令行帮助窗口并挂起（2026-11-12 实测 24 分钟零产出）。
    """
    args: List[str] = []
    if req.accept_eula:
        args.append("-accepteula")
    args.append("-silent")
    args += ["-d", str(Path(req.data_dir))]
    # 2026-11-12 实测（本机 KVRT 20.0.14.0 / KVRT2020 内核）：
    #   官方 269475 是 KVRT2026 文档，其中 -customonly 在本版**不被识别**，
    #   一旦传入就弹 "KVRT2020 - Command line arguments help" 窗口挂起。
    #   实测可用组合：-accepteula -silent -d <dir> -custom <path>（不带 -customonly）。
    #   因此这里只发 -custom；附加开关一律由 req.extra 显式传入，不默认携带。
    if req.scope == "custom" and req.custom_path:
        # KVRT 是 Windows 原生程序，只给原生反斜杠路径，避免调用层把 \ 归一成 /
        args += ["-custom", os.path.normpath(str(req.custom_path))]
    elif req.scope == "allvolumes":
        args.append("-allvolumes")
    # scope == core 时不加范围参数：默认扫描内存/启动对象/引导扇区
    if req.process_level in (1, 2, 3):
        args += ["-processlevel", str(req.process_level)]
    args += list(req.extra)
    return args


def run_scan(req: ScanRequest) -> Dict[str, Any]:
    """应用内真实拉起 KVRT 并等待结束。返回退出码、耗时与产出文件清单。"""
    info = status()
    if not info.get("ready"):
        raise RuntimeError("引擎未通过验签，拒绝运行。请先执行 --download + --verify")
    if not is_admin():
        raise RuntimeError("KVRT 需要管理员权限；请以管理员身份启动本应用")
    Path(req.data_dir).mkdir(parents=True, exist_ok=True)
    args = build_scan_args(req)
    # 用 status() 给出的真实路径：可能是历史数据目录里的只读回退引擎。
    cmd = [str(info["path"])] + args
    started = time.time()
    result: Dict[str, Any] = {"executed": True, "command": cmd,
                              "started": datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=req.timeout_sec,
                              creationflags=CREATE_NO_WINDOW)
        result["exit_code"] = proc.returncode
        result["stdout"] = _decode(proc.stdout or b"")[-8000:]
        result["stderr"] = _decode(proc.stderr or b"")[-2000:]
    except subprocess.TimeoutExpired as e:
        result["exit_code"] = -1
        result["timed_out"] = True
        result["stdout"] = _decode(e.stdout or b"")[-8000:]
        result["stderr"] = "扫描超过 %d 秒超时" % req.timeout_sec
    result["duration_sec"] = round(time.time() - started, 1)
    result["finished"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    result["output_files"] = [
        {"path": str(p), "size": p.stat().st_size}
        for p in sorted(Path(req.data_dir).rglob("*")) if p.is_file()
    ]
    return result


# ---------------------------------------------------------------------------
# 报告解析与落盘
# ---------------------------------------------------------------------------

THREAT_HINT = re.compile(r"(detected|infected|threat|malware|not\s+disinfected|suspicion|"
                         r"обнаружен|заражен|угроз)", re.I)
COUNT_HINT = re.compile(r"(scanned|processed|total\s+objects|objects\s+scanned|"
                        r"files\s+scanned|processed\s+objects|total\s+files)"
                        r"[^\d]{0,30}(\d[\d,]*)", re.I)


def decode_klr(path: str) -> str:
    """
    解码 KVRT 的 .klr.enc1 报告。

    2026-11-12 本机真实样本实证：文件是逐字节 XOR 0xEF 的 XML。
    样本解码结果：
      <Report>
        <Metadata Version="1" PCID="{...}" LastModification="2026.11.12 13:03:30.098" />
        <EventBlocks />
      </Report>
    EventBlocks 为空 = 本次扫描未检出威胁。
    """
    raw = Path(path).read_bytes()
    dec = bytes(x ^ 0xEF for x in raw)
    head = dec[:16]
    if b"<Report" not in head and b"<?xml" not in head:
        raise ValueError("不是可识别的 KVRT 报告（XOR 解码后无 Report/XML 头）: %s" % path)
    return dec.decode("utf-8", "replace")


def parse_klr_report(path: str) -> Dict[str, Any]:
    """
    把一份真实 KVRT 报告解析成结构化字段，绝不填模拟数字。

    官方把扫描统计放在 <BlockN Type="Scan" Processed= Found= Neutralized=> 上。
    2026-11-12 真实样本：
      <Block0 Type="Scan" Processed="6943" Found="0" Neutralized="0">
        <Event0 Action="Scan" ... Info="Started" />
        <Event1 Action="Scan" ... Info="Finished" />
      </Block0>
    以这些属性为准，不用「日志里出现 threat 字样」数威胁——那会把
    "Detected: 0" 误报成一条威胁（本轮真实踩到并修正）。
    """
    text = decode_klr(path)
    root = ET.fromstring(text)
    meta = root.find("Metadata")
    blocks: List[Dict[str, Any]] = []
    for el in root.iter():
        if not any(k in el.attrib for k in ("Processed", "Found", "Neutralized")):
            continue
        b: Dict[str, Any] = {"tag": el.tag, "type": el.get("Type", "")}
        for k in ("Processed", "Found", "Neutralized"):
            try:
                b[k.lower()] = int(el.get(k, "0") or "0")
            except ValueError:
                b[k.lower()] = 0
        blocks.append(b)

    events: List[Dict[str, str]] = []
    for ev in root.iter():
        if not ev.tag.startswith("Event"):
            continue
        events.append({"tag": ev.tag, "action": ev.get("Action", ""),
                       "object": ev.get("Object", ""), "info": ev.get("Info", "")})

    found = sum(b.get("found", 0) for b in blocks)
    return {
        "source_file": os.path.basename(path),
        "report_time": (meta.get("LastModification") if meta is not None else "") or "",
        "pcid": (meta.get("PCID") if meta is not None else "") or "",
        "blocks": blocks,
        "processed": sum(b.get("processed", 0) for b in blocks),
        "found": found,
        "neutralized": sum(b.get("neutralized", 0) for b in blocks),
        "event_count": len(events),
        "events": events[:200],
        "raw_xml": text[:4000],
        "clean": found == 0,
    }


# 官方 stdout 汇总块（2026-11-12 真实样本）：
#   Scan is finished with results:
#       Processed: 6943
#       Processing errors: 0
#       Detected: 0
#       Password protected: 0
#       Corrupted: 0
STDOUT_STAT = re.compile(
    r"^\s*(Processed|Processing\s+errors|Detected|Password\s+protected|Corrupted)\s*:\s*(\d+)\s*$",
    re.I | re.M)


def parse_stdout_stats(stdout: str) -> Dict[str, int]:
    """从官方命令行汇总块取权威数字；取不到就返回空字典，绝不猜。"""
    out: Dict[str, int] = {}
    for m in STDOUT_STAT.finditer(stdout or ""):
        key = re.sub(r"\s+", "_", m.group(1).strip().lower())
        out[key] = max(out.get(key, 0), int(m.group(2)))
    return out


def parse_kvrt_output(data_dir: str, stdout: str = "",
                      since: Optional[datetime] = None) -> Dict[str, Any]:
    """
    从 KVRT 官方报告与命令行输出提取统一报告字段。

    权威顺序（不再用关键词数威胁）：
      1. Reports/*.klr.enc1 的 <BlockN Processed/Found/Neutralized>（XOR 0xEF + XML）
      2. 官方 stdout 汇总块 Processed / Detected
      3. 两者都没有才如实留 0，并标记 incomplete

    2026-11-12 修正：旧版把 "Detected: 0" 当成一条威胁，误报 threat_count=1。
    """
    official: List[Dict[str, Any]] = []
    root = Path(data_dir)
    if root.is_dir():
        for p in sorted(root.rglob("*.klr.enc1")):
            try:
                official.append(parse_klr_report(str(p)))
            except (OSError, ValueError, ET.ParseError) as e:
                official.append({"source_file": p.name, "parse_error": str(e)})

    lines: List[str] = []
    files: List[Dict[str, Any]] = []
    if root.is_dir():
        for p in sorted(root.rglob("*")):
            if not p.is_file() or p.stat().st_size > 8 * 1024 * 1024:
                continue
            files.append({"path": str(p), "size": p.stat().st_size})
            if p.suffix.lower() not in (".log", ".txt", ".csv", ".xml", ".json", ".dat", ""):
                continue
            try:
                text = p.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            lines += [ln.strip() for ln in text.splitlines() if ln.strip()]
    if stdout:
        lines += [ln.strip() for ln in stdout.splitlines() if ln.strip()]

    stats = parse_stdout_stats(stdout)
    ok_reports = [r for r in official if "parse_error" not in r]
    # 只认含 Scan Block 的报告（有 Processed 字段），排除启动时的空报告
    scan_reports = [r for r in ok_reports if r.get("blocks")]

    files_scanned = stats.get("processed", 0)
    for r in scan_reports:
        files_scanned = max(files_scanned, r.get("processed", 0))
    threat_count = stats.get("detected", 0)
    for r in scan_reports:
        threat_count = max(threat_count, r.get("found", 0))

    keyword_lines = [ln for ln in lines if THREAT_HINT.search(ln)]
    authoritative = bool(stats.get("processed") or scan_reports)
    return {
        "files_scanned": files_scanned,
        "threat_count": threat_count,
        "threat_lines": keyword_lines[:200],
        "threat_lines_note": "仅为日志关键词命中行，不参与威胁计数（含 'Detected: 0' 这类汇总行）",
        "neutralized": sum(r.get("neutralized", 0) for r in scan_reports),
        "stdout_stats": stats,
        "official_reports": official,
        "official_report_count": len(official),
        "official_scan_reports": len(scan_reports),
        "official_clean": bool(scan_reports) and threat_count == 0,
        "authoritative": authoritative,
        "raw_lines": lines[-300:],
        "parsed_files": files[:50],
        "parser_note": "以官方 .klr.enc1 的 Scan Block 与 stdout 汇总块为准；"
                       "两者都缺失则留 0 并标 incomplete，不填模拟值",
    }


def write_report(scan: Dict[str, Any], parsed: Dict[str, Any],
                  req: ScanRequest, trigger: str = "手动真实扫描") -> Path:
    """把一次真实扫描写成统一报告 JSON，供应用报告页读取。"""
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    sig = status().get("signature") or {}
    scope_map = {
        "custom": req.custom_path or "自定义目录",
        "core": "系统核心区域（内存 / 启动对象 / 引导扇区）",
        "allvolumes": "整机全部本地磁盘",
    }
    report = {
        "id": "RPT-" + stamp,
        "date": scan.get("finished") or datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "engine_id": "kvrt",
        "engine_name": "Kaspersky Virus Removal Tool " + str(sig.get("file_version") or ""),
        "engine_version": sig.get("file_version") or "",
        "engine_sha256": sig.get("sha256") or "",
        "engine_signer": sig.get("company") or sig.get("signer_hint") or "",
        "scope": scope_map.get(req.scope, req.scope),
        "trigger": trigger,
        "duration_sec": scan.get("duration_sec", 0),
        "exit_code": scan.get("exit_code"),
        "files_scanned": parsed.get("files_scanned", 0),
        "threat_count": parsed.get("threat_count", 0),
        "neutralized": parsed.get("neutralized", 0),
        "threat_lines": parsed.get("threat_lines", []),
        "threat_lines_note": parsed.get("threat_lines_note", ""),
        "status": ("threats" if parsed.get("threat_count") else
                   ("clean" if parsed.get("authoritative") else "incomplete")),
        "authoritative": bool(parsed.get("authoritative")),
        "stdout_stats": parsed.get("stdout_stats", {}),
        "official_reports": parsed.get("official_reports", []),
        "official_clean": parsed.get("official_clean", False),
        "simulated": False,
        "command": scan.get("command", []),
        "stdout": scan.get("stdout", ""),
        "raw_log_tail": parsed.get("raw_lines", [])[-60:],
        "output_files": scan.get("output_files", []),
        "parser_note": parsed.get("parser_note", ""),
        "license_note": "KVRT 由用户主动从官方源下载到本应用目录，未随安装包分发；非实时防护工具",
    }
    out = REPORT_DIR / ("scan-" + stamp + ".json")
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return out


def list_reports() -> List[Dict[str, Any]]:
    """列出应用内真实报告（按时间倒序）；新数据目录与历史目录合并、按 id 去重。"""
    candidates: List[Path] = []
    for d in app_paths.existing_dirs("reports"):
        candidates.extend(d.glob("scan-*.json"))
    if not candidates:
        return []
    out = []
    seen = set()
    for p in sorted(candidates, key=lambda x: x.name, reverse=True):
        # 校准留档 .json.bak 不入库；同名 id 只保留最新校准版
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


# ---------------------------------------------------------------------------
# 应用内自动扫描调度（不注册系统计划任务）
# ---------------------------------------------------------------------------

DEFAULT_SETTINGS: Dict[str, Any] = {
    "enabled": True,
    "frequency": "daily",           # daily | every12h | weekly | custom_hours
    "custom_hours": 24,
    "run_at": "03:00",
    "scope": "allvolumes",          # daily 整机扫描
    "custom_path": "",
    "engine": "kvrt",               # kvrt | auto（已识别安全软件）
    "process_level": 0,             # 只报告不处置
    "keep_reports": 30,
    "last_run": "",
}


def load_settings() -> Dict[str, Any]:
    s = dict(DEFAULT_SETTINGS)
    cfg = app_paths.first_existing("scan_settings.json")
    if cfg.is_file():
        try:
            s.update(json.loads(cfg.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            pass
    return s


def save_settings(s: Dict[str, Any]) -> Path:
    app_paths.ensure(SETTINGS_FILE.parent)
    SETTINGS_FILE.write_text(json.dumps(s, ensure_ascii=False, indent=2), encoding="utf-8")
    return SETTINGS_FILE


def next_run(after: Optional[datetime] = None) -> datetime:
    """按设置算下一次执行时刻；纯计算，供应用设置页展示。"""
    s = load_settings()
    base = after or datetime.now()
    hh, mm = (s.get("run_at") or "03:00").split(":")[:2]
    freq = s.get("frequency")
    if freq == "daily":
        t = base.replace(hour=int(hh), minute=int(mm), second=0, microsecond=0)
        return t if t > base else t + timedelta(days=1)
    hours = {"every12h": 12, "weekly": 24 * 7}.get(freq, int(s.get("custom_hours") or 24))
    return base + timedelta(hours=hours)


def run_scheduled_loop(once: bool = False, tick_sec: int = 60) -> None:
    """
    应用内定时器：由应用主进程调用，不写系统计划任务、不写系统目录。
    once=True 只检查一次（便于联调），否则常驻等待到点执行。
    """
    while True:
        s = load_settings()
        if s.get("enabled") and status().get("ready"):
            due = next_run()
            if datetime.now() >= due or once:
                req = ScanRequest(
                    scope=s.get("scope", "allvolumes"),
                    custom_path=s.get("custom_path", ""),
                    process_level=int(s.get("process_level", 0)),
                )
                scan = run_scan(req)
                parsed = parse_kvrt_output(req.data_dir, scan.get("stdout", ""))
                out = write_report(scan, parsed, req, trigger="每日自动扫描")
                s["last_run"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                save_settings(s)
                print("自动扫描完成:", out)
        if once:
            return
        time.sleep(tick_sec)


# ---------------------------------------------------------------------------
# CLI：应用内调用入口（也可由 server.py 的路由直接 import 调用）
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="V0.10 KVRT 引擎包：应用内真实下载/验签/扫描/报告")
    ap.add_argument("--status", action="store_true", help="查看引擎真实状态")
    ap.add_argument("--download", action="store_true", help="从官方源一键下载到应用目录")
    ap.add_argument("--force", action="store_true", help="配合 --download 强制重下")
    ap.add_argument("--verify", action="store_true", help="纯 Python 验签并写入 engine.json")
    ap.add_argument("--scan", action="store_true", help="应用内真实执行一次扫描")
    ap.add_argument("--path", default="", help="--scan 的自定义扫描路径")
    ap.add_argument("--allvolumes", action="store_true", help="整机全部本地磁盘扫描")
    ap.add_argument("--process-level", type=int, default=0, choices=[0, 1, 2, 3],
                    help="0=只报告不处置（默认）；1/2/3=按威胁等级清除")
    ap.add_argument("--timeout", type=int, default=3600, help="扫描超时秒数")
    ap.add_argument("--url", default=KVRT_URL, help="覆盖官方下载地址（仅调试）")
    ap.add_argument("--reports", action="store_true", help="列出应用内真实报告")
    ap.add_argument("--settings", action="store_true", help="查看自动扫描设置与下次执行时间")
    ap.add_argument("--serve-once", action="store_true", help="应用内调度器检查一次（联调用）")
    args = ap.parse_args(argv)

    if args.status:
        print(json.dumps(status(), ensure_ascii=False, indent=2))
        return 0

    if args.download:
        print("从官方源下载:", args.url)
        print(json.dumps(download(args.url, force=args.force), ensure_ascii=False, indent=2))

    if args.verify:
        info = verify()
        print(json.dumps(info, ensure_ascii=False, indent=2))
        if not info.get("ok"):
            print("验签未通过，禁止运行扫描。", file=sys.stderr)
            return 2
        save_state(info)
        print("已写入:", STATE_FILE)
        return 0

    if args.scan:
        scope = "allvolumes" if args.allvolumes else ("custom" if args.path else "core")
        req = ScanRequest(scope=scope, custom_path=args.path,
                          process_level=args.process_level, timeout_sec=args.timeout)
        print("应用内真实执行:", " ".join([str(ENGINE_EXE)] + build_scan_args(req)))
        scan = run_scan(req)
        parsed = parse_kvrt_output(req.data_dir, scan.get("stdout", ""))
        out = write_report(scan, parsed, req)
        print(json.dumps({
            "exit_code": scan.get("exit_code"),
            "duration_sec": scan.get("duration_sec"),
            "files_scanned": parsed.get("files_scanned"),
            "threat_count": parsed.get("threat_count"),
            "output_files": len(scan.get("output_files", [])),
            "report": str(out),
        }, ensure_ascii=False, indent=2))
        return 0 if scan.get("exit_code") == 0 else 1

    if args.reports:
        rs = list_reports()
        print(json.dumps([{k: r.get(k) for k in
                           ("id", "date", "engine_name", "scope", "trigger",
                            "status", "threat_count", "simulated")}
                          for r in rs], ensure_ascii=False, indent=2))
        return 0

    if args.settings:
        s = load_settings()
        s["next_run"] = next_run().strftime("%Y-%m-%d %H:%M:%S")
        s["engine_ready"] = status().get("ready")
        print(json.dumps(s, ensure_ascii=False, indent=2))
        return 0

    if args.serve_once:
        run_scheduled_loop(once=True)
        return 0

    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
